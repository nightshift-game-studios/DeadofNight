extends SceneTree
## Mouse-look / menu input regression test:  godot --headless --path . -s res://tests/input_test.gd
## Bug (build 2): a crosshair ColorRect at the exact screen centre kept the default MOUSE_FILTER_STOP. With the
## mouse captured every InputEventMouseMotion is reported at the centre, so the GUI ate it and player.gd's
## _unhandled_input never turned the camera. Checks, at round 0, after every menu (skill tree, map picker,
## character screen, Field Card offer) and mid-round:
##  - no visible Control that takes the mouse covers the screen centre while playing,
##  - a motion event at the centre reaches _unhandled_input and turns the player,
##  - menus pause the game (zombies and round timers frozen) and closing restores CAPTURED + unpauses.
## Headless has no real mouse capture, so the capture and camera-turn checks are skipped there (the centre-blocker
## scan still catches this bug). Run under a display (e.g. xvfb-run ... --rendering-driver opengl3,
## no --headless) for the full end-to-end path. Exit code = number of failures.

var _fails := 0
var _passes := 0
var _capture_works := false
var _probe: Probe


class Probe extends Node:
	var motion := 0
	func _unhandled_input(e: InputEvent) -> void:
		if e is InputEventMouseMotion:
			motion += 1


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


func _centre() -> Vector2:
	return root.get_visible_rect().size / 2.0


## Every visible Control (outside a hidden CanvasLayer) that would take a mouse event at the screen centre.
func _blockers() -> Array:
	var out := []
	_scan(root, _centre(), out)
	return out


func _scan(n: Node, c: Vector2, out: Array) -> void:
	if n is CanvasLayer and not (n as CanvasLayer).visible:
		return
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is Control:
		var ctl := n as Control
		if ctl.mouse_filter != Control.MOUSE_FILTER_IGNORE and ctl.is_visible_in_tree() and ctl.get_global_rect().has_point(c):
			out.append(str(ctl.get_path()) + " (" + ctl.get_class() + ")")
	for ch in n.get_children():
		_scan(ch, c, out)


## Pushes a mouse motion at the screen centre (where a captured mouse reports it) and checks it is handled.
func _look_check(main, label: String) -> void:
	var player = main.get_node("Player")
	var b := _blockers()
	check(b.is_empty(), "%s: nothing at the screen centre takes the mouse %s" % [label, "" if b.is_empty() else str(b)])
	check(not paused, "%s: game is not paused" % label)
	if _capture_works:
		check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "%s: mouse is captured" % label)
	else:
		print("SKIP  %s: mouse capture (not available headless)" % label)
	var y0: float = player.rotation.y
	var p0: float = player.head.rotation.x
	var n0 := _probe.motion
	var ev := InputEventMouseMotion.new()
	ev.position = _centre()
	ev.global_position = _centre()
	ev.relative = Vector2(30, 12)
	ev.screen_relative = Vector2(30, 12)
	root.push_input(ev)
	await process_frame
	check(_probe.motion > n0, "%s: mouse motion reaches _unhandled_input" % label)
	if _capture_works:
		check(not is_equal_approx(player.rotation.y, y0) and not is_equal_approx(player.head.rotation.x, p0),
			"%s: mouse motion turns the player (yaw %+.3f, pitch %+.3f)" % [label, player.rotation.y - y0, player.head.rotation.x - p0])
	player.rotation.y = y0
	player.head.rotation.x = p0


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	root.push_input(ev)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	root.push_input(up)


