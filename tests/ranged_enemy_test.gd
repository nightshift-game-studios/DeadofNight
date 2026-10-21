extends SceneTree
## Gallspitter + ThrownProjectile test (Skillz, DESIGN §22 / MAIN_HOOKS §22).
##   godot --headless --path . -s res://tests/ranged_enemy_test.gd [-- --realtime]
## On the synthetic AI course (tests/ai_nav_course.tscn, the same harness as ai_nav_test):
##   data / contract   locked numbers (projectiles.json bile_glob, zombies.json gallspitter, difficulty specials and shares),
##                     ThrownProjectile.spawn(spec) contract, visual-only copies, placeholder sockets / clips
##   projectile        lob flight times, direct hit on a standing player, miss on a strafing one (dodgeable at
##                     8 / 14 / 22 m even reacting late), the puddle: DoT ticks, no stacking, 25% slow, 4 s
##   behaviour         keeps range and spits, telegraph >= 0.7 s before release, retreats when rushed, camper priority,
##                     unreachable (perch) priority + spits up at it, heavy hit cancels the wind-up, weak melee,
##                     never stands still while it wants to move (no nav stall)
## Exit code = number of failures.

const ZOMBIE := preload("res://scenes/enemy.tscn")
const MAIN := "res://scenes/main.tscn"
const COURSE_SCENE := "res://tests/ai_nav_course.tscn"
const SPITTER := "res://scripts/enemies/variants/gallspitter.gd"
const PS := preload("res://scripts/combat/player_status.gd")
const STILL_EPS := 0.3
const STILL_MAX := 3.0

var _passes := 0
var _fails := 0
var main: Node
var pl: CharacterBody3D
var G: GDScript # gallspitter.gd (statics)
var TP: GDScript ## thrown_projectile.gd, loaded in _run: a ThrownProjectile reference here would compile it (-> grenade -> explosion -> weapon_item, which needs the GearDB autoload) before the autoloads exist


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
	return int(ceil(t * 60.0)) # physics step = 1/60 game s (240 Hz x time_scale 4, or 60 Hz realtime)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	TP = load("res://scripts/projectiles/thrown_projectile.gd")
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_ranged_enemy_test.cfg"
	progress.reset_skills()
	var realtime := OS.get_cmdline_user_args().has("--realtime")
	if not realtime:
		Engine.physics_ticks_per_second = 240
		Engine.max_physics_steps_per_frame = 16
	G = load(SPITTER)
	_data_checks()
	main = load(MAIN).instantiate()
	main.map_scene = load(COURSE_SCENE)
	root.add_child(main)
	current_scene = main
	await wait(3)
	main._break_timer = 1.0e9
	main.field_cards_enabled = false
	await _wait_bake(main.nav_region)
	Engine.time_scale = 1.0 if realtime else 4.0
	pl = main.player
	pl.set("invulnerable_t", 0.0)
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
	if only == "" or only == "contract":
		await _contract_checks()
	if only == "" or only == "projectile":
		await _projectile_checks()
	if only == "" or only == "puddle":
		await _puddle_checks()
	if only == "" or only == "placeholder":
		await _placeholder_checks()
	if only == "" or only == "range":
		await _keep_range_checks()
	if only == "" or only == "camp":
		await _camp_checks()
	if only == "" or only == "perch":
		await _perch_checks()
	if only == "" or only == "melee":
		await _stagger_and_melee_checks()
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("ranged_enemy_test: %d passed, %d failed" % [_passes, _fails])
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

func _spawn(pos: Vector3, health: int = 100) -> Node:
	var z = main.make_zombie({"kind": "zombie", "vid": "gallspitter", "health": health, "speed": 3.2, "damage": 10})
	main.zombies_root.add_child(z)
	z.global_position = pos
	return z


