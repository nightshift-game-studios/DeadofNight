extends SceneTree
## Gallspitter line-of-sight + projectile / puddle collision test (Skillz, playtest 2026-10-22 #11: "spitters shoot through walls").
##   godot --headless --path . -s res://tests/gallspitter_los_test.gd
## On the synthetic AI course (tests/ai_nav_course.tscn); the walls / props are layer-1 StaticBody3Ds added at runtime in the
## open NE corner (no navmesh rebake needed: LOS and projectiles only look at physics).
##   start gating      blocked LOS -> no wind-up (blocked_starts), it repositions (moves, never spits through the wall); clear LOS -> spits
##   release re-check  LOS lost during the 0.7 s wind-up -> nothing is fired (blocked_releases), no projectile exists
##   projectile        a glob stops at a wall / a prop and its puddle lies on the near side (never behind it); a player hugging
##                     the far side is not hit through it and is not hurt / slowed by the puddle next to the wall; a ceiling hit
##                     drips to the floor below (not onto the roof); control: same shot without the wall hits
## Exit code = number of failures.

const ZOMBIE_MAIN := "res://scenes/main.tscn"
const COURSE_SCENE := "res://tests/ai_nav_course.tscn"
const PS := preload("res://scripts/combat/player_status.gd")

var _passes := 0
var _fails := 0
var main: Node
var pl: CharacterBody3D
var G: GDScript
var TP: GDScript
var _walls: Array = []


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func secs(t: float) -> int:
	return int(ceil(t * 60.0))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	TP = load("res://scripts/projectiles/thrown_projectile.gd")
	G = load("res://scripts/enemies/variants/gallspitter.gd")
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_gallspitter_los_test.cfg"
	progress.reset_skills()
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 16
	main = load(ZOMBIE_MAIN).instantiate()
	main.map_scene = load(COURSE_SCENE)
	root.add_child(main)
	current_scene = main
	await wait(3)
	main._break_timer = 1.0e9
	main.field_cards_enabled = false
	await _wait_bake(main.nav_region)
	Engine.time_scale = 4.0
	pl = main.player
	pl.set("invulnerable_t", 0.0)
	await _gating_checks()
	await _release_checks()
	await _projectile_checks()
	await _clear()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("gallspitter_los_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


func _wait_bake(region: NavigationRegion3D, max_frames: int = 1200) -> bool:
	for i in max_frames:
		var m := region.get_navigation_map()
		if not region.is_baking() and m.is_valid() and NavigationServer3D.map_get_iteration_id(m) > 0 \
				and region.navigation_mesh and region.navigation_mesh.get_polygon_count() > 0:
			await wait(3)
			return true
		await physics_frame
	return false


# ------------------------------------------------------------------ helpers

func _spawn(pos: Vector3) -> Node:
	var z = main.make_zombie({"kind": "zombie", "vid": "gallspitter", "health": 100, "speed": 3.2, "damage": 10})
	main.zombies_root.add_child(z)
	z.global_position = pos
	return z


## A layer-1 solid (wall / prop / ceiling) the physics world sees at once.
func _solid(pos: Vector3, size: Vector3, nm: String = "TestWall") -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = nm
	b.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	b.add_child(cs)
	main.add_child(b)
	b.global_position = pos
	_walls.append(b)
	return b


func _drop_solids() -> void:
	for w in _walls:
		if is_instance_valid(w):
			w.queue_free()
	_walls.clear()


func _clear() -> void:
	for z in get_nodes_in_group("enemies"):
		z.queue_free()
	for n in get_nodes_in_group("thrown_projectiles") + get_nodes_in_group("gall_puddles"):
		n.queue_free()
	_drop_solids()
	G.reset_camping()
	PS.clear(pl)
	await wait(3)


func _place_player(p: Vector3) -> void:
	pl.set_physics_process(false)
	pl.global_position = p
	pl.velocity = Vector3.ZERO
	pl.health = pl.max_health
	pl.dead = false
	pl.set("invulnerable_t", 0.0)


func _spawn_glob(from: Vector3, aim: Vector3) -> Node:
	return TP.spawn({"type_id": &"bile_glob", "variant": &"", "rarity": 0, "pos": from, "vel": TP.lob_velocity(from, aim), "owner_id": 0, "seed": 7})


# ------------------------------------------------------------------ start gating

func _gating_checks() -> void:
	# blocked line of sight: 16 m apart (inside the 8-22 m band), a 5 m tall wall in between
	await _clear()
	var ppos := Vector3(28, 0.1, -32)
	_place_player(ppos)
	_solid(Vector3(28, 2.5, -24), Vector3(30, 5, 0.6))
	await wait(2)
	var z = _spawn(Vector3(28, 0.1, -16))
	var st := {"started": 0, "wall_side_spit": 0}
	z.spit_started.connect(func(_s, _t): st.started += 1)
	z.spit_released.connect(func(s, _p, _i): if s.global_position.z > -23.0: st.wall_side_spit += 1)
	var p0: Vector3 = z.global_position
	for i in secs(2.2): # first_spit_delay is 1 s: an unchecked spitter would have started a wind-up by now
		await physics_frame
		pl.global_position = ppos
	check(st.started == 0 and z.spits == 0, "wall between spitter and target: no wind-up in 2.2 s (started %d, spat %d)" % [st.started, z.spits])
	var moved: float = Vector2(z.global_position.x - p0.x, z.global_position.z - p0.z).length()
	check(moved > 0.8 and z.mode_name() in ["move", "approach", "retreat"], "it repositions instead: mode %s, moved %.1f m" % [z.mode_name(), moved])
	check(z.blocked_starts >= 0, "blocked_starts counter exists (%d)" % z.blocked_starts)
	# 14 s more: every spit that does happen leaves from a spot that really sees the target (it walked around the wall)
	var spits_ok := true
	var rel := [0]
	z.spit_released.connect(func(s, _p, info):
		rel[0] += 1
		var q := PhysicsRayQueryParameters3D.create(info.from, info.target.global_position + Vector3(0, 1.2, 0), 1)
		spits_ok = spits_ok and s.get_world_3d().direct_space_state.intersect_ray(q).is_empty())
	for i in secs(14.0):
		await physics_frame
		pl.global_position = ppos
	check(spits_ok and st.wall_side_spit == 0, "over 16 s it never spits from the blocked side (%d spits, all with a clear ray)" % rel[0])
	# clear line of sight: spits
	await _clear()
	_place_player(ppos)
	await wait(2)
	z = _spawn(Vector3(28, 0.1, -16))
	var cl := {"started": 0}
	z.spit_started.connect(func(_s, _t): cl.started += 1)
	for i in secs(4.0):
		await physics_frame
		pl.global_position = ppos
	check(cl.started >= 1 and z.spits >= 1, "clear line of sight: it winds up and spits (%d started, %d spat)" % [cl.started, z.spits])
	await _clear()


# ------------------------------------------------------------------ release re-check

func _release_checks() -> void:
	await _clear()
	var ppos := Vector3(28, 0.1, -32)
	_place_player(ppos)
	await wait(2)
	var z = _spawn(Vector3(28, 0.1, -16))
	var n_proj0: int = TP.spawned_total
	var armed := false
	for i in secs(5.0): # wait for a wind-up that started with a clear shot
		await physics_frame
		pl.global_position = ppos
		if z.mode_name() == "spit" and z._spit_t >= 0.1 and not z._released:
			armed = true
			break
	check(armed, "wind-up started with a clear line of sight")
	if not armed:
		await _clear()
		return
	var wall := _solid(Vector3(28, 2.5, -22), Vector3(30, 5, 0.6)) # cover appears mid-wind-up
	var spits0: int = z.spits
	for i in secs(1.0):
		await physics_frame
		pl.global_position = ppos
	check(z.blocked_releases >= 1 and z.spits == spits0 and TP.spawned_total == n_proj0, "line of sight lost before the release: nothing fired (blocked_releases %d, projectiles spawned %d)" % [z.blocked_releases, TP.spawned_total - n_proj0])
	check(z.mode_name() != "spit" and get_nodes_in_group("thrown_projectiles").is_empty(), "back out of the spit (mode %s), no glob in the world" % z.mode_name())
	wall.queue_free()
	await _clear()


# ------------------------------------------------------------------ projectile / puddle collision

func _shot(from: Vector3, aim: Vector3, hold_player: Vector3 = Vector3.INF) -> Dictionary:
	var g = _spawn_glob(from, aim)
	var res := {"hit": null, "pos": Vector3.INF, "puddle": null, "g": g}
	g.impacted.connect(func(pp, w, hp): res.hit = hp; res.pos = w; res.puddle = pp.hazard)
	for i in secs(3.0):
		await physics_frame
		if hold_player != Vector3.INF:
			pl.global_position = hold_player
		if res.pos != Vector3.INF:
			break
	return res


func _projectile_checks() -> void:
	var from := Vector3(28, 1.5, -16)
	var far := Vector3(28, 0.5, -32)
	# wall: stops on the near face (z -23.7), the puddle lies on the near side, never behind it
	await _clear()
	_place_player(Vector3(30, 0.1, -10)) # out of the way
	_solid(Vector3(28, 2.5, -24), Vector3(30, 5, 0.6))
	await wait(2)
	var r := await _shot(from, far)
	check(r.pos != Vector3.INF and r.pos.z > -23.9 and r.pos.z < -22.0 and r.hit == null, "glob stops on the near face of a wall (impact z %.2f, wall z -23.7)" % r.pos.z)
	var pd = r.puddle
	check(pd != null and is_instance_valid(pd) and pd.global_position.z > -23.9 and pd.global_position.y < 0.5, "its puddle lies on the near side, snapped to the floor (%s)" % [pd.global_position.snapped(Vector3.ONE * 0.01) if pd else "none"])
	await _clear()
	# a prop (a tall crate on the glob's arc): same
	_place_player(Vector3(30, 0.1, -10))
	_solid(Vector3(28, 2.25, -24), Vector3(3, 4.5, 3), "TestCrate")
	await wait(2)
	r = await _shot(from, far)
	check(r.pos != Vector3.INF and r.pos.z > -22.4 and r.hit == null and r.puddle != null and r.puddle.global_position.z > -22.4, "glob stops on a prop (a crate): impact z %.2f, puddle %s" % [r.pos.z, r.puddle.global_position.snapped(Vector3.ONE * 0.01) if r.puddle else "none"])
	await _clear()
	# a player hugging the far side of the wall: not hit through it, and the puddle beside the wall can't hurt or slow them
	var behind := Vector3(28, 0.1, -24.9)
	_place_player(behind)
	_solid(Vector3(28, 2.5, -24), Vector3(30, 5, 0.6))
	await wait(2)
	var hp0: int = pl.health
	r = await _shot(from, far, behind)
	check(r.hit == null and pl.health == hp0, "player 0.6 m behind the wall: not hit through it (%d -> %d)" % [hp0, pl.health])
	for i in secs(4.5):
		await physics_frame
		pl.global_position = behind
	check(pl.health == hp0 and is_equal_approx(PS.move_mult(pl), 1.0), "and the puddle next to the wall does not hurt or slow them (%d HP, speed x%.2f)" % [pl.health, PS.move_mult(pl)])
	await _clear()
	# control: same player position, no wall -> the glob does hit
	_place_player(behind)
	await wait(2)
	hp0 = pl.health
	r = await _shot(from, behind + Vector3(0, 0.5, 0), behind)
	check(r.hit == pl and pl.health < hp0, "control (no wall): the same glob hits the player (%d -> %d)" % [hp0, pl.health])
	await _clear()
	# a ceiling: thrown straight up, the puddle drips to the floor below, not onto the roof
	_place_player(Vector3(30, 0.1, -10))
	_solid(Vector3(28, 3.5, -24), Vector3(12, 1, 12), "TestCeiling") # underside y 3.0, roof y 4.0
	await wait(2)
	var up = TP.spawn({"type_id": &"bile_glob", "variant": &"", "rarity": 0, "pos": Vector3(28, 1.5, -24), "vel": Vector3(0, 9, 0), "owner_id": 0, "seed": 7})
	var res := {"pos": Vector3.INF, "puddle": null}
	up.impacted.connect(func(pp, w, _h): res.pos = w; res.puddle = pp.hazard)
	for i in secs(1.5):
		await physics_frame
		if res.pos != Vector3.INF:
			break
	check(res.pos != Vector3.INF and res.pos.y < 3.1 and res.puddle != null and res.puddle.global_position.y < 0.5,
		"hit on a ceiling underside (y %.2f): the puddle is on the floor below (y %s), not on the roof" % [res.pos.y, str(snappedf(res.puddle.global_position.y, 0.01)) if res.puddle else "none"])
	await _clear()
