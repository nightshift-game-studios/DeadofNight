extends SceneTree
## Dev tool (not a test): screenshots for /workspace/skillz/screens/. Needs a display (xvfb-run):
##   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . -s res://tests/skill_shots.gd
## 1) the existing skill_tree_menu.gd (Gooey's, unedited) fed v2 data through the Progress shims,
## 2) a backend layout preview drawn straight from the v2 x/y grid (NOT a UI proposal; checks the data),
## 3) a Field Card offer (round 5 milestone) in the TEMP chooser.

const OUT := "/workspace/skillz/screens/"


func _initialize() -> void:
	_go.call_deferred()


func snap(name: String) -> void:
	for i in 4:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(OUT + name)
	print("saved ", OUT + name, " ", img.get_size())


func _go() -> void:
	var prog = root.get_node("Progress")
	var rs = root.get_node("RunState")
	prog.save_path = "user://progress_shots_skills.cfg"
	prog.reset_skills()
	prog.xp = 250 * 14
	for id in ["mk_root", "mk_aim", "mk_aim", "mk_spotter", "sv_root", "sv_skin", "lg_spare", "fr_root"]:
		prog.buy_rank(id)
	change_scene_to_file("res://scenes/main.tscn")
	for i in 40:
		await process_frame
	var m = current_scene
	m._break_timer = 99999.0
	# 1) existing menu with v2 data
	m.skill_menu.open()
	await snap("skill_tree_menu_v2_data.png")
	m.skill_menu.close()
	for i in 3:
		await process_frame
	# 2) layout preview from the v2 grid
	var layer := CanvasLayer.new()
	layer.layer = 50
	m.add_child(layer)
	var prev := Preview.new()
	prev.prog = prog
	prev.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(prev)
	await snap("skill_tree_v2_grid_preview.png")
	layer.queue_free()
	for i in 3:
		await process_frame
	# 3) run-pick offer (milestone round 5)
	rs.rng.seed = 11
	prog.skill_ranks.merge({"mk_legend": 1, "lg_black": 1, "lg_wide": 1})
	prog._recompute_spent()
	m.player.apply_stats()
	rs.refresh_allowances()
	m.player.points = 1800
	m.current_round = 5
	rs.add_card("c_deep_pockets")
	rs.open_offer(5)
	await snap("run_pick_offer_r5_milestone.png")
	rs.skip()
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	quit()


class Preview extends Control:
	var prog
	const CELL := Vector2(112, 96)
	const ORIGIN := Vector2(70, 120)
	const TILE := Vector2(92, 58)

	func _ready() -> void:
		queue_redraw()

	func _pos(n: Dictionary) -> Vector2:
		return ORIGIN + Vector2(float(n.x) * CELL.x, float(n.y) * CELL.y)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.07, 0.07, 0.08))
		var f := ThemeDB.fallback_font
		draw_string(f, Vector2(24, 40), "BACKEND LAYOUT PREVIEW - data/skill_tree.json v2 x/y grid (not the UI; Gooey owns the menu)", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.9, 0.9, 0.85))
		draw_string(f, Vector2(24, 64), "solid = requires (all-of)   dashed = requires_any   orange ring = owned   OR = choice_group   K = keystone group   rows 4/5 at x 4-6 = class strips (one active)", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.7, 0.7, 0.65))
		var colors := {}
		for b in prog.branches():
			var c: Array = b.get("color", [0.6, 0.6, 0.6])
			colors[b.id] = Color(c[0], c[1], c[2])
			var bx := ORIGIN.x + float(b.x) * CELL.x
			var by := ORIGIN.y - 30.0
			if str(b.get("class", "")) != "":
				by = ORIGIN.y + (4.0 if b.id == "soldier" else 5.0) * CELL.y + TILE.y + 15.0
				bx = ORIGIN.x + float(b.x) * CELL.x
			draw_string(f, Vector2(bx, by), str(b.name).to_upper() + ("  (" + str(b["class"]) + ")" if str(b.get("class", "")) != "" else ""), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, colors[b.id])
		for id in prog.all_node_ids():
			var n: Dictionary = prog.get_skill(id)
			var to := _pos(n) + TILE * 0.5
			for r in n.get("requires", []):
				draw_line(_pos(prog.get_skill(r)) + TILE * 0.5, to, Color(0.55, 0.55, 0.5, 0.8), 2.0)
			for r in n.get("requires_any", []):
				draw_dashed_line(_pos(prog.get_skill(r)) + TILE * 0.5, to, Color(0.55, 0.55, 0.5, 0.8), 2.0, 6.0)
		for id in prog.all_node_ids():
			var n: Dictionary = prog.get_skill(id)
			var p := _pos(n)
			var col: Color = colors.get(n.branch, Color.GRAY)
			var st: String = prog.state(id)
			var fill := Color(0.13, 0.13, 0.14)
			if st == "locked" or st == "excluded":
				fill = Color(0.1, 0.1, 0.1)
			draw_rect(Rect2(p, TILE), fill)
			draw_rect(Rect2(p, TILE), col if st != "locked" else col.darkened(0.5), false, 3.0 if n.type in ["keystone", "capstone"] else 1.5)
			if prog.rank(id) > 0:
				draw_rect(Rect2(p - Vector2(3, 3), TILE + Vector2(6, 6)), Color(1.0, 0.6, 0.2), false, 2.0)
			draw_string(f, p + Vector2(5, 16), str(n.name), HORIZONTAL_ALIGNMENT_LEFT, TILE.x - 8, 11, Color(0.92, 0.92, 0.88))
			draw_string(f, p + Vector2(5, 32), "%s  %d/%d" % [n.type, prog.rank(id), int(n.ranks)], HORIZONTAL_ALIGNMENT_LEFT, TILE.x - 8, 10, Color(0.7, 0.7, 0.65))
			var tag := ""
			if str(n.choice_group) == "keystone":
				tag = "K"
			elif str(n.choice_group) != "":
				tag = "OR"
			draw_string(f, p + Vector2(5, 50), "%s  %s" % [st, tag], HORIZONTAL_ALIGNMENT_LEFT, TILE.x - 8, 10, col)