func _clear() -> void:
	for z in get_nodes_in_group("enemies"):
		z.queue_free()
	for n in get_nodes_in_group("thrown_projectiles") + get_nodes_in_group("gall_puddles"):
		n.queue_free()
	for n in get_nodes_in_group("player"):
		if n != pl:
			n.queue_free()
	G.reset_camping()
	PS.clear(pl)
	await wait(3)


func _place_player(p: Vector3, driven: bool) -> void:
	pl.set_physics_process(not driven)
	pl.global_position = p
	pl.velocity = Vector3.ZERO
	pl.health = pl.max_health
	pl.dead = false
	pl.set("invulnerable_t", 0.0)


## A second "player" (co-op stand-in): capsule on layer 2, in the player group, counts damage.
func _fake_player(pos: Vector3) -> CharacterBody3D:
	var s := GDScript.new()
	s.source_code = "extends CharacterBody3D\nvar dead := false\nvar health := 100.0\nvar max_health := 100\nvar damage_taken := 0.0\nfunc take_damage(a: float, _att: Node = null) -> void:\n\tdamage_taken += a\n"
	s.reload()
	var f := CharacterBody3D.new()
	f.set_script(s)
	f.name = "FakePlayer"
	f.collision_layer = 2
	f.collision_mask = 1
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	cs.shape = cap
	cs.position.y = 0.9
	f.add_child(cs)
	f.add_to_group("player")
	main.add_child(f)
	f.global_position = pos
	return f


func _spawn_glob(from: Vector3, aim: Vector3, extra: Dictionary = {}) -> Node:
	var spec := {"type_id": &"bile_glob", "variant": &"", "rarity": 0, "pos": from, "vel": TP.lob_velocity(from, aim),
		"owner_id": 0, "seed": 7}
	spec.merge(extra, true)
	return TP.spawn(spec)


# ------------------------------------------------------------------ data (no scene)

func _data_checks() -> void:
	var d: Dictionary = TP.type_def(&"bile_glob")
	check(is_equal_approx(float(d.visual_radius), 0.18) and is_equal_approx(float(d.collision_radius), 0.25) and is_equal_approx(float(d.launch_speed), 9.0),
		"projectiles.json bile_glob: visual r 0.18, collision r 0.25, launch speed 9 m/s (locked)")
	var imp: Dictionary = d.get("impact", {})
	check(str(imp.hazard) == "gall_puddle" and is_equal_approx(float(imp.radius), 2.5) and is_equal_approx(float(imp.duration), 4.0)
		and is_equal_approx(float(imp.slow), 0.25) and float(imp.dps) > 0.0 and float(imp.dps) <= 5.0,
		"impact: gall puddle 2.5 m, 4 s, 25%% slow, light DoT %.1f/s" % float(imp.dps))
	check(TP.type_def(&"nope").is_empty(), "unknown type_id -> {}")
	var v := ZombieVariants.get_variant("gallspitter")
	check(bool(v.get("special")) and ZombieVariants.script_path("gallspitter") == SPITTER and str(v.get("model", "")).ends_with("gallspitter.glb")
		and float(v.damage_mult) < 1.0 and float(v.health_mult) < 1.0 and not bool(v.get("runner", true)),
		"zombies.json gallspitter: special, script, model path, weak (damage x%.2f, HP x%.2f), no runner bonus" % [float(v.damage_mult), float(v.health_mult)])
	var bh := ZombieVariants.behavior("gallspitter")
	check(is_equal_approx(float(bh.engage_min), 8.0) and is_equal_approx(float(bh.engage_max), 22.0) and is_equal_approx(float(bh.spit_windup), 0.7)
		and is_equal_approx(float(bh.spit_recovery), 0.4), "behavior: engage 8-22 m, spit 0.7 s wind-up + 0.4 s recovery (locked)")
	var in_mix := false
	for e in ZombieVariants.data().get("wave_mix", []):
		in_mix = in_mix or e.get("weights", {}).has("gallspitter")
	check(not in_mix, "gallspitter is not in the regular wave_mix (difficulty specials only)")
	var D = load("res://scripts/world/difficulty.gd")
	var first := {"easy": 6, "medium": 5, "hard": 4}
	for prof in first:
		var fr: int = first[prof]
		check(D.special_share("gallspitter", fr - 1, prof) == 0.0 and D.special_share("gallspitter", fr, prof) > 0.0,
			"%s: first Gallspitter round %d (share %.3f)" % [prof, fr, D.special_share("gallspitter", fr, prof)])
	var e12: float = D.spawn_share("gallspitter", 12, "easy")
	var m12: float = D.spawn_share("gallspitter", 12, "medium")
	var h12: float = D.spawn_share("gallspitter", 12, "hard")
	check(e12 < m12 and m12 <= h12 and h12 <= 0.075 and D.spawn_share("gallspitter", 6, "hard") > D.spawn_share("gallspitter", 6, "medium"),
		"r12 share easy %.3f < medium %.3f <= hard %.3f (<= 7.5%%); r6 hard > medium" % [e12, m12, h12])
	# the other specials keep their balance: unchanged on easy / medium, hard only pays its share of the walker floor
	var before := {"easy": {"crawler": 0.070, "bloated": 0.060, "riot": 0.050}, "medium": {"crawler": 0.120, "bloated": 0.100, "riot": 0.090},
		"hard": {"crawler": 0.122, "bloated": 0.105, "riot": 0.096}}
	for prof in before:
		var worst := 0.0
		for k in before[prof]:
			worst = maxf(worst, absf(D.spawn_share(k, 12, prof) - float(before[prof][k])))
		check(worst <= 0.004, "%s r12: crawler / bloated / riot shares within 0.004 of before the Gallspitter (worst %.4f)" % [prof, worst])
	var hw: Dictionary = D.spawn_weights(12, "hard")
	check(absf(float(hw.city) - 0.25) < 0.005, "hard r12: walker floor still 25%% (%.3f), Gallspitter pays its share" % float(hw.city))
	var hit_g := false
	for i in 400:
		hit_g = hit_g or D.pick_spawn_variant(10, (i + 0.5) / 400.0, "hard") == "gallspitter"
	check(hit_g, "Difficulty.pick_spawn_variant spawns Gallspitters (hard r10)")


