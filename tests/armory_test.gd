extends SceneTree
## Armory: Gravemark currency, save v4 migration, drop rules x difficulty, upgrade cost curve, attachment effects,
## Gooey's Armory API (Skillz).
##   godot --headless --path . -s res://tests/armory_test.gd   (exit code = failures)
## Uses its own save file, never the real one.

var _fails := 0
var _passes := 0
var _sig: Array = []


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _src(code: String) -> Object:
	var gs := GDScript.new()
	gs.source_code = code
	gs.reload()
	return gs.new()


func _reset(prog: Node) -> void:
	prog.gravemarks = 0
	prog.gravemarks_lifetime = 0
	prog.match_gravemarks = 0
	prog.armory = {"upgrades": {}, "owned": [], "equipped": {}}
	prog.stash = {}
	prog.skill_ranks = {}
	prog.notify_armory("load", "", false)


func _zombie(meta: Dictionary = {}, variant: String = "") -> Object:
	var z = _src("extends Node3D\nvar variant_id := \"\"\nvar health := 100.0\nvar max_health := 100\n")
	z.variant_id = variant
	for k in meta:
		z.set_meta(k, meta[k])
	return z


func _run() -> void:
	var prog: Node = root.get_node("Progress")
	var A = load("res://scripts/armory/armory.gd")
	var D = load("res://scripts/world/difficulty.gd")
	var Ads = load("res://scripts/combat/ads_profile.gd")
	var gdb = root.get_node("GearDB")
	A.reload()
	D.set_active("")
	var test_dir := OS.get_user_data_dir().path_join("armory_test")
	DirAccess.make_dir_recursive_absolute(test_dir)
	prog.save_path = test_dir.path_join("progress_armory_test.cfg")
	DirAccess.remove_absolute(prog.save_path)
	_reset(prog)
	prog.currency_changed.connect(func(b): _sig.append(["cur", b]))
	prog.gravemark_gained.connect(func(n, s): _sig.append(["gain", n, s]))
	prog.armory_changed.connect(func(k, i): _sig.append(["arm", k, i]))

	# ------------------------------------------------------------ data
	var att_ids: Array = A.attachment_ids()
	check(att_ids.size() >= 30, "attachments.json: %d parts (>= 30)" % att_ids.size())
	var slot_ids: Array = A.slots().map(func(s): return str(s.id))
	check(slot_ids == ["optic", "muzzle", "barrel", "grip", "mag", "stock"], "six slots: optic muzzle barrel grip mag stock")
	check(A.slots().all(func(s): return str(s.socket) in ["Rail", "Muzzle", "Barrel", "Underbarrel", "MagWell", "Stock"]),
		"slot sockets match DESI_ATTACHMENTS (Rail/Muzzle/Barrel/Underbarrel/MagWell/Stock)")
	check(A.weapons().size() == 9 and A.weapons().all(func(w): return not A.class_slots(w.id).is_empty()), "all 9 archetypes have slots")
	check(A.class_slots("sidearm") == ["optic", "muzzle", "mag"] and A.class_slots("rocket_launcher") == ["optic", "grip", "mag"]
		and A.class_slots("auto_rifle").size() == 6, "class slots per DESI §1 (sidearm 3, rocket 3, rifles 6)")
	var every_slot_has_part := true
	for w in A.weapons():
		for s in A.class_slots(w.id):
			if att_ids.filter(func(id): return A.is_compatible(id, w.id) and str(A.attachment(id).slot) == s).is_empty():
				every_slot_has_part = false
	check(every_slot_has_part, "every slot of every class has at least one compatible part")
	for n in ["Pinhole", "Lamplight Reflex", "Tallow Holo", "Crow's Eye 3x", "Longwatch 6x", "Pocket Hush", "Hush Can",
			"Mourner's Sleeve", "Splitjaw Brake", "Flare Cage", "Tightjaw Choke", "Fence Post", "Knuckle Stub", "Lean Grip",
			"Halfmoon Stop", "Crutch Bipod", "Second Mouth", "Gravesight", "Echo Drum"]:
		if not att_ids.any(func(id): return str(A.attachment(id).name) == n):
			check(false, "brief name present: " + n)
	check(att_ids.all(func(id): return str(A.attachment(id).get("summary", "")).length() <= 60), "summaries <= 60 chars")
	check(att_ids.filter(func(id): return not A.attachment(id).get("effects", []).is_empty()).size() >= 12,
		"at least 12 parts have behaviour effects (not just flat %)")
	check(A.is_compatible("pinhole", "sidearm") and not A.is_compatible("longwatch_6x", "smg")
		and A.is_compatible("longwatch_6x", "sniper_rifle") and A.is_compatible("longwatch_6x", "scout_rifle")
		and not A.is_compatible("longwatch_6x", "auto_rifle"), "optic size caps: Pinhole on sidearm, Longwatch only sniper/scout")
	check(A.compatible_archetypes("tightjaw_choke") == ["shotgun"] and A.compatible_archetypes("speedloader_ring") == ["hand_cannon"],
		"class-locked parts: Tightjaw = shotgun, Speedloader = hand cannon")
	check(not A.is_compatible("hush_can", "sidearm") and not A.is_compatible("fence_post", "sidearm"), "no muzzle can / grip where the slot or list says no")

	# ------------------------------------------------------------ currency ledger
	_sig.clear()
	check(prog.gravemark_balance() == 0, "fresh balance 0")
	prog.add_gravemark(3, "test")
	check(prog.gravemarks == 3 and prog.gravemarks_lifetime == 3 and prog.match_gravemarks == 3, "add_gravemark(3): balance, lifetime, match")
	check(_sig.has(["gain", 3, "test"]) and _sig.has(["cur", 3]), "gravemark_gained + currency_changed fire")
	prog.add_gravemark(0)
	prog.add_gravemark(-2)
	check(prog.gravemarks == 3, "zero / negative adds ignored")
	check(not prog.spend_gravemark(5) and prog.gravemarks == 3, "can't spend more than the balance")
	check(prog.spend_gravemark(2) and prog.gravemarks == 1 and prog.gravemarks_lifetime == 3, "spend 2 -> 1 (lifetime unchanged)")

	# ------------------------------------------------------------ save v4 + migration from v3
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "save_version", 3)
	cfg.set_value("stats", "xp", 750)
	cfg.set_value("skills", "version", 2)
	cfg.set_value("skills", "ranks", {"mk_root": 1})
	var legacy_w = gdb.roll_weapon("auto_rifle", 1, 3).to_dict()
	legacy_w.erase("item_id")
	var legacy_b = gdb.roll_weapon("smg", 0, 2).to_dict()
	legacy_b.erase("item_id")
	cfg.set_value("stash", "version", 1)
	cfg.set_value("stash", "data", {"version": 1, "equipped": {"primary": legacy_w}, "backpack": {"primary": [legacy_b]}})
	cfg.save(prog.save_path)
	prog.gravemarks = 99
	prog.load_data()
	check(prog.loaded_save_version == 3 and prog.gravemarks == 0 and prog.armory.owned.is_empty()
		and prog.armory.upgrades.is_empty() and prog.rank("mk_root") == 1, "v3 save: 0 Gravemarks, empty armory, skills kept")
	var mid: String = str(prog.stash.equipped.primary.get("item_id", ""))
	var bid: String = str(prog.stash.backpack.primary[0].get("item_id", ""))
	check(mid.begins_with("g") and mid.length() == 17 and bid != "" and bid != mid, "v3 stash items get stable unique item_ids on load")
	prog.add_gravemark(7, "test")
	prog.armory.upgrades["auto_rifle"] = 2
	prog.armory.owned.append("hush_can")
	prog.armory.equipped["auto_rifle"] = {"muzzle": "hush_can"}
	prog.save_data()
	var c2 := ConfigFile.new()
	c2.load(prog.save_path)
	check(int(c2.get_value("meta", "save_version", 0)) == 4 and prog.SAVE_VERSION == 4, "written as save_version 4")
	check(int(c2.get_value("armory", "gravemarks", -1)) == 7 and c2.has_section_key("armory", "data"), "[armory] gravemarks + data saved")
	prog.gravemarks = 0
	prog.armory = {"upgrades": {}, "owned": [], "equipped": {}}
	prog.load_data()
	check(prog.loaded_save_version == 4 and prog.gravemarks == 7 and A.upgrade_tier("auto_rifle") == 2 and A.owned("hush_can")
		and A.loadout("auto_rifle") == {"muzzle": "hush_can"}, "v4 reload: balance, tier, owned, loadout")
	check(str(prog.stash.equipped.primary.item_id) == mid, "item_id survives the save round trip")
	var junk: Dictionary = prog.migrate_armory({"upgrades": {"smg": 0, "auto_rifle": "3"}, "owned": ["a", "a", 5], "equipped": {"x": 4, "smg": {"optic": ""}}})
	check(junk.upgrades == {"auto_rifle": 3} and junk.owned == ["a", "5"] and junk.equipped == {"smg": {}}
		and prog.migrate_armory(null) == {"upgrades": {}, "owned": [], "equipped": {}}, "migrate_armory drops junk")
	var g1 = gdb.roll_weapon("sidearm", 0, 1)
	var g2 = gdb.roll_weapon("sidearm", 0, 1)
	var g3 = gdb.item_from_dict(g1.to_dict())
	check(g1.item_id != g2.item_id and g3.item_id == g1.item_id, "new items get distinct item_ids; to_dict/item_from_dict keeps it")
	_reset(prog)

	# ------------------------------------------------------------ drops x difficulty
	D.set_active("easy")
	A.reset_match_state()
	check(is_equal_approx(A.drop_mult(), 1.0), "easy drop mult 1.0")
	D.set_active("medium")
	check(is_equal_approx(A.drop_mult(), 1.35), "medium drop mult 1.35 (difficulty.json)")
	D.set_active("hard")
	check(is_equal_approx(A.drop_mult(), 1.75), "hard drop mult 1.75")
	check(A.roll_count(0.2, 0.3) == 1 and A.roll_count(0.2, 0.4) == 0, "hard: 20% chance becomes 35%")
	check(A.roll_count(1.0, 0.7) == 2 and A.roll_count(1.0, 0.8) == 1, "hard: guaranteed 1 x 1.75 = 1 + 75% roll")
	D.set_active("easy")
	check(A.roll_count(0.2, 0.19) == 1 and A.roll_count(0.2, 0.21) == 0, "easy: 20% stays 20%")

	_reset(prog)
	A.reset_match_state()
	check(A.on_zombie_died(_zombie({"is_boss": true, "boss_id": "bellwether"}), 10) == 2, "easy Bellwether kill pays 2")
	check(A.on_zombie_died(_zombie({"is_boss": true, "boss_id": "choir_host"}), 10) == 1, "second boss in the same round pays 1")
	check(A.on_zombie_died(_zombie({"boss_echo": true}), 10, 0.0) == 0, "Choir echoes pay nothing")
	check(A.on_zombie_died(_zombie({"elite": true}), 10, 0.1) == 1 and A.on_zombie_died(_zombie({"elite": true}), 10, 0.5) == 0, "elite: 20% roll")
	check(A.on_zombie_died(_zombie({}, "soldier"), 10, 0.005) == 1 and A.on_zombie_died(_zombie({}, "soldier"), 10, 0.007) == 0, "soldier: 0.6% roll")
	check(A.on_zombie_died(_zombie({}, "city"), 10, 0.001) == 1 and A.on_zombie_died(_zombie({}, "city"), 10, 0.01) == 0, "regular: 0.15% roll")
	check(prog.gravemarks == 6 and _sig.has(["gain", 2, "boss"]), "paid into Progress with source tags")
	D.set_active("hard")
	A.reset_match_state()
	check(A.on_zombie_died(_zombie({"is_boss": true, "boss_id": "bellwether"}), 6) == 4, "hard Bellwether: 2 x 1.75 -> 4")
	D.set_active("easy")
	check(A.on_round_cleared(9) == 0 and A.on_round_cleared(10, 0.5) == 1 and A.on_round_cleared(20, 0.5) == 1, "milestone: 1 at rounds 10 / 20")
	D.set_active("hard")
	check(A.on_round_cleared(30, 0.5) == 2 and A.on_round_cleared(30, 0.9) == 1, "hard milestone 1.75 -> 1 or 2")
	D.set_active("easy")
	A.reset_match_state()
	var c_a: int = A.on_chest_opened(3, 0.0)
	var c_b: int = A.on_chest_opened(3, 0.0)
	var c_c: int = A.on_chest_opened(4, 0.0)
	var c_d: int = A.on_chest_opened(5, 0.0)
	check(c_a == 1 and c_b == 0 and c_c == 1 and c_d == 0, "chest: max 1 per round, 2 per match")
	check(A.on_chest_opened(6, 0.9) == 0, "chest roll above 4% pays nothing")
	check(A.on_chest_opened(1, 0.0) == 1 and prog.match_gravemarks == 1, "lower round = new match: chest + match counters reset")
	prog.match_gravemarks = A.match_cap() - 1
	check(A.award(3, "test") == 1 and A.award(2, "test") == 0, "match cap clips payouts")
	prog.begin_match_gravemarks()
	check(prog.match_gravemarks == 0 and A.award(2, "test") == 2, "begin_match_gravemarks resets the cap")

	# ------------------------------------------------------------ cost curve + income model
	var costs: Array = []
	for t in range(1, A.max_tier() + 1):
		costs.append(A.tier_cost("auto_rifle", t))
	var growth := float(A.cfg().upgrades.get("min_growth", 1.6))
	var steep := true
	for i in range(1, costs.size()):
		if float(costs[i]) < float(costs[i - 1]) * growth:
			steep = false
	check(A.max_tier() == 5 and costs == [3, 6, 11, 20, 36], "upgrade tiers I-V cost 3/6/11/20/36 (data)")
	check(steep, "each tier costs >= %.1fx the previous one" % growth)
	check(A.tier_cost("rocket_launcher", 5) == 45 and A.upgrade_total_cost("auto_rifle") == 76, "rocket x1.25; one archetype to V = 76")
	check(A.tier_cost("auto_rifle", 0) == 0 and A.tier_cost("auto_rifle", 6) == 0, "out-of-range tier costs 0")
	var e15: Dictionary = A.expected_match_income("easy", 15)
	var e20: Dictionary = A.expected_match_income("easy", 20)
	var m15: Dictionary = A.expected_match_income("medium", 15)
	var h15: Dictionary = A.expected_match_income("hard", 15)
	print("      easy R15 breakdown: ", e15, "\n      easy R20: ", e20, "\n      hard R15: ", h15)
	print("      income R15: easy %.2f  medium %.2f  hard %.2f   easy R20 %.2f" % [e15.total, m15.total, h15.total, e20.total])
	check(e15.total >= 3.0 and e15.total <= 6.0, "Easy round-15 match earns 3-6 Gravemarks (%.2f)" % e15.total)
	check(e20.total <= 10.0, "Easy round-20 match stays <= 10 (%.2f)" % e20.total)
	check(h15.total > m15.total and m15.total > e15.total and h15.total >= e15.total * 1.8, "Hard > Medium > Easy, Hard >= 1.8x Easy")
	check(h15.total < float(A.match_cap()), "never dozens: Hard R15 under the match cap")
	var me: Dictionary = A.matches_to_max("easy")
	var mm: Dictionary = A.matches_to_max("medium")
	var mh: Dictionary = A.matches_to_max("hard")
	print("      matches to max one weapon: easy %d medium %d hard %d; everything: %d / %d / %d" % [me.one_weapon_max,
		mm.one_weapon_max, mh.one_weapon_max, me.everything, mm.everything, mh.everything])
	check(me.one_weapon_max >= 12, "Easy-only: maxing one weapon is a grind (>= 12 matches)")
	check(mh.one_weapon_max * 2 <= me.one_weapon_max, "Hard maxes a weapon in at most half the Easy matches")
	check(me.everything > mm.everything and mm.everything > mh.everything, "everything: Easy > Medium > Hard matches")

	# ------------------------------------------------------------ Armory API (outside a match: no player, no inventory)
	_reset(prog)
	prog.bind_inventory(null)
	var api = A.new()
	var api_sig: Array = []
	api.currency_changed.connect(func(b): api_sig.append(["cur", b]))
	api.armory_changed.connect(func(k, i): api_sig.append([k, i]))
	check(api.currency_name == "Gravemark" and api.currency_icon_key == "gravemark" and api.currency_balance() == 0, "currency name / icon / balance")
	var ups: Array = api.list_upgrades()
	check(ups.size() == 9 and ups.all(func(u): return u.has_all(["id", "name", "summary", "cost", "level", "current_level",
		"max_level", "owned", "slot", "requirements", "can_afford", "tiers"])), "list_upgrades: 9 tracks with Gooey's fields")
	var lst: Array = api.list_attachments("auto_rifle")
	check(lst.size() >= 15 and lst.all(func(a): return a.has_all(["id", "name", "summary", "cost", "owned", "equipped", "slot",
		"requirements", "can_afford", "state", "tier", "icon"])), "list_attachments(auto_rifle): %d parts with Gooey's fields" % lst.size())
	check(api.list_attachments("auto_rifle", "optic").all(func(a): return a.slot == "optic"), "slot filter")
	check(api.list_slots("sidearm").size() == 3 and api.list_weapons().size() == 9, "list_slots / list_weapons")
	check(not api.can_afford("hush_can") and not api.purchase("hush_can"), "broke: can't afford / purchase fails")
	prog.add_gravemark(40, "test")
	check(api_sig.has(["cur", 40]), "instance forwards currency_changed")
	check(api.can_afford("hush_can") and api.cost("hush_can") == 4 and api.purchase("hush_can") and api.currency_balance() == 36,
		"buy Hush Can for 4")
	check(api_sig.has(["purchase", "hush_can"]) and not api.can_afford("hush_can") and not api.purchase("hush_can"), "armory_changed(purchase); can't buy twice")
	check(not api.equip_attachment("auto_rifle", "optic", "hush_can"), "wrong slot rejected")
	check(not api.equip_attachment("sidearm", "", "hush_can"), "incompatible weapon rejected")
	check(api.equip_attachment("auto_rifle", "muzzle", "hush_can") and api.equipped("auto_rifle") == {"muzzle": "hush_can"}
		and api_sig.has(["equip", "hush_can"]), "equip Hush Can on Auto Rifle")
	check(api.list_attachments("auto_rifle").filter(func(a): return a.id == "hush_can")[0].state == "equipped", "state: equipped")
	var crow: Dictionary = api.list_attachments("auto_rifle").filter(func(a): return a.id == "crows_eye_3x")[0]
	check(crow.state == "locked" and not crow.requirements.is_empty() and not api.can_afford("crows_eye_3x"), "tier-2 optic locked until Rework II")
	check(api.purchase("upg_auto_rifle") and api.purchase("upg_auto_rifle") and A.upgrade_tier("auto_rifle") == 2
		and api.currency_balance() == 27, "buy Auto Rifle Rework I + II (3 + 6)")
	check(api_sig.has(["upgrade", "upg_auto_rifle"]) and api.list_upgrades("auto_rifle")[0].level == 2
		and api.list_upgrades("auto_rifle")[0].cost == 11, "upgrade entry: level 2, next cost 11")
	check(api.purchase("crows_eye_3x") and api.equip_attachment("auto_rifle", "optic", "crows_eye_3x"), "Crow's Eye buyable + equippable at tier II")
	check(api.purchase("fat_drum") and api.equip_attachment("auto_rifle", "", "fat_drum") and api.purchase("lean_grip")
		and api.equip_attachment("auto_rifle", "grip", "lean_grip"), "Fat Drum + Lean Grip on the Auto Rifle")
	check(api.unequip("auto_rifle", "grip") and not api.equipped("auto_rifle").has("grip") and api.equip_attachment("auto_rifle", "grip", "lean_grip"),
		"unequip + re-equip")
	var c3 := ConfigFile.new()
	c3.load(prog.save_path)
	check("crows_eye_3x" in c3.get_value("armory", "data", {}).get("owned", []), "purchases save at once")
	# item_id resolves to its archetype
	var w_ar = gdb.roll_weapon("auto_rifle", 0, 1)
	prog.stash = {"version": 1, "equipped": {"primary": w_ar.to_dict()}, "backpack": {}}
	check(A.resolve_weapon(w_ar.item_id) == "auto_rifle" and api.equipped(w_ar.item_id) == api.equipped("auto_rifle"),
		"weapon_id can be a gear item_id (resolved via the stash)")
	prog.stash = {}

	# ------------------------------------------------------------ attachment effects on weapons
	var ar = gdb.roll_weapon("auto_rifle", 2, 5)
	var sm = gdb.roll_weapon("smg", 2, 5)
	var skill_mag := 1.0 + float(Engine.get_meta(&"skill_mag_bonus", 0.0))
	check(ar.mag_size() == int(round(float(ar.arch.base_mag) * (0.7 + ar.stat("magazine") * 0.006) * skill_mag * 1.6)), "Fat Drum: magazine x1.6 (%d)" % ar.mag_size())
	var ar_reload_base = float(ar.arch.base_reload) * (1.35 - ar.stat("reload") * 0.007)
	check(is_equal_approx(ar.reload_time(), ar_reload_base * 1.35 * 0.95), "Fat Drum reload x1.35 and Rework II reload x0.95")
	check(is_equal_approx(ar.falloff_start(), float(ar.arch.base_range) * (0.6 + ar.stat("range") * 0.008) * 0.92), "Hush Can range -8%")
	check(ar.effective_item_power() == ar.item_power + 16, "Rework II: +16 Item Power")
	var p_base = 1.0 + (ar.item_power - 100) * 0.004
	check(is_equal_approx(ar.power_mult(), p_base + 16 * 0.004), "damage uses the effective Item Power")
	check(sm.effective_item_power() == sm.item_power and sm.mag_size() == int(round(float(sm.arch.base_mag) * (0.7 + sm.stat("magazine") * 0.006) * skill_mag)),
		"other archetypes untouched")
	check(bool(A.flag("auto_rifle", "tracer_hidden")) and is_equal_approx(float(A.flag("auto_rifle", "flash_mult", 1.0)), 0.2),
		"Hush Can flags: tracer hidden, flash x0.2")
	check(is_equal_approx(Ads.ads_fov("auto_rifle"), 40.0) and is_equal_approx(Ads.target_fov(true, "auto_rifle", 75.0), 40.0),
		"Crow's Eye: Auto Rifle ADS FOV 55 -> 40")
	check(is_equal_approx(Ads.ads_fov("smg"), 65.0), "no optic: family FOV")
	check(is_equal_approx(Ads.move_speed_mult(true, "auto_rifle"), 1.0 - 0.3 / (0.85 * 1.3)), "ADS move: Crow's Eye x0.85, Lean Grip x1.3 on the penalty")
	check(is_equal_approx(Ads.spread_mult(true, "auto_rifle"), 0.45 * 0.9) and is_equal_approx(Ads.spread_mult(false, "auto_rifle"), 1.0),
		"ADS spread: Lean Grip -10%; hip unchanged")
	Ads.target_fov(false, "auto_rifle", 75.0)
	check(is_equal_approx(Ads.spread_mult(true), 0.45 * 0.9), "no archetype arg: uses the last target_fov archetype (live player hook)")
	check(is_equal_approx(Ads.move_speed_mult(true, "smg"), 0.7) and is_equal_approx(Ads.spread_mult(true, "smg"), 0.45), "smg: plain ADS numbers")
	# shotgun pellets + choke, splitjaw recoil, longwatch scope overlay on a scout
	prog.add_gravemark(60, "test")
	for id in ["tightjaw_choke", "splitjaw_brake"]:
		api.purchase(id)
	api.equip_attachment("shotgun", "muzzle", "tightjaw_choke")
	var sg = gdb.roll_weapon("shotgun", 1, 3)
	check(sg.pellets() == int(sg.arch.pellets) - 2 and is_equal_approx(sg.spread_deg(), float(sg.arch.spread) * (1.4 - sg.stat("stability") * 0.008) * 0.6),
		"Tightjaw: 2 fewer pellets, spread x0.6")
	api.equip_attachment("smg", "muzzle", "splitjaw_brake")
	check(is_equal_approx(sm.recoil(), 0.09 * (1.5 - sm.stat("stability") * 0.01) * 0.6) and is_equal_approx(float(A.flag("smg", "flash_mult", 1.0)), 1.8),
		"Splitjaw: recoil x0.6, flash x1.8")
	for i in 4:
		api.purchase("upg_scout_rifle")
	check(api.purchase("longwatch_6x") and api.equip_attachment("scout_rifle", "optic", "longwatch_6x") and Ads.wants_scope_overlay("scout_rifle")
		and is_equal_approx(Ads.ads_fov("scout_rifle"), 22.0), "Longwatch (tier 3, Rework IV): Scout ADS 22 FOV + scope overlay")
	var sc = gdb.roll_weapon("scout_rifle", 1, 3)
	check(is_equal_approx(sc.headshot_mult(), float(sc.arch.get("headshot_multiplier", 2.0)) + 0.4), "Longwatch precision +0.4")

	# ------------------------------------------------------------ behaviour effects through the SkillRunner
	var fp = _src("extends Node3D\nvar w\nvar ads_active := false\nfunc current_weapon():\n\treturn w\nfunc is_airborne():\n\treturn false\nfunc emit_ammo():\n\tpass\n")
	root.add_child(fp)
	fp.w = ar
	var runner = load("res://scripts/skills/skill_runner.gd").new()
	root.add_child(runner)
	runner.setup(fp)
	runner.rebuild()
	var arm_fx: Array = runner.effects.filter(func(e): return e.source_kind == "armory")
	check(arm_fx.size() >= 2 and arm_fx.all(func(e): return e.weapon_arch != ""), "SkillRunner attaches equipped-part effects, gated by archetype")
	var fresh = _zombie()
	var hurt = _zombie()
	hurt.health = 40.0
	check(is_equal_approx(runner.modify("damage_out", 100.0, {"source": "gun", "weapon": ar, "target": fresh}), 125.0),
		"Hush Can ambush: +25% on an unhurt zombie")
	check(is_equal_approx(runner.modify("damage_out", 100.0, {"source": "gun", "weapon": ar, "target": hurt}), 100.0), "no bonus once it's hurt")
	check(is_equal_approx(runner.modify("damage_out", 100.0, {"source": "gun", "weapon": sm, "target": fresh}), 100.0), "SMG in ctx: Auto Rifle parts off")
	fp.ads_active = true
	check(is_equal_approx(runner.modify("damage_out", 100.0, {"source": "gun", "weapon": ar, "target": hurt, "distance": 99.0, "falloff_start": 20.0}), 115.0),
		"Crow's Eye: +15% beyond falloff while aiming")
	fp.ads_active = false
	check(is_equal_approx(runner.modify("damage_out", 100.0, {"source": "gun", "weapon": ar, "target": hurt, "distance": 99.0, "falloff_start": 20.0}), 100.0),
		"... and nothing from the hip")
	# Echo Drum: precision kill puts rounds back (refill_mag through the bus)
	prog.add_gravemark(40, "test")
	for i in 2:
		api.purchase("upg_auto_rifle")
	check(A.upgrade_tier("auto_rifle") == 4 and api.purchase("echo_drum") and api.equip_attachment("auto_rifle", "mag", "echo_drum"), "Echo Drum on a Rework IV Auto Rifle")
	runner.rebuild()
	ar.ammo = 5
	var bus = root.get_node("GameEvents")
	bus.emit_event(&"enemy_killed", {"player": fp, "source": "gun", "weapon": ar, "is_headshot": true, "target": hurt})
	check(ar.ammo == 8, "Echo Drum: precision kill returns 3 rounds (%d)" % ar.ammo)
	bus.emit_event(&"enemy_killed", {"player": fp, "source": "gun", "weapon": ar, "is_headshot": false, "target": hurt})
	bus.emit_event(&"enemy_killed", {"player": fp, "source": "gun", "weapon": sm, "is_headshot": true, "target": hurt})
	check(ar.ammo == 8, "body kills / other weapons don't refill")
	runner.queue_free()
	fp.queue_free()

	# ------------------------------------------------------------ cleanup
	_reset(prog)
	D.set_active("")
	A.reset_match_state()
	DirAccess.remove_absolute(prog.save_path)
	print("armory_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
