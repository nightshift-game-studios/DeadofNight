extends SceneTree
## Economy v2 (Skillz, Jason v0.6.1 playtest Batch A; DESIGN §21). Own save file + XDG temp dir, never the real save.
##   XDG_DATA_HOME=/tmp/econ_xdg godot --headless --path . -s res://tests/econ_test.gd   (exit code = failures)
## Points, paid + relocating chests and ChestSpots (Mapz format), drops, Scrap + save v6 (.tmp / .bak), XP curve,
## StatEffects on the live player, GearDB.is_upgrade + Pickup.rarity, MatchStats.

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _src(code: String) -> Object:
	var gs := GDScript.new()
	gs.source_code = code
	gs.reload()
	return gs.new()


const MAP_SRC := "extends Node3D\nvar start_area := &\"start\"\nvar unlocked := {&\"start\": true}\nfunc is_area_open(a) -> bool:\n\treturn unlocked.has(StringName(a))\n"


func _marker(parent: Node, n: String, pos: Vector3, meta: Dictionary) -> Marker3D:
	var m := Marker3D.new()
	m.name = n
	m.position = pos
	for k in meta:
		m.set_meta(k, meta[k])
	parent.add_child(m)
	return m


func _run() -> void:
	var prog = root.get_node("Progress")
	var gdb = root.get_node("GearDB")
	var P = load("res://scripts/autoload/progress.gd")
	prog.save_path = "user://progress_econ_test.cfg"
	P.delete_save_files(prog.save_path)

	# ------------------------------------------------------------ 1. points ~ -50%
	var rp: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/run_picks.json"))
	check(prog.points_per_hit == 3 and prog.points_per_kill == 25 and int(rp.offer.skip_points_per_round) == 25
		and int(rp.offer.cache_points_per_round) == 25, "points: 3 / hit, 25 / kill, skip + cache 25 x round (was 5 / 50 / 50 / 50)")
	var bc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/bosses.json"))
	check(int(bc.get("default_points_per_kill", 0)) == 25, "boss kill points 25 (was 50)")

	# ------------------------------------------------------------ 2. chests: price + ChestSpots
	var CH = load("res://scripts/items/chest.gd")
	var cc: Dictionary = prog.chest_cfg()
	check(CH.price_for(0, cc) == 1500 and CH.price_for(1, cc) == 1750 and CH.price_for(20, cc) == 3000 and bool(cc.relocate),
		"chest price 1500, +250 per chest bought this match, cap 3000; relocate on")
	var map: Node3D = _src(MAP_SRC)
	map.name = "FakeMap"
	root.add_child(map)
	var holder := Node3D.new()
	holder.name = "ChestSpots"
	map.add_child(holder)
	var s1 := _marker(holder, "ChestSpot1", Vector3(0, 0, 0), {"area": &"start", "initial": true})
	_marker(holder, "ChestSpot2", Vector3(10, 0, 0), {"area": &"start", "hidden": true})
	_marker(holder, "ChestSpot3", Vector3(20, 0, 0), {"area": [&"yard", &"start"]}) # boundary: one side open
	_marker(holder, "ChestSpot4", Vector3(30, 0, 0), {"area": [&"yard", &"cellar"]}) # all areas locked
	_marker(holder, "ChestSpot5", Vector3(40, 0, 0), {"area": "start", "weight": 0.0}) # weight 0 never picked
	_marker(holder, "ChestSpot6", Vector3(50, 0, 0), {"area": &"start", "weight": 2.0})
	var extra := Marker3D.new() # group member outside ChestSpots counts too
	extra.name = "LooseSpot"
	extra.add_to_group("chest_spot")
	map.add_child(extra)
	extra.position = Vector3(60, 0, 0)
	extra.set_meta("area", &"cellar")
	s1.rotation.y = 0.7
	var spots: Array = ChestSpots.collect(map)
	check(spots.size() == 7 and spots.all(func(s): return s.source == "chest_spots"), "collect: 6 ChestSpots children + 1 chest_spot group member (%d)" % spots.size())
	var t1: Transform3D = spots[0].transform
	check(t1.basis.z.is_equal_approx(-s1.global_basis.z) and t1.origin.is_equal_approx(s1.global_position), "chest front (+Z) faces the marker's -Z (walkway)")
	check(spots[2].areas == [&"yard", &"start"] and spots[4].areas == [&"start"] and bool(spots[1].hidden) and bool(spots[0].initial)
		and not bool(spots[1].initial), "meta: area StringName / String / Array, hidden, initial")
	var cands: Array = ChestSpots.candidates(spots, Vector3.ZERO, [Vector3(50, 0, 0)], map, null, cc)
	var names: Array = cands.map(func(c): return c.spot.name)
	names.sort()
	check(names == ["ChestSpot2", "ChestSpot3"], "candidates skip own spot, occupied, all-locked boundary, weight 0, locked area (%s)" % [names])
	var w2: float = cands.filter(func(c): return c.spot.name == "ChestSpot2")[0].w
	check(is_equal_approx(w2, float(cc.hidden_bias)), "hidden spot weight x hidden_bias (%.1f)" % w2)
	var near: Array = ChestSpots.candidates(spots, Vector3.ZERO, [], map, Vector3(20, 0, 0), cc)
	var w3: float = near.filter(func(c): return c.spot.name == "ChestSpot3")[0].w
	check(is_equal_approx(w3, float(cc.near_player_mult)), "spot next to the player x near_player_mult (%.2f)" % w3)
	map.unlocked[&"cellar"] = true
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var got := {}
	var bad := false
	for i in 300:
		var sp: Dictionary = ChestSpots.pick(spots, Vector3.ZERO, [], map, null, cc, rng)
		got[sp.name] = int(got.get(sp.name, 0)) + 1
		bad = bad or sp.name == "ChestSpot1" or sp.name == "ChestSpot5"
	check(not bad and got.has("ChestSpot4") and got.has("LooseSpot") and int(got.get("ChestSpot2", 0)) > int(got.get("ChestSpot3", 0)),
		"pick: never the current / weight-0 spot; unlocking cellar opens Spot4 + LooseSpot; hidden picked more (%s)" % [got])
	check(ChestSpots.pick(spots.slice(0, 1), Vector3.ZERO, [], map, null, cc).is_empty(), "nothing free -> {} (chest waits for the next round)")
	# off-navmesh spots (arena Tower perch): skipped while an on-navmesh spot is free, used only when nothing else is
	var nm := NavigationMesh.new()
	nm.vertices = PackedVector3Array([Vector3(-5, 0, -5), Vector3(65, 0, -5), Vector3(65, 0, 5), Vector3(-5, 0, 5)])
	nm.add_polygon(PackedInt32Array([3, 2, 1, 0]))
	var nreg := NavigationRegion3D.new()
	nreg.navigation_mesh = nm
	root.add_child(nreg)
	var nav_rid: RID = root.world_3d.navigation_map
	var nwait := 0
	while nwait < 240 and NavigationServer3D.map_get_closest_point(nav_rid, Vector3(10, 3.4, 1)) == Vector3.ZERO:
		await physics_frame
		nwait += 1
	print("  nav probe after %d frames: closest to (10, 3.4, 1) = %s" % [nwait, NavigationServer3D.map_get_closest_point(nav_rid, Vector3(10, 3.4, 1))])
	var perch: Dictionary = spots[1].duplicate()
	var pt: Transform3D = perch.transform
	pt.origin.y = 3.4
	perch.transform = pt
	var nav_spots: Array = [spots[0], perch, spots[2]]
	var on_names: Array = ChestSpots.candidates(nav_spots, Vector3.ZERO, [], map, null, cc, nav_rid).map(func(c): return c.spot.name)
	check(on_names == ["ChestSpot3"] and ChestSpots.on_navmesh(spots[2], nav_rid, cc) and not ChestSpots.on_navmesh(perch, nav_rid, cc),
		"off-navmesh spot (3.4 m perch) skipped while an on-navmesh spot is free (%s)" % [on_names])
	var island := NavigationMesh.new() # the perch top has its own navmesh island (arena Tower): snaps, but no path to it
	island.vertices = PackedVector3Array([Vector3(8, 3.4, -2), Vector3(12, 3.4, -2), Vector3(12, 3.4, 3), Vector3(8, 3.4, 3)])
	island.add_polygon(PackedInt32Array([3, 2, 1, 0]))
	var ireg := NavigationRegion3D.new()
	ireg.navigation_mesh = island
	root.add_child(ireg)
	nwait = 0
	while nwait < 240 and NavigationServer3D.map_get_closest_point(nav_rid, Vector3(10, 3.4, 1)).y < 3.0:
		await physics_frame
		nwait += 1
	check(ChestSpots.on_navmesh(perch, nav_rid, cc) and not ChestSpots.on_navmesh(perch, nav_rid, cc, Vector3(30, 0, 0))
		and ChestSpots.on_navmesh(spots[2], nav_rid, cc, Vector3(30, 0, 0))
		and ChestSpots.candidates(nav_spots, Vector3.ZERO, [], map, null, cc, nav_rid, Vector3(30, 0, 0)).map(func(c): return c.spot.name) == ["ChestSpot3"],
		"navmesh island (Tower top): snaps, but unreachable from the player spawn -> off-navmesh with nav_ref")
	ireg.free()
	var only_perch: Dictionary = ChestSpots.pick([spots[0], perch], Vector3.ZERO, [], map, null, cc, null, nav_rid)
	check(str(only_perch.get("name", "")) == "ChestSpot2", "only an off-navmesh spot free -> still used (a chest never sticks open)")
	check(ChestSpots.candidates(nav_spots, Vector3.ZERO, [], map, null, cc).size() == 2, "no nav map -> no navmesh filter")
	nreg.free()
	holder.free()
	extra.free()
	var fb := Node3D.new()
	fb.name = "Chests"
	map.add_child(fb)
	_marker(fb, "Chest1", Vector3(1, 0, 1), {"area": &"start"})
	_marker(fb, "Chest2", Vector3(9, 0, 1), {})
	var fspots: Array = ChestSpots.collect(map)
	check(fspots.size() == 2 and fspots.all(func(s): return s.source == "chests_fallback" and s.initial)
		and (fspots[0].transform as Transform3D).basis.z.is_equal_approx(Vector3(0, 0, 1)), "no ChestSpots: fallback to Chests/ markers as-is")
	map.free()

	# ------------------------------------------------------------ 3. drops rarer
	# grenade drops (MAIN_HOOKS §24c): grenades.json drop_weight x rarity_mult
	var gw: Dictionary = gdb.grenade_drop_weights()
	check(gw.size() == 9 and is_equal_approx(float(gw.frag), 116.0) and is_equal_approx(float(gw.pulse), 69.6)
		and is_equal_approx(float(gw.requiem_bell), 0.6) and float(gw.gravewell) < 4.0, "grenade drop weights = drop_weight x rarity_mult (frag %.0f, Requiem %.2f)" % [gw.frag, gw.requiem_bell])
	var grng := RandomNumberGenerator.new()
	grng.seed = 25
	var gcount := {}
	for i in 4000:
		var gid: String = gdb.roll_grenade_id(grng)
		gcount[gid] = int(gcount.get(gid, 0)) + 1
	check(int(gcount.get("frag", 0)) > int(gcount.get("pulse", 0)) and int(gcount.get("pulse", 0)) > int(gcount.get("cinderjar", 0))
		and int(gcount.get("cinderjar", 0)) > int(gcount.get("rookery", 0)) and int(gcount.get("requiem_bell", 0)) < 30, "grenade rolls follow the weights (%s)" % [gcount])
	var CI = load("res://scripts/items/consumable_item.gd")
	var gp = gdb.grenade_pickup("rookery")
	var gp2 = gdb.item_from_dict(gp.to_dict()) if gp else null
	check(gp != null and gp.id == "grenade_rookery" and gp.effect == CI.Effect.GRENADE and not gp.auto_use
		and gp.color.is_equal_approx(load("res://scripts/gear/rarity.gd").color(2)) and gp2 != null and gp2.grenade_id == "rookery" and gp2.display_name == gp.display_name,
		"grenade pickup: ConsumableItem GRENADE, rarity colour, to_dict / from_dict round-trip (%s)" % [gp.to_dict() if gp else {}])
	var has_g := false
	var saved_dc: float = float(gdb.loot.tables.zombie.drop_chance)
	gdb.loot.tables.zombie.drop_chance = 1.0
	for i in 400:
		for it in gdb.roll_table("zombie", 5):
			has_g = has_g or ("grenade_id" in it and "fittings" in it) # §25: GrenadeItem (equippable), not the old consumable
	gdb.loot.tables.zombie.drop_chance = saved_dc
	check(has_g and gdb.loot.tables.chest.entries.any(func(e): return e.get("kind") == "grenade"), "zombie + chest tables can drop grenades")
	var lt: Dictionary = gdb.loot.tables.zombie
	check(is_equal_approx(float(lt.drop_chance), 0.08), "zombie drop chance 0.08 (was 0.14)")
	var A = load("res://scripts/armory/armory.gd")
	var odds: Array = A.table_rarity_odds(lt, 1)
	check(odds.size() == 5 and odds[3] < 0.03 and odds[4] < 0.005, "rarity odds r1: Legendary %.1f%%, Mythic %.2f%%" % [odds[3] * 100.0, odds[4] * 100.0])

	# ------------------------------------------------------------ 5. Gravemark sources (income model)
	var m10: float = A.expected_match_income("medium", 10).total
	var m7: float = A.expected_match_income("medium", 7).total
	check(m10 >= 11.0 and m10 <= 16.0 and m7 >= 5.0, "Medium match pays %.1f GM at r10, %.1f at r7 (was 6.1 / 1.1)" % [m10, m7])

	# ------------------------------------------------------------ 8. Scrap + save v6
	prog.scrap = 0
	prog.scrap_lifetime = 0
	var sig: Array = []
	prog.scrap_gained.connect(func(n, s): sig.append([n, s]))
	var inv = load("res://scripts/items/inventory.gd").new()
	root.add_child(inv)
	var rare_w = gdb.roll_weapon("smg", 2, 3, "", 200)
	inv.backpack[rare_w.slot].append(rare_w)
	var val: int = prog.scrap_value(rare_w)
	check(val == 6 + 2 and A.scrap_yield(0) == 1 and A.scrap_yield(4) == 25, "scrap yield: Rare 6 + 1 per 50 IP over 100 (IP 200 -> %d); Common 1, Mythic 25 (salvage pass 2026-10-22)" % val)
	check(prog.scrap_item(rare_w, inv, "stash") == val and prog.scrap == val and not inv.backpack[rare_w.slot].has(rare_w)
		and sig == [[val, "stash"]], "scrap_item: removes the item, pays Scrap, scrap_gained(n, source)")
	check(not prog.spend_scrap(val + 1) and prog.spend_scrap(1) and prog.scrap == val - 1 and prog.scrap_lifetime == val, "spend_scrap")
	prog.xp = prog.xp_for_level(7)
	prog.save_data()
	var cf := ConfigFile.new()
	cf.load(prog.save_path)
	check(int(cf.get_value("meta", "save_version", 0)) == 6 and int(cf.get_value("scrap", "balance", -1)) == val - 1, "saved as v6 with [scrap] balance")
	prog.add_scrap(10, "test")
	prog.save_data() # previous file -> .bak
	FileAccess.open(prog.save_path, FileAccess.WRITE).store_string("[meta\ngarbage")
	prog.scrap = 0
	prog.load_data()
	check(prog.loaded_from == "bak" and prog.scrap == val - 1, "torn main: Scrap recovered from .bak (%s, %d)" % [prog.loaded_from, prog.scrap])
	var v5 := ConfigFile.new()
	v5.set_value("meta", "save_version", 5)
	v5.set_value("stats", "xp", 250 * 19 + 125)
	P.delete_save_files(prog.save_path)
	v5.save(prog.save_path)
	prog.load_data()
	check(prog.loaded_save_version == 5 and prog.scrap == 0 and prog.get_level() == 20 and prog.xp_rebased_from == 4875
		and prog.xp == prog.xp_for_level(20) + prog.xp_to_next(20) / 2, "v5 save: Scrap 0, level 20 kept on the curve (xp %d)" % prog.xp)

	# ------------------------------------------------------------ 6. XP curve
	check(prog.xp_to_next(1) == 300 and prog.xp_to_next(2) == 400 and prog.xp_to_next(40) == 2000, "xp_to_next 300 / 400 / ... cap 2000")
	var lv_ok := true
	for l in [1, 2, 5, 10, 20, 30]:
		lv_ok = lv_ok and prog.level_for_xp(prog.xp_for_level(l)) == l and prog.level_for_xp(prog.xp_for_level(l) - 1) == maxi(l - 1, 1)
	check(lv_ok and prog.xp_for_level(10) == 6300 and prog.xp_for_level(20) == 22700, "xp_for_level / level_for_xp round-trip (L10 6300, L20 22700)")

	# ------------------------------------------------------------ 10. is_upgrade + Pickup.rarity
	var held = gdb.roll_weapon("smg", 2, 3, "primary", 150)
	inv.equipped["primary"] = held
	var hi = gdb.roll_weapon("smg", 1, 3, "primary", 160)
	var same_c = gdb.roll_weapon("smg", 0, 3, "primary", 150)
	var same_l = gdb.roll_weapon("smg", 3, 3, "primary", 150)
	held.item_power = 150
	hi.item_power = 160
	same_c.item_power = 150
	same_l.item_power = 150
	var holder_p: Object = _src("extends Node\nvar inventory\n")
	holder_p.inventory = inv
	check(gdb.is_upgrade(hi, holder_p) and not gdb.is_upgrade(same_c, holder_p) and gdb.is_upgrade(same_l, holder_p)
		and not gdb.is_upgrade(held, holder_p), "is_upgrade: higher IP yes, same IP lower rarity no, same IP higher rarity yes, the held item no")
	var helmet = gdb.roll_armor("helmet", 0, 1, 100)
	check(gdb.is_upgrade(helmet, inv) and not gdb.is_upgrade(gdb.consumable("health_pack"), inv)
		and not gdb.is_upgrade(null, inv), "is_upgrade: empty slot -> true (Inventory works as player too); consumables / null -> false")
	var pk: Area3D = load("res://scripts/items/pickup.gd").new()
	pk.item = same_l
	check(pk.rarity == 3 and pk.get_rarity() == 3 and pk.is_gear() and gdb.is_upgrade(pk, holder_p) and pk.is_upgrade_for(holder_p),
		"Pickup.rarity (3 Legendary) + is_upgrade on a pickup")
	pk.item = null
	check(pk.rarity == -1, "Pickup.rarity -1 without gear")
	pk.free()

	# ------------------------------------------------------------ slot rule: primary = big guns, secondary = handguns
	var G = load("res://scripts/autoload/gear_db.gd")
	check(G.slot_for("smg") == "primary" and G.slot_for("shotgun") == "primary" and G.slot_for("pulse_rifle") == "primary"
		and G.slot_for("sidearm") == "secondary" and G.slot_for("hand_cannon") == "secondary" and G.slot_for("rocket_launcher") == "heavy",
		"slot_for: SMG / shotgun / LMG primary, sidearm + hand cannon (revolver) secondary, rocket launcher heavy")
	var arch_ok := true
	for a in gdb.weapon_list:
		arch_ok = arch_ok and str(a.slot) == G.slot_for(str(a.id))
	check(arch_ok, "every archetype's slot field matches slot_rules")
	var pistol = gdb.roll_weapon("sidearm", 1, 1)
	var rifle = gdb.roll_weapon("auto_rifle", 1, 1)
	check(pistol.slot == "secondary" and G.slot_refusal(pistol, "secondary") == "" and G.slot_refusal(pistol, "primary") == "Primary takes big guns only"
		and G.slot_refusal(rifle, "secondary") == "Secondary takes handguns only" and G.slot_refusal(rifle, "primary") == ""
		and G.slot_refusal(gdb.roll_armor("helmet", 0, 1), "helmet") == "", "slot_refusal texts (\"%s\")" % G.slot_refusal(rifle, "secondary"))
	var sidearm_old: Dictionary = pistol.to_dict()
	sidearm_old.slot = "primary" # a pre-rule save: sidearm in the primary slot, smg in secondary
	var smg_old: Dictionary = gdb.roll_weapon("smg", 0, 1).to_dict()
	smg_old.slot = "secondary"
	var hc_old: Dictionary = gdb.roll_weapon("hand_cannon", 2, 1).to_dict()
	hc_old.slot = "primary"
	var inv_m = load("res://scripts/items/inventory.gd").new()
	root.add_child(inv_m)
	inv_m.load_save_dict({"equipped": {"primary": sidearm_old, "secondary": smg_old}, "backpack": {"primary": [hc_old]}})
	var mig: Array = inv_m.slot_migrations.map(func(m): return "%s:%s->%s/%s" % [m.id, m.from, m.slot, m.to])
	check(inv_m.equipped.primary != null and inv_m.equipped.primary.archetype == "smg" and inv_m.equipped.secondary.archetype == "sidearm"
		and inv_m.backpack.secondary.size() == 1 and inv_m.backpack.secondary[0].archetype == "hand_cannon" and inv_m.backpack.primary.is_empty(),
		"old save migrated: smg -> primary, sidearm -> secondary, stashed hand cannon -> secondary stash (%s)" % [mig])
	var two_hand: Dictionary = gdb.roll_weapon("hand_cannon", 0, 1).to_dict()
	two_hand.slot = "primary"
	inv_m.load_save_dict({"equipped": {"primary": two_hand, "secondary": pistol.to_dict()}, "backpack": {}})
	check(inv_m.equipped.secondary.archetype == "sidearm" and inv_m.equipped.primary == null and inv_m.backpack.secondary.size() == 1
		and inv_m.slot_migrations.size() == 1 and inv_m.slot_migrations[0].to == "stash", "right slot taken: the moved weapon goes to the stash, nothing lost")
	var stale = gdb.roll_weapon("pulse_rifle", 0, 1)
	stale.slot = "secondary"
	inv_m.equipped.primary = null
	check(inv_m.equip_refusal(stale) != "" and inv_m.take_and_equip(stale).ok == false, "take_and_equip refuses a weapon whose slot breaks the rule")
	check(inv_m.add_item(stale) and stale.slot == "primary" and inv_m.equipped.primary == stale, "add_item re-homes it to its right slot")
	inv_m.free()

	# ------------------------------------------------------------ 9 + 11. live player: StatEffects, MatchStats
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	var main = current_scene
	main._break_timer = 9999.0
	var pl = main.player
	var pin = pl.inventory
	if not pl.has_method("get_stat_effects"):
		print("  (player.gd without MAIN_HOOKS §21b: StatEffects player checks skipped)")
		await _grenade_pickup_checks(main, pl)
		await _match_stats_checks(main, pl, prog)
		_finish(prog, P, inv)
		return
	for s in ["helmet", "gauntlets", "chest", "legs", "class_item"]:
		pin.equipped[s] = null
	pl.recalc_stats()
	var base := {"walk": pl.walk_speed, "sprint": pl.sprint_speed, "crouch": pl.crouch_speed, "regen_d": pl.regen_delay,
		"regen_r": pl.regen_rate, "gren": pl.grenade_cooldown, "melee": pl.melee_damage, "melee_cd": pl.melee_cooldown,
		"abil": float(pl.ability.cooldown) if pl.ability else 0.0}
	check(is_zero_approx(pl.damage_reduction) and absf(float(pl.get_stat_effects().move_speed_pct)) < 0.01, "no armor: no stat effects")
	var arm = gdb.roll_armor("chest", 0, 1, 100)
	arm.stats = {"agility": 20, "toughness": 20, "vitality": 20, "ordnance": 20, "focus": 20, "brawn": 20}
	pin.equipped["chest"] = arm
	pl.recalc_stats()
	var k := 1.0 - pow(0.8, 2.0) # ease_out(0.2) = 0.36
	check(is_equal_approx(pl.walk_speed, base.walk * (1.0 + 0.25 * k)) and is_equal_approx(pl.sprint_speed, base.sprint * (1.0 + 0.25 * k))
		and is_equal_approx(pl.crouch_speed, base.crouch * (1.0 + 0.25 * k)), "Agility 20: walk / sprint / crouch +%.1f%%" % (25.0 * k))
	check(is_equal_approx(pl.damage_reduction, 0.4 * k), "Toughness 20: damage reduction %.1f%% (was 6%%)" % (40.0 * k))
	pl.health = pl.max_health
	var hp0: int = pl.health
	pl.take_damage(50.0)
	var lost: int = hp0 - pl.health
	check(lost > 0 and lost < 50 and absi(lost - int(round(50.0 * (1.0 - 0.4 * k)))) <= 1, "damage taken: 50 -> %d" % lost)
	check(is_equal_approx(pl.regen_delay, maxf(base.regen_d - 2.5 * k, 1.5)) and is_equal_approx(pl.regen_rate, base.regen_r + 20.0 * k), "Vitality 20: regen sooner + faster")
	check(is_equal_approx(pl.grenade_cooldown, base.gren * (1.0 - 0.5 * k)), "Ordnance 20: grenade cooldown -%.0f%%" % (50.0 * k))
	check(pl.ability == null or is_equal_approx(float(pl.ability.cooldown), maxf(base.abil * (1.0 - 0.4 * k), 1.0)), "Focus 20: ability cooldown -%.0f%%" % (40.0 * k))
	check(is_equal_approx(pl.melee_damage, base.melee * (1.0 + 0.6 * k)) and is_equal_approx(pl.melee_cooldown, base.melee_cd * (1.0 - 0.4 * k)), "Brawn 20: melee +%.0f%%, cooldown -%.0f%%" % [60.0 * k, 40.0 * k])
	var fx: Dictionary = pl.get_stat_effects()
	check(absf(float(fx.move_speed_pct) - 25.0 * k) < 0.01 and absf(float(fx.damage_taken_pct) + 40.0 * k) < 0.01 and int(fx.stats.agility) == 20
		and fx.has_all(["crouch_speed_pct", "regen_delay_s", "grenade_cooldown_pct", "ability_cooldown_pct", "melee_damage_pct", "from_armor"]),
		"get_stat_effects(): live percentages (move +%.1f%%, damage taken %.1f%%)" % [fx.move_speed_pct, fx.damage_taken_pct])
	check(StatEffects.rows(pl).size() == 6, "StatEffects.rows: one display row per stat")
	var pv: Dictionary = pl.get_stat_effects({"agility": 20, "toughness": 80})
	var rws: Array = StatEffects.rows(pl, {"totals": {"agility": 40, "toughness": 100}})
	arm.stats = {"agility": 40, "toughness": 100, "vitality": 20, "ordnance": 20, "focus": 20, "brawn": 20}
	pl.recalc_stats()
	var real: Dictionary = pl.get_stat_effects()
	var agi_row: Dictionary = rws[0]
	check(int(pv.stats_next.agility) == 40 and int(pv.stats_next.toughness) == 100 and absf(float(pv.next.move_speed_pct) - float(real.move_speed_pct)) < 0.01
		and absf(float(pv.next.damage_taken_pct) - float(real.damage_taken_pct)) < 0.01 and absf(float(pv.next.regen_delay_s) - float(real.regen_delay_s)) < 0.01,
		"get_stat_effects(preview): +20 Agility / +80 Toughness (clamped) predicts the real recalc (move %+.1f%%, damage %+.1f%%)" % [pv.next.move_speed_pct, pv.next.damage_taken_pct])
	check(int(agi_row.value) == 20 and int(agi_row.value_next) == 40 and absf(float(agi_row.effects[0].next) - float(real.move_speed_pct)) < 0.01
		and str(agi_row.effects[0].text_next) != "" and not StatEffects.rows(pl)[0].effects[0].has("next"),
		"StatEffects.rows(player, {totals}): value_next / effect next + text_next (%s -> %s)" % [agi_row.effects[0].text, agi_row.effects[0].text_next])
	pin.equipped["chest"] = null
	pl.recalc_stats()

	await _grenade_pickup_checks(main, pl)
	await _match_stats_checks(main, pl, prog)
	_finish(prog, P, inv)


