extends SceneTree
## Zombie navigation course test (Skillz, DESIGN §18 / MAIN_HOOKS §17).
##   godot --headless --path . -s res://tests/ai_nav_test.gd [-- --skip-ranged] [-- --baseline] [-- --maps=arena,rustwell_foundry] [-- --realtime]
## Runs zombies of every variant (walker / worker / soldier / crawler / bloated / riot / echo add) and a boss through ramp,
## stair and obstacle courses on Arena, Rustwell Foundry, Drowned Cannery and the synthetic course
## (tests/ai_nav_course.tscn). The player stands at each course's goal (invulnerable); zombies start at the course's starts.
## A zombie fails if it doesn't get within REACH_FLAT m (flat, |dy| <= REACH_DY; ranged kinds: their own attack envelope, 0.8 x attack_range flat and |dy| < attack_max_dy; ranged bosses: their stop distance) of the player inside the time budget, or if it
## ever stands still (< STILL_EPS m of movement) for more than STILL_MAX s while it wants to move (boss telegraphs, crawler
## grabs excluded). A zombie that arrives is removed 0.5 s later (the player kills it), so the goal never jams. Prints per-map reach rates and the worst still time; "--baseline" only measures.
## Sim speed: physics runs at 240 Hz with time_scale 4 (same 1/60 s physics step as the game, 4x wall clock).
## Exit code = number of failures.

const ZOMBIE := preload("res://scenes/enemy.tscn")
const MAIN := "res://scenes/main.tscn"
const BossCatalogScr := preload("res://scripts/enemies/boss_catalog.gd")
const NAV_SCRIPT := "res://scripts/enemies/ai/zombie_nav.gd"
const COURSE_SCENE := "res://tests/ai_nav_course.tscn"
const REACH_FLAT := 2.0
const REACH_DY := 1.2
const STILL_EPS := 0.3
const STILL_MAX := 3.0
const BASE_SPEED := 3.0
const STEP := 1.0 / 60.0

const KINDS := ["city", "worker", "soldier", "crawler", "bloated", "riot", "echo"]