# ------------------------------------------------------------------ contract

func _contract_checks() -> void:
	await _clear()
	_place_player(Vector3(30, 0.1, -25), true)
	check(TP.spawn({"type_id": &"nope", "pos": Vector3.ZERO}) == null, "spawn(): unknown type -> null")
	var n0: int = TP.spawned_total
	var p = _spawn_glob(Vector3(30, 1.5, -10), Vector3(31, 0.5, -10), {"seed": 42, "owner_id": 1234})
	check(p != null and p.get_script() == TP and p.type_id == &"bile_glob" and p.variant == &"" and p.rarity == 0 and p.seed_value == 42 and p.owner_id == 1234
		and not p.is_visual_only and TP.spawned_total == n0 + 1 and p.get_parent() == current_scene,
		"spawn(spec): ThrownProjectile with the spec's type_id / variant / rarity / seed / owner_id, under the current scene")
	await wait(secs(1.0))
	# visual-only copy (a co-op client): flies, splashes, leaves the puddle visual, but no damage / slow
	var hp0: int = pl.health
	var vp = _spawn_glob(Vector3(30, 1.5, -14), pl.global_position + Vector3(0, 0.5, 0), {"visual_only": true})
	var got_hit := [false, null]
	vp.impacted.connect(func(pp, _w, hitp): got_hit[0] = hitp != null; got_hit[1] = pp.hazard)
	for i in secs(1.6):
		await physics_frame
		pl.global_position = Vector3(30, 0.1, -25)
	await wait(secs(1.2))
	var puddle = got_hit[1]
	check(got_hit[0] and pl.health == hp0 and PS.move_mult(pl) == 1.0 and puddle != null and is_instance_valid(puddle) and puddle.is_visual_only,
		"is_visual_only: the copy reaches the player (hit %s) and leaves a puddle visual, but no damage (%d -> %d) and no slow" % [got_hit[0], hp0, pl.health])
	await _clear()