func _grenade_pickup_checks(main, pl) -> void:
	var gdb = root.get_node("GearDB")
	var before: Dictionary = pl.grenade_data
	var pk = load("res://scenes/pickup.tscn").instantiate() if ResourceLoader.exists("res://scenes/pickup.tscn") else null
	if pk == null:
		check(false, "scenes/pickup.tscn exists")
		return
	pk.item = gdb.grenade_pickup("gravewell") # legacy consumable: §25 turns it into an equipped GrenadeItem
	main.add_child(pk)
	pk.global_position = pl.global_position + Vector3(3, 0, 0)
	await physics_frame
	check(str(pk.get_prompt()).begins_with("Swap grenade: Gravewell"), "grenade pickup prompt (%s)" % pk.get_prompt())
	var k0: float = pl.grenade_cooldown / maxf(float(before.get("cooldown", 20.0)), 0.001)
	pk.interact(pl)
	await physics_frame
	var eg = pl.inventory.equipped.get("grenade") if pl.inventory.equipped.has("grenade") else null
	check(str(pl.grenade_data.get("name", "")) == "Gravewell" and (eg == null or str(eg.grenade_id) == "gravewell") and (not is_instance_valid(pk) or pk.is_queued_for_deletion()),
		"E on a grenade pickup: player throws Gravewell (equipped as a GrenadeItem), pickup gone (was %s)" % before.get("name", "?"))
	check(absf(pl.grenade_cooldown - float(pl.grenade_data.get("cooldown", 20.0)) * k0) < 0.01, "grenade cooldown follows the new grenade (%.1f s)" % pl.grenade_cooldown)
	pl.recalc_stats()
	check(str(pl.grenade_data.get("name", "")) == "Gravewell", "picked-up grenade survives recalc_stats")
	var again = gdb.grenade_pickup("gravewell")
	check(not again.give_grenade(pl), "same grenade again: not taken")
	if pl.has_method("apply_stats") and FileAccess.get_file_as_string("res://scripts/player.gd").contains("grenade_override"):
		pl.apply_stats()
		check(str(pl.grenade_data.get("name", "")) == "Gravewell", "player.gd §24c: picked-up grenade survives apply_stats")
	if pl.has_meta("grenade_override"):
		pl.remove_meta("grenade_override")
	pl.grenade_data = before
	pl.recalc_stats()