## map -> [{name, goal, starts[], boss?}]. Goals sit on top of ramps / stairs / behind obstacles; starts are on the ground.
const COURSES := {
	"arena": [
		{"name": "platform_ramp", "goal": Vector3(12.0, 1.6, -12.5), "starts": [Vector3(-17, 0.1, 17), Vector3(17, 0.1, 17), Vector3(0, 0.1, -17), Vector3(-17, 0.1, -17)], "boss": "bellwether"},
		{"name": "behind_cover", "goal": Vector3(0.0, 0.1, -12.0), "starts": [Vector3(0.5, 0.1, 3.5), Vector3(-9, 0.1, 9), Vector3(6, 0.1, 9)], "boss": "lantern_stalker"},
		{"name": "ruin_rubble", "goal": Vector3(3.0, 0.1, 9.0), "starts": [Vector3(3.0, 0.1, 17.0), Vector3(-3, 0.1, 17.5), Vector3(9, 0.1, 17.5)], "boss": "choir_host"},
	],
	"rustwell_foundry": [
		{"name": "c2_roof_ramp", "goal": Vector3(2.0, 2.7, 26.6), "starts": [Vector3(8, 0.1, 34.5), Vector3(-14, 0.1, 34.5), Vector3(14, 0.1, 10), Vector3(0, 0.1, 12)], "boss": "bellwether"},
		{"name": "dock_ramps", "goal": Vector3(-42.5, 1.1, 20.0), "starts": [Vector3(-33, 0.1, 34.5), Vector3(-25, 0.1, 15), Vector3(-34, 0.1, 6)]},
		{"name": "bx2_roof_ramp", "goal": Vector3(-39.5, 3.9, 26.0), "starts": [Vector3(-25, 0.1, 32), Vector3(-34, 0.1, 18)]},
		{"name": "footbridge_stair", "goal": Vector3(-30.0, 4.3, 6.7), "starts": [Vector3(-10, 0.1, 14), Vector3(-25, 0.1, 30)]},
		{"name": "foundry_pit", "goal": Vector3(-26.0, -0.9, -8.5), "starts": [Vector3(-42.6, 0.1, -16), Vector3(-24, 0.1, -28.5)], "boss": "bellwether"},
		{"name": "foundry_catwalk", "goal": Vector3(-30.0, 4.3, -11.7), "starts": [Vector3(-24, 0.1, -28.5), Vector3(-28, 0.1, 0)]},
		{"name": "mezzanine_stair", "goal": Vector3(0.0, 3.7, -27.5), "starts": [Vector3(-8, 0.1, -28.5), Vector3(0, 0.1, 5)]},
		{"name": "pump_roof_stair", "goal": Vector3(37.0, 4.1, -23.0), "starts": [Vector3(22, 0.1, -28.5), Vector3(25, 0.1, 0)]},
		{"name": "pipe_rack_stair", "goal": Vector3(41.2, 3.1, 0.0), "starts": [Vector3(42.5, 0.1, 30), Vector3(30, 0.1, 25)]},
		# Mapz nav audit checkpoints (FINDINGS.md, 2026-10-19): spawn near the spot, path through it, no stall > 3 s.
		{"name": "cp_rackbridgew_dither", "spot": "under RackBridgeW, around RackR2 (-5.8, 0, -23)", "vias": [Vector3(-5.8, 0, -23)], "via_tol": 1.5,
			"goal": Vector3(0.5, 0.1, -19.0), "starts": [Vector3(-8.4, 0.1, -19.0), Vector3(-8.4, 0.1, -17.0)]},
		{"name": "cp_bx1_roof", "spot": "BoxcarBX1 roof (-39.3, 3.8, 16.9) -> PlankBridgeBX1", "vias": [Vector3(-39.3, 3.8, 16.9), Vector3(-39.5, 4.0, 10.7), Vector3(-39.0, 4.0, 9.6)], "via_tol": 1.5,
			"goal": Vector3(-30.0, 4.3, 6.7), "starts": [Vector3(-39.5, 4.0, 26.0), Vector3(-39.5, 4.0, 24.5)]},
		{"name": "cp_plankbridge_bx1", "spot": "PlankBridgeBX1 (-39.0, 4.0, 9.6) / (-39.5, 4.0, 10.7) -> BX1 roof", "vias": [Vector3(-39.0, 4.0, 9.6), Vector3(-39.5, 4.0, 10.7), Vector3(-39.3, 3.8, 16.9)], "via_tol": 1.5,
			"goal": Vector3(-39.4, 3.9, 18.5), "starts": [Vector3(-30.0, 4.4, 6.7), Vector3(-31.5, 4.4, 6.7)]},
		{"name": "cp_mezzanine_foot", "spot": "StairMezzanine foot corner (2, 0, -1)", "vias": [Vector3(2.0, 0, -1.0)], "via_tol": 2.0,
			"goal": Vector3(14.5, 3.7, -5.0), "starts": [Vector3(-3.0, 0.1, 3.0), Vector3(-1.0, 0.1, 5.0)]},
		{"name": "cp_d4_doorway", "spot": "D4 Furnace Passage doorway (-16, 0, -20)", "vias": [Vector3(-16.0, 0, -20.0)], "via_tol": 1.5,
			"goal": Vector3(-9.0, 0.1, -20.0), "starts": [Vector3(-22.0, 0.1, -20.0), Vector3(-22.0, 0.1, -18.0), Vector3(-22.0, 0.1, -22.0)]},
		{"name": "cp_d6_doorway", "spot": "D6 Fence Breach doorway (16, 0, 20)", "vias": [Vector3(16.0, 0, 20.0)], "via_tol": 1.5,
			"goal": Vector3(23.0, 0.1, 20.0), "starts": [Vector3(10.0, 0.1, 20.0), Vector3(10.0, 0.1, 18.0), Vector3(10.0, 0.1, 22.0)]},
		# Rack aisle R1/R2 north mouth (Mapz: (-8.4, 0, -22), corner pads at (-10, -22) on R1 and (-6.8, -22) on R2): one route
		# turns west round the R1 pad, one east round the R2 pad; each must pass the mouth and its pad.
		{"name": "cp_rack_mouth_pad_w", "spot": "R1/R2 aisle mouth (-8.4, 0, -22) + R1 pad (-10, 0, -22)", "vias": [Vector3(-8.4, 0, -22.0), Vector3(-10.0, 0, -22.0)], "via_tol": 1.5,
			"goal": Vector3(-14.5, 0.1, -23.5), "starts": [Vector3(-8.4, 0.1, -12.0), Vector3(-8.4, 0.1, -14.0)]},
		{"name": "cp_rack_mouth_pad_e", "spot": "R1/R2 aisle mouth (-8.4, 0, -22) + R2 pad (-6.8, 0, -22)", "vias": [Vector3(-8.4, 0, -22.0), Vector3(-6.8, 0, -22.0)], "via_tol": 1.5,
			"goal": Vector3(-4.0, 0.1, -23.6), "starts": [Vector3(-8.4, 0.1, -12.0), Vector3(-8.4, 0.1, -14.0)]},
		# Mapz 2026-10-20 reach table (their maps, no carve): worst stall on the map, the c2 roof ramp echo at (-10.9, 0, 23.1),
		# 1.8 s - south of RampC2Roof's foot (-12, 0, 27.65); route from the yard past the spot, up the ramp onto ContainerC2.
		{"name": "cp_c2roof_ramp_echo", "spot": "c2 roof ramp approach, Mapz worst echo stall (-10.9, 0, 23.1)", "vias": [Vector3(-10.9, 0, 23.1)], "via_tol": 2.0,
			"goal": Vector3(2.0, 2.7, 26.6), "starts": [Vector3(-10.9, 0.1, 18.5), Vector3(-8.5, 0.1, 19.0)]},
		{"name": "cp_hoppercar_nw", "spot": "HopperCar NW corner (-32, 0, 24)", "vias": [Vector3(-32.4, 0, 24.4)], "via_tol": 1.5,
			"goal": Vector3(-27.0, 0.1, 27.5), "starts": [Vector3(-34.5, 0.1, 16.0), Vector3(-34.5, 0.1, 18.0)]},
	],
	"drowned_cannery": [
		# Mapz (playtest #17, replaces the old hard map's course): ramp and deck goals taken from the map's layout_data
		# (RAMPS / DECKS); starts are spawn markers or plain ground in the same area. All doors are open in this test.
		{"name": "crane_deck", "goal": Vector3(0.0, 4.1, 0.0), "starts": [Vector3(28.5, 0.1, 12.5), Vector3(-28.5, 0.1, 12.5), Vector3(12.0, 0.1, -10.5)], "boss": "bellwether"},
		{"name": "net_gantry", "goal": Vector3(-38.0, 3.7, 26.5), "starts": [Vector3(-20.5, 0.1, 16.0), Vector3(-20.0, 0.1, 30.0)]},
		{"name": "ice_mezzanine", "goal": Vector3(51.0, 3.7, 28.0), "starts": [Vector3(20.5, 0.1, 16.0), Vector3(30.0, 0.1, 30.0)]},
		{"name": "launch_gantry", "goal": Vector3(52.5, 3.7, 2.0), "starts": [Vector3(32.0, 0.1, 12.5), Vector3(36.0, 0.1, 2.0)], "boss": "lantern_stalker"},
		{"name": "slip_hut_ramp", "goal": Vector3(36.0, 2.1, -7.25), "starts": [Vector3(32.0, 0.1, 12.5), Vector3(46.0, 0.1, -1.0)]},
		{"name": "pit_floor", "goal": Vector3(-4.0, -0.9, -26.0), "starts": [Vector3(-20.5, 0.1, -38.5), Vector3(12.0, 0.1, -10.5)], "boss": "lantern_stalker"},
	],
	"ai_course": [
		{"name": "u_trap", "goal": Vector3(0.0, 0.1, -9.0), "starts": [Vector3(0.0, 0.1, -3.0), Vector3(-1.5, 0.1, -3.5), Vector3(1.5, 0.1, -3.5)], "boss": "bellwether"},
		{"name": "wedge_ramp", "goal": Vector3(20.0, 2.1, -16.0), "starts": [Vector3(20.0, 0.1, 6.0), Vector3(14.0, 0.1, 4.0)]},
		{"name": "step_ledges", "goal": Vector3(-20.0, 0.7, -14.0), "starts": [Vector3(-20.0, 0.1, 4.0), Vector3(-14.0, 0.1, 2.0)], "boss": "lantern_stalker"},
		{"name": "box_stairs", "goal": Vector3(-20.0, 1.6, 18.0), "starts": [Vector3(-8.0, 0.1, 8.0), Vector3(-14.0, 0.1, 6.0)]},
		{"name": "doorway_pillars", "goal": Vector3(18.0, 0.1, 22.0), "starts": [Vector3(4.0, 0.1, 6.0), Vector3(10.0, 0.1, 6.0)], "boss": "choir_host"},
		{"name": "steep_slope", "goal": Vector3(0.0, 2.6, 24.0), "starts": [Vector3(0.0, 0.1, 10.0), Vector3(-3.0, 0.1, 10.0)]},
	],
}

