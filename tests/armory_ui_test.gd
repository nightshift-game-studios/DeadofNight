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

	# ---- Item Power breakdown helpers (Armory §1a)
	check(UIStyle.ip_breakdown_text({"base_rolled": 290, "rework_bonus": 22, "total": 312}) == "290 rolled + 22 Rework",
		"ip_breakdown_text: 290 rolled + 22 Rework")
	check(UIStyle.ip_breakdown_text({"base_rolled": 290, "rework_bonus": 0, "total": 290}) == "290 rolled",
		"ip_breakdown_text hides Rework when bonus is 0")
	var blk = UIStyle.ip_breakdown_block({"base_rolled": 290, "rework_bonus": 22, "total": 312})
	check(blk.find_child("IPTotal", true, false).text == "312" and "Rework" in blk.find_child("IPBreakdown", true, false).text,
		"ip_breakdown_block shows total big + breakdown")
	blk.free()

	# ---- Armory weapon header IP (best owned SMG + Rework bonus)
	var gdb = root.get_node("GearDB")
	var smg_w = gdb.roll_weapon("smg", 2, 1, "primary")
	smg_w.item_power = 290
	prog.stash = {"version": 1, "equipped": {"primary": smg_w.to_dict()}, "backpack": {}}
	var smg_bonus: int = int(ArmoryScr.power_bonus("smg"))
	menu._select_weapon("smg")
	await process_frame
	var wip = menu._right.find_child("WeaponIP", true, false)
	check(wip != null, "armory weapon header has IP plate")
	if wip:
		var bdh: Dictionary = wip.get_meta("breakdown")
		check(int(bdh.total) == 290 + smg_bonus and str(bdh.source) == "best_owned",
			"header IP = best owned 290 + Rework %d (%s)" % [smg_bonus, str(bdh)])
		var bl = wip.find_child("IPBreakdown", true, false)
		check(bl != null and bl.text == UIStyle.ip_breakdown_text(bdh), "header breakdown line (%s)" % (bl.text if bl else "?"))
	var sn_bd: Dictionary = menu.api.item_power_breakdown("sniper_rifle")
	check(not ("Rework" in UIStyle.ip_breakdown_text(sn_bd)) or int(sn_bd.rework_bonus) > 0, "no Rework part for 0-bonus type")

	# ---- Attachment icons: att_mine_lamp.png on the SMG grip row, glyph fallback elsewhere
	check(UIStyle.attachment_tex("mine_lamp") != null, "attachment_tex loads att_mine_lamp.png")
	check(UIStyle.attachment_tex("definitely_not_a_part") == null, "attachment_tex null without art")
	var lamp_row: Node = null
	var glyph_rows := 0
	for row in menu._right.find_children("*", "PanelContainer", true, false):
		if row.has_meta("att_id"):
			if str(row.get_meta("att_id")) == "mine_lamp":
				lamp_row = row
			elif row.find_child("AttGlyph", true, false) != null:
				glyph_rows += 1
	check(lamp_row != null and lamp_row.find_child("AttIcon", true, false) != null, "Mine Lamp row shows att_mine_lamp.png")
	check(lamp_row != null and lamp_row.find_child("AttGlyph", true, false) == null, "Mine Lamp row has no glyph fallback")
	check(glyph_rows > 0, "parts without art keep the glyph fallback (%d rows)" % glyph_rows)

	# ---- Refresh on armory_changed: buying the next SMG Rework bumps the header IP
	prog.gravemarks = 500
	prog.currency_changed.emit(500)
	var before_total := int(menu.api.item_power_breakdown("smg").total)
	check(menu.api.purchase("upg_smg"), "buy next SMG Rework")
	await process_frame
	await process_frame
	var wip2 = menu._right.find_child("WeaponIP", true, false)
	var after_total := int(wip2.get_meta("breakdown").total) if wip2 else -1
	check(after_total > before_total, "header IP refreshes on armory_changed (%d -> %d)" % [before_total, after_total])

	menu.close()
	menu.queue_free()
	await process_frame

	# ---- Character screen weapon card: total big + "rolled + Rework" line, refresh on armory/inventory changes
	var CharScr = load("res://scripts/ui/character_screen.gd")
	var cs = CharScr.new()
	root.add_child(cs)
	await process_frame
	cs.visible = true
	var inv = load("res://scripts/items/inventory.gd").new()
	root.add_child(inv)
	await process_frame
	cs._bind_ip_sources(inv)
	var cw = gdb.roll_weapon("smg", 2, 1, "primary")
	cw.item_power = 290
	prog.stash = {"version": 1, "equipped": {"primary": cw.to_dict()}, "backpack": {}}
	cs.debug_show_tooltip(cw, Vector2(40, 40))
	await process_frame
	var cbd: Dictionary = cs._last_card_ip
	var b_now: int = int(ArmoryScr.power_bonus("smg"))
	check(int(cbd.get("base_rolled", -1)) == 290 and int(cbd.rework_bonus) == b_now and int(cbd.total) == 290 + b_now,
		"card IP breakdown 290 + %d Rework (%s)" % [b_now, str(cbd)])
	check(int(cbd.total) == cw.effective_item_power(), "card total == effective_item_power()")
	var ct = cs._tooltip.find_child("IPTotal", true, false)
	var cb = cs._tooltip.find_child("IPBreakdown", true, false)
	check(ct != null and ct.text == str(290 + b_now), "card shows total IP big (%s)" % (ct.text if ct else "?"))
	check(cb != null and cb.text == "290 rolled + %d Rework" % b_now, "card breakdown line (%s)" % (cb.text if cb else "?"))
	# armory_changed (upgrade) -> card re-renders with the new bonus
	check(ArmoryScr.new().purchase("upg_smg"), "buy another SMG Rework while card open")
	await process_frame
	var b_new: int = int(ArmoryScr.power_bonus("smg"))
	var ct2 = cs._tooltip.find_child("IPTotal", true, false)
	check(b_new > b_now and ct2 != null and ct2.text == str(290 + b_new), "card refreshes on armory_changed (%s)" % (ct2.text if ct2 else "?"))
	check(cs._tooltip.visible and cs._tooltip.position == Vector2(40, 40), "re-render keeps a fixed card in place")
	# inventory changed -> re-render (rolled IP edited on the live item)
	prog.bind_inventory(inv)
	cw.item_power = 300
	inv.equipped[cw.slot] = cw # live item (Armory reads the bound Inventory before the stash)
	inv.changed.emit()
	await process_frame
	var cb3 = cs._tooltip.find_child("IPBreakdown", true, false)
	check(cb3 != null and cb3.text.begins_with("300 rolled"), "card refreshes on Inventory.changed (%s)" % (cb3.text if cb3 else "?"))
	# 0 bonus type: Rework part hidden
	var sn = gdb.roll_weapon("sniper_rifle", 2, 1, "secondary")
	sn.item_power = 250
	cs.debug_show_tooltip(sn, Vector2(40, 40))
	await process_frame
	var cb4 = cs._tooltip.find_child("IPBreakdown", true, false)
	check(int(ArmoryScr.power_bonus("sniper_rifle")) != 0 or (cb4 != null and cb4.text == "250 rolled"),
		"card hides Rework part when bonus is 0 (%s)" % (cb4.text if cb4 else "?"))
	prog.bind_inventory(null)

	# ---- Total IP everywhere on the character screen (slot plates, AVG header, tile/card delta, VS EQUIPPED)
	var stub_src := GDScript.new()
	stub_src.source_code = "extends Node\nvar inventory\nvar player_class = null\nvar ability = null\nvar walk_speed := 5.0\nvar _base_walk := 5.0\nvar damage_reduction := 0.0\nvar regen_delay := 4.0\nvar grenade_cooldown := 10.0\nvar melee_damage := 50.0\n"
	stub_src.reload()
	var stub = stub_src.new()
	root.add_child(stub)
	var inv2 = load("res://scripts/items/inventory.gd").new()
	root.add_child(inv2)
	await process_frame
	stub.inventory = inv2
	prog.bind_inventory(inv2)
	prog.armory = {"upgrades": {"smg": 2}, "owned": [], "equipped": {}}
	prog.stash = {"version": 1, "equipped": {}, "backpack": {}}
	var bonus2: int = int(ArmoryScr.power_bonus("smg"))
	var eq_w = gdb.roll_weapon("smg", 2, 1, "primary")
	eq_w.item_power = 290
	var alt_w = gdb.roll_weapon("smg", 2, 1, "primary")
	alt_w.item_power = 280
	for sl in inv2.equipped.keys():
		inv2.equipped[sl] = null
		inv2.backpack[sl] = []
	inv2.equipped[eq_w.slot] = eq_w
	inv2.backpack[eq_w.slot] = [alt_w]
	cs.player = stub
	cs._expanded = eq_w.slot
	cs.refresh()
	await process_frame
	check(cs.display_ip(eq_w) == 290 + bonus2, "display_ip(weapon) = rolled + Rework (%d)" % cs.display_ip(eq_w))
	var slot_wrap = cs._left.find_child("Slot_" + eq_w.slot, true, false)
	var sip = slot_wrap.find_child("SlotIP", true, false) if slot_wrap else null
	var sip_n = sip.find_child("IPNumber", true, false) if sip else null
	check(sip_n != null and sip_n.text == str(290 + bonus2), "slot plate shows total IP (%s)" % (sip_n.text if sip_n else "?"))
	check(cs._avg_ip_label.text == str(290 + bonus2), "AVG IP header uses total (%s)" % cs._avg_ip_label.text)
	check(("RANGE %d-%d" % [290 + bonus2, 290 + bonus2]) in cs._avg_ip_sub.text, "AVG range uses total (%s)" % cs._avg_ip_sub.text.replace("\n", " "))
	var alt_tile: Node = null
	for t in slot_wrap.find_children("*", "Button", true, false):
		if t.has_meta("gear") and t.get_meta("gear") == alt_w:
			alt_tile = t
	var tip_n = alt_tile.find_child("TileIP", false, false).find_child("IPNumber", true, false) if alt_tile else null
	check(tip_n != null and tip_n.text == str(280 + bonus2), "stash tile plate shows total IP (%s)" % (tip_n.text if tip_n else "?"))
	var cmp2: Dictionary = cs.compare_display_ip(inv2, alt_w)
	check(cmp2.get("text", "") == "-10" and cmp2.get("worse", false), "delta vs equipped on totals (-10)")
	cs.debug_show_tooltip(alt_w, Vector2(40, 40))
	await process_frame
	check(cs._last_card_power.get("text", "") == "-10", "card +N delta uses totals (%s)" % cs._last_card_power.get("text", ""))
	var vs_ok := false
	for l in cs._tooltip.find_children("*", "Label", true, false):
		if str(l.text).begins_with("VS EQUIPPED") and str(l.text).ends_with("IP %d" % (290 + bonus2)):
			vs_ok = true
	check(vs_ok, "VS EQUIPPED line shows equipped total IP")
	var roll_ok := false
	for l in cs._tooltip.find_children("*", "Label", true, false):
		if str(l.text) == "OF IP 280 RANGE":
			roll_ok = true
	check(roll_ok, "ROLL bar keeps the rolled IP: OF IP 280 RANGE")
	# armory_changed: buy SMG Rework III -> slot plate / AVG update in place, no rebuild
	prog.gravemarks = 500
	check(ArmoryScr.new().purchase("upg_smg"), "buy SMG Rework III with screen open")
	await process_frame
	var bonus3: int = int(ArmoryScr.power_bonus("smg"))
	check(sip_n != null and is_instance_valid(sip_n) and sip_n.text == str(290 + bonus3), "slot plate refreshes on armory_changed (%s)" % (sip_n.text if sip_n else "?"))
	check(cs._avg_ip_label.text == str(290 + bonus3), "AVG refreshes on armory_changed (%s)" % cs._avg_ip_label.text)
	# Inventory.changed: rolled IP edited on the live item -> totals follow
	cs._bind_ip_sources(inv2)
	eq_w.item_power = 300
	inv2.changed.emit()
	await process_frame
	check(cs._avg_ip_label.text == str(300 + bonus3), "AVG refreshes on Inventory.changed (%s)" % cs._avg_ip_label.text)
	check(tip_n != null and is_instance_valid(tip_n) and tip_n.text == str(280 + bonus3), "tile plate stays total after change (%s)" % (tip_n.text if tip_n else "?"))
	prog.bind_inventory(null)
	cs.player = null
	cs.queue_free()
	inv.queue_free()
	inv2.queue_free()
	stub.queue_free()
	await process_frame

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
