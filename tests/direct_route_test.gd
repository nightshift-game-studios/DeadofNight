extends SceneTree
## Zombie route directness test (Skillz, playtest 2026-10-22 #13; DESIGN §18 / MAIN_HOOKS §17g).
##   godot --headless --path . -s res://tests/direct_route_test.gd [-- --maps=arena,rustwell_foundry,drowned_cannery] [-- --baseline] [-- --verbose]
## Jason: zombies must take the fastest, most direct route to the player and only detour when stuck or a wall is in the way.
## On each map, random navmesh start/goal pairs (seeded) are split into
##   CLEAR   - nothing between them: the navmesh path is the straight line (L_nav <= 1.03 S + 0.2 m), same level (|dy| < 0.5),
##             and three rays (0.3 / 0.9 / 1.6 m up) against the world are free; and
##   BLOCKED - a wall / prop / ramp is in the way (L_nav >= 1.2 S).
## A lone walker (player held at the goal) must:
##   CLEAR   - travel <= CLEAR_RATIO x the straight line to the 2 m reach ring (+ 0.5 m), never stray > CLEAR_DEV m from the
##             start->goal line, and keep its heading within CLEAR_HEAD deg of the bearing to the player (after the first 0.6 s);
##   BLOCKED - reach the player, travelling <= BLOCKED_RATIO x the navmesh-optimal path (+ BLOCKED_SLACK m): detours only
##             where a wall forces them, never a wander;
##   CROWD   - six walkers released 1 m apart in a clear lane: each travels <= CROWD_RATIO x its own straight line (light
##             separation is allowed, swirling round each other is not).
## Thresholds (see the constants): measured on the pre-#13 code (ZombieNav a-baseline) and on the new direct-steering code.
## "--baseline" only prints (INFO), never fails. Exit code = number of failures.

const ZOMBIE := preload("res://scenes/enemy.tscn")
const MAIN := "res://scenes/main.tscn"
const NAV_SCRIPT := "res://scripts/enemies/ai/zombie_nav.gd"
const REACH := 2.0 ## flat metres from the player counted as arrived (ai_nav_test REACH_FLAT)
const REACH_DY := 1.2
## Six zombies queue on one player: the back ones stop at the attack ring behind the front ones (~2.2-2.4 m out), which is
## arrived, not stalled (measured: final distances 2.16 / 2.33 m), so the crowd check counts <= 2.6 m.
const CROWD_REACH := 2.6
const BASE_SPEED := 3.0
const STEP := 1.0 / 60.0
const SEED := 1337
## Pure straight chase is 1.00 (the zombie's lateral wobble from move_and_slide / floor snap is mm). 1.06 leaves room for the
## 0.5 m start-up and the last-step overshoot of the reach ring on a 10 m run; the old waypoint-following code measured up to ~1.0x too
## in open ground, so this guards against regressions: any flank / spread / wander offset of >= 1.5 m on a 20 m run breaks it.
const CLEAR_RATIO := 1.06
const CLEAR_DEV := 0.6
const CLEAR_HEAD := 14.0
## A blocked route follows the navmesh funnel path; the body can cut corners (shorter) or lose ~0.3 m per corner to the
## waypoint radius / corner sweep (longer), ramps add climb length the flat path doesn't, so 1.15x + 1.5 m.
const BLOCKED_RATIO := 1.15
const BLOCKED_SLACK := 1.5
## RVO separation: neighbours 1 m apart in a start cluster push each other sideways for the first metres only.
const CROWD_RATIO := 1.12
## Moving player (ping-pong across the zombie's line at 4 m/s, +-5 m): the zombie steers at where the player IS (pure pursuit), not
## at where a throttled path query saw it 0.35 s / 1 m ago: mean heading error <= PURSUE_MEAN deg, 95th percentile <= PURSUE_P95 deg
## while it has a clear line (3 rays) and is >= 3 m out. (A static player needs no such check: the navmesh path is the line.)
const PURSUE_MEAN := 2.0
const PURSUE_P95 := 5.0
## Share of a clear walk spent in direct-chase mode (nav.direct): the zombie only follows waypoints for the first ~0.3 s (the
## first path query) and the last 2.5 m (direct_chase_dist walks straight too, but is not counted as nav.direct).
const DIRECT_SHARE := 0.7
const CLEAR_PAIRS := 6
const BLOCKED_PAIRS := 3