func _run() -> void:
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_input_test.cfg" # never touch the real save
	progress.reset_skills()
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	var main = current_scene
	main._break_timer = 9999.0
	_probe = Probe.new()
	root.add_child(_probe)
	await wait(5)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await process_frame
	_capture_works = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	print("INFO  mouse capture %s, viewport %s" % ["available" if _capture_works else "unavailable (headless)", root.get_visible_rect().size])

	# ---------------------------------------------------------------- round 0
	await _look_check(main, "round 0 start")
	var hud_ignores := true
	for c in main.hud.find_children("*", "Control", true, false):
		hud_ignores = hud_ignores and (c as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE
	check(hud_ignores, "every HUD Control ignores the mouse")
	main.hud.add_loot(main.get_node("Player").inventory.equipped.primary) # rows added later
	await process_frame
	var late_ok := true
	for c in main.hud.find_children("*", "Control", true, false):
		late_ok = late_ok and (c as Control).mouse_filter == Control.MOUSE_FILTER_IGNORE
	check(late_ok, "HUD Controls added later (loot feed) ignore the mouse too")

	# skill tree (K)
	_press("skill_tree")
	await wait(2)
	check(main.skill_menu.visible and paused and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED, "K opens the skill tree (paused, mouse free)")
	_press("skill_tree")
	await wait(2)
	check(not main.skill_menu.visible, "K again closes the skill tree")
	await _look_check(main, "after skill tree")

	# map picker (M), closed with Esc
	var mp = main.get("map_picker") # null on builds without the map picker
	if mp:
		_press("map_next")
		await wait(2)
		check(mp.visible and paused, "M opens the map picker (paused)")
		var esc := InputEventKey.new()
		esc.physical_keycode = KEY_ESCAPE
		esc.keycode = KEY_ESCAPE
		esc.pressed = true
		root.push_input(esc)
		await wait(2)
		check(not mp.visible and current_scene == main, "Esc closes the map picker (same match)")
		await _look_check(main, "after map picker")

	# character screen (Tab) at round 0
	_press("inventory")
	await wait(2)
	check(main.character_screen.visible and paused, "Tab opens the character screen (paused)")
	_press("inventory")
	await wait(2)
	check(not main.character_screen.visible, "Tab again closes the character screen")
	await _look_check(main, "after character screen (round 0)")

	# ---------------------------------------------------------------- mid-round: inventory pauses the game
	main._start_round(1)
	main._spawn_timer = 0.0
	for i in 600:
		if main.zombies_root.get_child_count() >= 2:
			break
		await physics_frame
	await wait(30) # let them start walking
	var zs: Array = main.zombies_root.get_children().filter(func(z): return z is Node3D)
	check(zs.size() >= 1, "round 1 spawned zombies (%d)" % zs.size())
	await _look_check(main, "round 1 (zombies alive)")
	var moving := false
	var before := zs.map(func(z): return z.global_position)
	await wait(20)
	for i in zs.size():
		moving = moving or zs[i].global_position.distance_to(before[i]) > 0.01
	check(moving, "zombies move while the game runs")
	_press("inventory")
	await wait(2)
	check(main.character_screen.visible and paused, "Tab mid-round opens the character screen and pauses")
	check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "character screen frees the mouse")
	var pos := zs.map(func(z): return z.global_position)
	var spawn_t: float = main._spawn_timer
	var to_spawn: int = main._to_spawn
	var p_pos: Vector3 = main.get_node("Player").global_position
	await wait(45)
	var frozen := true
	for i in zs.size():
		frozen = frozen and is_instance_valid(zs[i]) and zs[i].global_position.distance_to(pos[i]) < 0.0001
	check(frozen, "zombies stop moving while the character screen is open")
	check(is_equal_approx(main._spawn_timer, spawn_t) and main._to_spawn == to_spawn, "spawn timer / wave stop while it is open")
	check(main.get_node("Player").global_position.distance_to(p_pos) < 0.0001, "player is frozen while it is open")
	_press("inventory")
	await wait(2)
	check(not main.character_screen.visible and not paused, "Tab closes it and unpauses")
	await _look_check(main, "after character screen (mid-round)")
	await wait(20)
	moving = false
	for i in zs.size():
		moving = moving or (is_instance_valid(zs[i]) and zs[i].global_position.distance_to(pos[i]) > 0.01)
	check(moving, "zombies move again after closing it")

	# ---------------------------------------------------------------- round-end Field Card pick
	for z in main.zombies_root.get_children():
		z.queue_free()
	main._alive = 0
	main._to_spawn = 0
	var rs = root.get_node("RunState")
	main._offer_pending = true
	rs.open_offer(1)
	await wait(2)
	check(main.run_pick_menu.visible and paused, "Field Card offer opens and pauses")
	check(main.run_pick_menu.take(0) or rs.skip() >= 0, "pick a Field Card")
	await wait(2)
	check(not main.run_pick_menu.visible and not paused, "offer closes and unpauses")
	main._break_timer = 9999.0
	await _look_check(main, "after round-end card pick")

	progress.reset_skills()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://progress_input_test.cfg"))
	print("input_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
