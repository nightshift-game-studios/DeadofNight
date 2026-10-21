extends SceneTree
## Gooey playtest pass, Part B (headless):  godot --headless --path . -s res://tests/playtest_b_test.gd
##   #14 109-node tree UI (one class dock, rail switches it, fits 1280 wide, no overlaps, SkillSpec pick / undo / respec),
##   #21 character slots screen, #9 class + Q ability loadout, #24 home SKILLS (+ Characters.enter_home / leave_home).
## Runs once WITHOUT Characters (autoload not in project.godot yet: screens must degrade), then adds it by hand.

const SAVE := "user://progress_playtest_b_test.cfg"
var _fails := 0
var _passes := 0
var prog
var chars

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond: _passes += 1
	else: _fails += 1

func frames(n: int) -> void:
	for i in n: await process_frame

func _initialize() -> void:
	_go.call_deferred()


static func label_overlaps(n: Node, min_area: float = 6.0) -> Array:
	var labs: Array = n.find_children("*", "Label", true, false).filter(func(l): return l.is_visible_in_tree() and l.text.strip_edges() != "" and not l.is_queued_for_deletion())
	var out: Array = []
	for i in labs.size():
		var a: Rect2 = labs[i].get_global_rect()
		for j in range(i + 1, labs.size()):
			if labs[i].is_ancestor_of(labs[j]) or labs[j].is_ancestor_of(labs[i]):
				continue
			var ia: Rect2 = a.intersection(labs[j].get_global_rect())
			if ia.get_area() > min_area:
				out.append("%s | %s" % [labs[i].text.left(24), labs[j].text.left(24)])
	return out


func _wipe() -> void:
	var P = load("res://scripts/autoload/progress.gd")
	P.delete_save_files(SAVE)
	var d: String = load("res://scripts/autoload/characters.gd").dir_for(SAVE)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))