var _fails := 0
var _passes := 0
var baseline := false
var _rows: Array = []


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
	MapRegistry.select(map_id)
	var main = load(MAIN).instantiate()
	root.add_child(main)
	current_scene = main
	await wait(3)
	main._break_timer = 1.0e9
	main.field_cards_enabled = false
	if main.map and main.map.has_method("open_all_doors"):
		main.map.open_all_doors()
	await wait(2)
	for i in 1200:
		var m: RID = main.nav_region.get_navigation_map()
		if not main.nav_region.is_baking() and m.is_valid() and NavigationServer3D.map_get_iteration_id(m) > 0 \
				and main.nav_region.navigation_mesh and main.nav_region.navigation_mesh.get_polygon_count() > 0:
			break
		await physics_frame
	await wait(3)
	return main


func _spawn(main: Node, kind: String, pos: Vector3) -> Node3D:
	var z = ZOMBIE.instantiate()
	ZombieVariants.apply_script(z, kind)
	z.setup(150, BASE_SPEED, 1)
	var sc := ZombieVariants.scene(kind)
	if sc:
		z.set_variant(kind, ZombieVariants.get_variant(kind), sc)
	main.zombies_root.add_child(z)
	z.global_position = pos
	return z


func _path_len(pts: PackedVector3Array) -> float:
	var l := 0.0
	for i in range(1, pts.size()):
		l += pts[i - 1].distance_to(pts[i])
	return l


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


## {clear, blocked, S, L, dy} for a navmesh start/goal pair (independent of ZombieNav: navmesh server + world rays).
func _classify(main: Node, a: Vector3, b: Vector3) -> Dictionary:
	var m: RID = main.nav_region.get_navigation_map()
	var pts := NavigationServer3D.map_get_path(m, a, b, true)
	var s := _flat(b - a).length()
	var l := _path_len(pts)
	var end_ok := not pts.is_empty() and pts[pts.size() - 1].distance_to(b) < 1.0
	var out := {"clear": false, "blocked": false, "S": s, "L": l, "dy": b.y - a.y, "ok": end_ok}
	if not end_ok or s < 1.0:
		return out
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var rays_free := true
	for h in [0.3, 0.9, 1.6]:
		var q := PhysicsRayQueryParameters3D.create(a - Vector3(0, 0.25, 0) + Vector3(0, h, 0), b - Vector3(0, 0.25, 0) + Vector3(0, h, 0), 1)
		if not space.intersect_ray(q).is_empty():
			rays_free = false
	out.clear = rays_free and l <= 1.03 * s + 0.2 and absf(b.y - a.y) < 0.5
	out.blocked = l >= 1.2 * s and absf(b.y - a.y) < 2.5
	return out


## Runs walkers from `starts` (all released together) to `goal` (player held there). Returns one record per walker.
func _walk(main: Node, kinds: Array, starts: Array, goal_in: Vector3, budget: float, reach: float = REACH) -> Array:
	var player: Node3D = main.player
	player.global_position = goal_in
	player.velocity = Vector3.ZERO
	player.set("invulnerable_t", 1.0e9)
	await wait(10)
	var goal: Vector3 = player.global_position
	var recs: Array = []
	for i in starts.size():
		var z := _spawn(main, kinds[i], starts[i] + Vector3(0, 0.1, 0))
		await physics_frame
		recs.append({"z": z, "kind": kinds[i], "start": z.global_position, "last": z.global_position, "len": 0.0, "dev": 0.0,
			"head": 0.0, "frames": 0, "dframes": 0, "reached_t": -1.0, "len_at_reach": 0.0, "S": _flat(goal - z.global_position).length()})
	var t := 0.0
	var done := false
	while t < budget and not done:
		await physics_frame
		player.global_position = goal
		player.velocity = Vector3.ZERO
		t += STEP
		done = true
		if _arg("trace") != "" and int(t / STEP) % 120 == 0:
			for r in recs:
				if is_instance_valid(r.z) and r.z.get("nav") != null:
					var zn = r.z.nav
					print("    TRACE t=%.1f pos %s direct %s straight %s bans %d stuck %d act %s" % [t, (r.z.global_position as Vector3).snapped(Vector3.ONE * 0.1), zn.direct, zn._path_straight, zn.direct_bans, zn.stuck_level, zn.last_action])
		for r in recs:
			if r.reached_t >= 0.0 or not is_instance_valid(r.z):
				continue
			done = false
			var z: Node3D = r.z
			var p: Vector3 = z.global_position
			r.frames += 1
			if z.get("nav") != null and z.nav.direct:
				r.dframes += 1
			r.len += p.distance_to(r.last)
			r.last = p
			var seg: Vector3 = _flat(goal - r.start)
			var rel: Vector3 = _flat(p - r.start)
			var along := clampf(rel.dot(seg) / maxf(seg.length_squared(), 0.01), 0.0, 1.0)
			r.dev = maxf(r.dev, (rel - seg * along).length())
			var to_p := _flat(goal - p)
			var v := _flat(z.velocity)
			if t > 0.6 and to_p.length() > 4.0 and v.length() > 0.5:
				r.head = maxf(r.head, rad_to_deg(v.normalized().angle_to(to_p.normalized())))
			if to_p.length() <= reach and absf(p.y - goal.y) <= REACH_DY:
				r.reached_t = t
				r.len_at_reach = r.len
	for r in recs:
		if is_instance_valid(r.z):
			r.final_d = _flat(goal - r.z.global_position).length()
			r.final_pos = r.z.global_position
			var zn = r.z.get("nav")
			r.state = ("direct %s bans %d flips %d stuck %d act %s path %d cur %d queries %d" % [zn.direct, zn.direct_bans, zn.direct_flips, zn.stuck_level, zn.last_action, zn.path.size(), zn.cursor, zn.path_queries]) if zn != null else ""
			r.z.queue_free()
	await wait(3)
	for r in recs:
		r.goal = goal
	return recs


