extends SceneTree
## Persistent stash + seen flags + save v3 migration + halved economy (Skillz).
##   godot --headless --path . -s res://tests/stash_test.gd   (exit code = failures)
## Uses its own save file, never the real one.

var _fails := 0
var _passes := 0
var _seen_events: Array = []


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


const WEAPON_SLOTS := ["primary", "secondary", "heavy"]
const ARMOR_SLOTS := ["helmet", "gauntlets", "chest", "legs", "class_item"]
const COMMON := 0
const RARE := 2
const LEGENDARY := 3
const MYTHIC := 4


func _new_inv() -> Node:
	var inv = load("res://scripts/items/inventory.gd").new()
	root.add_child(inv)
	inv.seen_changed.connect(func(it): _seen_events.append(it))
	return inv


func _load_main() -> Node:
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	var m = current_scene
	m._break_timer = 9999.0
	return m


func _run() -> void:
	var prog = root.get_node("Progress")
	var gear = root.get_node("GearDB")
	prog.stash = {"equipped": {"primary": {"class": "weapon"}}} # pretend the real save had gear
	prog.save_path = "user://progress_stash_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prog.save_path))
	check(prog.stash.is_empty(), "changing save_path drops the in-memory stash (tests never see real gear)")

	# ------------------------------------------------------------ economy
	check(prog.points_per_hit == 5 and prog.points_per_kill == 50, "economy.json: 5 per hit, 50 per kill (was 10 / 100)")
	var econ: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/economy.json"))
	check(int(econ._previous.points_per_hit) == 10 and int(econ._previous.points_per_kill) == 100, "economy.json keeps the previous values for reference")
	var maps: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/maps.json"))
	check(JSON.stringify(maps).contains("750 / 1000 / 1250"), "door prices untouched (750 / 1000 / 1250)")

	# ------------------------------------------------------------ seen flags
	var inv = _new_inv()
	check(inv.stash_cap == 40 and int(gear.loot.stash.cap) == 40, "stash cap 40 (data/loot_tables.json -> stash.cap)")
	var w1 = gear.roll_weapon("sidearm", COMMON, 1)
	check(w1.seen == false, "freshly rolled gear starts unseen")
	inv.add_item(w1)
	check(inv.equipped.primary == w1 and w1.seen, "auto-equipped pickup is marked seen")
	_seen_events.clear()
	var w2 = gear.roll_weapon("hand_cannon", LEGENDARY, 5)
	inv.add_item(w2)
	check(inv.backpack.primary.has(w2) and not w2.seen, "backpack pickup stays unseen")
	check(_seen_events == [w2], "seen_changed(item) fires when an unseen item arrives")
	check(inv.has_unseen("primary") and inv.has_unseen("") and not inv.has_unseen("helmet") and not inv.has_unseen("secondary"),
		"has_unseen(slot): primary yes, '' yes, helmet/secondary no")
	check(inv.unseen_count("") == 1 and inv.unseen_count("primary") == 1 and inv.unseen_count("heavy") == 0, "unseen_count per slot and overall")
	_seen_events.clear()
	inv.mark_seen(w2)
	inv.mark_seen(w2)
	check(w2.seen and _seen_events == [w2] and not inv.has_unseen(), "mark_seen flips once, emits once, no-op when already seen")
	var a1 = gear.roll_armor("helmet", COMMON, 1)
	var a2 = gear.roll_armor("helmet", RARE, 3)
	var a3 = gear.roll_armor("legs", RARE, 3)
	inv.add_item(a1)
	inv.add_item(a2)
	inv.add_item(a3)
	inv.add_item(gear.roll_armor("legs", RARE, 3))
	check(inv.unseen_count("helmet") == 1 and inv.unseen_count("legs") == 1, "armor slot ids work for unseen_count")
	inv.mark_all_seen("helmet")
	check(not inv.has_unseen("helmet") and inv.has_unseen("legs"), "mark_all_seen(slot) clears only that slot")
	var w3 = gear.roll_weapon("auto_rifle", RARE, 2)
	inv.add_item(w3)
	inv.equip(w3)
	check(inv.equipped.primary == w3 and w3.seen, "equip() marks the item seen")
	var junk = gear.roll_weapon("scout_rifle", COMMON, 1)
	inv.add_item(junk)
	_seen_events.clear()
	inv.dismantle(junk)
	check(_seen_events == [junk] and not inv.has_unseen("primary"), "scrapping an unseen item emits seen_changed and clears its badge")
	inv.mark_all_seen()
	check(inv.unseen_count() == 0, "mark_all_seen() clears everything")

	# ------------------------------------------------------------ cap
	var inv_cap = _new_inv()
	var slots: Array = WEAPON_SLOTS + ARMOR_SLOTS
	for s in slots:
		inv_cap.equipped[s] = gear.roll_weapon("", COMMON, 1, s) if s in WEAPON_SLOTS else gear.roll_armor(s, COMMON, 1)
	var added := 0
	for i in 60:
		var s: String = slots[i % slots.size()]
		var it = gear.roll_weapon("", COMMON, 1, s) if s in WEAPON_SLOTS else gear.roll_armor(s, COMMON, 1)
		if inv_cap.add_item(it):
			added += 1
	check(added == 40 and inv_cap.carried_count() == 40 and inv_cap.stash_full(), "stash holds 40 spare pieces across slots (%d)" % added)
	var extra = gear.roll_armor("chest", MYTHIC, 9)
	check(not inv_cap.add_item(extra) and inv_cap.last_reject == "stash_full", "41st piece refused: last_reject = stash_full")
	check(inv_cap.reject_message().contains("stash full: 40/40"), "reject_message(): %s" % inv_cap.reject_message())
	inv_cap.dismantle(inv_cap.backpack.chest[0])
	check(inv_cap.stash_space() == 1 and inv_cap.add_item(extra), "scrap frees a space and the pickup fits again")
	var inv_slot = _new_inv()
	inv_slot.equipped.helmet = gear.roll_armor("helmet", COMMON, 1)
	for i in inv_slot.backpack_size:
		inv_slot.add_item(gear.roll_armor("helmet", COMMON, 1))
	check(not inv_slot.add_item(gear.roll_armor("helmet", COMMON, 1)) and inv_slot.last_reject == "slot_full",
		"per-slot grid limit (%d) still applies: last_reject = slot_full" % inv_slot.backpack_size)

	# ------------------------------------------------------------ save dict
	var unseen_bp = gear.roll_armor("gauntlets", LEGENDARY, 4)
	inv.add_item(gear.roll_armor("gauntlets", COMMON, 1))
	inv.add_item(unseen_bp)
	var sd: Dictionary = JSON.parse_string(JSON.stringify(inv.to_save_dict()))
	check(int(sd.version) == 1 and sd.backpack.gauntlets.any(func(d): return d.seen == false), "to_save_dict carries version + per-item seen")
	var inv_rt = _new_inv()
	inv_rt.load_save_dict(sd)
	check(inv_rt.unseen_count("gauntlets") == 1 and inv_rt.unseen_count() == 1 and inv_rt.carried_count() == inv.carried_count(),
		"JSON round trip keeps seen flags and carried items")
	var legacy: Dictionary = sd.duplicate(true)
	for s in legacy.backpack:
		for d in legacy.backpack[s]:
			d.erase("seen")
	for s in legacy.equipped:
		if legacy.equipped[s]:
			legacy.equipped[s].erase("seen")
	var inv_leg = _new_inv()
	inv_leg.load_save_dict(legacy)
	check(inv_leg.unseen_count() == 0 and inv_leg.carried_count() == inv.carried_count(), "legacy items (no 'seen' key) load as seen: old stashes don't light up")
	var bad: Dictionary = sd.duplicate(true)
	bad.backpack.primary.append({"class": "weapon", "id": "x", "archetype": "deleted_gun", "slot": "primary"})
	bad.backpack.helmet.append({"class": "armor", "id": "y", "slot": "legs"})
	var inv_bad = _new_inv()
	inv_bad.load_save_dict(bad)
	check(inv_bad.carried_count() == inv.carried_count(), "unknown archetypes / wrong-slot items are dropped on load")

	# ------------------------------------------------------------ Progress save v3 + migration
	check(prog.migrate_stash(null) == {} and prog.migrate_stash([1]) == {} and prog.migrate_stash({"backpack": {}}) == {}, "migrate_stash: no/bad data -> {}")
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "xp", 500)
	cfg.set_value("skills", "version", 2)
	cfg.set_value("skills", "ranks", {"mk_root": 1})
	cfg.save(prog.save_path)
	prog.load_data()
	check(prog.loaded_save_version == 2 and prog.stash.is_empty() and not prog.has_stash() and prog.rank("mk_root") == 1,
		"v2 save loads: skills kept, no stash (starter loadout next match)")
	prog.bind_inventory(inv)
	check(prog.save_stash(), "save_stash() captures the bound inventory")
	var c2 := ConfigFile.new()
	c2.load(prog.save_path)
	check(int(c2.get_value("meta", "save_version", 0)) == 3 and c2.has_section_key("stash", "data") and int(c2.get_value("stash", "version", 0)) == 1,
		"save written as v3: [meta] save_version 3, [stash] version + data")
	check(c2.get_value("skills", "ranks", {}) == {"mk_root": 1}, "skills survive the v3 rewrite")
	prog.stash = {}
	prog.load_data()
	check(prog.loaded_save_version == 3 and prog.has_stash(), "v3 save reloads its stash")
	var inv_r = _new_inv()
	check(prog.restore_stash(inv_r) and inv_r.carried_count() == inv.carried_count() and inv_r.unseen_count() == inv.unseen_count()
		and inv_r.equipped.primary.display_name == inv.equipped.primary.display_name, "restore_stash rebuilds equipped + carried + seen")
	prog.bind_inventory(null)
	for n in [inv, inv_cap, inv_slot, inv_rt, inv_leg, inv_bad, inv_r]:
		n.queue_free()
	await wait(2)

	# ------------------------------------------------------------ match flow (main scene)
	prog.clear_stash()
	var main = await _load_main()
	var player = main.get_node("Player")
	check(player.inventory.equipped.primary != null and player.inventory.equipped.primary.archetype == "sidearm"
		and player.inventory.carried_count() == 0, "no stash: Common starter loadout")
	check(prog.bound_inventory() == player.inventory, "player binds its inventory to Progress")
	var hc = gear.roll_weapon("hand_cannon", LEGENDARY, 8)
	var hc_name: String = hc.display_name
	player.receive_item(hc)
	var hv = gear.roll_weapon("rocket_launcher", RARE, 4)
	player.receive_item(hv)
	check(not hc.seen and hv.seen, "match pickups: backpack item unseen, auto-equipped heavy seen")
	prog.record_match(3, 2)
	var c3 := ConfigFile.new()
	c3.load(prog.save_path)
	var saved: Dictionary = c3.get_value("stash", "data", {})
	check(saved.get("backpack", {}).get("primary", []).any(func(d): return d.display_name == hc_name and d.seen == false)
		and saved.equipped.heavy != null, "match end (record_match) writes the stash with seen flags")
	player.inventory.mark_seen(hc)
	var main2 = await _load_main() # restart: the old Inventory leaves the tree and saves first
	var p2 = main2.get_node("Player")
	var restored: Array = p2.inventory.backpack.primary.filter(func(i): return i.display_name == hc_name)
	check(restored.size() == 1 and restored[0].seen, "restart restores carried gear; seen set before the restart persisted")
	check(p2.inventory.equipped.heavy != null and p2.inventory.equipped.heavy.archetype == "rocket_launcher", "equipped loadout (heavy) restored")
	check(prog.bound_inventory() == p2.inventory, "new match rebinds the new inventory")
	check(p2.inventory.get_equipped_weapon() != null, "restored loadout has an active weapon")
	var unseen2 = gear.roll_armor("chest", LEGENDARY, 6)
	p2.receive_item(unseen2)
	prog._notification(Node.NOTIFICATION_WM_CLOSE_REQUEST) # quit path
	var c4 := ConfigFile.new()
	c4.load(prog.save_path)
	check(c4.get_value("stash", "data", {}).get("backpack", {}).get("chest", []).any(func(d): return d.seen == false),
		"window close (quit) saves the stash, including new unseen pickups")
	_finish(prog)


func _finish(prog) -> void:
	prog.bind_inventory(null)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prog.save_path))
	print("STASH TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
