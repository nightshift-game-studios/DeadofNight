extends SceneTree
## Merchant (Skillz, DESIGN.md §20): data, fake-clock hourly refresh (top of the hour, rollback guard, forward jump,
## re-anchor), deterministic stock, reroll escalation + reset, buy + every refusal reason, stash cap, Gravemark
## deduction, persistence round-trip, save v4 -> v5 migration, crash-safe .tmp / .bak (incl. files copied forward
## by SaveMigration), API shape vs MERCHANT_API.md (+ Gooey's merchant_api.gd names when present).
##   godot --headless --path . -s res://tests/merchant_test.gd   (exit code = failures)
## Works in user://merchant_test/, never touches the real save.

const MERCHANT_PATH := "res://scripts/merchant/merchant.gd" ## load()ed at run time (a preload compiles GearDB users before the autoloads exist)
const INVENTORY_PATH := "res://scripts/items/inventory.gd"
const MigrationScript := preload("res://scripts/autoload/save_migration.gd")
const API_DOC := "/workspace/skillz/MERCHANT_API.md" ## read when present (dev box); the hard-coded lists below always run
const H := 3600.0

var _fails := 0
var _passes := 0
var fc := {"t": 0.0, "ms": 0}
var sig := []


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _new_merchant() -> Node:
	var m: Node = load(MERCHANT_PATH).new()
	m.clock = func(): return fc.t
	m.ticks = func(): return fc.ms
	m.stock_changed.connect(func(r): sig.append(["stock", r]))
	m.refreshed.connect(func(): sig.append(["refreshed"]))
	m.reroll_cost_changed.connect(func(c): sig.append(["cost", c]))
	m.purchased.connect(func(o, w, p): sig.append(["bought", o, w, p]))
	return m


func _count(kind: String, arg = null) -> int:
	return sig.filter(func(s): return s[0] == kind and (arg == null or s[1] == arg)).size()


func _ids(m: Node) -> Array:
	return m.get_stock().map(func(o): return str(o.offer_id))


func _sigs(m: Node) -> Array:
	return m.get_stock().map(func(o): return [o.archetype, o.rarity, o.item_power, o.item.display_name, Array(o.perks), o.item.stats, o.price])


