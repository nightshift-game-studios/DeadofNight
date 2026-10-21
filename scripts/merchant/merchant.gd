extends Node
## Home-screen Merchant (Skillz, DESIGN.md §20; contract /workspace/skillz/MERCHANT_API.md, Gooey's UI calls it through
## scripts/ui/merchant_api.gd). Sells rolled guns for Gravemarks (Progress). Per player and local: no netcode.
##
## Register as the autoload "Merchant" (MAIN_HOOKS §19). It also works as a plain `merchant.gd.new()` instance (Gooey's
## MerchantAPI.create() fallback): every bit of state lives in Progress.merchant (saved in user://progress.cfg
## [merchant], save v5), so any number of instances agree; only signals and preview caches are per instance.
##
## Stock: data/merchant.json stock_size (4..6) slots, each with its own rarity weights (slot 0 = featured, Rare+).
## Guns come from GearDB.roll_weapon(arch, rarity, round, "", item_power) with a merchant item_power by rarity (mid-match
## level). Stock is deterministic from Progress.merchant.seed + the refresh index + the reroll count (+ slot), so a
## fake clock reproduces it exactly. The rolled guns are stored as WeaponItem.to_dict(), so a load shows the same stock.
##
## Clock: hourly refresh aligned to multiples of refresh_seconds since the unix epoch (top of the hour).
## trusted time = max(clock, last_seen_time, session anchor + monotonic ticks). So:
##  - clock goes back: never refreshes early; in a running session the countdown keeps going on the monotonic clock,
##    after a restart it waits for the clock to pass last_seen_time again;
##  - clock goes back more than rollback_reanchor_seconds (a bogus forward jump being corrected): the stock is kept,
##    no refresh, and last_seen / the refresh index re-anchor to the corrected clock so the timer works again;
##  - clock jumps forward any amount: exactly one refresh.
## Checks (buy_check / reroll_check / get_stock) never emit signals or roll; refresh happens in refresh_if_due().

signal stock_changed(reason: String) ## "refresh" | "reroll" | "buy" | "load"
signal purchased(offer_id: String, item: WeaponItem, price: int)
signal refreshed ## free hourly refresh (also emits stock_changed("refresh"))
signal reroll_cost_changed(new_cost: int)

const DATA_PATH := "res://data/merchant.json"
const STATE_VERSION := 1
## Refusal reasons (MERCHANT_API.md). Gooey's UI shows them as-is.
const R_SOLD := "Sold out"
const R_FUNDS := "Not enough Gravemarks (need %d)"
const R_STASH := "Stash full (%d/%d)"
const R_EXPIRED := "Stock expired"
const R_SLOT_FULL := "No backpack room for that weapon type" ## added field (same text as Gooey's stub)
const R_UNAVAILABLE := "The Gravecrew merchant is away" ## no Progress / GearDB (should never happen in game)
const DIFFS := ["easy", "medium", "hard"]
const CLOCK_SLACK := 2.0 ## seconds the wall clock may lag the monotonic estimate before it counts as a rollback

## Injectable clock (tests): () -> float unix seconds. Default Time.get_unix_time_from_system.
var clock: Callable = Callable()
## Seconds added to the clock (same test hook name as Gooey's stub, so merchant_ui_test can drive the real Merchant).
var now_offset: float = 0.0
## First paid reroll price after a refresh (read-only; same name as Gooey's stub field).
var reroll_base: int:
	get:
		return cost_for_reroll(0)
## Injectable monotonic clock (tests): () -> int milliseconds. Default Time.get_ticks_msec.
var ticks: Callable = Callable()
## Optional grant target. null -> Progress.bound_inventory() (the home Kit inventory), else straight into Progress.stash.
var inventory: Node = null
var data: Dictionary = {}

var _items: Dictionary = {} ## offer_id -> preview WeaponItem (rebuilt from the saved dict)
var _last_refusal: String = ""
var _income_cache: Dictionary = {} ## diff -> Gravemarks per typical match
var _anchor_unix: float = -1.0 ## trusted time at _anchor_ticks (this session)
var _anchor_ticks: int = 0


func _init() -> void:
	reload_data()
	var p := _progress()
	if p and p.has_signal("armory_changed") and not p.armory_changed.is_connected(_on_progress_changed):
		p.armory_changed.connect(_on_progress_changed)


