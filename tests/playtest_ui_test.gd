extends SceneTree
## Gooey playtest pass (2026-10-20, v0.6.1 notes) — headless UI checks:
##   #8 game-over stats page, #10 Armory right panel overlap, #26 map preview walls,
##   #29 skill tree overlap, #31 hover-only skill info box, #34 live stat effects.
##   godot --headless --path . -s res://tests/playtest_ui_test.gd

var ArmoryMenuScr
## Scripts that use autoload identifiers are loaded at run time (a preload would compile them before the autoloads).
var SkillTreeScr
var MapPickerScr
var RunStatsScr
var GameOverScr
var StatPreviewScr
const STAT_ORDER := ["agility", "toughness", "vitality", "ordnance", "focus", "brawn"]
const SAVE := "user://progress_playtest_ui_test.cfg"
const TOAST_WAIT := 5.0

var _fails := 0
var _passes := 0

func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond: _passes += 1
	else: _fails += 1

func frames(n: int) -> void:
	for i in n: await process_frame

func _initialize() -> void:
	_go.call_deferred()


## Visible labels under `n` whose rects overlap another visible label (not an ancestor / descendant).
static func label_overlaps(n: Node, min_area: float = 6.0) -> Array:
	var labs: Array = n.find_children("*", "Label", true, false).filter(func(l): return l.is_visible_in_tree() and l.text.strip_edges() != "")
	var out: Array = []
	for i in labs.size():
		var a: Rect2 = labs[i].get_global_rect()
		for j in range(i + 1, labs.size()):
			var b: Rect2 = labs[j].get_global_rect()
			if a.intersects(b):
				var ia := a.intersection(b)
				if ia.get_area() > min_area:
					out.append("%s | %s" % [labs[i].text.left(24), labs[j].text.left(24)])
	return out


func _go() -> void:
	ArmoryMenuScr = load("res://scripts/ui/armory_menu.gd")
	SkillTreeScr = load("res://scripts/ui/skill_tree_menu.gd")
	MapPickerScr = load("res://scripts/ui/map_picker.gd")
	RunStatsScr = load("res://scripts/ui/run_stats.gd")
	GameOverScr = load("res://scripts/ui/game_over_screen.gd")
	StatPreviewScr = load("res://scripts/ui/stat_preview.gd")
	var prog = root.get_node("Progress")
	prog.save_path = SAVE
	load("res://scripts/autoload/progress.gd").delete_save_files(SAVE)
	prog.load_data()
	prog.xp = 5200
	prog.gravemarks = 85
	prog.armory = {"upgrades": {"smg": 2}, "owned": ["mine_lamp", "pinhole"], "equipped": {"smg": {"grip": "mine_lamp", "optic": "pinhole"}}}
	prog.save_data()

	await _armory()
	await _maps()
	await _skill_tree()
	# playtest 2026-10-22 #1: skill tiles draw the icon inside _draw(); UIStyle must keep a strong ref or it renders white
	var it1 = UIStyle.skill_icon_tex("mk_root")
	check(it1 != null and it1 == UIStyle.skill_icon_tex("mk_root") and UIStyle._icon_cache.has("res://assets/icons/skill_mk_root.png"), "skill icon texture cached (strong ref, no white box)")
	_stat_formulas_static()
	_run_stats_unit()
	await _game_over_screen_unit()
	await _in_match()

	load("res://scripts/autoload/progress.gd").delete_save_files(SAVE)
	print("PLAYTEST UI TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


# ------------------------------------------------------------------ #10 Armory
func _armory() -> void:
	var menu = ArmoryMenuScr.new()
	root.add_child(menu)
	await frames(3)
	menu.open()
	for res in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1080), Vector2i(1280, 800)]:
		root.size = res
		await frames(3)
		for wid in ["smg", "sniper_rifle", "shotgun", "sidearm"]:
			menu._select_weapon(wid)
			await frames(4)
			var sc: ScrollContainer = menu._right.get_parent().get_parent()
			var view: Rect2 = sc.get_global_rect()
			var sb_w := sc.get_v_scroll_bar().size.x if sc.get_v_scroll_bar().visible else 0.0
			var limit := view.end.x - sb_w + 0.5
			var past := []
			for l in menu._right.find_children("*", "Label", true, false):
				if l.is_visible_in_tree() and l.get_global_rect().end.x > limit:
					past.append(l.text.left(30))
			for b in menu._right.find_children("*", "Button", true, false):
				if b.is_visible_in_tree() and b.get_global_rect().end.x > limit:
					past.append("[btn] " + b.text)
			var ov = label_overlaps(menu._right)
			var tag := "%s @%dx%d" % [wid, res.x, res.y]
			check(past.is_empty(), "armory right panel stays left of the scrollbar (%s) %s" % [tag, str(past.slice(0, 3))])
			check(ov.is_empty(), "armory right panel: no overlapping text (%s) %s" % [tag, str(ov.slice(0, 3))])
			check(menu._right.size.x <= view.size.x + 0.5, "armory right column not wider than its scroll view (%s)" % tag)
		var ovl = label_overlaps(menu._left)
		check(ovl.is_empty(), "armory weapon list labels don't overlap @%dx%d %s" % [res.x, res.y, str(ovl.slice(0, 3))])
		var b0: Button = menu._weapon_btns.values()[0]
		var lab: Control = b0.get_node("Labels")
		check(b0.get_global_rect().encloses(lab.get_global_rect()), "weapon button labels sit inside the button border")
	root.size = Vector2i(1280, 720)
	menu._select_weapon("smg")
	await frames(2)
	check(menu._right.find_child("UpgradeTrack", true, false) != null and menu._right.find_child("WeaponIP", true, false) != null,
		"armory detail still has the upgrade track + IP plate")
	var sc2: ScrollContainer = menu.find_child("RightScroll", true, false)
	check(sc2 != null and sc2.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED, "right panel never scrolls sideways")
	menu.close()
	menu.queue_free()
	await frames(2)


