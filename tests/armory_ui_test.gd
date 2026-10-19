extends SceneTree
## UI Armory + Gravemark (Gooey). Uses a throwaway save.
##   godot --headless --path . -s res://tests/armory_ui_test.gd

const ArmoryScr := preload("res://scripts/armory/armory.gd")
const ArmoryMenuScr := preload("res://scripts/ui/armory_menu.gd")
const MapPickerScr := preload("res://scripts/ui/map_picker.gd")
const SettingsScr := preload("res://scripts/autoload/settings.gd")

var _fails := 0
var _passes := 0

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond: _passes += 1
	else: _fails += 1

func _initialize() -> void:
	_go.call_deferred()

func _go() -> void:
	var prog = root.get_node("Progress")
	prog.save_path = "user://progress_armory_ui_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prog.save_path))
	prog.load_data()
	prog.gravemarks = 0
	prog.armory = {"upgrades": {}, "owned": [], "equipped": {}}
	prog.save_data()

	# ---- Gravemark chip helper
	var chip = UIStyle.gravemark_chip(7, 20)
	check(chip != null and chip.find_child("GravemarkAmount", true, false).text == "7", "gravemark_chip shows amount")
	check(chip.find_child("GravemarkIcon", true, false) != null, "gravemark_chip uses real gravemark.png (GravemarkIcon)")
	check(chip.find_child("GravemarkGlyph", true, false) == null, "gravemark_chip does not fall back to G glyph")
	check(UIStyle.gravemark_tex() != null, "gravemark_tex loads")
	UIStyle.set_gravemark_chip_amount(chip, 12)
	check(chip.find_child("GravemarkAmount", true, false).text == "12", "set_gravemark_chip_amount updates")
	chip.free()

	# ---- Balance shows + updates in menu
	var menu = ArmoryMenuScr.new()
	root.add_child(menu)
	await process_frame
	menu.open()
	await process_frame
	check(menu.visible and menu._bal_chip != null, "armory menu builds with balance chip")
	prog.gravemarks = 40
	prog.currency_changed.emit(40)
	await process_frame
	check(menu._bal_chip.find_child("GravemarkAmount", true, false).text == "40", "armory balance updates live")

	# ---- Lists populate for a weapon
	menu._weapon_id = "smg"
	menu.refresh()
	await process_frame
	var ups: Array = menu.api.list_upgrades("smg")
	check(ups.size() == 1 and ups[0].has("tiers") and (ups[0].tiers as Array).size() == 5, "upgrade track I-V for SMG")
	var atts: Array = menu.api.list_attachments("smg")
	check(atts.size() >= 3, "attachments list for SMG (%d)" % atts.size())
	check(menu._right.find_child("UpgradeTrack", true, false) != null, "upgrade track UI present")
	# type clarity label
	var found_type := false
	for lab in menu._right.find_children("*", "Label", true, false):
		if "APPLIES TO ALL" in lab.text.to_upper():
			found_type = true
			break
	check(found_type, "upgrade header says applies to all <type>s")

	# ---- Purchase with seeded balance
	var uid := str(ups[0].id) # upg_smg
	var cost0: int = int(ups[0].cost)
	check(menu.api.can_afford(uid), "can afford first SMG rework at 40 GM (cost %d)" % cost0)
	check(menu.api.purchase(uid), "purchase SMG Rework I")
	check(prog.gravemarks == 40 - cost0 and int(ArmoryScr.upgrade_tier("smg")) == 1, "purchase deducts + marks tier I")
	menu.refresh()
	await process_frame

	# ---- Disabled reasons
	prog.gravemarks = 0
	prog.currency_changed.emit(0)
	await process_frame
	menu.refresh()
	await process_frame
	var next_id := str(menu.api.list_upgrades("smg")[0].id)
	check(not menu.api.can_afford(next_id), "cannot afford next tier at 0 GM")
	var reason := menu._disable_reason(next_id, true)
	check("Gravemark" in reason or "Need" in reason, "disabled reason mentions Gravemarks (%s)" % reason)

	# Seed enough for an attachment buy that has no purchase req, or buy cheap optic after tier
	prog.gravemarks = 200
	prog.save_data()
	# Find a tier-1 attachment for smg
	var buy_id := ""
	for a in menu.api.list_attachments("smg"):
		if int(a.get("tier", 1)) == 1 and not bool(a.get("owned", false)) and bool(a.get("can_afford", false)):
			buy_id = str(a.id)
			break
	if buy_id == "":
		# force afford
		for a in menu.api.list_attachments("smg"):
			if int(a.get("tier", 1)) == 1 and not bool(a.get("owned", false)):
				buy_id = str(a.id)
				break
	check(buy_id != "", "found a tier-1 attachment to buy (%s)" % buy_id)
	var bal_b: int = prog.gravemarks
	var c_att: int = int(menu.api.cost(buy_id))
	check(menu.api.purchase(buy_id) and prog.gravemarks == bal_b - c_att and menu.api.is_owned(buy_id),
		"attachment purchase marks owned + deducts")

	# ---- Equip / unequip reflects
	var slot := ""
	for a in menu.api.list_attachments("smg"):
		if str(a.id) == buy_id:
			slot = str(a.slot)
			break
	check(menu.api.equip_attachment("smg", slot, buy_id), "equip attachment")
	menu.refresh()
	await process_frame
	var eq_ok := false
	for a in menu.api.list_attachments("smg", slot):
		if str(a.id) == buy_id and bool(a.get("equipped", false)):
			eq_ok = true
	check(eq_ok, "equipped state in list_attachments")
	check(menu.api.unequip("smg", slot), "unequip")
	check(str(menu.api.equipped("smg").get(slot, "")) == "", "unequip clears slot")

	# ---- Persist across save reload
	menu.api.equip_attachment("smg", slot, buy_id)
	prog.save_data()
	var path: String = prog.save_path
	prog.gravemarks = 0
	prog.armory = {"upgrades": {}, "owned": [], "equipped": {}}
	prog.load_data()
	check(int(ArmoryScr.upgrade_tier("smg")) == 1 and ArmoryScr.owned(buy_id)
		and str(ArmoryScr.loadout("smg").get(slot, "")) == buy_id,
		"armory state persists across save reload")
	check(prog.gravemarks == bal_b - c_att, "gravemarks persisted (%d)" % prog.gravemarks)

	# Confirm UI — compact centered overlay card (not stretched across panel)
	prog.gravemarks = 100
	prog.currency_changed.emit(100)
	menu._ask_buy("upg_sidearm", "upgrade")
	await process_frame
	check(menu._confirm_overlay != null and menu._confirm_overlay.visible, "confirm overlay visible")
	check(menu._confirm.visible and "Gravemark" in menu._confirm_label.text, "buy confirm panel shows")
	check(menu._confirm.custom_minimum_size.x >= 440 and menu._confirm.custom_minimum_size.y >= 180,
		"confirm card is compact (~460x200), not full panel")
	check(menu._confirm.get_parent() is CenterContainer, "confirm card centered via CenterContainer")
	check(menu._confirm.get_parent().get_parent() == menu._confirm_overlay, "confirm not a panel child")
	var cost_lbl = menu._confirm.find_child("ConfirmCost", true, false) as Label
	check(cost_lbl != null and "→" in cost_lbl.text and "100" in cost_lbl.text, "confirm shows balance → after")
	check(menu._confirm_cost_row.find_child("GravemarkIcon", true, false) != null, "confirm cost row has Gravemark icon")
	check(menu._bal_chip.find_child("GravemarkIcon", true, false) != null, "header chip uses GravemarkIcon texture")
	menu._confirm_no()
	check(not menu._confirm.visible and not menu._confirm_overlay.visible, "confirm cancel hides overlay")

	menu.close()
	menu.queue_free()

	# ---- G4M3N fix: ads rebind + aim migration
	var st = SettingsScr.get_or_create(root)
	# Write legacy aim binding into cfg
	var cfg := ConfigFile.new()
	cfg.set_value("bindings", "aim", [{"type": "mouse_button", "button": MOUSE_BUTTON_RIGHT}])
	# Settings uses BIND_SECTION - check name
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.SAVE_PATH))
	var cfg2 := ConfigFile.new()
	cfg2.set_value("settings", "ads_mode", "hold")
	cfg2.set_value("bindings", "aim", [{"t": "mouse", "button": 3}])
	cfg2.save(st.SAVE_PATH)
	st.load_from_disk()
	check("ads" in SettingsScr.BINDABLE and "aim" not in SettingsScr.BINDABLE, "BINDABLE uses ads not aim")
	check(SettingsScr.BIND_LABELS.get("ads", "") == "Aim Down Sights", "ads labelled Aim Down Sights")
	# After load, ads should have events (migrated) and aim key erased from disk
	var cfg3 := ConfigFile.new()
	cfg3.load(st.SAVE_PATH)
	check(not cfg3.has_section_key("bindings", "aim"), "legacy aim binding erased from settings.cfg")
	check(InputMap.has_action("ads"), "ads action exists")

	# ---- Door pluralization + Hard note
	check(MapPickerScr._short_hint({"doors": [], "areas": {}}) == "OPEN LAYOUT // NO DOORS", "no doors hint")
	var one = MapPickerScr._short_hint({"doors": [{"cost": 750, "opens": ["a"]}], "areas": {}})
	check(one.begins_with("1 DOOR (750)") and "1 AREA" in one, "1 DOOR single cost (%s)" % one)
	var two = MapPickerScr._short_hint({"doors": [{"cost": 750, "opens": ["a"]}, {"cost": 1250, "opens": ["b"]}], "areas": {}})
	check("2 DOORS (750-1250)" in two, "N DOORS range (%s)" % two)
	var same = MapPickerScr._short_hint({"doors": [{"cost": 750, "opens": ["a"]}, {"cost": 750, "opens": ["b"]}], "areas": {}})
	check("2 DOORS (750)" in same and "750-750" not in same, "same min/max shows single cost (%s)" % same)

	var mp = MapPickerScr.new()
	mp.home_mode = true
	mp.dry_run = true
	root.add_child(mp)
	await process_frame
	mp.open()
	await process_frame
	mp.select_row("arena")
	await process_frame
	check(mp._diff_note != null and not mp._diff_note.visible, "Hard note hidden for Easy arena")
	if MapRegistry.is_valid("lockout_substation") or true:
		# lockout may be missing scene but still in list with difficulty hard
		mp.select_row("lockout_substation")
		await process_frame
		check(mp._diff_note.visible == (MapPickerScr.map_difficulty("lockout_substation") == "hard"),
			"Hard note visible only for Hard maps")
	mp.close()

	DirAccess.remove_absolute(ProjectSettings.globalize_path(prog.save_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.SAVE_PATH))
	print("ARMORY UI TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