# ------------------------------------------------------------------ projectile

func _projectile_checks() -> void:
	await _clear()
	for r in [8.0, 14.0, 22.0]:
		var from := Vector3(28, 1.45, -6)
		var to := from + Vector3(0, -0.95, -r)
		var v: Vector3 = TP.lob_velocity(from, to)
		var t: float = r / 9.0
		var pts: PackedVector3Array = TP.lob_points(from, v, t)
		var apex := 0.0
		for q in pts:
			apex = maxf(apex, q.y - from.y)
		check(is_equal_approx(Vector2(v.x, v.z).length(), 9.0) and pts[pts.size() - 1].distance_to(to) < 0.01 and t >= 0.85 and t <= 2.5 and apex <= 4.5,
			"lob %.0f m: 9 m/s horizontal, lands on the aim, flight %.2f s (0.9-2.4), apex %.1f m" % [r, t, apex])
	# direct hit on a player standing still, at 8 / 14 / 22 m
	for r in [8.0, 14.0, 22.0]:
		await _clear()
		var ppos := Vector3(28, 0.1, -28)
		_place_player(ppos, true)
		await wait(2)
		var hp0: int = pl.health
		var from := ppos + Vector3(0, 1.35, r)
		var p = _spawn_glob(from, ppos + Vector3(0, 0.5, 0))
		var res := [null, Vector3.INF]
		p.impacted.connect(func(_p, w, hitp): res[0] = hitp; res[1] = w)
		for i in secs(r / 9.0 + 0.6):
			await physics_frame
			pl.global_position = ppos
		check(res[0] == pl and pl.health <= hp0 - 14, "standing still at %.0f m: direct hit, %d HP (%d -> %d)" % [r, hp0 - pl.health, hp0, pl.health])
	# dodge: a player who starts strafing at walk speed only after the release (0.3 s late, worst case) is never hit,
	# and is out of the puddle when it lands
	for r in [8.0, 14.0, 22.0]:
		await _clear()
		var ppos := Vector3(28, 0.1, -28)
		_place_player(ppos, true)
		await wait(2)
		var hp0: int = pl.health
		var from := ppos + Vector3(0, 1.35, r)
		var p = _spawn_glob(from, ppos + Vector3(0, 0.5, 0))
		var res := [null, Vector3.INF]
		p.impacted.connect(func(_p, w, hitp): res[0] = hitp; res[1] = w)
		var walked := 0.0
		var flight: float = r / 9.0
		for i in secs(flight + 1.5):
			await physics_frame
			var t := float(i + 1) / 60.0
			if t > 0.3:
				walked += 5.0 / 60.0
			pl.global_position = ppos + Vector3(walked, 0, 0)
		var land_off := VC_flat(res[1], ppos + Vector3(_walk_at(flight), 0, 0))
		check(res[0] == null and pl.health == hp0 and res[1] != Vector3.INF,
			"strafing at 5 m/s from 0.3 s after the release at %.0f m: dodged (no direct hit, no puddle damage, %d HP), landed %.1f m from the player" % [r, hp0 - pl.health, land_off])
	await _clear()


func _trace(z: Node, t: float) -> void:
	var tg: Node3D = z.target
	print("TRACE t %.0f mode %s good %s pos %s tgt %s d %.1f spot %s pi %d/%d cd %.1f spits %d" % [t, z.mode_name(), z._good, z.global_position.snapped(Vector3.ONE * 0.1),
		tg.name if tg else "-", VC_flat(z.global_position, tg.global_position) if tg else -1.0, z.spot, z._pi, z._path.size(), z._cd, z.spits])


func _walk_at(t: float) -> float:
	return maxf(t - 0.3, 0.0) * 5.0


func VC_flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


# ------------------------------------------------------------------ puddle