func _median(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]


func _run_map(main: Node, map_id: String) -> void:
	var m: RID = main.nav_region.get_navigation_map()
	seed(SEED)
	var clear: Array = []
	var blocked: Array = []
	var tries := 0
	while (clear.size() < CLEAR_PAIRS or blocked.size() < BLOCKED_PAIRS) and tries < 2000:
		tries += 1
		var a := NavigationServer3D.map_get_random_point(m, 1, true)
		var b := NavigationServer3D.map_get_random_point(m, 1, true)
		var s := _flat(b - a).length()
		if s < 8.0 or s > 30.0 or absf(a.y - b.y) > 2.5:
			continue
		if a.y > 0.9 or b.y > 0.9:
			continue # ground level starts only (roofs / catwalks are covered by ai_nav_test)
		var c := _classify(main, a, b)
		if c.clear and clear.size() < CLEAR_PAIRS:
			clear.append({"a": a, "b": b, "c": c})
		elif c.blocked and blocked.size() < BLOCKED_PAIRS and c.L < 55.0:
			blocked.append({"a": a, "b": b, "c": c})
	print("  %s: %d clear + %d blocked pairs after %d samples" % [map_id, clear.size(), blocked.size(), tries])
	check(clear.size() >= 3 and blocked.size() >= 1, "%s: enough clear (%d) and blocked (%d) navmesh pairs to test" % [map_id, clear.size(), blocked.size()])
	var ratios: Array = []
	var crowd_done := false
	for pr in clear:
		var recs := await _walk(main, ["city"], [pr.a], pr.b, clampf(pr.c.S / 2.0 + 12.0, 15.0, 40.0))
		var r: Dictionary = recs[0]
		var ok: bool = r.reached_t >= 0.0
		var eff := maxf(r.S - REACH, 0.1)
		var ratio: float = (r.len_at_reach / eff) if ok else INF
		ratios.append(ratio)
		var line := "%s clear   %5.1f m  from %s: %s  travelled %.1f m / straight %.1f m = %.3f  max off-line %.2f m  max heading err %.1f deg" % [
			map_id, r.S, (pr.a as Vector3).snapped(Vector3.ONE * 0.1), ("reached %.1fs" % r.reached_t) if ok else "NOT REACHED", r.len_at_reach, eff, ratio, r.dev, r.head]
		_rows.append(line)
		print("  " + line)
		_debug_unreached(r)
		var share: float = float(r.dframes) / maxf(r.frames, 1.0)
		print("    steering straight at the player %.0f%% of the walk" % (share * 100.0))
		check(share >= DIRECT_SHARE, "%s clear %.0f m: steers straight at the player (not along waypoints) %.0f%% of the walk >= %.0f%%" % [map_id, r.S, share * 100.0, DIRECT_SHARE * 100.0])
		check(ok and r.len_at_reach <= eff * CLEAR_RATIO + 0.5 and r.dev <= CLEAR_DEV and r.head <= CLEAR_HEAD,
			"%s clear %.0f m: straight at the player (ratio %.3f <= %.2f, off-line %.2f m <= %.1f, heading %.1f deg <= %.0f)" % [map_id, r.S, ratio, CLEAR_RATIO, r.dev, CLEAR_DEV, r.head, CLEAR_HEAD])
		if not crowd_done and pr.c.S >= 14.0:
			crowd_done = true
			await _crowd(main, map_id, pr)
			await _pursuit(main, map_id, pr)
	for pr in blocked:
		var recs := await _walk(main, ["city"], [pr.a], pr.b, clampf(pr.c.L / 2.0 + 15.0, 20.0, 60.0))
		var r: Dictionary = recs[0]
		var ok: bool = r.reached_t >= 0.0
		var eff: float = maxf(pr.c.L - REACH, 0.1)
		var ratio: float = (r.len_at_reach / eff) if ok else INF
		var line := "%s blocked %5.1f m (navmesh %.1f m = %.2fx)  from %s: %s  travelled %.1f m = %.3f x nav path  (%.2f x straight)" % [
			map_id, r.S, pr.c.L, pr.c.L / pr.c.S, (pr.a as Vector3).snapped(Vector3.ONE * 0.1), ("reached %.1fs" % r.reached_t) if ok else "NOT REACHED", r.len_at_reach, ratio, r.len_at_reach / maxf(r.S - REACH, 0.1)]
		_rows.append(line)
		print("  " + line)
		_debug_unreached(r)
		check(ok and r.len_at_reach <= eff * BLOCKED_RATIO + BLOCKED_SLACK,
			"%s blocked %.0f m: detours only where blocked (travelled %.1f m <= %.2f x navmesh %.1f m + %.1f)" % [map_id, r.S, r.len_at_reach, BLOCKED_RATIO, eff, BLOCKED_SLACK])
	print("  %s clear ratios: median %.3f max %.3f" % [map_id, _median(ratios), ratios.max() if not ratios.is_empty() else 0.0])