func _ready() -> void: # autoload: Progress may not have been reachable from _init yet
	var p := _progress()
	if p and p.has_signal("armory_changed") and not p.armory_changed.is_connected(_on_progress_changed):
		p.armory_changed.connect(_on_progress_changed)


func reload_data() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH)) if FileAccess.file_exists(DATA_PATH) else null
	data = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	_items.clear()
	_income_cache.clear()


# ================================================================== public API (MERCHANT_API.md)

## 4..6 offer dicts (see MERCHANT_API.md). Rolls the very first stock silently; never refreshes or emits.
func get_stock() -> Array:
	if not _ensure_stock():
		return []
	var out: Array = []
	for o in _state().stock:
		out.append(_decorate(o))
	return out


func buy_check(offer_id: String) -> Dictionary:
	var o := _find(offer_id)
	if o.is_empty() or _due():
		return {"ok": false, "reason": R_EXPIRED}
	return _check(o)


func buy(offer_id: String) -> Dictionary:
	var c := buy_check(offer_id)
	if not c.ok:
		return _refuse(c.reason, true)
	var p := _progress()
	var o := _find(offer_id)
	var price := int(o.price)
	if not p.spend_gravemark(price):
		return _refuse(R_FUNDS % price, true)
	var w := _preview(o) # the very object the card showed goes to the stash (UI compares identity, like the stub)
	w.seen = false
	var g := _grant(w)
	if not g.ok:
		p.refund_gravemark(price)
		_items.erase(offer_id) # never reuse a preview a failed grant may have touched
		return _refuse(str(g.reason), true)
	o["sold"] = true
	_last_refusal = ""
	if g.live:
		p.save_stash() # captures the live inventory (with the new gun) + writes the merchant state
	else:
		p.save_data()
	purchased.emit(offer_id, w, price)
	stock_changed.emit("buy")
	return {"ok": true, "reason": "", "item": w}


## Price of the next paid reroll (rises per use, resets at the free refresh).
func reroll_cost() -> int:
	return cost_for_reroll(int(_state().get("rerolls", 0)))


func reroll_check() -> Dictionary:
	if not _ensure_stock():
		return {"ok": false, "reason": R_UNAVAILABLE}
	if _due():
		return {"ok": false, "reason": R_EXPIRED}
	var c := reroll_cost()
	if _balance() < c:
		return {"ok": false, "reason": R_FUNDS % c}
	return {"ok": true, "reason": ""}


## Replaces every unsold slot (sold ones stay sold) and new offer ids for them.
func reroll() -> Dictionary:
	var c := reroll_check()
	if not c.ok:
		return _refuse(c.reason, false)
	var cost := reroll_cost()
	if not _progress().spend_gravemark(cost):
		return _refuse(R_FUNDS % cost, false)
	var st := _state()
	st["rerolls"] = int(st.rerolls) + 1
	st["gen"] = int(st.gen) + 1
	_roll_stock(true)
	_last_refusal = ""
	_progress().save_data()
	reroll_cost_changed.emit(reroll_cost())
	stock_changed.emit("reroll")
	return {"ok": true, "reason": ""}


## Seconds until the free refresh (top of the next hour on the trusted clock; 0 = due, call refresh_if_due()).
func time_to_refresh() -> int:
	var period := _period()
	var t := _trusted_now()
	var idx := int(_state().get("hour_index", -1))
	if idx < 0:
		idx = _index_of(t)
	return maxi(int(ceil(float(idx + 1) * period - t)), 0)


## Home-screen open + every second (Gooey's timer). True if the stock changed (free refresh, or the first roll).
func refresh_if_due() -> bool:
	if _progress() == null or _gear_db() == null:
		return false
	var st := _state()
	var t := _trusted_now()
	var idx := _index_of(t)
	if st.stock.is_empty() or int(st.hour_index) < 0:
		_refresh_to(idx)
		return true
	if idx <= int(st.hour_index):
		return false # same hour, or the clock went back: never early
	_refresh_to(idx) # one refresh however far the clock jumped
	return true


func last_refusal_reason() -> String:
	return _last_refusal


# ================================================================== extras (additive, for UI / tests / design table)