func _rm_all(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_rm_all(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _stash_ids(st: Dictionary) -> Array:
	var out := []
	for s in st.get("equipped", {}):
		if typeof(st.equipped[s]) == TYPE_DICTIONARY:
			out.append(str(st.equipped[s].get("item_id", "")))
	for s in st.get("backpack", {}):
		for d in st.backpack[s]:
			out.append(str(d.get("item_id", "")))
	return out


func _gdb() -> Node:
	return root.get_node("GearDB")


func _reset(prog: Node, path: String) -> void:
	prog.save_path = path
	for suf in ["", ".tmp", ".bak", ".corrupt"]:
		DirAccess.remove_absolute(path + suf)
	prog.gravemarks = 0
	prog.gravemarks_lifetime = 0
	prog.stash = {}
	prog.merchant = {}
	prog.bind_inventory(null)


func _inventory() -> Node:
	var inv: Node = load(INVENTORY_PATH).new()
	root.add_child(inv)
	inv.give_fresh_starter_loadout()
	inv.add_item(_gdb().roll_weapon("sniper_rifle", Rarity.COMMON, 1))
	return inv


func _offer(m: Node, pred: Callable) -> Dictionary:
	for o in m.get_stock():
		if pred.call(o):
			return o
	return {}


func _run() -> void:
	var prog: Node = root.get_node("Progress")
	var real_path: String = prog.save_path
	var real_merchant: Dictionary = prog.merchant.duplicate(true)
	var real_bal: int = prog.gravemarks
	var dir := OS.get_user_data_dir().path_join("merchant_test")
	_rm_all(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("progress.cfg")
	_reset(prog, path)

	# ------------------------------------------------------------ data + design table
	var m := _new_merchant()
	check(m.data.get("version", 0) == 1 and m.stock_size() == 5, "data/merchant.json loads, stock_size 5")
	# Jason's retune (2026-10-19): "not too cheap, rewarding". Targets in Hard matches (Armory income ~14 / match).
	var A = load("res://scripts/armory/armory.gd")
	var inc_ok := true
	for d in ["easy", "medium", "hard"]:
		inc_ok = inc_ok and absf(m.income_per_match(d) - float(A.matches_to_max(d).per_match)) < 1e-6
	# Economy v2 (DESIGN §21): income per typical match (Easy r12 / Medium r10 / Hard r8) is now ~12 / ~15 / ~16
	check(inc_ok and m.income_per_match("easy") >= 9.0 and m.income_per_match("easy") <= 14.0 and m.income_per_match("medium") >= 12.0
		and m.income_per_match("medium") <= 17.0 and m.income_per_match("hard") >= 13.0 and m.income_per_match("hard") <= 19.0,
		"income from Armory.expected_match_income: %.2f / %.2f / %.2f" % [m.income_per_match("easy"), m.income_per_match("medium"), m.income_per_match("hard")])
	# Economy v2: one price_mult (0.5) over the retuned table prices 13 / 28 / 63 / 154 / 315
	var base_prices := [13, 28, 63, 154, 315]
	var pm_ok := absf(m.price_mult() - 0.5) < 1e-6
	for r in 5:
		pm_ok = pm_ok and m.price_for(r) == maxi(int(round(base_prices[r] * 0.5)), 1)
	check(pm_ok, "price_mult 0.5 halves every price: %s" % [[0, 1, 2, 3, 4].map(func(r): return m.price_for(r))])
	var med := [0, 1, 2, 3, 4].map(func(r): return m.matches_to_afford(m.price_for(r), "medium"))
	var bands := [[0.3, 0.7], [0.6, 1.2], [1.5, 2.8], [3.8, 6.5], [8.0, 13.5]]
	var band_ok := true
	for r in 5:
		band_ok = band_ok and med[r] >= bands[r][0] and med[r] <= bands[r][1]
	check(band_ok, "prices in Medium matches %s (targets ~0.5 / ~1 / ~2 / ~5 / ~10)" % [med.map(func(x): return snappedf(x, 0.01))])
	var feat_ok := true
	for r in range(2, 5):
		feat_ok = feat_ok and absi(m.price_for(r, true) - int(round(m.price_for(r) * 1.15))) <= 1
	check(feat_ok and float(m.data.featured_bonus.price_mult) == 1.15, "featured slot stays x1.15: %d / %d / %d" % [m.price_for(2, true), m.price_for(3, true), m.price_for(4, true)])
	check([0, 1, 2, 3, 4, 5, 6].map(func(n): return m.cost_for_reroll(n)) == [5, 9, 15, 24, 36, 51, 66], "reroll costs 5,9,15,24,36 then +15")
	check(m.matches_to_afford(m.cost_for_reroll(0), "hard") >= 0.3 and m.cost_for_reroll(0) < m.price_for(0) and m.cost_for_reroll(3) > m.price_for(1) * 0.8,
		"rerolls matter: first ~1/3 Hard match, below a Common; the 4th costs about an Uncommon")
	var o0: Array = m.slot_odds(0)
	var o1: Array = m.slot_odds(1)
	check(m.slot_featured(0) and not m.slot_featured(1) and o0[0] == 0.0 and o0[1] == 0.0, "slot 0 featured, Rare or better")
	check(o1[4] <= 0.02 and o0[4] <= 0.1 and absf(o1.reduce(func(a, b): return a + b, 0.0) - 1.0) < 1e-6, "Mythic is rare (%.1f%% featured, %.1f%% regular)" % [o0[4] * 100, o1[4] * 100])
	var tbl: Array = m.design_table()
	for row in tbl:
		print("  table: %s IP %s perks %d (playstyle >= %d, roll q >= %.2f) price %d (featured %d) odds F %.1f%% / R %.1f%% matches e/m/h %.1f / %.1f / %.1f (featured %.1f / %.1f / %.1f)" % [
			row.rarity, row.ip, row.perks, row.playstyle_min, row.roll_quality_floor, row.price, row.featured_price, row.odds_featured * 100, row.odds_regular * 100,
			row.matches.easy, row.matches.medium, row.matches.hard, row.matches_featured.easy, row.matches_featured.medium, row.matches_featured.hard])
	for row in m.reroll_table(7):
		print("  reroll #%d: %d GM = %.2f / %.2f / %.2f matches" % [row.n, row.cost, row.matches.easy, row.matches.medium, row.matches.hard])
	check(tbl.size() == 5 and tbl[0].matches.medium <= 1.0 and tbl[4].matches.easy >= 8.0 and tbl[3].matches_featured.hard > tbl[3].matches.hard,
		"matches-to-buy table: Common within 1 Medium match, Mythic 8+ Easy matches, featured costs more")
	var ips_ok := true
	for r in 4:
		ips_ok = ips_ok and int(m.rarity_cfg(r + 1).item_power[0]) > int(m.rarity_cfg(r).item_power[-1])
	check(ips_ok, "item power rises with rarity")
	# Legendary / Mythic beat what drops in-run: highest drop IP at the end of a typical match (+ variance)
	var ipc: Dictionary = root.get_node("GearDB").item_power_cfg()
	var typical: Dictionary = A.cfg().expected.typical_rounds
	var max_rounds: int = typical.values().reduce(func(a, b): return maxi(int(a), int(b)), 0)
	var drop_max := func(rid: String) -> int:
		return int(ipc.base) + int(ipc.per_round) * (max_rounds - 1) + int(ipc.rarity_bonus[rid]) + int(ipc.variance)
	check(int(m.rarity_cfg(3).item_power[0]) > drop_max.call("legendary") and int(m.rarity_cfg(4).item_power[0]) > drop_max.call("mythic") + 5,
		"IP floors beat in-run drops at round %d: Legendary %d > %d, Mythic %d > %d" % [max_rounds, int(m.rarity_cfg(3).item_power[0]), drop_max.call("legendary"),
		int(m.rarity_cfg(4).item_power[0]), drop_max.call("mythic")])
	var gdbp: Dictionary = root.get_node("GearDB").perks
	var play_ids: Array = gdbp.keys().filter(func(k): return bool(gdbp[k].get("playstyle", false)))
	check(play_ids.size() >= 3 and gdbp.keys().all(func(k): return gdbp[k].has("playstyle") or gdbp[k].get("signature", false)), "perks.json tags playstyle perks (%s)" % [play_ids])
	var sig_ids: Array = m.signature_perks()
	check(m.data.mythic_signature_perks.size() >= 2, "data names %d Mythic signature perks" % m.data.mythic_signature_perks.size())
	if sig_ids.is_empty():
		print("  (signature perks not in GearDB.perks: MAIN_HOOKS §19c not applied; Mythic offers carry no signature yet)")
	else:
		check(sig_ids.all(func(k): return bool(gdbp[k].get("signature", false))), "signature perks are flagged signature (kept out of random drops)")
		var leaks := 0
		for k in 300:
			var drop = root.get_node("GearDB").roll_weapon("", Rarity.MYTHIC, 10)
			leaks += drop.perks.filter(func(id): return id in sig_ids).size()
		check(leaks == 0, "300 random Mythic drops carry no signature perk (GearDB filter, §19c)")

	# ------------------------------------------------------------ API shape (MERCHANT_API.md)
	var methods := ["get_stock", "buy_check", "buy", "reroll_cost", "reroll_check", "reroll", "time_to_refresh", "refresh_if_due", "last_refusal_reason"]
	var signals := {"stock_changed": 1, "purchased": 3, "refreshed": 0, "reroll_cost_changed": 1}
	check(methods.all(func(n): return m.has_method(n)), "every MERCHANT_API.md method exists")
	var sig_ok := true
	for s in m.get_signal_list():
		if signals.has(s.name):
			sig_ok = sig_ok and s.args.size() == signals[s.name]
	check(sig_ok and signals.keys().all(func(n): return m.has_signal(n)), "every signal exists with its arg count")
	if FileAccess.file_exists(API_DOC):
		var doc := FileAccess.get_file_as_string(API_DOC)
		var rx := RegEx.create_from_string("Merchant\\.([a-z_]+)\\(")
		var named: Array = []
		for mt in rx.search_all(doc):
			named.append(mt.get_string(1))
		var rs := RegEx.create_from_string("- `([a-z_]+)\\(")
		var signames: Array = []
		var sig_sec := doc.substr(doc.find("## Signals"))
		sig_sec = sig_sec.substr(0, sig_sec.find("\n## ", 4)) if sig_sec.find("\n## ", 4) > 0 else sig_sec
		for mt in rs.search_all(sig_sec):
			signames.append(mt.get_string(1))
		check(named.size() >= 8 and named.all(func(n): return m.has_method(n)), "MERCHANT_API.md calls all implemented (%s)" % [named])
		check(signames.size() == 4 and signames.all(func(n): return m.has_signal(n)), "MERCHANT_API.md signals all implemented (%s)" % [signames])
		for r in ["Sold out", "Not enough Gravemarks (need N)", "Stash full (40/40)", "Stock expired"]:
			check(doc.contains(r), "doc reason: %s" % r)
	else:
		print("  (MERCHANT_API.md not on this machine: doc parse skipped)")
	check(m.R_SOLD == "Sold out" and m.R_FUNDS % 9 == "Not enough Gravemarks (need 9)" and m.R_STASH % [40, 40] == "Stash full (40/40)" and m.R_EXPIRED == "Stock expired",
		"reason strings match MERCHANT_API.md exactly")
	if ResourceLoader.exists("res://scripts/ui/merchant_api.gd"):
		var MAPI = load("res://scripts/ui/merchant_api.gd")
		check(MAPI.METHODS.values().all(func(n): return m.has_method(n)) and MAPI.SIGNALS.values().all(func(n): return m.has_signal(n)),
			"Gooey's merchant_api.gd METHODS / SIGNALS all resolve on the real Merchant")
		var api = MAPI.create()
		check(api != null and not MAPI.is_stub(api), "MerchantAPI.create() picks the real Merchant")

	# ------------------------------------------------------------ first roll + top-of-hour alignment
	var h0 := 490000.0 * H # an hour boundary
	fc.t = h0 + 1234.0
	check(m.refresh_if_due() == true and _count("refreshed") == 1 and _count("stock", "refresh") == 1, "first call rolls the stock (refresh)")
	var st: Dictionary = prog.merchant
	check(int(st.hour_index) == 490000 and m.time_to_refresh() == 3600 - 1234, "aligned to the top of the hour: %ds left" % m.time_to_refresh())
	var stock: Array = m.get_stock()
	check(stock.size() == 5, "5 offers")
	var keys := ["offer_id", "slot", "item", "archetype", "rarity", "item_power", "perks", "price", "sold", "owned", "can_afford", "reason"]
	var shape_ok := true
	for o in stock:
		shape_ok = shape_ok and keys.all(func(k): return o.has(k)) and o.item != null and o.item.has_method("card_stats") and typeof(o.offer_id) == TYPE_STRING \
			and typeof(o.perks) == TYPE_ARRAY and typeof(o.price) == TYPE_INT and o.sold == false and o.item.seen == false
	check(shape_ok, "offer dicts carry every MERCHANT_API.md key with the right types (preview items unseen)")
	check(stock.map(func(o): return o.slot) == [0, 1, 2, 3, 4] and stock[0].featured and stock[0].rarity >= Rarity.RARE, "slots 0..4, slot 0 featured Rare+")
	var archs := stock.map(func(o): return o.archetype)
	var uniq := {}
	for a in archs:
		uniq[a] = true
	check(uniq.size() == 5, "no duplicate archetypes in one stock %s" % [archs])
	check(stock.all(func(o): return o.reason == "Not enough Gravemarks (need %d)" % o.price and not o.can_afford), "0 Gravemarks: every offer says need N")
	var ids0 := _ids(m)
	fc.t = h0 + H - 1.0
	check(m.refresh_if_due() == false and m.time_to_refresh() == 1 and _ids(m) == ids0, "1 s before the hour: no refresh, 1 s left")
	fc.t = h0 + H
	check(m.refresh_if_due() == true and _ids(m) != ids0 and int(prog.merchant.hour_index) == 490001 and m.time_to_refresh() == 3600,
		"exactly at the top of the hour: refresh, full hour left")
	check(_count("refreshed") == 2 and _count("stock", "refresh") == 2 and m.refresh_if_due() == false, "refreshed + stock_changed(refresh) once per hour")

	# ------------------------------------------------------------ rollback guard
	var ids1 := _ids(m)
	fc.t = h0 + H + 600.0
	m.refresh_if_due()
	m.reset_session_clock() # "restart the game"
	fc.t = h0 - 2.0 * H # clock set back 3 h
	check(m.refresh_if_due() == false and _ids(m) == ids1, "clock back 3 h: no refresh")
	check(m.time_to_refresh() == 3000, "timer frozen at the last trusted time (%ds, expected 3000)" % m.time_to_refresh())
	fc.t = h0 + 2.0 * H - 1.0
	check(m.refresh_if_due() == false, "clock returns to normal: still the same hour until its end")
	fc.t = h0 + 2.0 * H
	check(m.refresh_if_due() == true, "then refreshes at the normal top of the hour")
	# in-session rollback: the monotonic clock keeps the timer going
	fc.t = h0 + 2.0 * H + 100.0
	m.refresh_if_due()
	var ids2 := _ids(m)
	fc.t -= 5000.0
	fc.ms += 1000 * 1700
	check(m.refresh_if_due() == false and m.time_to_refresh() == 3600 - 1800, "in-session rollback: countdown keeps going on the monotonic clock (%ds)" % m.time_to_refresh())
	fc.ms += 1000 * 1800
	check(m.refresh_if_due() == true and _ids(m) != ids2, "in-session rollback: refresh after a real hour, not early, not never")
	m.reset_session_clock()
	fc.t = h0 + 3.0 * H + 10.0
	m.refresh_if_due()

	# ------------------------------------------------------------ forward jump + re-anchor
	sig.clear()
	var ids3 := _ids(m)
	fc.t = h0 + 3.0 * H + 10.0 + 10.0 * 365.0 * 86400.0
	check(m.refresh_if_due() == true and m.refresh_if_due() == false and _count("refreshed") == 1, "clock +10 years: exactly one refresh")
	var ids4 := _ids(m)
	check(ids4 != ids3, "forward jump rolled new stock")
	fc.t = h0 + 3.0 * H + 20.0 # the player fixes the clock
	check(m.refresh_if_due() == false and _ids(m) == ids4, "clock corrected (back 10 years): stock kept, no refresh")
	check(m.time_to_refresh() == 3600 - 20 and int(prog.merchant.hour_index) == 490003, "re-anchored to the real clock (%ds left)" % m.time_to_refresh())
	fc.t = h0 + 4.0 * H
	check(m.refresh_if_due() == true, "next real top of the hour refreshes again")
	fc.t = h0 + 4.0 * H + 1.0
	m.refresh_if_due()

	# ------------------------------------------------------------ deterministic stock
	var seed_state: Dictionary = {"version": 1, "seed": 4242}
	prog.merchant = seed_state.duplicate(true)
	var ma := _new_merchant()
	ma.refresh_if_due()
	var sa := _sigs(ma)
	prog.merchant = seed_state.duplicate(true)
	var mb := _new_merchant()
	mb.refresh_if_due()
	check(_sigs(mb) == sa, "same seed + refresh index -> identical stock (rarity, archetype, IP, name, perks, stats)")
	fc.t += H
	mb.refresh_if_due()
	check(_sigs(mb) != sa, "next refresh index -> different stock")
	ma.free()
	mb.free()

	# ------------------------------------------------------------ rarity / IP / perks over many refreshes
	prog.merchant = {"version": 1, "seed": 99}
	var mr := _new_merchant()
	var counts := [[0, 0, 0, 0, 0], [0, 0, 0, 0, 0]]
	var bad := []
	var n_hours := 100
	var low_q := []
	var no_play := []
	var commons := []
	var mythics := 0
	for i in n_hours:
		fc.t += H
		mr.refresh_if_due()
		for o in mr.get_stock():
			var r: int = o.rarity
			counts[0 if o.featured else 1][r] += 1
			var c: Dictionary = mr.rarity_cfg(r)
			var fb := 4 if o.featured else 0
			var want_perks: int = Rarity.PERK_SLOTS[r] + (1 if r == Rarity.MYTHIC else 0) + (1 if o.featured else 0) \
				+ (1 if r == Rarity.MYTHIC and not sig_ids.is_empty() else 0)
			if o.item.roll_quality < float(c.roll_quality_floor):
				low_q.append([r, o.item.roll_quality])
			var n_play: int = o.perks.filter(func(k): return mr.is_playstyle_perk(k)).size()
			if n_play < int(c.playstyle_perks_min):
				no_play.append([r, o.perks])
			if r == Rarity.MYTHIC:
				mythics += 1
				var mp = o.item.arch.get("mythic", {}).get("perk", "")
				if mp != "" and o.perks[0] != mp:
					bad.append(["mythic perk", o.perks])
				if not sig_ids.is_empty() and o.perks.filter(func(k): return k in sig_ids).size() != 1:
					bad.append(["signature", o.perks])
			if r < Rarity.MYTHIC and o.perks.any(func(k): return bool(gdbp[k].get("signature", false))):
				bad.append(["signature below Mythic", o.perks])
			if r == Rarity.COMMON:
				commons.append(o.item)
			if o.item_power < int(c.item_power[0]) + fb or o.item_power > int(c.item_power[1]) + fb or o.perks.size() != want_perks \
					or o.price != mr.price_for(r, o.featured) or o.item.rarity != r:
				bad.append([o.slot, r, o.item_power, o.perks.size(), want_perks])
	print("  rarity counts featured %s regular %s" % [counts[0], counts[1]])
	check(bad.is_empty(), "every roll: IP in its rarity band (+4 featured), guaranteed perk count, price by rarity (%d bad: %s)" % [bad.size(), bad.slice(0, 3)])
	check(counts[0][0] == 0 and counts[0][1] == 0 and counts[0][2] > counts[0][3], "featured slot never below Rare, mostly Rare")
	check(low_q.is_empty(), "no duds: every offer meets its rarity's roll_quality_floor (%d below: %s)" % [low_q.size(), low_q.slice(0, 3)])
	check(no_play.is_empty() and counts[0][3] + counts[1][3] > 0 and mythics > 0, "every Legendary / Mythic has >= 1 playstyle perk (%d Leg, %d Myth sampled)" % [counts[0][3] + counts[1][3], mythics])
	# Commons are a little better than the starter gun: Common rolled at round 1 (GearDB.roll_weapon(arch, COMMON, 1)).
	var gdbn: Node = root.get_node("GearDB")
	var s_dmg := 0.0
	var s_stats := 0.0
	var s_ipmax := 0
	# Seeded starter sample: the Merchant stock above is already seeded (seed 99 + fake clock), so the whole
	# comparison is deterministic and can't flake on an unlucky starter roll.
	seed(hash(["merchant_test_starter_baseline", 99]))
	var m_dmg := 0.0
	var m_stats := 0.0
	var each_ok := true
	for w in commons:
		var md: float = w.damage()
		var mt: float = w.stats.values().reduce(func(a, b): return a + b, 0)
		var sd := 0.0
		var stt := 0.0
		for k in 20:
			var starter = gdbn.roll_weapon(str(w.archetype), Rarity.COMMON, 1)
			sd += starter.damage() / 20.0
			stt += float(starter.stats.values().reduce(func(a, b): return a + b, 0)) / 20.0
			s_ipmax = maxi(s_ipmax, int(starter.item_power))
		s_dmg += sd
		s_stats += stt
		m_dmg += md
		m_stats += mt
		# Guaranteed part only: IP floor (checked below) and the power multiplier it buys. Per-gun damage still
		# carries the +/- stat_variance roll, so it's compared on the average (gain check below), not per item.
		each_ok = each_ok and w.power_mult() > 1.06 and int(w.item_power) >= int(m.rarity_cfg(0).item_power[0])
		if md <= sd * 0.97:
			print("  (info) %s Common rolled low damage: %.1f vs starter avg %.1f" % [w.archetype, md, sd])
	var n_c: int = maxi(commons.size(), 1)
	var gain := m_dmg / maxf(s_dmg, 0.001) - 1.0
	check(commons.size() >= 20 and each_ok and s_ipmax < int(m.rarity_cfg(0).item_power[0]),
		"every Merchant Common out-powers the starter roll (guaranteed: IP %d+ vs starter max %d, power mult > 1.06)" % [int(m.rarity_cfg(0).item_power[0]), s_ipmax])
	randomize()
	check(gain > 0.05 and gain < 0.25 and m_stats / n_c > s_stats / n_c,
		"...but only a little: +%.1f%% damage, stat total %.0f vs %.0f on average (%d Commons)" % [gain * 100.0, m_stats / n_c, s_stats / n_c, commons.size()])
	var reg_total: int = counts[1].reduce(func(a, b): return a + b, 0)
	check(counts[1][4] <= reg_total * 0.03 and counts[1][0] > counts[1][3], "regular slots: Mythic <= 3%% (%d/%d), Common > Legendary" % [counts[1][4], reg_total])
	mr.free()

	# ------------------------------------------------------------ reroll escalation + reset
	prog.merchant = {"version": 1, "seed": 7}
	sig.clear()
	fc.t = h0 + 10.0 * H + 5.0
	var inv := _inventory()
	prog.bind_inventory(inv)
	m.refresh_if_due()
	check(m.reroll_cost() == 5 and m.reroll_check().reason == "Not enough Gravemarks (need 5)" and not m.reroll().ok
		and m.last_refusal_reason() == "Not enough Gravemarks (need 5)", "reroll with 0 Gravemarks refused: need 5")
	prog.add_gravemark(2000, "test")
	# buy slot 1 first: a sold slot must survive rerolls
	var cheap := _offer(m, func(o): return o.slot == 1)
	var before_buy: int = prog.gravemarks
	var br: Dictionary = m.buy(cheap.offer_id)
	check(br.ok and br.item != null and prog.gravemarks == before_buy - int(cheap.price), "buy slot 1: ok, Gravemarks %d -> %d (price %d)" % [before_buy, prog.gravemarks, cheap.price])
	var paid := []
	var bal0: int = prog.gravemarks
	var ids_prev := _ids(m)
	var keep_ok := true
	var change_ok := true
	for i in 6:
		var c: int = m.reroll_cost()
		var rr: Dictionary = m.reroll()
		paid.append(c)
		var now_ids := _ids(m)
		keep_ok = keep_ok and now_ids[1] == ids_prev[1] and m.get_stock()[1].sold
		for j in now_ids.size():
			if j != 1:
				change_ok = change_ok and now_ids[j] != ids_prev[j]
		ids_prev = now_ids
		if not rr.ok:
			paid.append("refused")
	check(paid == [5, 9, 15, 24, 36, 51] and prog.gravemarks == bal0 - 140, "reroll costs escalate %s, total 140 deducted" % [paid])
	check(keep_ok and change_ok, "reroll replaces every unsold slot (new offer ids), the sold slot stays sold")
	check(_count("stock", "reroll") == 6 and _count("cost", 66) >= 1, "stock_changed(reroll) + reroll_cost_changed per reroll")
	fc.t = h0 + 11.0 * H
	check(m.refresh_if_due() and m.reroll_cost() == 5 and int(prog.merchant.rerolls) == 0 and _count("cost", 5) >= 1, "free refresh resets the reroll price to 5")

	# ------------------------------------------------------------ buy + every refusal
	sig.clear()
	prog.gravemarks = 0
	prog.currency_changed.emit(0)
	var o: Dictionary = m.get_stock()[2]
	check(m.buy_check("lot_nope").reason == "Stock expired" and m.buy("lot_nope").reason == "Stock expired", "unknown offer id -> Stock expired")
	check(m.buy_check(o.offer_id).reason == "Not enough Gravemarks (need %d)" % o.price, "short -> Not enough Gravemarks (need %d)" % o.price)
	var r_short: Dictionary = m.buy(o.offer_id)
	check(not r_short.ok and r_short.item == null and r_short.reason == m.last_refusal_reason() and prog.gravemarks == 0, "refused buy: {ok false, reason, item null}, nothing spent")
	prog.add_gravemark(int(o.price) + 3, "test")
	var cur_sig := []
	var cb := func(b): cur_sig.append(b)
	prog.currency_changed.connect(cb)
	var carried0: int = inv.carried_count()
	var rb: Dictionary = m.buy(o.offer_id)
	prog.currency_changed.disconnect(cb)
	var gun = rb.item
	check(rb.ok and rb.reason == "" and prog.gravemarks == 3 and cur_sig == [3], "buy deducts exactly the price via Progress (currency_changed %s)" % [cur_sig])
	var in_inv: bool = inv.backpack[gun.slot].has(gun) or inv.equipped[gun.slot] == gun
	check(in_inv and gun.item_id == str(o.item_id), "gun is in the stash Inventory with the offer's item_id")
	check(inv.backpack[gun.slot].has(gun) and gun.seen == (not inv.badge_worthy(gun)) and inv.carried_count() == carried0 + 1, "slot occupied -> backpack, '!' only if Rare+ / an upgrade (playtest #18)")
	check(_count("bought") == 1 and sig.filter(func(s): return s[0] == "bought")[0][3] == o.price and _count("stock", "buy") == 1, "purchased(offer_id, item, price) + stock_changed(buy)")
	var after: Dictionary = _offer(m, func(x): return x.offer_id == o.offer_id)
	check(after.sold and after.owned and after.reason == "Sold out" and m.buy_check(o.offer_id).reason == "Sold out" and m.buy(o.offer_id).reason == "Sold out",
		"sold slot: sold + owned, buy again -> Sold out")
	inv.equip(gun)
	check(inv.equipped[gun.slot] == gun and gun.seen, "bought gun equips like any stash gear")
	var saved := ConfigFile.new()
	saved.load(path)
	check(saved.has_section_key("merchant", "data") and gun.item_id in _stash_ids(saved.get_value("stash", "data")),
		"buy saved at once: merchant state + the gun in [stash]")

	# stash full (40/40): weapon slot occupied, 40 spare armor pieces
	prog.add_gravemark(2000, "test")
	var target := _offer(m, func(x): return not x.sold and inv.equipped.get(x.item.slot) != null)
	var k := 0
	while inv.carried_count() < 40:
		var s: String = inv.ARMOR_SLOTS[k % inv.ARMOR_SLOTS.size()]
		if inv.backpack[s].size() < inv.backpack_size:
			inv.backpack[s].append(_gdb().roll_armor(s, Rarity.COMMON, 1))
		k += 1
	var bal_full: int = prog.gravemarks
	check(not target.is_empty() and m.buy_check(target.offer_id).reason == "Stash full (40/40)", "40 spare pieces -> Stash full (40/40)")
	var rf: Dictionary = m.buy(target.offer_id)
	check(not rf.ok and rf.reason == "Stash full (40/40)" and prog.gravemarks == bal_full and not _offer(m, func(x): return x.offer_id == target.offer_id).sold,
		"stash-full buy refused, nothing spent, slot unsold")
	check(_offer(m, func(x): return x.offer_id == target.offer_id).reason == "Stash full (40/40)", "get_stock reason shows Stash full (40/40)")
	# weapon type grid full (9) but stash not full
	for s in inv.ARMOR_SLOTS:
		inv.backpack[s].clear()
	var ws: String = target.item.slot
	while inv.backpack[ws].size() < inv.backpack_size:
		inv.backpack[ws].append(_gdb().roll_weapon(str(target.archetype), Rarity.COMMON, 1))
	check(m.buy_check(target.offer_id).reason == "No backpack room for that weapon type", "9/9 tiles for that weapon type -> No backpack room for that weapon type")
	inv.backpack[ws].clear()
	# empty equip slot ignores the cap (auto-equip, like Inventory.add_item)
	check(m.buy_check(target.offer_id).ok, "room again -> ok")
	# expired: hour over but refresh not run yet
	fc.t = h0 + 12.0 * H
	check(m.buy_check(target.offer_id).reason == "Stock expired" and m.reroll_check().reason == "Stock expired", "hour over before refresh_if_due(): Stock expired (buy + reroll)")
	check(m.get_stock().all(func(x): return x.reason == "Stock expired"), "pending refresh: cards show Stock expired")
	var stale_id: String = target.offer_id
	m.refresh_if_due()
	check(m.buy(stale_id).reason == "Stock expired", "old offer id after refresh -> Stock expired")

	# no live inventory: straight into Progress.stash
	prog.capture_stash()
	prog.bind_inventory(null)
	var od := _offer(m, func(x): return not x.sold)
	var rd: Dictionary = m.buy(od.offer_id)
	var found := false
	for s in prog.stash.get("backpack", {}):
		for d in prog.stash.backpack[s]:
			found = found or str(d.item_id) == str(od.item_id)
	for s in prog.stash.get("equipped", {}):
		found = found or (prog.stash.equipped[s] != null and str(prog.stash.equipped[s].item_id) == str(od.item_id))
	check(rd.ok and found and _offer(m, func(x): return x.offer_id == od.offer_id).owned, "no bound inventory: gun written into the saved stash, owned=true")

	# ------------------------------------------------------------ persistence round trip
	var before: Dictionary = prog.merchant.duplicate(true)
	var stock_before := _sigs(m)
	var ids_before := _ids(m)
	sig.clear()
	prog.save_data()
	prog.merchant = {}
	prog.stash = {}
	prog.gravemarks = 0
	prog.load_data()
	var after_m: Dictionary = prog.merchant
	check(after_m.seed == before.seed and after_m.hour_index == before.hour_index and after_m.rerolls == before.rerolls and after_m.gen == before.gen
		and after_m.last_seen_time == before.last_seen_time, "save/load keeps seed, refresh index, rerolls, gen, last_seen_time")
	check(_ids(m) == ids_before and _sigs(m) == stock_before and m.get_stock().map(func(x): return x.sold) == before.stock.map(func(x): return x.sold),
		"save/load keeps the exact stock (offer ids, items, sold flags)")
	check(_count("stock", "load") == 1, "load -> stock_changed(load)")
	var inv2: Node = load(INVENTORY_PATH).new()
	root.add_child(inv2)
	prog.restore_stash(inv2)
	var all2 := []
	for s in inv2.backpack:
		all2.append_array(inv2.backpack[s].map(func(g): return g.item_id))
	for s in inv2.equipped:
		if inv2.equipped[s]:
			all2.append(inv2.equipped[s].item_id)
	check(gun.item_id in all2 and od.item_id in all2, "bought guns come back from the stash after a reload (match start restore)")
	inv2.queue_free()
	var m2 := _new_merchant()
	check(_ids(m2) == ids_before and m2.reroll_cost() == m.reroll_cost(), "a second Merchant instance sees the same state (all state in Progress)")
	m2.free()

	# ------------------------------------------------------------ v4 -> v5 migration
	var v4 := ConfigFile.new()
	v4.set_value("meta", "save_version", 4)
	v4.set_value("stats", "xp", 1234)
	v4.set_value("armory", "gravemarks", 17)
	v4.set_value("armory", "data", {"upgrades": {"auto_rifle": 1}, "owned": [], "equipped": {}})
	_reset(prog, path)
	v4.save(path)
	prog.load_data()
	check(prog.loaded_save_version == 4 and prog.merchant.is_empty() and prog.gravemarks == 17 and prog.xp == prog.rebase_xp(1234)
		and prog.xp_rebased_from == 1234 and prog.get_level() == 5 and prog.loaded_from == "main",
		"v4 save loads: empty merchant state, Gravemarks kept, xp re-based onto the v6 curve (level 5 kept, %d xp)" % prog.xp)
	fc.t = h0 + 20.0 * H
	m.reset_session_clock()
	check(m.refresh_if_due() and m.get_stock().size() == 5 and int(prog.merchant.hour_index) == 490020, "fresh merchant rolls its first stock on a migrated save")
	var c5 := ConfigFile.new()
	c5.load(path)
	check(int(c5.get_value("meta", "save_version", 0)) == prog.SAVE_VERSION and prog.SAVE_VERSION >= 6 and c5.has_section_key("merchant", "data") and int(c5.get_value("merchant", "version", 0)) == 1,
		"written back as save_version %d with [merchant] version 1" % prog.SAVE_VERSION)
	var xp_v6: int = prog.xp
	prog.load_data()
	check(prog.loaded_save_version == prog.SAVE_VERSION and prog.merchant.stock.size() == 5 and prog.xp == xp_v6, "current-version reload (xp not re-based twice)")
	check(prog.migrate_merchant(null).is_empty() and prog.migrate_merchant("junk").is_empty()
		and prog.migrate_merchant({"seed": 3, "stock": [{"offer_id": "x"}, 5, {"offer_id": "lot1_0", "item": {}}]}).stock.size() == 1,
		"migrate_merchant: junk -> {}, malformed offers dropped")

	# ------------------------------------------------------------ crash-safe .tmp / .bak
	_reset(prog, path)
	prog.xp = 100
	prog.save_data()
	prog.xp = 200
	prog.save_data()
	var bak := ConfigFile.new()
	check(FileAccess.file_exists(path) and FileAccess.file_exists(path + ".bak") and not FileAccess.file_exists(path + ".tmp"), "save: progress.cfg + .bak, no .tmp left")
	check(bak.load(path + ".bak") == OK and int(bak.get_value("stats", "xp", 0)) == 100 and bool(bak.get_value("end", "complete", false)), ".bak = the previous good save")
	_write(path, "[stats\nxp=garbage =\n\"")
	prog.xp = 0
	prog.load_data()
	check(prog.loaded_from == "bak" and prog.xp == 100, "corrupt main -> falls back to .bak")
	prog.xp = 300
	prog.save_data()
	check(FileAccess.file_exists(path + ".corrupt") and bak.load(path + ".bak") == OK and int(bak.get_value("stats", "xp", 0)) == 100,
		"next save parks the corrupt file as .corrupt, keeps the good .bak")
	prog.load_data()
	check(prog.loaded_from == "main" and prog.xp == 300, "main readable again")
	# crash between 'main -> .bak' and '.tmp -> main': main missing, .tmp complete and newer
	prog.xp = 400
	prog.save_data()
	DirAccess.copy_absolute(path, path + ".tmp")
	DirAccess.remove_absolute(path)
	prog.xp = 0
	prog.load_data()
	check(prog.loaded_from == "tmp" and prog.xp == 400, "main missing, complete newer .tmp -> .tmp wins over .bak")
	# torn .tmp (no [end]) -> ignored
	_write(path + ".tmp", "[meta]\nsave_serial=999999\n[stats]\nxp=999\n")
	prog.xp = 0
	prog.load_data()
	check(prog.loaded_from == "bak" and prog.xp == 300, "torn .tmp ignored -> .bak")
	prog.save_data()
	check(not FileAccess.file_exists(path + ".tmp") and FileAccess.file_exists(path), "next save replaces the stray .tmp")
	# main missing, .bak only
	DirAccess.remove_absolute(path)
	prog.xp = 0
	prog.load_data()
	check(prog.loaded_from == "bak" and prog.xp == 300, "main missing -> .bak")
	# nothing at all
	_reset(prog, path)
	prog.load_data()
	check(prog.loaded_from == "none" and prog.merchant.is_empty(), "no files -> fresh")

	# ------------------------------------------------------------ crash files copied forward by SaveMigration (Gravecrew rename)
	var mig := dir.path_join("mig")
	var don := mig.path_join("DeadofNight")
	var fps := mig.path_join("FPS Starter")
	var gc := mig.path_join("Gravecrew")
	DirAccess.make_dir_recursive_absolute(don)
	DirAccess.make_dir_recursive_absolute(fps)
	var good := ConfigFile.new()
	good.set_value("meta", "save_version", 5)
	good.set_value("meta", "save_serial", 7)
	good.set_value("stats", "xp", 777)
	good.set_value("end", "complete", true)
	good.save(don.path_join("progress.cfg.bak")) # DeadofNight crashed mid-save: no main, only .bak + a torn .tmp
	_write(don.path_join("progress.cfg.tmp"), "[meta]\nsave_serial=8\n[stats]\nxp=1")
	_write(fps.path_join("progress.cfg"), "[stats]\nxp=5\n")
	_write(fps.path_join("progress.cfg.bak"), "[stats]\nxp=4\n")
	var has_recovery: bool = "RECOVERY_FILES" in MigrationScript.new().get_script().get_script_constant_map()
	if has_recovery:
		var rm: Dictionary = MigrationScript.migrate_all([don, fps], gc)
		check(rm.dirs.size() >= 1 and rm.dirs[0] == don, "SaveMigration counts a .bak-only dir as a save (DeadofNight first)")
		check(FileAccess.get_file_as_string(gc.path_join("progress.cfg.bak")).contains("777"), "the .bak comes from the same dir as the rest (DeadofNight), not FPS Starter's")
		check(FileAccess.file_exists(gc.path_join("progress.cfg")) and FileAccess.get_file_as_string(gc.path_join("progress.cfg")).contains("xp=5"),
			"FPS Starter fills in the missing progress.cfg (never overwrites)")
		# the newer dir's main came from FPS Starter here; prove the opposite case: newer dir has main -> older .bak skipped
		var gc2 := mig.path_join("Gravecrew2")
		var don2 := mig.path_join("DoN2")
		DirAccess.make_dir_recursive_absolute(don2)
		_write(don2.path_join("progress.cfg"), "[stats]\nxp=9\n")
		var r2: Dictionary = MigrationScript.migrate_all([don2, fps], gc2)
		check(r2.dirs.size() == 1 or not FileAccess.file_exists(gc2.path_join("progress.cfg.bak")), "older dir's .bak never pairs with a newer dir's progress.cfg")
	else:
		print("  (SaveMigration without RECOVERY_FILES: MAIN_HOOKS §19b not applied, copy-forward checks skipped)")
		DirAccess.make_dir_recursive_absolute(gc)
		DirAccess.copy_absolute(don.path_join("progress.cfg.bak"), gc.path_join("progress.cfg.bak"))
		DirAccess.copy_absolute(don.path_join("progress.cfg.tmp"), gc.path_join("progress.cfg.tmp"))
		DirAccess.remove_absolute(gc.path_join("progress.cfg"))
	# Progress on the migrated dir: with only the copied .bak + torn .tmp, it recovers 777
	_reset(prog, gc.path_join("progress_only_bak.cfg"))
	DirAccess.copy_absolute(don.path_join("progress.cfg.bak"), gc.path_join("progress_only_bak.cfg.bak"))
	DirAccess.copy_absolute(don.path_join("progress.cfg.tmp"), gc.path_join("progress_only_bak.cfg.tmp"))
	prog.load_data()
	check(prog.loaded_from == "bak" and prog.xp == prog.rebase_xp(777), "migrated dir with a copied .bak + torn .tmp: recovers from .bak (legacy xp 777 re-based)")
	prog.save_data()
	check(FileAccess.file_exists(prog.save_path) and not FileAccess.file_exists(prog.save_path + ".tmp"), "first save in the new dir writes progress.cfg, clears the stale .tmp")
	# a stale .tmp next to a readable main is ignored
	_write(prog.save_path + ".tmp", "[meta]\nsave_serial=99999\n[stats]\nxp=1\n[end]\ncomplete=true\n")
	prog.load_data()
	check(prog.loaded_from == "main" and prog.xp == prog.rebase_xp(777), "readable main always wins over a copied-forward .tmp")

	# ------------------------------------------------------------ cleanup
	m.free()
	inv.queue_free()
	_rm_all(dir)
	prog.save_path = real_path
	prog.merchant = real_merchant
	prog.gravemarks = real_bal
	prog.bind_inventory(null)
	print("MERCHANT TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