var _fails := 0
var _passes := 0
var baseline := false
var _stats := {} ## map -> {n, reached, worst_still, worst_where, nav_ok, nav_n}
var _records: Array = []
var _checkpoints: Array = []


## Closest flat distance from v to a polyline (segments with |dy| < 1.5 of v).
func _poly_dist(pts: PackedVector3Array, v: Vector3) -> float:
	var best := INF
	var q := Vector2(v.x, v.z)
	for i in range(1, pts.size()):
		var a := Vector2(pts[i - 1].x, pts[i - 1].z)
		var b := Vector2(pts[i].x, pts[i].z)
		var ab := b - a
		var t := clampf((q - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var y := lerpf(pts[i - 1].y, pts[i].y, t)
		if absf(y - v.y) < 1.5:
			best = minf(best, (a + ab * t).distance_to(q))
	return best


func check(cond: bool, what: String) -> void:
	if baseline and not cond:
		print("INFO  (baseline) " + what)
		return
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


func _arg(name: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a == "--" + name:
			return "1"
		if a.begins_with("--" + name + "="):
			return a.substr(name.length() + 3)
	return fallback


func _load_main(map_id: String) -> Node:
	var main = load(MAIN).instantiate()
	if map_id == "ai_course":
		main.map_scene = load(COURSE_SCENE)
	else:
		MapRegistry.select(map_id)
	root.add_child(main)
	current_scene = main
	await wait(3)
	main._break_timer = 1.0e9
	main.field_cards_enabled = false
	if main.map and main.map.has_method("open_all_doors"):
		main.map.open_all_doors()
	await wait(2)
	await _wait_bake(main.nav_region)
	return main


func _wait_bake(region: NavigationRegion3D, max_frames: int = 1200) -> bool:
	for i in max_frames:
		var m := region.get_navigation_map()
		if not region.is_baking() and m.is_valid() and NavigationServer3D.map_get_iteration_id(m) > 0 \
				and region.navigation_mesh and region.navigation_mesh.get_polygon_count() > 0:
			await wait(3)
			return true
		await physics_frame
	return false


func _spawn(main: Node, kind: String, pos: Vector3) -> Node3D:
	var z = ZOMBIE.instantiate()
	if BossCatalogScr.is_boss_id(kind):
		z.set_script(load(BossCatalogScr.script_path(kind)))
		z.setup(400, BASE_SPEED, 1)
		z.configure_boss(kind, 10, "easy")
	elif kind == "echo":
		z.setup(150, BASE_SPEED * 1.1, 1)
		z.set_meta("boss_echo", true)
		BossCatalogScr.apply_echo_model(z)
	else:
		ZombieVariants.apply_script(z, kind)
		z.setup(150, BASE_SPEED, 1)
		var sc := ZombieVariants.scene(kind)
		if sc:
			z.set_variant(kind, ZombieVariants.get_variant(kind), sc)
	z.set_meta("ai_kind", kind)
	main.zombies_root.add_child(z)
	z.global_position = pos
	return z


## True while the zombie is busy with something that isn't walking (boss telegraph, crawler grab, swing).
func _busy(z: Node) -> bool:
	if "phase" in z and int(z.get("phase")) != 0:
		return true
	if "grab_state" in z and str(z.get("grab_state")) != "":
		return true
	return false


func _nav_reach(nav_map: RID, from: Vector3, to: Vector3) -> Dictionary:
	var a := NavigationServer3D.map_get_closest_point(nav_map, from)
	var b := NavigationServer3D.map_get_closest_point(nav_map, to)
	var path := NavigationServer3D.map_get_path(nav_map, a, b, true)
	var ok := not path.is_empty() and path[path.size() - 1].distance_to(b) < 1.0 and b.distance_to(to) < 1.5
	var length := 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	return {"ok": ok, "len": length, "goal_off": b.distance_to(to), "start_off": a.distance_to(from),
		"end": path[path.size() - 1] if not path.is_empty() else Vector3.INF}


func _run_course(main: Node, map_id: String, c: Dictionary) -> void:
	var player: Node3D = main.player
	var goal: Vector3 = c.goal
	player.global_position = goal
	player.velocity = Vector3.ZERO
	player.set("invulnerable_t", 1.0e9)
	await wait(10)
	goal = player.global_position # where the player actually settled
	var nav_map: RID = main.nav_region.get_navigation_map()
	var st: Dictionary = _stats.get(map_id, {"n": 0, "reached": 0, "worst_still": 0.0, "worst_where": "", "nav_ok": 0, "nav_n": 0, "t": 0.0})
	var zs: Array = []
	var max_len := 0.0
	var kinds: Array = KINDS.duplicate()
	if c.has("boss"):
		kinds.append(c.boss)
	var i := 0
	for s in c.starts:
		var nr := _nav_reach(nav_map, s, goal)
		st.nav_n += 1
		if nr.ok:
			st.nav_ok += 1
		else:
			print("NAVGAP %s/%s start %s -> goal %s: path ends %s (goal %.2f m off mesh, start %.2f m off)" % [map_id, c.name, s, goal.snapped(Vector3.ONE * 0.01), nr.end, nr.goal_off, nr.start_off])
		max_len = maxf(max_len, nr.len if nr.ok else s.distance_to(goal) * 1.6)
		if c.has("vias"):
			var np := NavigationServer3D.map_get_path(nav_map, NavigationServer3D.map_get_closest_point(nav_map, s), NavigationServer3D.map_get_closest_point(nav_map, goal), true)
			for v in c.vias:
				var dv := _poly_dist(np, v)
				if dv > float(c.via_tol):
					print("INFO  %s/%s: nav route from %s passes %.1f m from spot %s" % [map_id, c.name, s, dv, v])
	for k in kinds:
		var s: Vector3 = c.starts[i % c.starts.size()]
		var off := Vector3((i % 3 - 1) * 0.9, 0.0, (int(i / 3) % 2) * 0.9)
		i += 1
		var z := _spawn(main, k, s + off)
		# Reach = REACH_FLAT, or the zombie's own stop distance for ranged ones (Lantern Stalker stops at 0.8 x 12 m).
		var reach := maxf(REACH_FLAT, float(z.attack_range) * 0.8 + 0.6)
		# Vertical reach: melee kinds stay strict (REACH_DY). Ranged kinds stop chasing once flat <= 0.8 x attack_range and
		# |dy| < attack_max_dy (enemy.gd _physics_process), so on a continuous ramp they legitimately park at a dy between
		# REACH_DY and attack_max_dy: that is inside their own attack envelope, count it as reached (read from the kind's config).
		var reach_dy := REACH_DY
		if float(z.attack_range) * 0.8 + 0.6 > REACH_FLAT:
			reach_dy = maxf(REACH_DY, float(z.attack_max_dy) - 0.01)
		var vd: Array = []
		for v in c.get("vias", []):
			vd.append(INF)
		zs.append({"z": z, "kind": k, "reach": reach, "reach_dy": reach_dy, "start": s, "anchor": s + off, "anchor_t": 0.0, "worst": 0.0, "reached_t": -1.0, "where": s, "vd": vd})
	var min_speed := BASE_SPEED * 0.7 * 0.85
	var budget := clampf(max_len / min_speed * 1.6 + 10.0, 20.0, 75.0)
	var t := 0.0
	var all_done := false
	while t < budget and not all_done:
		await physics_frame
		t += STEP
		all_done = true
		for r in zs:
			var z = r.z
			if not is_instance_valid(z):
				continue
			if r.reached_t >= 0.0:
				# The player "kills" a zombie 0.5 s after it arrives, so the goal never jams with a crowd.
				if t - r.reached_t > 0.5:
					r.end = z.global_position
					var zn = z.get("nav")
					if zn:
						r.nav_stats = {"susp": zn.suspends, "res": zn.resumes, "unstick": zn.unstick_count, "last": zn.last_action, "hops": zn.hops, "sweep": zn.sweep_blocks, "q": zn.path_queries}
					z.queue_free()
				continue
			all_done = false
			var p: Vector3 = z.global_position
			if _arg("trace-kind") == r.kind and int(t / STEP) % 15 == 0:
				var zn = z.get("nav")
				var near := ""
				for o in zs:
					if o != r and is_instance_valid(o.z) and o.z.global_position.distance_to(p) < 2.5:
						var on = o.z.get("nav")
						near += " %s d%.1f susp=%s ph=%s" % [o.kind, o.z.global_position.distance_to(p), on.suspended if on else "-", o.z.get("phase")]
				print("  TRACE t%.2f %s pos %s v %s lvl %d act %s wall %s cur %d/%d%s" % [t, r.kind, p.snapped(Vector3.ONE * 0.01), Vector3(z.velocity.x, 0, z.velocity.z).snapped(Vector3.ONE * 0.01), zn.stuck_level, zn.last_action, z.is_on_wall(), zn.cursor, zn.path.size(), near])
			for vi in r.vd.size():
				var v: Vector3 = c.vias[vi]
				if absf(p.y - v.y) < 1.5:
					r.vd[vi] = minf(r.vd[vi], Vector2(p.x - v.x, p.z - v.z).length())
			var flat := Vector2(p.x - goal.x, p.z - goal.z).length()
			if flat <= r.reach and absf(p.y - goal.y) <= r.reach_dy:
				r.reached_t = t
				continue
			if _busy(z) or p.distance_to(r.anchor) > STILL_EPS:
				r.anchor = p
				r.anchor_t = t
			elif t - r.anchor_t > r.worst:
				r.worst = t - r.anchor_t
				r.where = p
	var cp := {"n": 0, "reached": 0, "via": 0, "worst": 0.0, "where": ""}
	for r in zs:
		var z = r.z
		st.n += 1
		if c.has("vias"):
			cp.n += 1
			if r.reached_t >= 0.0:
				cp.reached += 1
			var via_ok := true
			for d in r.vd:
				via_ok = via_ok and d <= float(c.via_tol)
			if via_ok:
				cp.via += 1
			if r.worst > cp.worst:
				cp.worst = r.worst
				cp.where = "%s at %s" % [r.kind, (r.where as Vector3).snapped(Vector3.ONE * 0.1)]
			check(via_ok, "%s/%s: %s passed through the spot (closest %s m)" % [map_id, c.name, r.kind, str(r.vd.map(func(x): return snappedf(x, 0.1)))])
		var ok: bool = r.reached_t >= 0.0
		if ok:
			st.reached += 1
		if r.worst > st.worst_still:
			st.worst_still = r.worst
			st.worst_where = "%s/%s %s at %s" % [map_id, c.name, r.kind, (r.where as Vector3).snapped(Vector3.ONE * 0.1)]
		var endp: Vector3 = z.global_position if is_instance_valid(z) else r.get("end", Vector3.INF)
		var line := "%s/%s %-15s start %s  %s  still max %.1fs  end %s" % [map_id, c.name, r.kind, r.start,
			("reached %.1fs" % r.reached_t) if ok else "NOT REACHED", r.worst, endp.snapped(Vector3.ONE * 0.1)]
		if _arg("verbose") != "" and r.has("nav_stats"):
			line += "  " + str(r.nav_stats)
		_records.append(line)
		print("  " + line)
		check(ok and r.worst <= STILL_MAX, "%s/%s: %s reaches the player (%s, still %.1fs)" % [map_id, c.name, r.kind,
			("%.1fs" % r.reached_t) if ok else "not reached in %.0fs" % budget, r.worst])
		if is_instance_valid(z):
			z.queue_free()
	if c.has("vias"):
		var line := "CHECKPOINT %-24s %-60s reached %d/%d  through spot %d/%d  worst still %.1fs%s" % [c.name, c.spot, cp.reached, cp.n, cp.via, cp.n, cp.worst, (" (" + cp.where + ")") if cp.where != "" else ""]
		_checkpoints.append(map_id + " " + line)
		print(line)
	st.t += t
	_stats[map_id] = st
	await wait(3)


func _component_checks(main: Node) -> void:
	if not ResourceLoader.exists(NAV_SCRIPT):
		check(false, "zombie_nav.gd present")
		return
	var w := _spawn(main, "city", main.player.global_position + Vector3(14, 0, 0))
	var c := _spawn(main, "crawler", main.player.global_position + Vector3(-6, 0, 0))
	var b := _spawn(main, "lantern_stalker", main.player.global_position + Vector3(0, 0, 6))
	var e := _spawn(main, "echo", main.player.global_position + Vector3(0, 0, -6))
	await wait(5)
	for z in [w, c, b, e]:
		var nav = z.get("nav")
		check(nav != null and nav.get_script() != null and nav.get_script().resource_path == NAV_SCRIPT,
			"%s has the ZombieNav component" % z.get_meta("ai_kind"))
		var ag: NavigationAgent3D = z.get_node("NavigationAgent3D")
		check(ag.avoidance_enabled and ag.max_neighbors > 0 and ag.neighbor_distance > 0.0, "%s: RVO avoidance on (r %.2f, %d neighbours, %.1f m)" % [z.get_meta("ai_kind"), ag.radius, ag.max_neighbors, ag.neighbor_distance])
		check(z.floor_snap_length >= 0.3 and z.floor_max_angle >= deg_to_rad(44.0), "%s: floor snap %.2f m, max floor angle %.0f deg" % [z.get_meta("ai_kind"), z.floor_snap_length, rad_to_deg(z.floor_max_angle)])
	var wag: NavigationAgent3D = w.get_node("NavigationAgent3D")
	var cag: NavigationAgent3D = c.get_node("NavigationAgent3D")
	check(cag.radius < wag.radius, "crawler avoidance radius %.2f < walker %.2f" % [cag.radius, wag.radius])
	# Repath throttle: 30 frames chasing a still target -> at most a handful of path queries.
	var nav = w.get("nav")
	var q0: int = int(nav.path_queries)
	await wait(60)
	var q := int(nav.path_queries) - q0
	check(q >= 1 and q <= 6, "repath throttled: %d path queries in 1 s with a still target" % q)
	# Stuck escalation: pin the walker in place by forcing its velocity to zero for 6 s and watch the levels climb.
	nav.debug_freeze = true
	var max_level := 0
	var levels := {}
	for i in 60 * 7:
		await physics_frame
		max_level = maxi(max_level, int(nav.stuck_level))
		levels[int(nav.stuck_level)] = true
	nav.debug_freeze = false
	check(levels.has(1) and levels.has(2) and levels.has(3), "stuck escalation repath -> sidestep -> detour (levels seen %s)" % [levels.keys()])
	check(int(nav.unstick_count) >= 3, "unstick actions fired (%d)" % nav.unstick_count)
	# Door rebake: a nav map change (NavigationServer3D.map_changed) repaths even with a still target.
	var mr0 := int(nav.map_repaths)
	NavigationServer3D.map_changed.emit(main.nav_region.get_navigation_map())
	await wait(20)
	check(int(nav.map_repaths) > mr0, "nav map_changed -> repath (%d)" % (int(nav.map_repaths) - mr0))
	for z in [w, c, b, e]:
		if is_instance_valid(z):
			z.queue_free()
	await wait(3)
	# Hop: a 0.5 m blocker the navmesh doesn't know (added after the bake) is taller than a step -> the zombie hops it.
	var pl0: Node3D = main.player
	pl0.global_position = Vector3(30, 0.1, -7)
	pl0.velocity = Vector3.ZERO
	var blk := StaticBody3D.new()
	var bcs := CollisionShape3D.new()
	var bsh := BoxShape3D.new()
	bsh.size = Vector3(5.0, 0.5, 0.6)
	bcs.shape = bsh
	blk.add_child(bcs)
	main.add_child(blk)
	blk.global_position = Vector3(30, 0.25, 0)
	var zh := _spawn(main, "city", Vector3(30, 0.1, 6))
	var hold_p := pl0.global_position
	var crossed := false
	for i in 60 * 8:
		await physics_frame
		pl0.global_position = hold_p
		pl0.velocity = Vector3.ZERO
		if is_instance_valid(zh) and zh.global_position.z < -0.6:
			crossed = true
			break
	var nh = zh.get("nav") if is_instance_valid(zh) else null
	check(crossed and nh != null and int(nh.hops) >= 1, "hops a 0.5 m blocker (hops %d, crossed %s, last %s)" % [int(nh.hops) if nh else -1, crossed, nh.last_action if nh else "-"])
	if is_instance_valid(zh):
		zh.queue_free()
	blk.queue_free()
	await wait(3)
	# Teleport last resort: only when out of every player's view and far away (ZombieNav.players()).
	var pl: Node3D = main.player
	pl.global_position = main._player_spawn.origin
	pl.velocity = Vector3.ZERO
	await wait(5)
	var cam: Camera3D = pl.camera
	var nm: RID = main.nav_region.get_navigation_map()
	var space := pl.get_world_3d().direct_space_state
	var front := Vector3.INF
	var fwd := Vector3.FORWARD
	var right := Vector3.RIGHT
	# Find a facing with an open, on-navmesh spot >= 16 m ahead (the course's cup trap blocks the spawn's default view).
	var hold0: Vector3 = pl.global_position
	for turn in 4:
		for i in 2:
			await physics_frame
			pl.global_position = hold0
			pl.velocity = Vector3.ZERO
		fwd = -cam.global_basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		right = Vector3(-fwd.z, 0.0, fwd.x) * -1.0
		for dist in [16.0, 20.0]:
			for lat in [0.0, 4.0, -4.0, 8.0, -8.0]:
				var cand := NavigationServer3D.map_get_closest_point(nm, pl.global_position + fwd * dist + right * lat)
				var ray := PhysicsRayQueryParameters3D.create(cam.global_position, cand + Vector3(0, 1.0, 0), 1, [pl.get_rid()])
				var hit := space.intersect_ray(ray)
				if _arg("verbose") != "":
					print("  front cand %s frustum=%s hit=%s" % [cand, cam.is_position_in_frustum(cand + Vector3(0, 1.0, 0)), hit.get("collider")])
				if cam.is_position_in_frustum(cand + Vector3(0, 1.0, 0)) and hit.is_empty() and cand.distance_to(pl.global_position) >= 15.0:
					front = cand
					break
			if front != Vector3.INF:
				break
		if front != Vector3.INF:
			break
		pl.rotation.y += PI * 0.5
	check(front != Vector3.INF, "found an open spot in front of the camera")
	if front == Vector3.INF:
		return
	var back := NavigationServer3D.map_get_closest_point(nm, pl.global_position - fwd * 14.0 - right * 8.0)
	var zf := _spawn(main, "city", front + Vector3(0, 0.05, 0))
	var zb := _spawn(main, "city", back + Vector3(0, 0.1, 0))
	var nf = zf.get("nav")
	var nb = zb.get("nav")
	nf.debug_freeze = true
	nb.debug_freeze = true
	var hold: Vector3 = pl.global_position
	for i in 20:
		await physics_frame
		pl.global_position = hold
		pl.velocity = Vector3.ZERO
	if _arg("verbose") != "":
		print("  player %s cam %s front %s zf %s back %s zb %s" % [pl.global_position, cam.global_position, front, zf.global_position, back, zb.global_position])
	check(ZombieNavScr().players(zf).size() == get_nodes_in_group("player").size() and ZombieNavScr().players(zf).has(pl), "ZombieNav.players() lists every player")
	check(nf.visible_to_player() and not nf.can_teleport(), "a zombie %.0f m in front of the camera" % front.distance_to(pl.global_position) + " counts as seen (no teleport)")
	check(not nb.visible_to_player() and nb.can_teleport(), "a zombie %.0f m behind the player is unseen and may teleport" % back.distance_to(pl.global_position))
	nf.debug_freeze = true
	nb.debug_freeze = true
	var b0 := zb.global_position
	for i in 60 * 7:
		await physics_frame
		pl.global_position = hold
		pl.velocity = Vector3.ZERO
		if i % 30 == 0 and _arg("verbose") != "":
			print("  vis f=%s b=%s lvl f=%d b=%d tp f=%d b=%d fpos %s" % [nf.visible_to_player(), nb.visible_to_player(), nf.stuck_level, nb.stuck_level, nf.teleports, nb.teleports, zf.global_position])
	check(int(nf.teleports) + int(nf.respawns) == 0, "seen + stuck: never teleported (%d unstick actions, last %s)" % [nf.unstick_count, nf.last_action])
	check(int(nb.teleports) + int(nb.respawns) >= 1, "unseen + stuck + far: last resort fired (%d teleport, %d respawn; moved %.1f m)" % [nb.teleports, nb.respawns, zb.global_position.distance_to(b0)])
	zf.queue_free()
	zb.queue_free()
	await wait(2)


## Netz flag (2026-10-20), §17f: nav decisions come from a per-zombie RandomNumberGenerator (never the global one), so
## two solo runs with one seed make identical decisions. (The freed-target fix is G4M3N's, already in e038c1f.)
func _robustness_checks(main: Node) -> void:
	if not ResourceLoader.exists(NAV_SCRIPT):
		return
	var pl: Node3D = main.player
	pl.global_position = Vector3(30, 0.1, -7)
	pl.velocity = Vector3.ZERO
	await wait(3)
	# reproducible nav rolls: global RNG untouched, same seed -> same decisions, other seed -> other decisions
	var src := FileAccess.get_file_as_string(NAV_SCRIPT)
	var rx := RegEx.create_from_string("(?<![\\w.])(randf|randi|randf_range|randi_range|randfn|pick_random|shuffle|randomize|seed)\\(")
	var hits: Array = []
	for m in rx.search_all(src):
		hits.append(m.get_string())
	check(hits.is_empty(), "zombie_nav.gd never uses the global RNG (calls found: %s)" % [hits])
	var a := await _rng_run(main, 777)
	var b := await _rng_run(main, 777)
	var c := await _rng_run(main, 778)
	var kinds_seen := {}
	for k in a:
		for e in a[k]:
			kinds_seen[str(e).get_slice(" ", 0)] = true
	check(kinds_seen.has("jitter") and kinds_seen.has("sidestep") and kinds_seen.has("detour"), "seeded run rolls repath jitter, sidestep side and detour pick (%s)" % [kinds_seen.keys()])
	# A run is a fixed wall of frames, but how many repaths land inside it can differ by one or two between runs
	# (physics settle). Determinism = each zombie's roll stream is identical over the rolls both runs made.
	var same := a.size() == b.size() and a.size() > 0
	var n_rolls := 0
	for k in a:
		if not b.has(k):
			same = false
			continue
		# Compare the rolled VALUES in order: the per-zombie stream is what the seed fixes. Which decision (repath jitter vs
		# a stuck sidestep) takes the next value depends on when physics lets the stuck window expire, which can move by a
		# repath between runs once zombies crowd each other; the value sequence is identical either way.
		var ra: PackedStringArray = _roll_values(a[k])
		var rb: PackedStringArray = _roll_values(b[k])
		var n := mini(ra.size(), rb.size())
		if n < 3 or ra.slice(0, n) != rb.slice(0, n):
			same = false
		n_rolls += n
	if not same and _arg("verbose") != "":
		print("  rng run A %s\n  rng run B %s" % [a, b])
	check(same and n_rolls > 0, "two solo runs with seed 777: identical nav decisions (%d shared rolls over %d zombies)" % [n_rolls, a.size()])
	check(a != c, "seed 778 gives different nav decisions than 777")


## "jitter 0.903230" -> "0.903230" (the rolled value only).
func _roll_values(log: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for e in log:
		out.append(str(e).get_slice(" ", 1))
	return out


## One seeded solo run: 4 zombies (2 pinned so they sidestep / detour), 5 s; returns {attach order: rng_log}.
func _rng_run(main: Node, s: int) -> Dictionary:
	var nav_scr = load(NAV_SCRIPT)
	var pl: Node3D = main.player
	var hold := Vector3(30, 0.1, -7)
	pl.global_position = hold
	pl.velocity = Vector3.ZERO
	await wait(2)
	nav_scr.set_run_seed(s)
	nav_scr.log_rolls = true
	var zs: Array = []
	var spots := [Vector3(24, 0.1, 6), Vector3(36, 0.1, 6), Vector3(27, 0.1, 9), Vector3(33, 0.1, 9)]
	var kinds := ["city", "worker", "soldier", "crawler"]
	for i in 4:
		zs.append(_spawn(main, kinds[i], spots[i]))
	await physics_frame
	zs[0].nav.debug_freeze = true
	zs[1].nav.debug_freeze = true
	for i in 60 * 5:
		await physics_frame
		pl.global_position = hold
		pl.velocity = Vector3.ZERO
	var out := {}
	for z in zs:
		if is_instance_valid(z):
			out[int(z.nav.rng_order)] = z.nav.rng_log.duplicate()
			z.queue_free()
	nav_scr.log_rolls = false
	nav_scr.set_run_seed(0)
	await wait(5)
	return out


## Boss telegraphs (no nav movement): the RVO wish must drop to the boss's real motion (0 in place) at once, a zombie walking
## head-on (lane 0.3 m off the boss) must not swerve while still 3.2-4.6 m out (only a moving boss is avoided that early) (a stale walking vector would make RVO see the boss rushing at it),
## and the first nav tick after the telegraph must walk the fresh wish (toward the player, who moved behind the boss),
## never a safe velocity computed before / during the telegraph.
const BOSS_TELEGRAPH := {"bellwether": "_start_slam", "choir_host": "_begin_channel", "lantern_stalker": "_begin_beam"}


func _boss_avoid_checks(main: Node) -> void:
	if not ResourceLoader.exists(NAV_SCRIPT):
		return
	var pl: Node3D = main.player
	var lane_z := -26.0
	for kind in BOSS_TELEGRAPH:
		if _arg("boss-kinds") != "" and not _arg("boss-kinds").split(",").has(kind):
			continue
		var hold := Vector3(34.0, 0.1, lane_z)
		pl.global_position = hold
		pl.velocity = Vector3.ZERO
		pl.set("invulnerable_t", 1.0e9)
		var boss := _spawn(main, kind, Vector3(21.0, 0.1, lane_z))
		boss.set("_cd", 999.0) # no special of its own: we trigger the telegraph
		var bn = boss.get("nav")
		for i in 50:
			await physics_frame
			pl.global_position = hold
			pl.velocity = Vector3.ZERO
		var ag: NavigationAgent3D = boss.get_node("NavigationAgent3D")
		var walk_v := ag.velocity.length()
		# Telegraph in place + a walker coming head-on along a lane 0.9 m to the side.
		boss.call(BOSS_TELEGRAPH[kind])
		var bpos := boss.global_position
		var mark := Marker3D.new()
		main.add_child(mark)
		mark.global_position = bpos + Vector3(-9.0, 0.0, 0.3)
		var w := _spawn(main, "city", bpos + Vector3(5.5, 0.0, 0.3))
		w.set("target", mark)
		var max_wish := 0.0
		var max_lat := 0.0
		var max_lat_d := 0.0
		var seen_lane := false
		var wag: NavigationAgent3D = w.get_node("NavigationAgent3D")
		for i in 60:
			await physics_frame
			pl.global_position = hold
			pl.velocity = Vector3.ZERO
			if int(boss.get("phase")) == 0:
				break # telegraph over
			if i >= 3:
				max_wish = maxf(max_wish, ag.velocity.length())
			if is_instance_valid(w):
				var d := Vector2(w.global_position.x - bpos.x, w.global_position.z - bpos.z).length()
				var v := Vector3(w.velocity.x, 0, w.velocity.z)
				if d > 3.2 and d < 4.6 and v.length() > 0.5:
					seen_lane = true
					var lat := absf(v.z) / v.length()
					if lat > max_lat:
						max_lat = lat
						max_lat_d = d
		check(bool(bn.suspends) and walk_v > 0.5 and max_wish < 0.05, "%s telegraph: avoidance wish %.2f -> %.2f m/s (suspended, not the stale walk vector)" % [kind, walk_v, max_wish])
		check(seen_lane and max_lat < 0.1, "%s telegraph: a walker coming head-on isn't pushed early by the stationary boss (lateral %.0f%% at %.1f m)" % [kind, max_lat * 100.0, max_lat_d])
		if is_instance_valid(w):
			w.queue_free()
		mark.queue_free()
		# The player moves behind the boss; the boss must resume toward the player on its first nav tick.
		var hold2 := Vector3(10.0, 0.1, lane_z)
		var r0 := int(bn.resumes)
		var first_dot := -2.0
		var ended := false
		for i in 60 * 10:
			await physics_frame
			pl.global_position = hold2
			pl.velocity = Vector3.ZERO
			if kind == "choir_host" and i == 60 and boss.has_method("_end_channel") and int(boss.get("phase")) != 0:
				boss.call("_end_channel", false)
			if ended:
				# first frame back in the walk phase = the first nav tick after the telegraph
				var to_p := Vector3(hold2.x - boss.global_position.x, 0, hold2.z - boss.global_position.z).normalized()
				var bv := Vector3(boss.velocity.x, 0, boss.velocity.z)
				first_dot = bv.normalized().dot(to_p) if bv.length() > 0.05 else 1.0
				if _arg("verbose") != "":
					print("  resume %s pos %s v %s path %s cursor %d q %d susp %s target %s" % [kind, boss.global_position, bv, bn.path, bn.cursor, bn.path_queries, bn.suspended, boss.target.global_position if boss.target else null])
				break
			ended = int(boss.get("phase")) == 0
		check(int(bn.resumes) > r0 and int(bn.resume_used_safe) == 0 and first_dot > 0.5, "%s after the telegraph: first nav tick walks the fresh wish (dot %.2f toward the player, stale safe uses %d)" % [kind, first_dot, int(bn.resume_used_safe)])
		boss.queue_free()
		await wait(3)


func ZombieNavScr() -> Script:
	return load(NAV_SCRIPT)


## Ramp-side carve fallback vs the maps' own carves (Mapz map contract: a ramp body with meta nav_side_carves ships its
## own side carves and must be skipped). Dry-run count on the loaded map, plus the strips the real call left behind.
func _carve_checks(main: Node, map_id: String, strips: int) -> void:
	var nav = load(NAV_SCRIPT)
	nav.prepare_nav_region(main.nav_region, true)
	var st: Dictionary = nav.last_carve_stats
	var wedges := int(st.wedges)
	var tagged := int(st.tagged)
	var would := int(st.added)
	var enabled := bool(nav.data().get("ramp_carve", {}).get("enabled", true))
	print("  %s: wedges %d, tagged nav_side_carves %d, fallback would add %d strips (carve %s)" % [map_id, wedges, tagged, would, "on" if enabled else "off"])
	check(strips == (would if enabled else 0), "%s: carve fallback added %d strips (expected %d: 2 per untagged wedge, 0 with carve off)" % [map_id, strips, would if enabled else 0])
	if tagged > 0 or wedges == 0:
		check(tagged == wedges and would == 0, "%s: every wedge ramp carries its own side carves (%d/%d tagged), fallback adds 0 strips" % [map_id, tagged, wedges])
	else:
		print("INFO  %s: no ramp carries nav_side_carves (map predates Mapz's carve tags); fallback strips on all %d wedges" % [map_id, wedges])


func _run() -> void:
	baseline = _arg("baseline") != ""
	var maps_arg := _arg("maps", "ai_course,arena,rustwell_foundry,drowned_cannery")
	if _arg("no-carve") != "" and ResourceLoader.exists(NAV_SCRIPT):
		var d: Dictionary = load(NAV_SCRIPT).data().duplicate(true)
		d["ramp_carve"] = {"enabled": false}
		load(NAV_SCRIPT).reload_data(d)
		print("ramp-side carve fallback OFF")
	elif _arg("carve") != "" and ResourceLoader.exists(NAV_SCRIPT):
		var d3: Dictionary = load(NAV_SCRIPT).data().duplicate(true)
		d3["ramp_carve"]["enabled"] = true
		load(NAV_SCRIPT).reload_data(d3)
		print("ramp-side carve fallback ON (forced)")
	if _arg("no-suspend") != "" and ResourceLoader.exists(NAV_SCRIPT):
		var d2: Dictionary = load(NAV_SCRIPT).data().duplicate(true)
		d2["avoidance"]["suspend_off_nav"] = false
		load(NAV_SCRIPT).reload_data(d2)
		print("off-nav avoidance suspend OFF (control run: the boss checks should fail)")
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_ai_nav_test.cfg"
	progress.reset_skills()
	if _arg("realtime") == "":
		Engine.physics_ticks_per_second = 240
		Engine.max_physics_steps_per_frame = 16
		Engine.time_scale = 4.0
	var wall0 := Time.get_ticks_msec()
	var did_components := false
	for map_id in maps_arg.split(","):
		if not COURSES.has(map_id):
			continue
		if map_id != "ai_course" and not MapRegistry.is_valid(map_id):
			print("SKIP  map %s not present" % map_id)
			continue
		print("== %s" % map_id)
		var main := await _load_main(map_id)
		check(main.nav_region.navigation_mesh.get_polygon_count() > 0, "%s: navmesh baked (%d polygons)" % [map_id, main.nav_region.navigation_mesh.get_polygon_count()])
		var carves: Node = main.nav_region.get_node_or_null("ZombieNavRampCarves")
		print("  %s: ramp-side carve strips %d" % [map_id, carves.get_child_count() if carves else 0])
		_carve_checks(main, map_id, carves.get_child_count() if carves else 0)
		Engine.time_scale = 4.0 if _arg("realtime") == "" else 1.0 # RunState.clear() resets it
		if not did_components and not baseline and (map_id == "ai_course" or not maps_arg.contains("ai_course")):
			did_components = true
			await _component_checks(main)
			if _arg("skip-boss-avoid") == "":
				await _boss_avoid_checks(main)
			if _arg("skip-robust") == "":
				await _robustness_checks(main)
		for c in COURSES[map_id]:
			await _run_course(main, map_id, c)
		if _arg("skip-ranged") == "" and not baseline:
			await _ranged_checks(main, map_id) # Skillz §22: Gallspitter standpoint walks on every map
		main.queue_free()
		current_scene = null
		await wait(5)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	MapRegistry.select("")
	print("")
	print("SUMMARY (%s)" % ("baseline" if baseline else "current"))
	var tot_n := 0
	var tot_r := 0
	var worst := 0.0
	for m in _stats:
		var s: Dictionary = _stats[m]
		tot_n += s.n
		tot_r += s.reached
		worst = maxf(worst, s.worst_still)
		print("  %-20s reach %d/%d (%.0f%%)  worst still %.1fs (%s)  nav paths %d/%d  sim %.0fs" % [m, s.reached, s.n,
			100.0 * s.reached / maxf(s.n, 1), s.worst_still, s.worst_where, s.nav_ok, s.nav_n, s.t])
	print("  TOTAL                reach %d/%d (%.0f%%)  worst still %.1fs  wall %.0fs" % [tot_r, tot_n, 100.0 * tot_r / maxf(tot_n, 1), worst, (Time.get_ticks_msec() - wall0) / 1000.0])
	if not _checkpoints.is_empty():
		print("CHECKPOINTS (Mapz nav audit spots)")
		for l in _checkpoints:
			print("  " + l)
	print("ai_nav_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


# ------------------------------------------------------------------ Skillz §22: ranged (Gallspitter) checkpoints

## The Gallspitter doesn't walk up to the player, so it isn't in KINDS: on each map it starts at the first two courses'
## starts with the player at the goal and must, within RANGED_TIME s, never stand still > STILL_MAX s while it wants to
## walk (wants_move(): approach / standpoint walk / retreat) and end up shooting (at least one spit) from 8-22 m.
const RANGED_TIME := 20.0
const RANGED_SCRIPT := "res://scripts/enemies/variants/gallspitter.gd"


func _ranged_checks(main: Node, map_id: String) -> void:
	if not ResourceLoader.exists(RANGED_SCRIPT) or ZombieVariants.get_variant("gallspitter").is_empty():
		return
	var player: Node3D = main.player
	var n := 0
	for c in COURSES[map_id]:
		if n >= 2 or c.has("vias"):
			continue
		n += 1
		player.global_position = c.goal
		player.velocity = Vector3.ZERO
		player.set("invulnerable_t", 1.0e9)
		await wait(10)
		var goal: Vector3 = player.global_position
		var zs: Array = []
		for s in c.starts.slice(0, 2):
			zs.append(_spawn(main, "gallspitter", s))
		var still: Array = []
		var last: Array = []
		for z in zs:
			still.append(0.0)
			last.append(z.global_position)
		var worst := 0.0
		for i in int(RANGED_TIME / STEP):
			await physics_frame
			player.global_position = goal
			for k in zs.size():
				var z = zs[k]
				if not is_instance_valid(z):
					continue
				if z.wants_move() and z.global_position.distance_to(last[k]) < STILL_EPS:
					still[k] += STEP
				else:
					still[k] = 0.0
					last[k] = z.global_position
				worst = maxf(worst, still[k])
		var spits := 0
		var shooters := 0
		var modes: Array = []
		for z in zs:
			if not is_instance_valid(z):
				continue
			spits += int(z.spits)
			shooters += 1 if int(z.spits) > 0 else 0
			var d := Vector2(z.global_position.x - goal.x, z.global_position.z - goal.z).length()
			modes.append("%s %.1fm %d spits %d hops" % [z.mode_name(), d, int(z.spits), int(z.hops)])
			z.queue_free()
		check(worst < STILL_MAX, "%s/%s ranged: Gallspitters never stall (worst still %.1f s) [%s]" % [map_id, c.name, worst, ", ".join(modes)])
		check(shooters == zs.size(), "%s/%s ranged: every Gallspitter gets a shot off within %.0f s (%d/%d, %d spits)" % [map_id, c.name, RANGED_TIME, shooters, zs.size(), spits])
		_checkpoints.append("%s ranged_%s: worst still %.1fs, %d/%d shooting, %d spits [%s]" % [map_id, c.name, worst, shooters, zs.size(), spits, ", ".join(modes)])
		for p in root.get_tree().get_nodes_in_group("thrown_projectiles") + root.get_tree().get_nodes_in_group("gall_puddles"):
			p.queue_free()
		await wait(5)