func stock_size() -> int:
	return clampi(int(data.get("stock_size", 5)), 4, 6)


func cost_for_reroll(n: int) -> int:
	var costs: Array = data.get("reroll_costs", [1, 2, 4, 7, 12])
	if costs.is_empty():
		return 1
	if n < costs.size():
		return int(costs[n])
	return int(costs[-1]) + int(data.get("reroll_cost_step", 6)) * (n - costs.size() + 1)


func rarity_cfg(r: int) -> Dictionary:
	return data.get("rarity", {}).get(Rarity.IDS[clampi(r, 0, 4)], {})


func price_for(r: int, featured: bool = false) -> int:
	var p := float(rarity_cfg(r).get("price", 1))
	if featured:
		p *= float(data.get("featured_bonus", {}).get("price_mult", 1.0))
	return maxi(int(round(p * price_mult())), 1)


## Global price dial (merchant.json price_mult, default 1). Economy v2 runs at 0.5; set it back to 1.0 to restore the
## §20.7 list prices. Saved stock is re-priced on read (_state), so a change applies at once, not at the next refresh.
func price_mult() -> float:
	return maxf(float(data.get("price_mult", 1.0)), 0.0)


## Normalized rarity odds (0..1, common..mythic) for stock slot i.
func slot_odds(i: int) -> Array:
	var w := _slot_weights(i)
	var tot := 0.0
	for v in w:
		tot += v
	return w.map(func(v): return v / tot if tot > 0.0 else 0.0)


func slot_featured(i: int) -> bool:
	return bool(_slot_cfg(i).get("featured", false))


## Typical matches needed to afford `price` on a difficulty (data income_per_match).
func matches_to_afford(price: int, diff: String) -> float:
	return float(price) / maxf(income_per_match(diff), 0.01)


## Gravemarks per typical match: Armory.matches_to_max(diff).per_match (= Armory.expected_match_income at the typical
## round count) when data income_source is "armory", else data income_per_match. Maps are 1:1 with difficulties.
func income_per_match(diff: String) -> float:
	if str(data.get("income_source", "")) == "armory":
		if not _income_cache.has(diff):
			var A = load("res://scripts/armory/armory.gd")
			_income_cache[diff] = float(A.matches_to_max(diff).get("per_match", 0.0)) if A else 0.0
		if float(_income_cache[diff]) > 0.0:
			return float(_income_cache[diff])
	return float(data.get("income_per_match", {}).get(diff, 7))


## Rows for DESIGN.md §20 / tests: {rarity, ip:[lo,hi], perks, price, featured_price, odds_featured, odds_regular, matches{easy, medium, hard}}.
func design_table() -> Array:
	var out: Array = []
	for r in 5:
		var c := rarity_cfg(r)
		var m := {}
		var mf := {}
		for d in DIFFS:
			m[d] = snappedf(matches_to_afford(price_for(r), d), 0.1)
			mf[d] = snappedf(matches_to_afford(price_for(r, true), d), 0.1)
		out.append({"rarity": Rarity.name_of(r), "ip": c.get("item_power", [100, 100]),
			"perks": Rarity.PERK_SLOTS[r] + (1 if r == Rarity.MYTHIC else 0) + int(c.get("bonus_perks", 0))
				+ (1 if r == Rarity.MYTHIC and not signature_perks().is_empty() else 0),
			"playstyle_min": int(c.get("playstyle_perks_min", 0)), "roll_quality_floor": float(c.get("roll_quality_floor", 0.0)),
			"price": price_for(r), "featured_price": price_for(r, true),
			"odds_featured": slot_odds(0)[r], "odds_regular": slot_odds(1)[r], "matches": m, "matches_featured": mf})
	return out


## The first n paid reroll prices after a refresh, each with matches-to-pay per difficulty.
func reroll_table(n: int = 7) -> Array:
	var out: Array = []
	for i in n:
		var cost := cost_for_reroll(i)
		var m := {}
		for d in DIFFS:
			m[d] = snappedf(matches_to_afford(cost, d), 0.01)
		out.append({"n": i + 1, "cost": cost, "matches": m})
	return out


## Fake-clock helpers for tests (drop the session anchor so a new clock is taken at face value).
func reset_session_clock() -> void:
	_anchor_unix = -1.0