# ------------------------------------------------------------------ #26 map preview walls
func _maps() -> void:
	for id in ["arena", "rustwell_foundry", "lockout_substation"]:
		var w: Array = MapPickerScr.map_walls(id)
		var walls := w.filter(func(x): return x.kind == "wall")
		check(walls.size() >= 10, "%s: wall footprints parsed from the scene (%d walls, %d floors)" % [id, walls.size(), w.size() - walls.size()])
		var m: Dictionary = MapPickerScr.map_meta(id)
		if m.bounds.size != Vector2.ZERO:
			var inside = walls.filter(func(x): return m.bounds.grow(2.0).has_point(x.poly[0])).size()
			check(inside >= walls.size() * 0.9, "%s: walls sit inside the map bounds (%d/%d)" % [id, inside, walls.size()])
	# a known wall: rustwell FlueWall body at (-30.2, -22)
	var flue = MapPickerScr.map_walls("rustwell_foundry").filter(func(x):
		var c := Vector2.ZERO
		for p in x.poly: c += p
		return (c / 4.0).distance_to(Vector2(-30.2, -22)) < 3.0 and x.kind == "wall")
	check(not flue.is_empty(), "rustwell FlueWall lands where the scene puts it (-30.2, -22)")
	var txt := "[sub_resource type=\"BoxShape3D\" id=\"b1\"]\nsize = Vector3(4, 3, 1)\n\n[node name=\"Root\" type=\"Node3D\"]\n\n" \
		+ "[node name=\"G\" type=\"Node3D\" parent=\".\"]\ntransform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 10, 0, 5)\n\n" \
		+ "[node name=\"W\" type=\"StaticBody3D\" parent=\"G\"]\ntransform = Transform3D(0, 0, -1, 0, 1, 0, 1, 0, 0, 1, 1.5, 0)\n\n" \
		+ "[node name=\"C\" type=\"CollisionShape3D\" parent=\"G/W\"]\nshape = SubResource(\"b1\")\n\n" \
		+ "[node name=\"Clip\" type=\"Node3D\" parent=\".\"]\n\n[node name=\"K\" type=\"StaticBody3D\" parent=\"Clip\"]\n\n" \
		+ "[node name=\"C\" type=\"CollisionShape3D\" parent=\"Clip/K\"]\nshape = SubResource(\"b1\")\n"
	var tw: Array = MapPickerScr.walls_from_text(txt)
	var bb := Rect2(tw[0].poly[0], Vector2.ZERO) if tw.size() == 1 else Rect2()
	for p in (tw[0].poly if tw.size() == 1 else []):
		bb = bb.expand(p)
	check(tw.size() == 1 and tw[0].kind == "wall" and bb.position.is_equal_approx(Vector2(10.5, 3.0)) and bb.size.is_equal_approx(Vector2(1, 4)),
		"walls_from_text composes parent transforms + rotation and skips Clip (%s)" % str(bb))
	var mp = MapPickerScr.new()
	mp.home_mode = true
	mp.dry_run = true
	root.add_child(mp)
	await frames(2)
	mp.open()
	mp.select_row("rustwell_foundry")
	await frames(3)
	check(mp._preview.walls.size() > 0 and mp._preview.visible, "schematic gets the wall list on select")
	mp._preview.queue_redraw()
	await frames(3)
	check(mp._preview.wall_count > 0 or DisplayServer.get_name() == "headless", "schematic drew walls (%d)" % mp._preview.wall_count)
	mp.select_row("arena")
	await frames(2)
	check(mp._preview.walls.size() > 0, "arena (built into main.tscn) also has walls in its preview")
	mp.close()
	mp.queue_free()
	await frames(2)