func _pursuit(main: Node, map_id: String, pr: Dictionary) -> void:
	var m: RID = main.nav_region.get_navigation_map()
	var player: Node3D = main.player
	var space: PhysicsDirectSpaceState3D = main.get_world_3d().direct_space_state
	var a: Vector3 = pr.a
	var centre: Vector3 = pr.b
	var dir := _flat(centre - a).normalized()
	var side := Vector3(-dir.z, 0.0, dir.x)
	player.global_position = centre
	player.velocity = Vector3.ZERO
	player.set("invulnerable_t", 1.0e9)
	await wait(10)
	var z := _spawn(main, "city", a + Vector3(0, 0.1, 0))
	var errs: Array = []
	var t := 0.0
	var off_nav := 0.0
	var phase_len := 10.0 / 4.0 # +-5 m at 4 m/s
	var frame := 0
	var p := centre
	while t < 8.0 and is_instance_valid(z):
		await physics_frame
		t += STEP
		frame += 1
		var ph := fmod(t, 2.0 * phase_len)
		var u := (ph / phase_len) if ph < phase_len else (2.0 - ph / phase_len) # 0..1..0
		var want := centre + side * (u * 10.0 - 5.0)
		if frame % 4 == 0:
			var c := NavigationServer3D.map_get_closest_point(m, want)
			off_nav = _flat(c - want).length()
			p = c - Vector3(0, 0.25, 0) if off_nav < 0.5 else p
		player.global_position = p
		player.velocity = Vector3.ZERO
		var zp: Vector3 = z.global_position
		var to_p := _flat(p - zp)
		var v := _flat(z.velocity)
		if t < 0.6 or to_p.length() < 3.0 or v.length() < 0.5 or absf(p.y - zp.y) > 0.6:
			continue
		var free := true
		for h in [0.3, 0.9, 1.6]:
			var q := PhysicsRayQueryParameters3D.create(zp + Vector3(0, h, 0), p + Vector3(0, h, 0), 1)
			if not space.intersect_ray(q).is_empty():
				free = false
				break
		if free and frame % 2 == 0:
			errs.append(rad_to_deg(v.normalized().angle_to(to_p.normalized())))
	if is_instance_valid(z):
		z.queue_free()
	await wait(3)
	errs.sort()
	var mean := 0.0
	for e in errs:
		mean += e
	mean /= maxf(errs.size(), 1.0)
	var p95: float = errs[int(errs.size() * 0.95)] if errs.size() > 0 else 0.0
	var line := "%s pursuit of a strafing player from %.0f m: %d samples, heading error mean %.2f deg, p95 %.2f deg, max %.1f deg" % [map_id, pr.c.S, errs.size(), mean, p95, errs.max() if errs.size() > 0 else 0.0]
	_rows.append(line)
	print("  " + line)
	check(errs.size() >= 100 and mean <= PURSUE_MEAN and p95 <= PURSUE_P95,
		"%s pursuit: a zombie with a clear line steers at the strafing player (mean %.2f <= %.1f deg, p95 %.2f <= %.0f deg, %d samples)" % [map_id, mean, PURSUE_MEAN, p95, PURSUE_P95, errs.size()])