# ================================================================== state (lives in Progress.merchant)

func _progress() -> Node:
	var ml := Engine.get_main_loop() as SceneTree
	return ml.root.get_node_or_null("Progress") if ml else null


func _gear_db() -> Node:
	var ml := Engine.get_main_loop() as SceneTree
	return ml.root.get_node_or_null("GearDB") if ml else null


func _state() -> Dictionary:
	var p := _progress()
	if p == null:
		return {"stock": [], "hour_index": -1, "rerolls": 0, "gen": 0, "seed": 0, "last_seen_time": 0}
	var m: Dictionary = p.merchant
	if m.is_empty() or int(m.get("version", 0)) != STATE_VERSION:
		var fresh := {"version": STATE_VERSION, "seed": randi(), "hour_index": -1, "rerolls": 0, "gen": 0,
			"last_seen_time": 0, "stock": []}
		for k in m: # keep whatever a migration left
			if k != "version":
				fresh[k] = m[k]
		p.merchant = fresh
		m = p.merchant
	for k in ["seed", "hour_index", "rerolls", "gen", "last_seen_time"]:
		if not m.has(k):
			m[k] = -1 if k == "hour_index" else (randi() if k == "seed" else 0)
	if typeof(m.get("stock")) != TYPE_ARRAY:
		m["stock"] = []
	for o in m.stock: # price_mult / list price changes apply to the saved stock too
		if typeof(o) == TYPE_DICTIONARY and o.has("rarity"):
			o["price"] = price_for(int(o.rarity), bool(o.get("featured", false)))
	return m


func _on_progress_changed(kind: String, _id: String) -> void:
	if kind == "load":
		_items.clear()
		_anchor_unix = -1.0
		stock_changed.emit("load")


func _ensure_stock() -> bool:
	if _progress() == null or _gear_db() == null:
		return false
	var st := _state()
	if st.stock.is_empty() or int(st.hour_index) < 0:
		var idx := _index_of(_trusted_now())
		st["hour_index"] = idx
		st["rerolls"] = 0
		st["gen"] = int(st.gen) + 1
		_roll_stock(false)
		_progress().save_data()
	return true


func _refresh_to(idx: int) -> void:
	var st := _state()
	st["hour_index"] = idx
	st["rerolls"] = 0
	st["gen"] = int(st.gen) + 1
	_roll_stock(false)
	_progress().save_data()
	refreshed.emit()
	stock_changed.emit("refresh")
	reroll_cost_changed.emit(reroll_cost())


# ================================================================== clock

func _period() -> float:
	return maxf(float(data.get("refresh_seconds", 3600)), 1.0)


func _index_of(t: float) -> int:
	return int(floor(t / _period()))


func _clock_now() -> float:
	return (float(clock.call()) if clock.is_valid() else Time.get_unix_time_from_system()) + now_offset


func _ticks_now() -> int:
	return int(ticks.call()) if ticks.is_valid() else Time.get_ticks_msec()


## Trusted time. While the wall clock agrees with the session's monotonic clock (within CLOCK_SLACK) it is used as-is
## and re-anchors the session (no drift can ratchet up). When it falls behind (rollback in this session) the anchor +
## monotonic elapsed time is used instead, and the anchor stays put. Never below last_seen_time (persisted), so after a
## restart with the clock set back the timer resumes from the last trusted time. Re-anchors after a large rollback
## (see header). Updates last_seen_time (saved with the next save).
func _trusted_now() -> float:
	var st := _state()
	var now := _clock_now()
	var tk := _ticks_now()
	var last := float(st.get("last_seen_time", 0))
	var t: float
	var mono := _anchor_unix + float(tk - _anchor_ticks) / 1000.0
	if _anchor_unix < 0.0 or now >= mono - CLOCK_SLACK:
		t = maxf(now, last)
		_anchor_unix = t
		_anchor_ticks = tk
	else:
		t = maxf(mono, last)
	if t - now > float(data.get("rollback_reanchor_seconds", 172800)):
		# Corrected bogus future: keep the stock, no refresh, timer restarts from the real clock.
		t = now
		_anchor_unix = t
		_anchor_ticks = tk
		if int(st.get("hour_index", -1)) > _index_of(now):
			st["hour_index"] = _index_of(now)
	st["last_seen_time"] = int(t)
	return t


