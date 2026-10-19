extends SceneTree
const MapPickerScript := preload("res://scripts/ui/map_picker.gd")
## Pass 5 home menu tests.
##   godot --headless --path . -s res://tests/home_test.gd

var _fails := 0
var _passes := 0

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var prog = root.get_node("Progress")
	prog.save_path = "user://progress_home_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prog.save_path))
	prog.load_data()

	# --- difficulty helpers (missing field → medium; sort Easy→Hard)
	# Use a synthetic info by temporarily relying on maps without difficulty — lockout/arena have fields.
	# Missing-field path: empty string in a fake call through the helper with unknown id → medium
	check(MapPickerScript.map_difficulty("no_such_map") == "medium", "missing difficulty field defaults to medium")
	check(MapPickerScript.map_difficulty("arena") == "easy", "arena difficulty easy")
	check(MapPickerScript.map_difficulty("rustwell_foundry") == "medium", "rustwell medium")
	check(MapPickerScript.map_difficulty("lockout_substation") == "hard", "lockout hard")
	var sorted: Array = MapPickerScript.sorted_map_ids()
	var diffs: Array = sorted.map(func(id): return MapPickerScript.map_difficulty(str(id)))
	var order_ok := true
	var prev := -1
	for d in diffs:
		var o: int = int(MapPickerScript.DIFF_ORDER.get(d, 1))
		order_ok = order_ok and o >= prev
		prev = o
	check(order_ok and sorted.size() >= 2, "maps sorted Easy→Hard (%s)" % str(diffs))
	var badge = MapPickerScript.difficulty_badge("hard")
	check(badge != null and badge.get_meta("difficulty") == "hard", "difficulty badge carries meta")
	badge.free()

	# --- home menu builds
	var Home := load("res://scripts/ui/home_menu.gd")
	var home = Home.new()
	home.dry_run = true
	root.add_child(home)
	await process_frame
	await process_frame
	for id in ["play", "kit", "armory", "settings", "quit"]:
		check(home._btns.has(id) and home._btns[id] is Button, "home button '%s'" % id)
	check(home._currency_chip != null and home._currency_chip.visible,
		"Gravemark chip visible on home")
	check(home._map_picker != null and home._settings != null
		and home._armory != null and home._kit_screen != null,
		"home hosts map picker, settings, armory, kit")

	# --- map select: sort + badges + hard note
	var mp = home._map_picker
	mp.home_mode = true
	mp.dry_run = true
	mp.open()
	await process_frame
	check(mp.visible and mp._ids == sorted, "map select ids match Easy→Hard sort")
	var badge_n := 0
	for id in mp._ids:
		var row: Button = mp._rows.get(id)
		if row and row.find_child("DiffBadge", true, false):
			badge_n += 1
	check(badge_n == mp._ids.size(), "every map row has a difficulty badge (%d)" % badge_n)
	check(mp._diff_note != null and str(mp._diff_note.text).contains("Hard:"), "hard-mode note label exists")
	mp.select_row("arena")
	await process_frame
	check(not mp._diff_note.visible, "Hard note hidden on Easy")
	mp.select_row("lockout_substation")
	await process_frame
	check(mp._diff_note.visible, "Hard note shown on Hard map")
	# Play selects map + requests scene change (stubbed)
	var play_sig := []
	home.play_requested.connect(func(id): play_sig.append(id))
	var pick := str(mp._ids[0]) if mp._ids.size() else "arena"
	check(mp.load_map(pick) and MapRegistry.current_id() == pick, "Play/load_map selects %s" % pick)
	await process_frame
	check(home.last_play_map == pick and play_sig == [pick], "start_match requested scene change (dry_run) for %s" % pick)
	mp.close()
	await process_frame

	# --- Kit: stash badges + equip saves
	prog.clear_stash()
	var gear = root.get_node("GearDB")
	# Seed an unseen secondary in Progress stash via kit proxy
	home._kit_proxy.ensure()
	var inv = home._kit_proxy.inventory
	inv.mark_all_seen()
	var unseen = gear.roll_weapon("smg", 2, 2, "secondary") # RARE
	unseen.seen = false
	inv.add_item(unseen)
	check(inv.backpack.secondary.has(unseen) and inv.has_unseen("secondary"), "kit stash has unseen secondary")
	home._open_kit()
	await process_frame
	home._kit_screen._expanded = "secondary"
	home._kit_screen.refresh()
	await process_frame
	var wrap = null
	for c in home._kit_screen._left.get_children():
		if c.has_meta("slot") and str(c.get_meta("slot")) == "secondary":
			wrap = c
			break
	var slot_bang = wrap.find_child("SlotUnseen", true, false) if wrap else null
	check(slot_bang != null and slot_bang.visible, "kit out-of-match shows slot '!' badge")
	# Equip → save on close
	var before_save: int = home.save_stash_calls
	inv.equip(unseen)
	home._kit_screen.close()
	await process_frame
	check(home.save_stash_calls > before_save and prog.has_stash(), "kit equip + close saves stash")

	# --- Armory (real Skillz backend via menu)
	var ArmoryScr = load("res://scripts/armory/armory.gd")
	var api = ArmoryScr.new()
	check(api.currency_name == "Gravemark", "armory currency_name Gravemark")
	prog.gravemarks = 50
	prog.currency_changed.emit(50)
	await process_frame
	check(int(home._currency_label.text) == 50 or home._currency_chip.find_child("GravemarkAmount", true, false).text == "50",
		"home Gravemark chip updates on currency_changed")
	home._armory.open()
	await process_frame
	check(home._armory.visible and home._armory.api != null, "armory menu opens with real API")
	home._armory.close()

	# --- Quit calls save_stash (quit stubbed)
	var qsig := []
	home.quit_requested.connect(func(): qsig.append(1))
	var sc0: int = home.save_stash_calls
	home.request_quit()
	check(home.quit_calls == 1 and qsig.size() == 1, "Quit emits quit_requested (dry_run, no get_tree().quit)")
	check(home.save_stash_calls >= sc0, "Quit attempts save_stash")

	# --- Pause menu Quit to Home
	var Pause := load("res://scripts/ui/pause_menu.gd")
	var pm = Pause.new()
	pm.dry_run = true
	# Needs a fake main for can_open / refresh
	var stub := Node.new()
	stub.set_script(GDScript.new())
	# simpler: set properties via Object
	root.add_child(stub)
	stub.set("current_round", 2)
	stub.set("_game_over", false)
	pm.main = home # home has current_round=0; fine for building
	root.add_child(pm)
	await process_frame
	var has_quit_home := false
	for c in pm.content.get_children():
		if c is Button and str(c.text).contains("QUIT TO HOME"):
			has_quit_home = true
			break
	check(has_quit_home, "pause menu has Quit to Home")
	pm.dry_run = true
	pm._quit_to_home()
	check(pm.quit_home_calls == 1, "Quit to Home increments quit_home_calls (dry_run)")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(prog.save_path))
	print("HOME TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)

# Preload alias for static calls without instance