func _go() -> void:
	root.size = Vector2i(1280, 720)
	prog = root.get_node("Progress")
	prog.save_path = SAVE
	_wipe()
	prog.load_data()
	prog.xp = 30000
	prog.selected_class = "soldier"
	prog.save_data()
	var had_autoload: bool = root.get_node_or_null("Characters") != null
	if not had_autoload:
		await _without_characters()
		chars = load("res://scripts/autoload/characters.gd").new()
		chars.name = "Characters"
		root.add_child(chars)
	else:
		chars = root.get_node("Characters")
		print("SKIP  inactive-Characters checks (autoload is installed)")
	chars.bind(SAVE)
	await _tree_checks()
	await _characters_screen()
	await _class_item_card()
	await _home_checks()
	chars.unbind()
	_wipe()
	print("PLAYTEST B TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


# ------------------------------------------------------------------ inactive Characters: screens still work
func _without_characters() -> void:
	var sm = load("res://scripts/ui/skill_tree_menu.gd").new()
	root.add_child(sm)
	await frames(2)
	sm.open()
	await frames(4)
	check(sm.spec() == null, "no Characters: tree falls back to Progress")
	var avail: Array = sm._ids.filter(func(i): return sm.ui_state(i) == "available")
	check(not avail.is_empty() and sm.buy(avail[0]) and prog.rank(avail[0]) == 1, "no Characters: buy still works (Progress.buy_rank)")
	prog.respec_allowed = true
	check(sm.respec_state().allowed and str(sm.respec_state().label).contains("FREE"), "no Characters: old free respec")
	sm._respec_armed = 1.0
	sm._on_respec_pressed()
	check(prog.skill_points_spent == 0, "no Characters: respec through Progress.respec()")
	sm.close()
	sm.queue_free()
	var cs = load("res://scripts/ui/character_select.gd").new()
	root.add_child(cs)
	await frames(2)
	cs.open()
	await frames(3)
	check(not cs.is_live() and cs.entries().size() == 1 and cs.find_child("SlotsOff", true, false) != null, "no Characters: one slot + 'switch on with the classes update'")
	check(cs.find_child("NewSlot", true, false) == null and cs.play_button.disabled, "no Characters: no create / switch")
	cs.close()
	cs.queue_free()
	await frames(2)


# ------------------------------------------------------------------ #14 tree on the real 109-node data + SkillSpec
func _tree_checks() -> void:
	check(prog.all_node_ids().size() >= 100, "#14 data: %d nodes" % prog.all_node_ids().size())
	chars.enter_home()
	var sm = load("res://scripts/ui/skill_tree_menu.gd").new()
	root.add_child(sm)
	await frames(2)
	sm.open()
	await frames(6)
	check(sm.spec() != null, "#14 tree uses Characters.spec")
	var cls_ids: Array = sm._ids.filter(func(i): return str(sm._defs[i].get("class", "")) != "")
	check(not cls_ids.is_empty() and cls_ids.all(func(i): return str(sm._defs[i].class) == "soldier"), "#14 only your class's dock is shown (%d soldier nodes)" % cls_ids.size())
	var gen: int = prog.all_node_ids().filter(func(i): return str(prog.get_skill(i).get("class", "")) == "").size()
	check(sm._nodes.size() == gen + cls_ids.size(), "#14 tiles = general + one class (%d)" % sm._nodes.size())
	check(sm._content_size.x <= sm._clip.size.x + 1.0, "#14 tree fits 1280 wide, no side panning (%.0f <= %.0f)" % [sm._content_size.x, sm._clip.size.x])
	# no two tiles / name plates collide
	var rects: Array = []
	for id in sm._nodes:
		rects.append([id, sm._nodes[id].body_rect(), sm._nodes[id].name_rect()])
	var hits: Array = []
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			for a in [1, 2]:
				for b in [1, 2]:
					var r: Rect2 = rects[i][a].intersection(rects[j][b])
					if r.get_area() > 4.0:
						hits.append("%s/%s" % [rects[i][0], rects[j][0]])
	check(hits.is_empty(), "#14 no tile / name overlaps (%s)" % str(hits.slice(0, 4)))
	var gen_max_y := 0.0
	for i in sm._ids:
		if str(sm._defs[i].get("class", "")) == "":
			gen_max_y = maxf(gen_max_y, sm._nodes[i].position.y)
	check(cls_ids.all(func(i): return sm._nodes[i].position.y > gen_max_y + 40.0), "#14 class dock sits under the general rows")
	var dock_name: Label = sm._canvas.find_child("ClassDockName", true, false)
	check(dock_name != null and dock_name.text == "SOLDIER", "#14 dock is labelled with the class")
	# rail tab -> another class's dock
	sm._jump_to_branch("sexton")
	await frames(3)
	check(sm.class_view == "sexton" and sm._ids.filter(func(i): return str(sm._defs[i].get("class", "")) == "sexton").size() >= 10, "#14 SEXTON tab shows the Sexton dock")
	check(sm._ids.all(func(i): return str(sm._defs[i].get("class", "")) in ["", "sexton"]), "#14 ... and only that dock")
	check(sm.get_children().filter(func(c): return c is PanelContainer and c.z_index == 20).size() == 1, "#14 rebuild keeps one info box")
	sm.view_class("soldier")
	await frames(3)
	# exclusive forks through SkillSpec
	var sp = sm.spec()
	var pair: Array = []
	for i in sm._ids:
		var inf: Dictionary = sp.node_info(i)
		if not inf.get("exclusive_with", []).is_empty() and str(inf.get("class", "")) == "" and str(inf.get("state", "")) == "available":
			pair = [i, inf.exclusive_with[0]]
			break
	if pair.is_empty(): # pick prerequisites until a fork opens
		for k in 12:
			var av: Array = sm._ids.filter(func(i): return str(sp.node_info(i).state) == "available" and str(sp.node_info(i).get("class", "")) == "" and sp.node_info(i).get("exclusive_with", []).is_empty())
			if av.is_empty():
				break
			sm.buy(av[0])
			for i in sm._ids:
				var inf2: Dictionary = sp.node_info(i)
				if not inf2.get("exclusive_with", []).is_empty() and str(inf2.get("state", "")) == "available":
					pair = [i, inf2.exclusive_with[0]]
					break
			if not pair.is_empty():
				break
	check(not pair.is_empty(), "#14 an exclusive fork is reachable")
	if not pair.is_empty():
		check(sm.buy(pair[0]), "#14 pick one side of the fork (spec.pick)")
		await frames(1)
		check(sm.ui_state(pair[1]) == "excluded", "#14 other side shows excluded")
		check(not sm.buy(pair[1]) and sm.toast_text() != "", "#14 picking the excluded side is refused with a toast (%s)" % sm.toast_text())
		sm.nav_input = true
		sm._show_tooltip(pair[0])
		await frames(1)
		check(sm._tooltip.find_child("UndoHint", true, false) != null, "#14 info box offers the free undo for this visit's pick")
		check(sm.refund(pair[0]) and prog.rank(pair[0]) == 0 and sm.ui_state(pair[1]) != "excluded", "#14 U / X undo refunds it and reopens the fork")
		sm.hide_tooltip()
	# stat preview lines in the info box
	var with_lines := ""
	for i in sm._ids:
		if not sp.preview(i).get("lines", []).is_empty():
			with_lines = i
			break
	if with_lines != "":
		sm._show_tooltip(with_lines)
		await frames(1)
		check(sm._tooltip.find_child("PreviewLine", true, false) != null, "#14 info box shows the stat before -> after (spec.preview)")
		sm.hide_tooltip()
	# respec through spec
	var any: Array = sm._ids.filter(func(i): return str(sp.node_info(i).state) == "available")
	sm.buy(any[0])
	chars.leave_home() # picks permanent -> respec needed
	chars.enter_home()
	var rs: Dictionary = sm.respec_state()
	check(rs.allowed and str(rs.label).begins_with("[R] RESPEC"), "#14 respec button reads spec.respec_cost (%s)" % rs.label)
	var used0 := int(sp.respec_cost().get("respecs_used", 0))
	sm._respec_armed = 1.0
	sm._on_respec_pressed()
	check(prog.skill_points_spent == 0 and int(sp.respec_cost().get("respecs_used", 0)) == used0 + 1, "#14 respec goes through Characters.spec.respec()")
	prog.respec_allowed = false
	chars.leave_home()
	check(not sm.respec_state().allowed, "#14 respec disabled outside home / round 0 / game over")
	chars.enter_home()
	check(label_overlaps(sm.panel).is_empty(), "#14 no overlapping text on the tree screen %s" % str(label_overlaps(sm.panel).slice(0, 3)))
	sm.close()
	sm.queue_free()
	await frames(2)


# ------------------------------------------------------------------ #21 slots + #9 loadout
func _characters_screen() -> void:
	var cs = load("res://scripts/ui/character_select.gd").new()
	root.add_child(cs)
	await frames(2)
	chars.enter_home()
	cs.open()
	await frames(3)
	check(cs.is_live() and cs.entries().size() == 1 and cs.slot_buttons.has(chars.active_id()), "#21 lists the characters (1 after migration)")
	check(cs.find_child("NewSlot", true, false) != null, "#21 free slot offers NEW CHARACTER")
	var first: int = chars.active_id()
	cs.select_slot(cs.NEW_ID)
	await frames(2)
	check(cs.name_edit != null and cs.create_button != null, "#21 create form (name + class)")
	cs.name_edit.text = "   "
	cs._refresh_create()
	check(cs.create_button.disabled, "#21 empty name refused")
	cs.name_edit.text = "Mabel"
	cs.pick_create_class("sexton")
	await frames(1)
	check(cs.name_edit.text == "Mabel" and cs.create_class == "sexton" and not cs.create_button.disabled, "#21 picking a class keeps the typed name")
	check(cs.create_now(), "#21 CREATE + PLAY AS")
	await frames(2)
	check(chars.count() == 2 and str(chars.get_character(chars.active_id()).name) == "Mabel" and prog.selected_class == "sexton" and prog.get_level() == 1,
		"#21 new character is live: own save, level 1, Sexton")
	check(cs.slot_buttons.size() >= 3, "#21 both slots listed (+ new)")
	# #9 loadout
	check(cs.class_buttons.size() == 4 and cs.class_buttons.has("chandler"), "#9 four classes to pick")
	check(cs.set_class("chandler") and prog.selected_class == "chandler", "#9 class switch saves per character")
	await frames(1)
	var abil: Array = cs.ability_buttons.keys()
	check(abil.size() >= 2, "#9 Q ability choices for the class (%d)" % abil.size())
	if abil.size() >= 2:
		var other: String = abil[1] if str(chars.ability_for("chandler")) == abil[0] else abil[0]
		check(cs.set_ability("chandler", other) and chars.ability_for("chandler") == other, "#9 Q ability pick saved")
	check(cs.find_child("ClassStats", true, false) != null and cs.find_child("AbilitySummary", true, false) != null, "#9 class stats + ability summary shown")
	await frames(3)
	check(label_overlaps(cs.panel).is_empty(), "#21/#9 no overlapping text %s" % str(label_overlaps(cs.panel).slice(0, 3)))
	check(Rect2(Vector2.ZERO, Vector2(1280, 720)).encloses(cs.panel.get_global_rect()), "#21 fits 1280x720 (%s)" % str(cs.panel.get_global_rect()))
	# switch back
	cs.select_slot(first)
	await frames(1)
	check(cs.switch_to(first) and chars.active_id() == first and prog.selected_class == "soldier", "#21 PLAY AS switches the live save back")
	# rename
	cs.rename_edit.text = "Old Tom"
	check(cs.rename_selected() and str(chars.get_character(first).name) == "Old Tom", "#21 rename")
	# delete (two steps) the other one
	var mabel: int = -1
	for e in chars.list():
		if str(e.name) == "Mabel":
			mabel = int(e.id)
	cs.select_slot(mabel)
	await frames(1)
	check(not cs.delete_selected() and cs._delete_token != "" and cs.delete_button.text.begins_with("CONFIRM"), "#21 delete asks to confirm first")
	check(cs.delete_selected() and chars.count() == 1, "#21 confirm deletes the character")
	cs.select_slot(chars.active_id())
	await frames(1)
	check(cs.delete_button.disabled, "#21 can't delete the last character")
	check(cs.chip_text().begins_with("OLD TOM") and cs.chip_text().contains("SOLDIER"), "#21 home chip text (%s)" % cs.chip_text())
	cs.close()
	cs.queue_free()
	await frames(2)


# ------------------------------------------------------------------ #24 home (needs the shared.patch home_menu hook)
func _home_checks() -> void:
	var home = load("res://scripts/ui/home_menu.gd").new()
	if not home.has_method("open_skills"):
		print("SKIP  #24 home SKILLS / chip: home_menu.gd hook not applied (shared.patch)")
		home.free()
		return
	home.dry_run = true
	home.name_prompt_on_launch = false
	prog.respec_allowed = false
	root.add_child(home)
	await frames(4)
	check(prog.respec_allowed, "#24 home calls Characters.enter_home (respec window open)")
	var order: Array = home._focus_order
	check(order.find("skills") == order.find("kit") + 1 and order.find("merchant") == order.find("armory") + 1, "#24 SKILLS sits after KIT (%s)" % str(order))
	var sk = home.open_skills()
	await frames(4)
	check(sk.visible and sk.spec() != null and sk._nodes.size() > 40, "#24 SKILLS opens the tree at home")
	var av: Array = sk._ids.filter(func(i): return sk.ui_state(i) == "available")
	check(sk.buy(av[0]) and sk.refund(av[0]), "#24 pick + free undo at home")
	sk.close()
	await frames(2)
	check(home._char_chip != null and home._char_chip.text.contains("OLD TOM"), "#21 header chip names the character (%s)" % home._char_chip.text)
	var cs = home.open_characters()
	await frames(2)
	check(cs.visible, "#21 chip opens CHARACTERS")
	cs.close()
	await frames(2)
	var bl: Rect2 = home._btns["quit"].get_global_rect()
	check(bl.end.y <= 720.0, "#24 7 menu buttons fit 720 high (quit ends at %.0f)" % bl.end.y)
	check(chars.spec.session_open, "#24 undo session open at home")
	check(home.start_match("arena") and not chars.spec.session_open, "#24 start_match calls leave_home (picks become permanent)")
	home.queue_free()
	await frames(2)


# ------------------------------------------------------------------ #9 class items on the kit item card
func _class_item_card() -> void:
	var gdb = root.get_node("GearDB")
	var CI = load("res://scripts/classes/class_items.gd")
	var item = gdb.roll_armor("chest", 3, 4) if gdb.has_method("roll_armor") else null
	if item == null:
		check(false, "#9 could not roll an armor piece")
		return
	CI.assign(item, "scout")
	prog.selected_class = "soldier"
	var ks = load("res://scripts/ui/character_screen.gd").new()
	root.add_child(ks)
	await frames(2)
	var box := VBoxContainer.new()
	ks._class_item_block(box, item)
	var head: Label = box.find_child("ClassItemHead", true, false)
	check(head != null and head.text.contains("WRONG CLASS") and box.find_child("ClassItemLine", true, false).text == item.class_line(),
		"#9 class item card: effect line + WRONG CLASS when you're another class")
	var t: Button = ks._tile(item, Vector2(64, 64), false)
	check(t.has_meta("wrong_class") and t.modulate.r < 0.9, "#9 wrong-class item tile is greyed")
	prog.selected_class = "scout"
	var box2 := VBoxContainer.new()
	ks._class_item_block(box2, item)
	check(not box2.find_child("ClassItemHead", true, false).text.contains("WRONG"), "#9 right class: no warning")
	prog.selected_class = "soldier"
	t.free()
	box.free()
	box2.free()
	ks.queue_free()
	await frames(2)