## The stock's hour is over (refresh pending). Checks refuse with "Stock expired" until refresh_if_due() runs.
func _due() -> bool:
	var st := _state()
	return int(st.get("hour_index", -1)) >= 0 and _index_of(_trusted_now()) > int(st.hour_index)


# ================================================================== rolling

func _slot_cfg(i: int) -> Dictionary:
	var slots: Array = data.get("slots", [])
	if slots.is_empty():
		return {}
	return slots[clampi(i, 0, slots.size() - 1)]


func _slot_weights(i: int) -> Array:
	var w: Dictionary = _slot_cfg(i).get("weights", {"common": 1})
	var out: Array = []
	for id in Rarity.IDS:
		out.append(maxf(float(w.get(id, 0.0)), 0.0))
	return out


func _pick_rarity(rng: RandomNumberGenerator, i: int) -> int:
	var w := _slot_weights(i)
	var tot := 0.0
	for v in w:
		tot += v
	if tot <= 0.0:
		return Rarity.COMMON
	var x := rng.randf() * tot
	for r in w.size():
		x -= w[r]
		if x < 0.0:
			return r
	for r in range(w.size() - 1, -1, -1):
		if w[r] > 0.0:
			return r
	return Rarity.COMMON


func _arch_pool() -> Array:
	var ids: Array = data.get("archetypes", [])
	var gdb := _gear_db()
	if ids.is_empty():
		ids = gdb.weapon_list.map(func(a): return str(a.id))
	return ids.filter(func(a): return gdb.weapons.has(a))


## Rolls every slot (or only unsold ones), deterministic from seed + hour_index + rerolls (+ slot).
func _roll_stock(only_unsold: bool) -> void:
	var st := _state()
	var gdb := _gear_db()
	var n := stock_size()
	var old: Array = st.stock
	var stock: Array = []
	var taken: Array = []
	for i in n:
		if only_unsold and i < old.size() and bool(old[i].get("sold", false)):
			taken.append(str(old[i].get("item", {}).get("archetype", "")))
	for i in n:
		if only_unsold and i < old.size() and bool(old[i].get("sold", false)):
			stock.append(old[i])
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([int(st.seed), int(st.hour_index), int(st.rerolls), i, "gravecrew_merchant"])
		var featured := slot_featured(i)
		var r := _pick_rarity(rng, i)
		var pool := _arch_pool()
		if bool(data.get("avoid_duplicate_archetypes", true)):
			var fresh := pool.filter(func(a): return not (a in taken))
			if not fresh.is_empty():
				pool = fresh
		var arch: String = str(pool[rng.randi_range(0, pool.size() - 1)])
		taken.append(arch)
		var c := rarity_cfg(r)
		var ipr: Array = c.get("item_power", [100, 100])
		var fb: Dictionary = data.get("featured_bonus", {}) if featured else {}
		var ip := rng.randi_range(int(ipr[0]), int(ipr[-1])) + int(fb.get("item_power", 0))
		# No duds: re-roll (deterministic) until the stat roll reaches the rarity's roll_quality_floor; keep the best.
		var w: WeaponItem = null
		for attempt in maxi(int(data.get("max_roll_attempts", 1)), 1):
			seed(rng.randi()) # roll_weapon's own picks (stats, maker, name, perks) use the global RNG
			var cand: WeaponItem = gdb.roll_weapon(arch, r, 1, "", ip)
			if w == null or cand.roll_quality > w.roll_quality:
				w = cand
			if w.roll_quality >= float(c.get("roll_quality_floor", 0.0)):
				break
		var extra := int(c.get("bonus_perks", 0)) + int(fb.get("bonus_perks", 0))
		var perk_ids: Array = _perk_pool().filter(func(k): return not (k in w.perks))
		while extra > 0 and not perk_ids.is_empty():
			w.perks.append(perk_ids.pop_at(rng.randi_range(0, perk_ids.size() - 1)))
			extra -= 1
		_ensure_playstyle(w, int(c.get("playstyle_perks_min", 0)), rng)
		if r == Rarity.MYTHIC:
			var sigs := signature_perks()
			if not sigs.is_empty():
				w.perks.append(sigs[rng.randi_range(0, sigs.size() - 1)])
		w.seen = false
		var oid := "lot%d_%d" % [int(st.gen), i]
		stock.append({"offer_id": oid, "slot": i, "featured": featured, "rarity": r,
			"price": price_for(r, featured), "sold": false, "item": w.to_dict()})
		_items[oid] = w
	randomize() # don't leave the global RNG on a predictable seed
	st["stock"] = stock