func _puddle_checks() -> void:
	await _clear()
	var ppos := Vector3(28, 0.1, -28)
	_place_player(ppos, true)
	await wait(2)
	var hp0: int = pl.health
	var from := ppos + Vector3(0, 1.35, 10)
	var p = _spawn_glob(from, ppos + Vector3(1.6, 0.0, 0)) # lands 1.6 m beside the player: no direct hit, inside the puddle
	var res := [null, null]
	p.impacted.connect(func(pp, _w, hitp): res[0] = hitp; res[1] = pp.hazard)
	for i in secs(10.0 / 9.0 + 0.3):
		await physics_frame
		pl.global_position = ppos
	var puddle = res[1]
	check(res[0] == null and puddle != null and is_instance_valid(puddle), "a near miss leaves a gall puddle")
	if puddle == null or not is_instance_valid(puddle):
		return
	await wait(2)
	check(is_equal_approx(PS.move_mult(pl), 0.75), "inside the puddle: player speed x%.2f (25%% slow)" % PS.move_mult(pl))
	for i in secs(4.2):
		await physics_frame
		pl.global_position = ppos
	var lost: int = hp0 - pl.health
	var dps := float(TP.type_def(&"bile_glob").impact.dps)
	check(lost >= int(dps * 3.5) and lost <= int(dps * 4.0) + 2, "standing in it for its 4 s: %d HP (DoT %.0f/s)" % [lost, dps])
	check(not is_instance_valid(puddle), "the puddle is gone after 4 s")
	await wait(secs(0.5))
	check(is_equal_approx(PS.move_mult(pl), 1.0), "slow ends with the puddle")
	# two puddles on top of each other (two Gallspitters, same spot) must not double the DoT
	await _clear()
	_place_player(ppos, true)
	var hp2: int = pl.health
	var imp: Dictionary = TP.type_def(&"bile_glob").impact
	var Hz = load("res://scripts/projectiles/gall_puddle.gd")
	Hz.spawn(current_scene, ppos + Vector3(0.5, 0, 0), imp, TP.type_def(&"bile_glob"), null, false)
	Hz.spawn(current_scene, ppos + Vector3(-0.5, 0, 0), imp, TP.type_def(&"bile_glob"), null, false)
	for i in secs(4.5):
		await physics_frame
		pl.global_position = ppos
	var lost2: int = hp2 - pl.health
	check(lost2 >= int(dps * 3.5) and lost2 <= int(dps * 4.0) + 2, "two overlapping puddles for 4 s: %d HP, same as one (no stacking)" % lost2)
	# a player standing 3 m away is unaffected
	await _clear()
	_place_player(ppos, true)
	var hp1: int = pl.health
	var p3 = _spawn_glob(from, ppos + Vector3(3.2, 0.0, 0))
	for i in secs(10.0 / 9.0 + 2.0):
		await physics_frame
		pl.global_position = ppos
	check(pl.health == hp1 and is_equal_approx(PS.move_mult(pl), 1.0), "3.2 m from the impact: outside the 2.5 m puddle, untouched")
	await _clear()


# ------------------------------------------------------------------ placeholder / spawn path