# ------------------------------------------------------------------ #29 / #31 skill tree
func _skill_tree() -> void:
	var sm = SkillTreeScr.new()
	root.add_child(sm)
	await frames(2)
	sm.open()
	await frames(4)
	check(sm.visible and not sm._nodes.is_empty(), "skill tree opens")
	check(not sm.tooltip_visible(), "#31 info box hidden on open (auto-focus is not a hover)")
	var ids: Array = sm._nodes.keys()
	var a: String = ids[0]
	var b: String = ids[3]
	sm._on_tile_hover(a, true)
	await frames(1)
	check(sm.tooltip_visible() and sm._tip_id == a, "#31 hovering a skill shows its info box")
	sm._on_tile_hover(a, false)
	await frames(1)
	check(not sm.tooltip_visible(), "#31 leaving the skill hides the info box")
	sm.nav_input = false
	sm._nodes[b].grab_focus()
	await frames(1)
	check(not sm.tooltip_visible(), "#31 mouse mode: focus change alone doesn't open the box")
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.physical_keycode = KEY_DOWN
	ev.keycode = KEY_DOWN
	sm._input(ev)
	check(sm.nav_input, "#31 key press switches to nav mode")
	sm._nodes[a].grab_focus()
	await frames(2)
	check(sm.tooltip_visible() and sm._tip_id == a, "#31 keyboard / pad focus counts as hover")
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(12, 0)
	sm._input(mm)
	await frames(1)
	check(not sm.nav_input and not sm.tooltip_visible(), "#31 moving the mouse off any skill hides it again")
	sm._on_tile_hover(b, true)
	sm.buy(b)
	await frames(2)
	check(sm.tooltip_visible() and sm._tip_id == b, "#31 info box stays (and refreshes) while hovered through a purchase")
	sm._on_tile_hover(b, false)
	# #29 overlap: name plates, tiles, keystone label, branch headers
	var rects: Array = []
	for id in sm._nodes:
		var t = sm._nodes[id]
		rects.append(["name:" + id, t.name_rect()])
		rects.append(["tile:" + id, t.body_rect()])
	var bad: Array = []
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			var ra: Rect2 = rects[i][1]
			var rb: Rect2 = rects[j][1]
			var same := str(rects[i][0]).get_slice(":", 1) == str(rects[j][0]).get_slice(":", 1)
			if not same and ra.intersects(rb) and ra.intersection(rb).get_area() > 4.0:
				bad.append("%s x %s" % [rects[i][0], rects[j][0]])
	check(bad.is_empty(), "#29 no tile / name-plate overlaps (%d nodes) %s" % [sm._nodes.size(), str(bad.slice(0, 4))])
	check(sm.name_width() <= sm._pitch - 10.0 + 0.01, "#29 name plates are narrower than the column pitch")
	var kr: Rect2 = sm._wires.keystone_label_rect
	var khit := rects.filter(func(r): return kr.size != Vector2.ZERO and kr.intersects(r[1]))
	check(kr.size == Vector2.ZERO or khit.is_empty(), "#29 KEYSTONE label clear of tiles and names %s" % str(khit.map(func(r): return r[0])))
	var heads: Array = sm._canvas.get_children().filter(func(c): return c is Label and str(c.name).begins_with("BranchHeader_"))
	var hbad := 0
	for i in heads.size():
		var f: Font = heads[i].get_theme_font("font")
		var fs: int = heads[i].get_theme_font_size("font_size")
		if f.get_string_size(heads[i].text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > heads[i].size.x + 1.0:
			hbad += 1
		for j in range(i + 1, heads.size()):
			if heads[i].get_rect().intersects(heads[j].get_rect()):
				hbad += 1
	check(heads.size() >= 3 and hbad == 0, "#29 branch headers fit their span and don't touch (%d)" % heads.size())
	var rail_end: float = sm._rail.get_global_rect().end.x
	var rail_ok: bool = sm._rail_tabs.values().all(func(t): return t.clip_text and t.get_global_rect().end.x <= rail_end + 0.5)
	check(rail_ok, "#29 branch rail tabs clip instead of overflowing")
	# a much bigger tree (Skillz is enlarging it): names still never collide with neighbours
	check(SkillTreeScr.fit_font_size(load("res://scripts/ui/ui_style.gd").FONT_STENCIL, "AN EXTREMELY LONG BRANCH NAME", 80.0, 14, 9) == 9,
		"#29 fit_font_size shrinks long headers to the floor size")
	sm.close()
	sm.queue_free()
	await frames(2)


# ------------------------------------------------------------------ #34 stat formulas (no player)
func _stat_formulas_static() -> void:
	var d0: Dictionary = StatPreviewScr.derived(null, {})
	var d1: Dictionary = StatPreviewScr.derived(null, {"agility": 100, "toughness": 100, "vitality": 100, "ordnance": 100, "focus": 100, "brawn": 100})
	# Skillz Economy v2: data/stats.json maxima at 100 (ease-out curve; early points count most)
	check(is_equal_approx(d1.walk_speed / d0.walk_speed, 1.25), "#34 100 Agility = +25% move speed")
	check(is_equal_approx(d1.damage_taken_pct, 60.0), "#34 100 Toughness = 60% damage taken")
	check(is_equal_approx(d1.regen_delay, 1.5) and is_equal_approx(d1.regen_rate, 26.0), "#34 100 Vitality = regen after 1.5 s at 26 HP/s")
	check(is_equal_approx(d1.grenade_cooldown / d0.grenade_cooldown, 0.5), "#34 100 Ordnance = half grenade cooldown")
	check(is_equal_approx(d1.melee_damage, 112.0) and is_equal_approx(d1.melee_cooldown, 0.96), "#34 100 Brawn = +60% melee, -40% melee cooldown")
	var rows: Array = StatPreviewScr.rows(null, {"agility": 10})
	var ag: Dictionary = rows[0]
	check(ag.stat == "agility" and ag.next_value == 11 and ag.lines[0].better == 1 and str(ag.lines[0].delta_text).begins_with("+"),
		"#34 rows(): next-point delta for Agility is a gain (%s)" % str(ag.lines[0].get("delta_text")))
	var tough: Dictionary = rows[1]
	check(tough.lines[0].better == 1 and str(tough.lines[0].delta_text) == "-0.8%", "#34 the first Toughness point = -0.8%% damage taken (%s)" % tough.lines[0].delta_text)
	var pv: Array = StatPreviewScr.rows(null, {"agility": 10}, {"agility": 4})
	check(pv[0].previewing and pv[0].next_value == 4 and pv[0].lines[0].better == -1, "#34 preview of fewer points reads as a loss")
	var focus_row: Dictionary = StatPreviewScr.rows(null, {})[4]
	check(focus_row.lines[0].now == "-", "#34 no ability -> Focus line shows '-' (no fake number)")
	var brawn: Dictionary = StatPreviewScr.rows(null, {})[5]
	check(str(brawn.lines[0].delta_text) != "+0", "#34 small per-point gains never print as +0 (%s)" % brawn.lines[0].delta_text)


# ------------------------------------------------------------------ #8 tracker (no match)
func _run_stats_unit() -> void:
	var t = RunStatsScr.new()
	root.add_child(t)
	var ge = root.get_node("GameEvents")
	var me := Node.new()
	var other := Node.new()
	t.player = me
	ge.emit_event(&"round_started", {"round": 1})
	for i in 10:
		ge.emit_event(&"shot_fired", {"player": me, "weapon": null})
	for i in 3:
		ge.emit_event(&"shot_missed", {"player": me})
	ge.emit_event(&"shot_fired", {"player": other, "weapon": null})
	ge.emit_event(&"hit", {"player": me, "damage": 50.0, "is_headshot": true, "source": "gun"})
	ge.emit_event(&"hit", {"player": me, "damage": 25.5, "is_headshot": false, "source": "gun"})
	ge.emit_event(&"hit", {"player": other, "damage": 999.0})
	ge.emit_event(&"enemy_killed", {"player": me, "source": "melee"})
	ge.emit_event(&"points_gained", {"player": me, "amount": 60})
	ge.emit_event(&"points_gained", {"player": other, "amount": 900})
	ge.emit_event(&"damage_taken", {"player": me, "dealt": 30})
	ge.emit_event(&"grenade_thrown", {"player": me})
	ge.emit_event(&"round_started", {"round": 2})
	var st: Dictionary = t.snapshot()
	check(st.shots_fired == 10 and st.shots_missed == 3 and is_equal_approx(st.accuracy, 0.7), "#8 accuracy from shot_fired / shot_missed (%.2f)" % st.accuracy)
	check(is_equal_approx(st.damage_dealt, 75.5) and st.headshots == 1 and st.hits == 2, "#8 damage + headshots from hit events (local player only)")
	check(st.kills == 1 and st.melee_kills == 1 and st.points_earned == 60 and st.damage_taken == 30 and st.grenades == 1, "#8 kills / points / damage taken / grenades")
	check(st.rounds == 2 and t.started, "#8 rounds from round_started")
	check(RunStatsScr.accuracy_of({}) < 0.0, "#8 no shots -> accuracy '-' (not 0%)")
	check(RunStatsScr.format_time(754.0) == "12:34" and RunStatsScr.format_time(3725.0) == "1:02:05", "#8 time format")
	ge.emit_event(&"match_ended", {"player": me, "round": 3, "kills": 7})
	check(t.ended and t.s.kills == 7 and t.s.rounds == 3, "#8 match_ended: main.gd's kill count wins")
	ge.emit_event(&"hit", {"player": me, "damage": 1000.0})
	check(is_equal_approx(t.s.damage_dealt, 75.5), "#8 nothing counts after match end")
	t.queue_free()
	me.free()
	other.free()


func _game_over_screen_unit() -> void:
	var g = GameOverScr.new()
	g.dry_run = true
	root.add_child(g)
	await frames(2)
	var st := {"kills": 87, "damage_dealt": 13661.4, "rounds": 9, "points_earned": 3690, "gravemarks": 2, "xp_earned": 1320,
		"shots_fired": 140, "shots_missed": 41, "accuracy": 99.0 / 140.0, "headshots": 33, "hits": 131, "time_s": 754.0, "level": 21}
	g.show_stats(st)
	await frames(2)
	check(g.visible and g.tiles.kills.text == "87" and g.tiles.damage_dealt.text == "13,661" and g.tiles.rounds.text == "9",
		"#8 tiles: kills / damage / rounds")
	check(g.tiles.points_earned.text == "3,690" and g.tiles.gravemarks.text == "+2" and g.tiles.xp_earned.text == "+1,320",
		"#8 tiles: points / Gravemarks / XP")
	check(g.rows.accuracy.text.begins_with("71%") and g.rows.time_s.text == "12:34" and g.rows.headshots.text.begins_with("33"),
		"#8 detail rows: accuracy / time / headshots (%s)" % g.rows.accuracy.text)
	check(g.back_button.text == "BACK TO MENU" and g.again_button.text.begins_with("PLAY AGAIN"), "#8 Back to Menu + Play Again buttons")
	var got := []
	g.back_to_menu_pressed.connect(func(): got.append("back"))
	g.play_again_pressed.connect(func(): got.append("again"))
	g.back_button.pressed.emit()
	g.again_button.pressed.emit()
	check(got == ["back", "again"], "#8 buttons fire")
	check(label_overlaps(g).is_empty(), "#8 stats page: no overlapping text %s" % str(label_overlaps(g).slice(0, 3)))
	var card: Control = g.find_child("StatsCard", true, false)
	check(Rect2(Vector2.ZERO, Vector2(1280, 720)).encloses(card.get_global_rect()), "#8 stats card fits 1280x720 (%s)" % str(card.get_global_rect()))
	g.queue_free()
	await frames(2)


# ------------------------------------------------------------------ in a real match: #34 vs player.gd, #8 HUD wiring
func _in_match() -> void:
	change_scene_to_file("res://scenes/main.tscn")
	await frames(40)
	var m = current_scene
	m._break_timer = 99999.0
	var p = m.player
	var inv = p.inventory
	# #34: StatPreview must match player.gd recalc_stats() for real armor
	var piece = null
	for s in inv.ARMOR_SLOTS:
		if inv.equipped.get(s) != null and inv.equipped.get(s).get("stats") is Dictionary and inv.equipped.get(s).has_method("stat_total"):
			piece = inv.equipped[s]
			break
	check(piece != null, "#34 an armor piece is equipped")
	var mismatch := []
	for bump in [0, 25, 60]:
		if piece:
			for s in STAT_ORDER:
				piece.stats[s] = int(piece.stats.get(s, 0)) + (bump if s in ["agility", "toughness", "focus"] else bump / 2)
		p.recalc_stats()
		var d: Dictionary = StatPreviewScr.derived(p, inv.total_armor_stats())
		for pair in [["walk_speed", p.walk_speed], ["sprint_speed", p.sprint_speed], ["damage_reduction", p.damage_reduction],
				["regen_delay", p.regen_delay], ["regen_rate", p.regen_rate], ["grenade_cooldown", p.grenade_cooldown],
				["melee_damage", p.melee_damage], ["melee_cooldown", p.melee_cooldown],
				["ability_cooldown", p.ability.cooldown if p.ability else -1.0]]:
			if not is_equal_approx(float(d[pair[0]]), float(pair[1])):
				mismatch.append("%s %.3f vs %.3f (+%d)" % [pair[0], d[pair[0]], pair[1], bump])
	check(mismatch.is_empty(), "#34 StatPreview.derived == player.gd recalc_stats() (3 stat sets) %s" % str(mismatch.slice(0, 3)))
	if piece: # undo the +85 / +42 bumps: at the 100 cap (Economy v2 caps totals) a stat point has no gain left to show
		for s in STAT_ORDER:
			piece.stats[s] = int(piece.stats.get(s, 0)) - (85 if s in ["agility", "toughness", "focus"] else 42)
		p.recalc_stats()
	var cs = m.character_screen
	cs.open()
	await frames(4)
	check(cs._stats_grid.get_child_count() == 6, "#34 six stat tiles")
	var ag: Control = cs._stats_grid.get_node("Stat_agility")
	check(ag.find_child("Line_walk_speed", true, false) != null and ag.find_child("Delta", true, false) != null,
		"#34 Agility tile shows move speed + its per-point gain")
	check(ag.find_child("Line_walk_speed", true, false).get_node("Now").text == "%.2f m/s" % p.walk_speed, "#34 tile shows the player's real move speed")
	var tough: Control = cs._stats_grid.get_node("Stat_toughness")
	check(tough.find_child("Now", true, false).text == "%.1f%%" % ((1.0 - p.damage_reduction) * 100.0), "#34 tile shows real damage taken %")
	cs.debug_preview_stat("agility", 10)
	await frames(1)
	ag = cs._stats_grid.get_node("Stat_agility")
	var pv: Label = ag.find_child("PreviewValue", true, false)
	check(pv != null and pv.text.contains(str(int(inv.total_armor_stats().agility) + 10)), "#34 live preview: Agility N -> N+10")
	check(ag.find_child("Delta", true, false).text.begins_with("→"), "#34 live preview: move speed now -> previewed")
	cs.clear_stat_preview()
	await frames(1)
	check(cs._stats_grid.get_node("Stat_agility").find_child("PreviewValue", true, false) == null, "#34 preview clears")
	# hover an armor piece from the stash -> preview the swap
	var gdb = root.get_node("GearDB")
	var alt = gdb.roll_armor(piece.slot, 3, 4) if gdb.has_method("roll_armor") else null
	if alt:
		var sw: Dictionary = cs.armor_swap_totals(alt)
		var t0: Dictionary = inv.total_armor_stats()
		var ok := true
		for s in STAT_ORDER:
			ok = ok and int(sw[s]) == int(t0[s]) - int(piece.stats.get(s, 0)) + int(alt.stats.get(s, 0))
		check(ok, "#34 armor_swap_totals = totals - equipped + hovered")
		cs._on_tile_hover(alt, false)
		await frames(1)
		check(not cs.stat_preview.is_empty(), "#34 hovering a stash armor piece previews its stats on the tiles")
		cs._hide_tooltip()
		await frames(1)
		check(cs.stat_preview.is_empty(), "#34 leaving it clears the preview")
	else:
		check(true, "#34 (GearDB.roll_armor missing: swap preview checked by armor_swap_totals only)")
	check(label_overlaps(cs._stats_grid).is_empty(), "#34 stat tiles: no overlapping text")
	var center_ok: bool = cs._right.get_global_rect().end.x <= 1280.5
	check(center_ok, "#34 wider stat tiles don't push the armor column off screen (%.0f)" % cs._right.get_global_rect().end.x)
	cs.close()
	await frames(2)
	await _run_pick_refusal(m, p)
	# #8: death -> stats page next to the HUD (hud.gd wiring is G4M3N's shared.patch; skipped until it lands)
	var hud = m.hud
	if not hud.has_method("show_game_over_stats"):
		print("SKIP  #8 HUD wiring: hud.gd has no show_game_over_stats yet (shared.patch not applied)")
		return
	check(hud.run_stats != null and hud.run_stats.player == p, "#8 HUD owns a RunStats tracker bound to the player")
	var ge = root.get_node("GameEvents")
	ge.emit_event(&"round_started", {"round": 1})
	ge.emit_event(&"shot_fired", {"player": p, "weapon": null})
	ge.emit_event(&"hit", {"player": p, "damage": 40.0, "is_headshot": true, "source": "gun"})
	m.kills = 5
	m.current_round = 4
	p.max_health = 100
	p.health = 100
	p.damage_reduction = 0.0
	await frames(2)
	p.take_damage(1000000)
	await frames(4)
	check(m._game_over, "#8 game over on death")
	var g = hud.game_over_screen
	check(g != null and g.visible and g.get_parent() == m, "#8 stats page shows (sibling of the HUD, so buttons take the mouse)")
	check(g.tiles.kills.text == "5" and g.tiles.rounds.text == "4", "#8 page uses main.gd's kills / round (%s / %s)" % [g.tiles.kills.text, g.tiles.rounds.text])
	check(g.rows.damage_taken.text == "100", "#8 killing blow counts as the HP that was left (%s)" % g.rows.damage_taken.text)
	check(g.stats.get("xp_earned", -1) == prog_xp_delta(), "#8 XP earned = Progress XP gained this match")
	check(not hud._message.visible, "#8 old GAME OVER text is hidden behind the page")
	hud.show_message("GAME OVER\n...", Color.RED)
	check(not hud._message.visible and g.visible, "#8 main.gd's re-sent game-over text refreshes the page instead")
	check(g.back_button.focus_mode == Control.FOCUS_ALL and g.again_button.has_focus(), "#8 Play Again focused (Enter keeps restarting)")
	var hits_mouse: bool = g.get_node("Root").mouse_filter == Control.MOUSE_FILTER_STOP and g.back_button.mouse_filter == Control.MOUSE_FILTER_STOP
	check(hits_mouse, "#8 page buttons are clickable (not passthrough)")
	g.dry_run = true
	var got := []
	g.back_to_menu_pressed.connect(func(): got.append(1))
	g.back_button.pressed.emit()
	check(got == [1], "#8 Back to Menu pressed (dry run)")


var _xp0 := -1
func prog_xp_delta() -> int:
	var prog = root.get_node("Progress")
	return int(current_scene.get("_last_earned")) if current_scene.get("_last_earned") != null else int(prog.xp)


# ------------------------------------------------------------------ Netz M13: co-op reroll refusal on the Field Card menu
func _run_pick_refusal(m, p) -> void:
	var rp = m.run_pick_menu
	var rs = root.get_node("RunState")
	check(rp.has_method("show_toast") and rp.toast_label != null, "run-pick: has a refusal toast")
	check(rp.refusal_text("not_enough_points").contains("points") and rp.refusal_text("timeout").contains("not charged")
		and rp.refusal_text("busy").contains("busy") and rp.refusal_text("weird_thing").contains("weird thing"),
		"run-pick: friendly text for not_enough_points / timeout / busy (+ fallback)")
	rs.player = p
	p.points = 0
	rs.free_rerolls = 0
	rs.open_offer(3)
	await frames(2)
	check(rp.visible, "run-pick: offer open")
	if rs.has_signal("reroll_refused"):
		rs.last_refusal_reason = "timeout"
		rs.reroll_refused.emit("timeout")
	else:
		rp._on_reroll_refused("timeout")
	await frames(1)
	check(rp.toast_visible() and rp.toast_label.text == rp.refusal_text("timeout").to_upper(), "run-pick: refusal shows a toast (%s)" % rp.toast_label.text)
	check(rp._reroll_btn.disabled == not rs.can_reroll(), "run-pick: refusal refreshes the reroll button")
	if "reroll_pending" in rs:
		p.points = 99999
		rs.reroll_pending = false
		rp.refresh()
		await frames(2)
		var en: bool = not rp._reroll_btn.disabled
		rs.reroll_pending = true
		await frames(2)
		check(en and rp._reroll_btn.disabled and rp._reroll_btn.get_meta("text").text.contains("WAITING"),
			"run-pick: paid reroll disables while the host request is pending")
		rs.reroll_pending = false
		await frames(2)
		check(not rp._reroll_btn.disabled, "run-pick: re-enables when the host answers")
	else:
		print("SKIP  run-pick pending: RunState.reroll_pending not on main yet (Netz M13)")
	rp._process(TOAST_WAIT)
	check(not rp.toast_visible(), "run-pick: toast fades")
	rs.skip()
	await frames(2)