## Random-perk pool: every perk except Mythic signatures (sorted, so rolls are deterministic).
func _perk_pool() -> Array:
	var gdb := _gear_db()
	var ids: Array = gdb.perks.keys().filter(func(k): return not bool(gdb.perks[k].get("signature", false)))
	ids.sort()
	return ids


func is_playstyle_perk(id: String) -> bool:
	return bool(_gear_db().perk(id).get("playstyle", false))


## Mythic signature perk ids from data that exist in GearDB.perks (none until MAIN_HOOKS §19c adds them).
func signature_perks() -> Array:
	var gdb := _gear_db()
	return data.get("mythic_signature_perks", []).filter(func(k): return gdb.perks.has(str(k))).map(func(k): return str(k))


## Swaps random non-playstyle perks for playstyle ones until `need` are on the gun. A Mythic's archetype perk (index 0,
## from weapons.json mythic.perk) is never swapped out.
func _ensure_playstyle(w: WeaponItem, need: int, rng: RandomNumberGenerator) -> void:
	var locked := 1 if w.rarity == Rarity.MYTHIC and w.arch.has("mythic") else 0
	var have := Array(w.perks).filter(func(k): return is_playstyle_perk(k)).size()
	while have < need:
		var cands: Array = _perk_pool().filter(func(k): return is_playstyle_perk(k) and not (k in w.perks))
		if cands.is_empty():
			return
		var pick: String = cands[rng.randi_range(0, cands.size() - 1)]
		var idx := -1
		for j in range(w.perks.size() - 1, locked - 1, -1):
			if not is_playstyle_perk(w.perks[j]):
				idx = j
				break
		if idx >= 0:
			w.perks[idx] = pick
		else:
			w.perks.append(pick)
		have += 1


# ================================================================== offers

func _find(offer_id: String) -> Dictionary:
	if _progress() == null:
		return {}
	for o in _state().stock:
		if str(o.get("offer_id", "")) == offer_id:
			return o
	return {}


func _preview(o: Dictionary) -> WeaponItem:
	var oid := str(o.offer_id)
	var w = _items.get(oid)
	if w == null or not is_instance_valid(w):
		w = _new_item(o)
		w.seen = false
		_items[oid] = w
	return w


func _new_item(o: Dictionary) -> WeaponItem:
	return _gear_db().item_from_dict(o.item) as WeaponItem


func _balance() -> int:
	var p := _progress()
	return int(p.gravemark_balance()) if p else 0


func _decorate(o: Dictionary) -> Dictionary:
	var w := _preview(o)
	var due := _due()
	var c := {"ok": false, "reason": R_EXPIRED} if due else _check(o)
	var r := int(o.rarity)
	return {"offer_id": str(o.offer_id), "slot": int(o.slot), "item_id": str(w.item_id), "item": w,
		"archetype": str(w.archetype), "rarity": r, "item_power": int(w.item_power), "perks": Array(w.perks),
		"attributes": w.attributes(), # playtest #33 named attribute rows (WEAPON_ATTRS.md)
		"price": int(o.price), "sold": bool(o.get("sold", false)), "owned": _owns(str(w.item_id)),
		"can_afford": _balance() >= int(o.price), "reason": "" if c.ok else str(c.reason),
		# added fields
		"featured": bool(o.get("featured", false)), "rarity_id": Rarity.IDS[r], "rarity_name": Rarity.name_of(r)}


func _check(o: Dictionary) -> Dictionary:
	if _progress() == null or _gear_db() == null:
		return {"ok": false, "reason": R_UNAVAILABLE}
	if bool(o.get("sold", false)):
		return {"ok": false, "reason": R_SOLD}
	var price := int(o.price)
	if _balance() < price:
		return {"ok": false, "reason": R_FUNDS % price}
	var room := _room(str(o.item.get("slot", "")))
	if not room.ok:
		return {"ok": false, "reason": room.reason}
	return {"ok": true, "reason": ""}