func _placeholder_checks() -> void:
	await _clear()
	_place_player(Vector3(30, 0.1, -28), true)
	var z = _spawn(Vector3(30, 0.1, -10))
	await wait(3)
	check(z.get_script().resource_path == SPITTER and z.variant_id == "gallspitter" and z.is_in_group("gallspitters"),
		"main.make_zombie(vid gallspitter): gallspitter.gd, variant data applied without the GLB")
	var walker = ZOMBIE.instantiate()
	walker.setup(100, 3.2, 10)
	check(z.contact_damage < 10 and z.max_health < 100 and is_equal_approx(z.model_height, float(ZombieVariants.get_variant("gallspitter").model_height)),
		"weak: swipe %d (walker 10), HP %d (walker 100), %.3f m tall" % [z.contact_damage, z.max_health, z.model_height])
	walker.free()
	var glb := ResourceLoader.exists("res://assets/models/zombies/gallspitter.glb")
	check(z.placeholder == not glb, "placeholder model while gallspitter.glb is missing (glb present: %s)" % glb)
	var ok_nodes := true
	for n in ["HeadPoint", "ProjectileSpawn", "Chest"]:
		ok_nodes = ok_nodes and z.model_root.find_child(n, true, false) != null
	check(ok_nodes and z.head_hitbox != null and z.head_hitbox.collision_layer == 32, "sockets HeadPoint / ProjectileSpawn / Chest, head hitbox (Head bone) on layer 32")
	var ap: AnimationPlayer = z._anim
	var clips_ok := ap != null
	for c in ["Idle", "Walk", "Spit", "Hit", "Death"]:
		clips_ok = clips_ok and ap.has_animation(c)
	check(clips_ok and is_equal_approx(ap.get_animation("Spit").length, 1.1) and ap.get_animation("Spit").has_marker("release")
		and is_equal_approx(ap.get_animation("Spit").get_marker_time("release"), 0.7) and is_equal_approx(z._release_at, 0.7) and is_equal_approx(z._spit_len, 1.1),
		"clips Idle / Walk / Spit (1.1 s, release marker 0.7) / Hit / Death; the spit times come from the clip")
	var mouth: Vector3 = z.mouth_pos() - z.global_position
	check(mouth.y > 1.0 and mouth.y < 1.75, "ProjectileSpawn at mouth height %.2f m (hunched idle)" % mouth.y)
	check(z._sac_mats.size() > 0, "GallSac material(s) wired to the wind-up glow (%d)" % z._sac_mats.size())
	await _clear()


# ------------------------------------------------------------------ keep range / telegraph / retreat / no stall

func _keep_range_checks() -> void:
	await _clear()
	var ppos := Vector3(-30, 0.1, -26)
	_place_player(ppos, true)
	pl.set("invulnerable_t", 1.0e9)
	var z = _spawn(Vector3(-30, 0.1, 8))
	var tele := {"start": -1.0, "release": -1.0}
	var clock := [0.0]
	z.spit_started.connect(func(_s, _t): if tele.start < 0.0: tele.start = clock[0])
	z.spit_released.connect(func(_s, _p, _i): if tele.release < 0.0: tele.release = clock[0])
	var still := 0.0
	var worst_still := 0.0
	var last_pos: Vector3 = z.global_position
	var in_band_t := 0.0
	var sample_tele := 0.0
	for i in secs(22.0):
		await physics_frame
		clock[0] += 1.0 / 60.0
		pl.global_position = ppos
		if z.wants_move() and z.global_position.distance_to(last_pos) < STILL_EPS:
			still += 1.0 / 60.0
		else:
			still = 0.0
			last_pos = z.global_position
		worst_still = maxf(worst_still, still)
		var d := VC_flat(z.global_position, ppos)
		if clock[0] > 12.0 and d >= 8.0 and d <= 22.5:
			in_band_t += 1.0 / 60.0
		if tele.start >= 0.0 and tele.release < 0.0:
			sample_tele = maxf(sample_tele, z.telegraph())
		if OS.get_cmdline_user_args().has("--trace") and i % 60 == 0:
			print("TRACE t %.0f mode %s good %s pos %s d %.1f spot %s pi %d/%d cd %.1f safe %s vel %s avoid %s susp %s" % [clock[0], z.mode_name(), z._good, z.global_position.snapped(Vector3.ONE * 0.1), d, z.spot, z._pi, z._path.size(), z._cd, z.nav._safe, z.velocity, z.nav._avoid_on, z.nav.suspended])
	var d_end := VC_flat(z.global_position, ppos)
	check(z.spits >= 2, "keeps range: spat %d times in 22 s at a stationary player (start 34 m away)" % z.spits)
	check(in_band_t >= 9.5, "holds 8-22 m after it got there (%.1f of the last 10 s in band, now %.1f m, mode %s)" % [in_band_t, d_end, z.mode_name()])
	check(tele.start >= 0.0 and tele.release - tele.start >= 0.69 and sample_tele > 0.8,
		"telegraph: release %.2f s after the wind-up starts (>= 0.7), glow ramps to %.2f" % [tele.release - tele.start, sample_tele])
	check(worst_still < STILL_MAX, "no nav stall: longest stand-still while it wanted to move %.1f s (< %.0f)" % [worst_still, STILL_MAX])
	# rush it: the player walks straight at it at 5 m/s
	var r0: int = z.retreats
	var min_d := INF
	var d_start := VC_flat(z.global_position, pl.global_position)
	var ppos2 := pl.global_position
	for i in secs(6.0):
		await physics_frame
		var to: Vector3 = z.global_position - ppos2
		to.y = 0.0
		if to.length() > 1.5:
			ppos2 += to.normalized() * 5.0 / 60.0
		pl.global_position = ppos2
		min_d = minf(min_d, VC_flat(z.global_position, ppos2))
		if z.wants_move() and z.global_position.distance_to(last_pos) < STILL_EPS:
			still += 1.0 / 60.0
		else:
			still = 0.0
			last_pos = z.global_position
		worst_still = maxf(worst_still, still)
	check(z.retreats > r0, "rushed from %.1f m: it backs off (%d retreats), closest %.1f m" % [d_start, z.retreats - r0, min_d])
	check(worst_still < STILL_MAX, "no stall while retreating (%.1f s)" % worst_still)
	await _clear()