func _finish(prog, P, inv) -> void:
	inv.free()
	P.delete_save_files(prog.save_path)
	print("econ_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


func _match_stats_checks(main, pl, prog) -> void:
	MatchStats.begin(main)
	var bus = root.get_node("GameEvents")
	var zfake: Object = _src("extends Node3D\nvar variant_id := \"soldier\"\n")
	root.add_child(zfake)
	bus.emit_event(&"hit", {"player": pl, "damage": 30.0, "is_headshot": true, "source": "gun", "target": zfake})
	bus.emit_event(&"hit", {"player": pl, "damage": 12.4, "is_headshot": false, "source": "gun", "target": zfake})
	bus.emit_event(&"enemy_killed", {"player": pl, "is_headshot": true, "source": "gun", "target": zfake})
	bus.emit_event(&"hit", {"player": Node.new(), "damage": 999.0}) # another player's hit: ignored
	for i in 4:
		bus.emit_event(&"shot_fired", {"player": pl})
	bus.emit_event(&"shot_missed", {"player": pl})
	bus.emit_event(&"healed", {"player": pl, "amount": 25})
	bus.emit_event(&"grenade_thrown", {"player": pl})
	bus.emit_event(&"card_picked", {})
	bus.emit_event(&"door_opened", {"player": pl})
	bus.emit_event(&"enemy_killed", {"player": pl, "source": "melee", "target": zfake})
	bus.emit_event(&"round_started", {"player": pl, "round": 4})
	bus.emit_event(&"round_cleared", {"player": pl, "round": 3})
	var p0: int = pl.points
	pl.add_points(100, "kill")
	pl.spend_points(40)
	prog.add_gravemark(2, "test")
	prog.add_scrap(5, "test")
	bus.emit_event(&"damage_taken", {"player": pl, "dealt": 17, "attacker": zfake})
	# v070 #3: a hit counts for at most the HP that was left (ctx.hp_before from Player.take_damage); no hp_before = whole `dealt`
	bus.emit_event(&"damage_taken", {"player": pl, "dealt": 40, "hp_before": 10, "attacker": zfake}) # overkill: counts 10
	bus.emit_event(&"damage_taken", {"player": pl, "dealt": 5, "hp_before": 100, "attacker": zfake}) # plain hit: counts 5
	bus.emit_event(&"damage_taken", {"player": pl, "dealt": 3, "hp_before": 0, "attacker": zfake}) # already at 0 HP: counts 0
	bus.emit_event(&"damage_taken", {"player": Node.new(), "dealt": 50, "hp_before": 50}) # another player: ignored
	pl.died.emit()
	bus.emit_event(&"match_ended", {"player": pl, "round": 4, "kills": 2})
	MatchStats.on_match_recorded(321)
	var sm: Dictionary = MatchStats.summary()
	print("  match stats: ", sm)
	check(sm.kills == 2 and sm.headshots == 1 and sm.headshot_kills == 1 and sm.hits == 2 and sm.damage_dealt == 42 and sm.damage_taken == 32,
		"MatchStats: kills / headshots / hits / damage dealt + taken (foreign hits ignored; taken = 17 + 10 of a 40 hit on 10 HP + 5 = %d)" % sm.damage_taken)
	check(MatchStats.damage_counted({"dealt": 40, "hp_before": 10}) == 10 and MatchStats.damage_counted({"dealt": 40}) == 40
		and MatchStats.damage_counted({"dealt": 4, "hp_before": 10}) == 4 and MatchStats.damage_counted({"dealt": -3, "hp_before": 10}) == 0,
		"MatchStats.damage_counted: min(dealt, hp_before), whole dealt without hp_before, never negative")
	check(sm.round_reached == 4 and sm.rounds == 3 and sm.points_earned == 100 and sm.points_spent == 40 and int(sm.points_by_reason.get("kill", 0)) == 100,
		"MatchStats: rounds, points earned / spent (%d -> %d)" % [p0, pl.points])
	check(sm.gravemarks == 2 and sm.scrap == 5 and sm.xp == 321 and not sm.active and sm.ended and str(sm.time_text).contains(":"),
		"MatchStats: Gravemark / Scrap / XP earned, clock stopped")
	check(sm.shots_fired == 4 and sm.shots_missed == 1 and sm.shots_hit == 3 and is_equal_approx(float(sm.accuracy), 0.75)
		and sm.healed == 25 and sm.grenades_thrown == 1 and sm.cards_picked == 1 and sm.doors_opened == 1
		and sm.melee_kills == 1 and sm.precision_kills == 1, "MatchStats: shots / accuracy 75%, healed, grenades, cards, doors, melee + precision kills")
	check(sm.cause_of_death.kind == "zombie" and sm.cause_of_death.name == "Soldier", "cause of death: last attacker (%s)" % [sm.cause_of_death])
	bus.emit_event(&"hit", {"player": pl, "damage": 5.0})
	check(MatchStats.summary().hits == 2, "events after match_ended are ignored")
	zfake.free()
	await wait(1)