func _refuse(reason: String, with_item: bool) -> Dictionary:
	_last_refusal = reason
	return {"ok": false, "reason": reason, "item": null} if with_item else {"ok": false, "reason": reason}


# ================================================================== stash (live inventory or the saved stash dict)

func _live_inventory() -> Node:
	if inventory and is_instance_valid(inventory):
		return inventory
	var p := _progress()
	var inv = p.bound_inventory() if p and p.has_method("bound_inventory") else null
	return inv if inv and is_instance_valid(inv) else null


func _cap() -> int:
	return int(_gear_db().loot.get("stash", {}).get("cap", Inventory.DEFAULT_STASH_CAP))


## Same rules as Inventory.add_item: an empty equip slot auto-equips (no cap); else the backpack needs room
## (stash cap first, then the 9-tile slot grid).
func _room(slot: String) -> Dictionary:
	var inv := _live_inventory()
	if inv:
		if inv.equipped.get(slot) == null:
			return {"ok": true, "reason": ""}
		if inv.stash_full():
			return {"ok": false, "reason": R_STASH % [inv.carried_count(), inv.stash_cap]}
		if inv.backpack.get(slot, []).size() >= inv.backpack_size:
			return {"ok": false, "reason": R_SLOT_FULL}
		return {"ok": true, "reason": ""}
	var stash: Dictionary = _progress().stash
	if stash.is_empty() or stash.get("equipped", {}).get(slot) == null:
		return {"ok": true, "reason": ""}
	var carried := 0
	for s in stash.get("backpack", {}):
		carried += (stash.backpack[s] as Array).size()
	var cap := _cap()
	if cap >= 0 and carried >= cap:
		return {"ok": false, "reason": R_STASH % [carried, cap]}
	if stash.get("backpack", {}).get(slot, []).size() >= 9:
		return {"ok": false, "reason": R_SLOT_FULL}
	return {"ok": true, "reason": ""}


## Puts the gun in the live inventory, or (no match / home inventory bound) straight into Progress.stash.
## Returns {ok, reason, live}.
func _grant(w: WeaponItem) -> Dictionary:
	var inv := _live_inventory()
	if inv:
		if inv.add_item(w):
			return {"ok": true, "reason": "", "live": true}
		return {"ok": false, "reason": _reject_reason(inv), "live": true}
	var p := _progress()
	var tmp := Inventory.new()
	for s in Inventory.WEAPON_SLOTS + Inventory.ARMOR_SLOTS:
		tmp.equipped[s] = null
		tmp.backpack[s] = []
	tmp.stash_cap = _cap()
	if not p.stash.is_empty():
		tmp.load_save_dict(p.stash.duplicate(true))
	var ok := tmp.add_item(w)
	var reason := "" if ok else _reject_reason(tmp)
	if ok:
		p.stash = tmp.to_save_dict()
	tmp.free()
	return {"ok": ok, "reason": reason, "live": false}


func _reject_reason(inv: Node) -> String:
	if str(inv.last_reject) == "stash_full":
		return R_STASH % [inv.carried_count(), inv.stash_cap]
	return R_SLOT_FULL


## `owned`: the stash (live inventory, else the saved stash) holds a gun with this item_id.
func _owns(item_id: String) -> bool:
	if item_id == "":
		return false
	var inv := _live_inventory()
	if inv:
		for s in inv.equipped:
			if inv.equipped[s] and str(inv.equipped[s].item_id) == item_id:
				return true
		for s in inv.backpack:
			for g in inv.backpack[s]:
				if str(g.item_id) == item_id:
					return true
		return false
	var stash: Dictionary = _progress().stash
	for s in stash.get("equipped", {}):
		var e = stash.equipped[s]
		if typeof(e) == TYPE_DICTIONARY and str(e.get("item_id", "")) == item_id:
			return true
	for s in stash.get("backpack", {}):
		for d in stash.backpack[s]:
			if typeof(d) == TYPE_DICTIONARY and str(d.get("item_id", "")) == item_id:
				return true
	return false