# ------------------------------------------------------------------ camping priority

func _camp_checks() -> void:
	await _clear()
	var center := Vector3(28, 0.1, -20)
	_place_player(center + Vector3(5, 0, 0), true)
	pl.set("invulnerable_t", 1.0e9)
	var camper := _fake_player(Vector3(6, 0.1, -27))
	var z = _spawn(Vector3(30, 0.1, -4))
	var early_target: Node = null
	var st := {"t": 0.0, "first": null}
	z.spit_released.connect(func(_s, _p, info): if st.t > 7.0 and st.first == null: st.first = info.target)
	for i in secs(18.0):
		await physics_frame
		st.t += 1.0 / 60.0
		var a: float = st.t * 1.2 # the real player keeps moving: a 5 m circle never stays inside the 3.5 m camp radius
		pl.global_position = center + Vector3(cos(a), 0, sin(a)) * 5.0
		camper.global_position = Vector3(6, 0.1, -27)
		if early_target == null and st.t >= 3.0:
			early_target = z.target
		if OS.get_cmdline_user_args().has("--trace") and i % 60 == 0:
			_trace(z, st.t)
	var first_shot_at: Node = st.first
	for i in secs(2.5): # let the last glob land
		await physics_frame
		camper.global_position = Vector3(6, 0.1, -27)
	check(early_target == pl, "before anyone camps it takes the nearest player (%s)" % [early_target.name if early_target else "none"])
	check(G.camp_time(camper) >= 6.0 and G.camp_time(pl) < 6.0, "camp tracker: camper %.1f s, moving player %.1f s" % [G.camp_time(camper), G.camp_time(pl)])
	check(z.target == camper and bool(z.last_pick.get("camping", false)), "after 6 s the camper (%.0f m) outranks the nearer moving player (%.0f m)"
		% [VC_flat(camper.global_position, z.global_position), VC_flat(pl.global_position, z.global_position)])
	check(first_shot_at == camper and camper.damage_taken > 0.0, "and gets spat at (%s): %.0f HP taken standing still" % [first_shot_at.name if first_shot_at else "no shot", camper.damage_taken])
	await _clear()


# ------------------------------------------------------------------ perch (melee can't reach)