func _debug_unreached(r: Dictionary) -> void:
	if r.reached_t < 0.0:
		print("    DEBUG not reached: kind %s start %s S %.1f final_d %.2f pos %s walked %.1f m  nav: %s  goal %s" % [r.kind, r.start, r.S, r.get("final_d", -1.0), r.get("final_pos", Vector3.ZERO), r.len, r.get("state", ""), r.goal])


func _crowd(main: Node, map_id: String, pr: Dictionary) -> void:
	var a: Vector3 = pr.a
	var dir := _flat(pr.b - a).normalized()
	var side := Vector3(-dir.z, 0.0, dir.x)
	var starts: Array = []
	var kinds := ["city", "worker", "soldier", "city", "worker", "soldier"]
	for i in 6:
		var c := NavigationServer3D.map_get_closest_point(main.nav_region.get_navigation_map(), a + side * ((i % 3 - 1) * 1.0) - dir * (int(i / 3) * 1.0))
		starts.append(c)
	var recs := await _walk(main, kinds, starts, pr.b, clampf(pr.c.S / 2.0 + 15.0, 20.0, 45.0), CROWD_REACH)
	var worst := 0.0
	var all_ok := true
	for r in recs:
		var ok: bool = r.reached_t >= 0.0
		all_ok = all_ok and ok
		var eff := maxf(r.S - CROWD_REACH, 0.1)
		var ratio: float = (r.len_at_reach / eff) if ok else INF
		worst = maxf(worst, ratio)
	var line := "%s crowd of 6, %.0f m: worst travelled/straight %.3f (%s)" % [map_id, pr.c.S, worst, str(recs.map(func(r): return snappedf(r.len_at_reach / maxf(r.S - CROWD_REACH, 0.1), 0.01) if r.reached_t >= 0.0 else -1.0))]
	for r in recs:
		_debug_unreached(r)
	_rows.append(line)
	print("  " + line)
	check(all_ok and worst <= CROWD_RATIO + 0.5 / maxf(pr.c.S - CROWD_REACH, 1.0), "%s crowd: six walkers released 1 m apart all go straight in (worst ratio %.3f <= %.2f)" % [map_id, worst, CROWD_RATIO])


func _run() -> void:
	baseline = _arg("baseline") != ""
	if _arg("legacy") != "":
		## before-numbers on the same tree: the old path-following steering (nav.direct_enabled false)
		var zn = load("res://scripts/enemies/ai/zombie_nav.gd")
		var d: Dictionary = zn.data().duplicate(true)
		(d["nav"] as Dictionary)["direct_enabled"] = false
		zn.reload_data(d)
		print("LEGACY: nav.direct_enabled = false")
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_direct_route_test.cfg"
	progress.reset_skills()
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 16
	Engine.time_scale = 4.0
	var wall0 := Time.get_ticks_msec()
	for map_id in _arg("maps", "arena,rustwell_foundry,drowned_cannery").split(","):
		if not MapRegistry.is_valid(map_id):
			print("SKIP  map %s not present" % map_id)
			continue
		print("== %s" % map_id)
		var main := await _load_main(map_id)
		Engine.time_scale = 4.0
		await _run_map(main, map_id)
		main.queue_free()
		current_scene = null
		await wait(5)
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	MapRegistry.select("")
	print("")
	print("SUMMARY (%s), wall %.0fs" % ["baseline" if baseline else "current", (Time.get_ticks_msec() - wall0) / 1000.0])
	for l in _rows:
		print("  " + l)
	print("direct_route_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