func _perch_checks() -> void:
	await _clear()
	var region: NavigationRegion3D = main.nav_region
	var tower := StaticBody3D.new()
	tower.name = "TestPerch"
	tower.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(3, 3, 3)
	cs.shape = bs
	tower.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = bs.size
	mi.mesh = bm
	tower.add_child(mi)
	region.add_child(tower)
	tower.global_position = Vector3(-29, 1.5, 24)
	region.bake_navigation_mesh(false)
	await wait(2)
	await _wait_bake(region)
	var top := Vector3(-29, 3.05, 24)
	_place_player(Vector3(-29, 0.1, -10), true) # the real player: on the ground, nearer
	pl.set("invulnerable_t", 1.0e9)
	var perched := _fake_player(top)
	var z = _spawn(Vector3(-29, 0.1, 2))
	var walker = ZOMBIE.instantiate()
	walker.setup(100, 3.2, 10)
	main.zombies_root.add_child(walker)
	walker.global_position = Vector3(-24, 0.1, 18)
	walker.target = perched
	await wait(secs(0.6))
	check(z.melee_unreachable(perched) and not z.melee_unreachable(pl), "perch on a 3 m block: unreachable for melee, the ground player isn't")
	var shots := {"n": 0}
	z.spit_released.connect(func(_s, _p, info): if info.target == perched: shots.n += 1)
	var best_walker := INF
	for i in secs(14.0):
		await physics_frame
		pl.global_position = Vector3(-29, 0.1, -10) + Vector3(sin(i / 60.0) * 4.0, 0, 0)
		perched.global_position = top
		walker.target = perched
		best_walker = minf(best_walker, VC_flat(walker.global_position, top) if absf(walker.global_position.y - top.y) < 1.2 else INF)
	check(z.target == perched and bool(z.last_pick.get("unreachable", false)), "it targets the perched player over the nearer ground player")
	check(int(shots.n) >= 1 and perched.damage_taken > 0.0, "and lobs up onto the perch (%d spits, %.0f HP)" % [int(shots.n), perched.damage_taken])
	check(best_walker == INF, "a walker can't get up there (why the Gallspitter is the counter)")
	tower.queue_free()
	walker.queue_free()
	await wait(2)
	region.bake_navigation_mesh(false)
	await wait(2)
	await _wait_bake(region)
	await _clear()


# ------------------------------------------------------------------ stagger / melee

func _stagger_and_melee_checks() -> void:
	await _clear()
	var ppos := Vector3(30, 0.1, -28)
	_place_player(ppos, true)
	pl.set("invulnerable_t", 1.0e9)
	var z = _spawn(Vector3(30, 0.1, -16))
	var started := [false]
	z.spit_started.connect(func(_s, _t): started[0] = true)
	for i in secs(6.0):
		await physics_frame
		pl.global_position = ppos
		if started[0] and z.mode_name() == "spit" and z.telegraph() > 0.2:
			break
	var s0: int = z.spits
	var c0: int = z.cancelled_spits
	z.take_damage(z.max_health * 0.3, z.head_center(), false, pl)
	await wait(secs(0.8))
	check(started[0] and z.cancelled_spits == c0 + 1 and z.spits == s0 and not z._dead, "a heavy hit (30%% HP) during the wind-up chokes the spit")
	# cornered (no standpoint to back off to: retreat off for this one): in arm's reach it swipes, for half a walker's damage
	await _clear()
	_place_player(Vector3(30, 0.1, -28), true)
	var z2 = _spawn(Vector3(30, 0.1, -27))
	z2.b = z2.b.duplicate()
	z2.b["retreat_range"] = 0.0
	z2.b["engage_min"] = 50.0 # and no spot to shoot from
	var hp0: int = pl.health
	for i in secs(3.0):
		await physics_frame
		pl.global_position = Vector3(30, 0.1, -28)
	check(pl.health < hp0 and (hp0 - pl.health) % z2.contact_damage == 0 and z2.contact_damage <= 5,
		"cornered it swipes weakly: %d HP in 3 s (%d per swipe)" % [hp0 - pl.health, z2.contact_damage])
	await _clear()
