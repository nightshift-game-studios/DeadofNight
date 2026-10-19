extends SceneTree
## Zombie variants (art pass 3, Skillz): Bloater / Crawler / Riot behaviour scripts, spawn weights per difficulty,
## Crawler body + health-bar height, Riot cone / armour math, Bloater burst friendly fire + puddle, PlayerStatus.
##   godot --headless --path . -s res://tests/variants_test.gd   (exit code = failures)
## Uses a stub player (group "player"); the real player.gd needs MAIN_HOOKS §15b for root / slow to move it.

const ZOMBIE := preload("res://scenes/enemy.tscn")
const PS := preload("res://scripts/combat/player_status.gd")
var VC # loaded in _run (preloading here would compile Explosion before the GearDB autoload exists)
var RiotScr

var _fails := 0
var _passes := 0
var world: Node3D
var pl: CharacterBody3D
var D


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


func frames(n: int) -> void:
	for i in n:
		await physics_frame


func secs(t: float) -> void:
	var end := Time.get_ticks_msec() + int(t * 1000.0)
	while Time.get_ticks_msec() < end:
		await physics_frame


func _player_stub() -> CharacterBody3D:
	var gs := GDScript.new()
	gs.source_code = """extends CharacterBody3D
var dead := false
var health := 100.0
var hits := 0
var pierce := 0.0
func take_damage(amount, _attacker = null):
	health -= float(amount)
	hits += 1
func mod_stat(stat, base, _ctx = {}):
	return pierce if str(stat) == "armor_pierce" else base
"""
	gs.reload()
	var p: CharacterBody3D = gs.new()
	p.name = "StubPlayer"
	p.add_to_group("player")
	p.collision_layer = 0
	p.collision_mask = 0
	return p


func _shooter(pos: Vector3, pierce: float = 0.0) -> Node3D:
	var gs := GDScript.new()
	gs.source_code = "extends Node3D\nvar pierce := 0.0\nfunc mod_stat(stat, base, _ctx = {}):\n\treturn pierce if str(stat) == \"armor_pierce\" else base\n"
	gs.reload()
	var s: Node3D = gs.new()
	s.pierce = pierce
	world.add_child(s)
	s.global_position = pos
	return s


func _z(vid: String, pos: Vector3, hp: int = 100) -> Node:
	var z = ZOMBIE.instantiate()
	ZombieVariants.apply_script(z, vid)
	z.setup(hp, 3.0, 10)
	z.set_variant(vid, ZombieVariants.get_variant(vid), ZombieVariants.scene(vid))
	z.position = pos # before add_child: never parked at the origin for a frame (it would stack on whatever is there)
	world.add_child(z)
	return z


func _run() -> void:
	D = load("res://scripts/world/difficulty.gd")
	VC = load("res://scripts/enemies/variants/variant_common.gd")
	RiotScr = load("res://scripts/enemies/variants/riot.gd")
	world = Node3D.new()
	root.add_child(world)
	var floor_body := StaticBody3D.new()
	var fs := CollisionShape3D.new()
	var bx := BoxShape3D.new()
	bx.size = Vector3(80, 1, 80)
	fs.shape = bx
	fs.position.y = -0.5
	floor_body.add_child(fs)
	world.add_child(floor_body)
	pl = _player_stub()
	world.add_child(pl)
	pl.global_position = Vector3(0, 0, 30)
	pl.dead = true # parked: zombies ignore it until a test brings it close

	_data()
	_weights()
	await _crawler()
	await _riot()
	await _bloater()
	await _burst_table()
	_player_status()

	world.queue_free()
	await frames(2)
	print("variants_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


# ------------------------------------------------------------------ data
func _data() -> void:
	check(ZombieVariants.ids().size() == 6, "zombies.json: 6 variants (%s)" % [ZombieVariants.ids()])
	for id in ["bloated", "crawler", "riot"]:
		var v := ZombieVariants.get_variant(id)
		check(bool(v.get("special")) and ResourceLoader.exists(ZombieVariants.script_path(id)) and ZombieVariants.scene(id) != null
			and not ZombieVariants.behavior(id).is_empty(), "%s: special, script %s, model, behavior knobs" % [id, ZombieVariants.script_path(id).get_file()])
		var in_mix := false
		for e in ZombieVariants.data().get("wave_mix", []):
			in_mix = in_mix or e.get("weights", {}).has(id)
		check(not in_mix, "%s is not in the regular wave_mix (only difficulty.json specials spawn it)" % id)
	check(not ZombieVariants.allows_runner("bloated") and ZombieVariants.allows_runner("crawler") and ZombieVariants.allows_runner("")
		and ZombieVariants.allows_runner("city"), "runner bonus: never on Bloaters")
	var z = ZOMBIE.instantiate()
	check(not ZombieVariants.apply_script(z, "city") and not ZombieVariants.apply_script(z, "") and z.get_script().resource_path == "res://scripts/enemy.gd",
		"apply_script leaves walkers on enemy.gd")
	check(ZombieVariants.apply_script(z, "riot") and z.get_script().resource_path.ends_with("riot.gd") and z.models.size() == 1
		and is_equal_approx(z.model_height, 1.795), "apply_script swaps in riot.gd and keeps the scene's models / height")
	z.free()


# ------------------------------------------------------------------ spawn weights
func _weights() -> void:
	var first := {"easy": {"crawler": 3, "bloated": 4, "riot": 8}, "medium": {"crawler": 5, "bloated": 5, "riot": 5},
		"hard": {"crawler": 2, "bloated": 3, "riot": 4}}
	for prof in first:
		for vid in first[prof]:
			var fr: int = first[prof][vid]
			check(D.special_share(vid, fr - 1, prof) == 0.0 and D.special_share(vid, fr, prof) > 0.0,
				"%s: %s from round %d (%.3f), none in round %d" % [prof, vid, fr, D.special_share(vid, fr, prof), fr - 1])
	for n in [1, 5, 8, 12, 20, 40]:
		for prof in ["easy", "medium", "hard"]:
			var w: Dictionary = D.spawn_weights(n, prof)
			var tot := 0.0
			var sp := 0.0
			for k in w:
				tot += float(w[k])
				if bool(ZombieVariants.get_variant(k).get("special", false)):
					sp += float(w[k])
			var walker := float(w.get("city", 0.0))
			var max_sp := 0.0
			for k in ["bloated", "crawler", "riot"]:
				max_sp = maxf(max_sp, float(w.get(k, 0.0)))
			check(absf(tot - 1.0) < 1e-4 and sp <= 0.41 and 1.0 - sp >= 0.59 and walker > max_sp,
				"%s r%d: shares sum 1, specials %.2f, regular walkers %.2f stay the bulk (city %.2f > any special %.2f)" % [prof, n, sp, 1.0 - sp, walker, max_sp])
	for vid in ["bloated", "crawler", "riot"]:
		var e: float = D.spawn_share(vid, 12, "easy")
		var m: float = D.spawn_share(vid, 12, "medium")
		var h: float = D.spawn_share(vid, 12, "hard")
		check(e < m and m <= h + 1e-6, "round 12 %s share easy %.3f < medium %.3f <= hard %.3f" % [vid, e, m, h])
		check(D.spawn_share(vid, 6, "hard") > D.spawn_share(vid, 6, "medium"), "round 6 %s: hard %.3f > medium %.3f (sooner, ramps faster)" % [vid, D.spawn_share(vid, 6, "hard"), D.spawn_share(vid, 6, "medium")])
	check(D.spawn_share("bloated", 30, "easy") <= 0.06 + 1e-6 and D.spawn_share("crawler", 30, "hard") <= 0.14 + 1e-6, "shares cap at max")
	# tuning pass: Hard round 12 plain walkers ~25% (pulled from Soldiers + specials)
	var hw: Dictionary = D.spawn_weights(12, "hard")
	var hsp: float = float(hw.get("bloated", 0.0)) + float(hw.get("crawler", 0.0)) + float(hw.get("riot", 0.0))
	print("HARD_MIX_R12 ", JSON.stringify(hw))
	check(absf(float(hw.city) - 0.25) <= 0.005 and hsp <= 0.33 and float(hw.soldier) < 0.29 and float(hw.soldier) > D.spawn_share("soldier", 12, "medium"),
		"hard r12: walkers %.3f (~25%%), soldiers %.3f (> medium), workers %.3f, specials %.3f" % [hw.city, hw.soldier, hw.worker, hsp])
	var fl := {"city": 0.1, "soldier": 0.5, "worker": 0.2, "riot": 0.2}
	D._apply_floors(fl, {"city": {"share": 0.25, "from": ["soldier", "riot"]}})
	check(is_equal_approx(fl.city, 0.25) and is_equal_approx(fl.worker, 0.2) and is_equal_approx(fl.soldier, 0.5 * (1.0 - 0.15 / 0.7))
		and is_equal_approx(fl.city + fl.soldier + fl.worker + fl.riot, 1.0), "share_floor: lifts city to 25%, paid pro rata by the listed variants only")
	var e12: Dictionary = D.spawn_weights(12, "easy")
	check(float(e12.city) > 0.25, "share_floor is Hard-only (easy r12 walkers %.3f already above)" % e12.city)
	# picks: the regular pick never returns a special; pick_spawn_variant follows the shares
	var regular_only := true
	for i in 200:
		regular_only = regular_only and not bool(ZombieVariants.get_variant(D.pick_variant(15, i / 200.0, "hard")).get("special", false))
	check(regular_only, "Difficulty.pick_variant (live main.gd without §15a) never spawns a special")
	var counts := {}
	var N := 2000
	for i in N:
		var v: String = D.pick_spawn_variant(10, (i + 0.5) / N, "hard")
		counts[v] = counts.get(v, 0) + 1
	var w10: Dictionary = D.spawn_weights(10, "hard")
	var close := true
	for k in w10:
		close = close and absf(float(counts.get(k, 0)) / N - float(w10[k])) < 0.002
	check(close, "pick_spawn_variant over an rng sweep matches spawn_weights (hard r10 %s)" % [counts])
	check(D.pick_spawn_variant(1, 0.99, "easy") != "" and D.spawn_share("riot", 7, "easy") == 0.0, "easy round 1 / 7: no Riot")


# ------------------------------------------------------------------ crawler
func _crawler() -> void:
	var walker = _z("city", Vector3(10, 0, -10))
	var c = _z("crawler", Vector3(0, 0, 0))
	await frames(2)
	var cap: CapsuleShape3D = VC.capsule(c)
	var wcap: CapsuleShape3D = VC.capsule(walker)
	var cs := c.get_node("CollisionShape3D") as CollisionShape3D
	check(is_equal_approx(cap.radius, 0.3) and is_equal_approx(cap.height, 0.7) and is_equal_approx(cs.position.y, 0.35),
		"crawler capsule r %.2f h %.2f at y %.2f" % [cap.radius, cap.height, cs.position.y])
	check(cap != wcap and is_equal_approx(wcap.height, 1.8) and is_equal_approx(wcap.radius, 0.35), "walker capsule untouched (r 0.35 h 1.8, not shared)")
	check(is_equal_approx(c.health_bar.position.y, 0.95) and is_equal_approx(walker.health_bar.position.y, walker.model_height - 0.14),
		"crawler health bar at %.2f m (walker %.2f m)" % [c.health_bar.position.y, walker.health_bar.position.y])
	check(c.max_health == 60 and c.speed > walker.speed and c.model_height < walker.model_height, "crawler: low HP (60), faster, smaller")
	check(c.head_hitbox != null, "crawler: head hitbox on its Head bone (normal headshot multiplier)")
	# grab
	pl.dead = false
	pl.health = 100.0
	pl.global_position = Vector3(0, 0, -1.0)
	c.rotation.y = 0.0
	await frames(3)
	check(c.grab_state == "lunge", "player within 1.2 m -> lunge (state %s)" % c.grab_state)
	check(VC.node(c, "GrabPoint") != null, "GrabPoint present (hand_r)")
	await secs(0.45)
	check(c.grab_state == "held" and PS.is_rooted(pl) and PS.move_mult(pl) == 0.0, "after the grip delay: held, player rooted (move_mult 0)")
	pl.velocity = Vector3(5, 3, 2)
	check(PS.pin(pl) and pl.velocity == Vector3(0, 3, 0), "pin(): horizontal velocity zeroed, jump velocity kept")
	await secs(0.8)
	check(pl.health < 100.0 and c.grab_drained > 0, "HP drains while held (%d drained in ~0.8 s)" % c.grab_drained)
	root.get_node("GameEvents").emit_event(&"jumped", {"player": pl})
	check(c.grab_state == "" and c.last_release == "jump" and not PS.is_rooted(pl), "a jump frees the player")
	check(c.grab_cd > 5.5, "grab cooldown %.1f s" % c.grab_cd)
	await frames(10)
	check(c.grab_state == "", "no re-grab during the cooldown")
	c.grab_cd = 0.0
	await frames(3)
	await secs(0.45)
	check(c.grab_state == "held", "grabs again after the cooldown")
	root.get_node("GameEvents").emit_event(&"melee_swung", {"player": pl})
	await frames(2)
	check(c.grab_state == "held" and PS.is_rooted(pl), "a melee swing that misses the crawler doesn't free the player")
	var shooter_m := _shooter(Vector3(0, 1.5, -20))
	c.take_damage(3.0, c.global_position + Vector3(0, 0.4, 0), false, shooter_m)
	check(c.grab_state == "held", "...nor does a bullet hit")
	VC.mark_melee()
	c.take_damage(5.0, c.global_position + Vector3(0, 0.4, 0), false, pl)
	check(c.grab_state == "" and c.last_release == "melee" and not PS.is_rooted(pl) and not c._dead, "a melee hit on the crawler frees the player")
	# timeout at grab_time (2 s)
	c.grab_cd = 0.0
	pl.health = 100.0
	await secs(0.45)
	var t0 := Time.get_ticks_msec()
	while c.grab_state != "" and Time.get_ticks_msec() - t0 < 3500:
		await physics_frame
	var held_s := (Time.get_ticks_msec() - t0) / 1000.0
	check(c.last_release == "timeout" and held_s > 1.6 and held_s < 2.6 and not PS.is_rooted(pl),
		"lets go after grab_time (%.2f s held, %d HP drained, ~6/s)" % [held_s, c.grab_drained])
	check(c.grab_drained >= 9 and c.grab_drained <= 14, "drain ~6 HP/s over 2 s (%d)" % c.grab_drained)
	# kill frees
	c.grab_cd = 0.0
	await secs(0.45)
	check(c.grab_state == "held", "held once more")
	c.take_damage(500.0, Vector3.ZERO, false, null)
	check(c.grab_state == "" and c.last_release == "killed" and not PS.is_rooted(pl), "killing it frees the player")
	pl.dead = true
	pl.global_position = Vector3(0, 0, 30)
	walker.queue_free()
	await frames(2)


# ------------------------------------------------------------------ riot
func _riot() -> void:
	var f := Vector3(0, 0, -1)
	check(RiotScr.is_frontal(f, Vector3(0, 0, -5), 100.0) and RiotScr.is_frontal(f, Vector3(sin(deg_to_rad(49)), 0, -cos(deg_to_rad(49))), 100.0)
		and RiotScr.is_frontal(f, Vector3(sin(deg_to_rad(50)), 0, -cos(deg_to_rad(50))), 100.0)
		and not RiotScr.is_frontal(f, Vector3(sin(deg_to_rad(51)), 0, -cos(deg_to_rad(51))), 100.0)
		and not RiotScr.is_frontal(f, Vector3(1, 0, 0), 100.0) and not RiotScr.is_frontal(f, Vector3(0, 0, 3), 100.0)
		and RiotScr.is_frontal(f, Vector3(0, 4, 0), 100.0) and RiotScr.is_frontal(f, Vector3(0.3, 5, -1), 100.0),
		"cone math: 100 deg = +/-50 deg frontal (49/50 in, 51 / side / back out; height ignored)")
	var b := ZombieVariants.behavior("riot")
	check(is_equal_approx(RiotScr.reduction_for("bullet", true, b), 0.8) and RiotScr.reduction_for("bullet", false, b) == 0.0
		and is_equal_approx(RiotScr.reduction_for("explosive", true, b), 0.4) and RiotScr.reduction_for("explosive", false, b) == 0.0
		and is_equal_approx(RiotScr.reduction_for("burn", false, b), 0.4) and is_equal_approx(RiotScr.reduction_for("bullet", true, b, 0.3), 0.5),
		"reduction: front 80%, back 0, explosive 40%, burn 40% (any side), armor_pierce 0.3 -> 50%")
	var r = _z("riot", Vector3(0, 0, 0), 1000)
	await frames(2)
	r.rotation.y = 0.0 # faces -Z
	await frames(1)
	check(r.max_health == 1300 and is_equal_approx(r.armor_hp, 975.0), "riot: 1.3x HP (%d), armour HP 0.75x (%.0f)" % [r.max_health, r.armor_hp])
	for n in ["ArmorVest", "Helmet", "Visor", "ArmorLegs", "ArmorFront"]:
		check(VC.node(r, n) != null and VC.node(r, n).visible, "riot node %s visible" % n)
	var front := _shooter(Vector3(0, 1.5, -10))
	var back := _shooter(Vector3(0, 1.5, 10))
	var side := _shooter(Vector3(10, 1.5, 0))
	var hp0: float = r.health
	r.take_damage(100.0, Vector3(0, 1.2, -0.3), false, front)
	check(is_equal_approx(hp0 - r.health, 20.0) and r.last_hit.frontal and is_equal_approx(r.armor_hp, 895.0), "front body hit: 100 -> 20 dealt, 80 off the armour")
	hp0 = r.health
	r.take_damage(250.0, r.head_center(), true, front)
	check(is_equal_approx(hp0 - r.health, 50.0), "front helmet / visor headshot: 250 -> 50")
	hp0 = r.health
	r.take_damage(100.0, Vector3(0, 1.2, 0.3), false, back)
	check(is_equal_approx(hp0 - r.health, 100.0) and not r.last_hit.frontal, "back hit: full damage")
	hp0 = r.health
	r.take_damage(100.0, Vector3(0.3, 1.2, 0), false, side)
	check(is_equal_approx(hp0 - r.health, 100.0), "side hit: full damage")
	hp0 = r.health
	load("res://scripts/combat/explosion.gd").explode(world, Vector3(0, 0.9, -1.0), 4.0, 100.0, 0.0, Color.WHITE, null, null, 0.1)
	var exp_dealt: float = hp0 - r.health
	var raw := 100.0 * (1.0 - 0.7 * (1.0 / 4.0))
	check(r.last_hit.kind == "explosive" and is_equal_approx(exp_dealt, raw * 0.6), "explosive from the front ignores half: %.1f of %.1f dealt (40%% off)" % [exp_dealt, raw])
	hp0 = r.health
	r._status_tick = true
	r.take_damage(10.0, Vector3.ZERO, false, null)
	r._status_tick = false
	check(r.last_hit.kind == "burn" and is_equal_approx(hp0 - r.health, 6.0), "burn tick ignores half: 10 -> 6")
	hp0 = r.health
	r.take_damage(100.0, Vector3(0, 1.2, -0.3), false, _shooter(Vector3(0, 1.5, -8), 0.3))
	check(is_equal_approx(hp0 - r.health, 50.0), "attacker armor_pierce 0.3 (future skills): front hit 100 -> 50")
	# leg break (cosmetic)
	var lh: float = r.leg_hp
	r.take_damage(lh + 1.0, Vector3(0, 0.3, -0.3), false, back)
	check(not r.legs_intact and not VC.node(r, "ArmorLegs").visible and r.armor_intact, "leg hits wear the leg armour off (ArmorLegs hidden), vest stays")
	# armour break
	var broke := [false]
	r.armor_broken.connect(func(_z): broke[0] = true)
	r.take_damage(r.armor_hp / 0.8 + 50.0, Vector3(0, 1.2, -0.3), false, front)
	check(broke[0] and not r.armor_intact and r.armor_hp == 0.0, "armour HP runs out -> armor_broken")
	check(not VC.node(r, "ArmorVest").visible and not VC.node(r, "Helmet").visible and not VC.node(r, "Visor").visible,
		"ArmorVest / Helmet / Visor hidden")
	check(BossArt_clip(r, "armor_break"), "Zombie_ArmorBreak plays")
	hp0 = r.health
	r.take_damage(100.0, Vector3(0, 1.2, -0.3), false, front)
	check(is_equal_approx(hp0 - r.health, 100.0) and r.last_hit.reduction == 0.0, "after the break: front hits do full damage")
	r.queue_free()
	await frames(2)


func BossArt_clip(z: Node, key: String) -> bool:
	var ap = z.get("_anim")
	return ap != null and z._anims.has(key) and ap.current_animation == z._anims[key]


# ------------------------------------------------------------------ bloater
func _bloater() -> void:
	var shooter := _shooter(Vector3(0, 1.5, -40))
	var bl = _z("bloated", Vector3(0, 0, 0))
	await frames(2)
	check(bl.max_health == 160 and bl.speed < 3.0 and VC.node(bl, "Pustules") != null and VC.node(bl, "Pustules").visible
		and VC.node(bl, "BurstPoint") != null, "bloater: 1.6x HP, slow, Pustules visible, BurstPoint")
	# pustules
	for i in 3:
		bl.take_damage(1.0, bl.burst_point() + Vector3(0.1, 0, 0), false, shooter)
	check(not bl.pustules_popped and is_equal_approx(bl.burst_radius(), 3.5), "3 pustule hits: still intact, burst r 3.5")
	bl.take_damage(1.0, bl.burst_point(), false, shooter)
	check(bl.pustules_popped and not VC.node(bl, "Pustules").visible and is_equal_approx(bl.burst_radius(), 2.1), "4th hit pops them: hidden, burst r 2.1")
	bl.queue_free()
	await frames(2)
	# windup burst: friendly fire + player damage + puddle
	var died := [0]
	bl = _z("bloated", Vector3(0, 0, 0))
	bl.died.connect(func(_z): died[0] += 1)
	var near = _z("city", Vector3(1.5, 0, 0))
	var mid = _z("worker", Vector3(0, 0, 2.6), 400)
	var far = _z("city", Vector3(6, 0, 0))
	for z in [near, mid, far]:
		z.speed = 0.0 # stand still for the radius check
	pl.dead = false
	pl.health = 100.0
	pl.global_position = Vector3(-3.0, 0, 0)
	await frames(2)
	var bursts := []
	bl.burst.connect(func(_b, info): bursts.append(info))
	bl.take_damage(1000.0, Vector3(0, 1.0, 0), false, shooter)
	check(bl.burst_state == "windup" and bursts.is_empty() and BossArt_clip(bl, "burst_windup") and died[0] == 1,
		"killed 3 m away by a bullet: Zombie_BurstWindup, no burst yet, died emitted once (normal kill points)")
	await secs(0.4)
	check(bursts.is_empty(), "...still winding up at 0.4 s")
	await secs(0.35)
	check(bursts.size() == 1, "burst after ~0.6 s")
	var info: Dictionary = bursts[0] if bursts.size() else {}
	check(not info.is_empty() and not info.instant and is_equal_approx(info.radius, 3.5) and info.zombie_hits >= 2, "burst r 3.5 from BurstPoint, hit %s zombies" % info.get("zombie_hits"))
	check(is_instance_valid(near) and near.health <= near.max_health * 0.4, "friendly fire: the walker 1.5 m away takes %.0f of %d" % [near.max_health - near.health, near.max_health])
	check(is_instance_valid(mid) and mid.health < mid.max_health and not mid._dead, "the worker 2.6 m away is hurt (%.0f / %d)" % [mid.health, mid.max_health])
	check(is_instance_valid(far) and far.health == far.max_health, "the walker 6 m away is untouched")
	check(pl.health < 100.0 and int(info.get("player_damage", 0)) > 0, "the player 3 m away takes %d" % info.get("player_damage", 0))
	var puddles: Array = get_nodes_in_group("bile_puddles")
	check(puddles.size() == 1 and is_equal_approx(puddles[0].radius, 2.2), "bile puddle r 2.2 left behind")
	pl.global_position = Vector3(0.5, 0, 0.5)
	await frames(3)
	check(puddles[0].player_inside and is_equal_approx(PS.slow_amp(pl), 0.45) and is_equal_approx(PS.move_mult(pl), 0.55), "standing in it: -45% speed")
	pl.global_position = Vector3(-6, 0, 0)
	await secs(0.3)
	check(PS.move_mult(pl) == 1.0, "slow ends shortly after stepping out")
	puddles[0].age = 3.95
	await secs(0.15)
	check(get_nodes_in_group("bile_puddles").is_empty(), "puddle gone after 4 s")
	for z in [mid, far]:
		if is_instance_valid(z):
			z.queue_free()
	# melee kill: instant
	bl = _z("bloated", Vector3(0, 0, 0))
	pl.global_position = Vector3(-2.3, 0, 0)
	await frames(2)
	bursts = []
	bl.burst.connect(func(_b, i): bursts.append(i))
	VC.mark_melee()
	bl.take_damage(1000.0, Vector3(0, 1.2, 0), false, pl)
	await process_frame
	await physics_frame
	check(bursts.size() == 1 and bursts[0].instant, "melee kill skips the windup")
	# kill within 2 m: instant
	bl = _z("bloated", Vector3(0, 0, 0))
	pl.global_position = Vector3(-1.5, 0, 0)
	await frames(2)
	bursts = []
	bl.burst.connect(func(_b, i): bursts.append(i))
	bl.take_damage(1000.0, Vector3(0, 1.2, 0), false, shooter)
	await process_frame
	await physics_frame
	check(bursts.size() == 1 and bursts[0].instant, "kill 1.5 m from the player skips the windup")
	# chain: a bloater in another's burst bursts too (deferred, no recursion)
	pl.global_position = Vector3(-20, 0, 0)
	var b1 = _z("bloated", Vector3(0, 0, 0))
	var b2 = _z("bloated", Vector3(1.2, 0, 0), 20)
	await frames(2)
	var chain := [0]
	b1.burst.connect(func(_b, _i): chain[0] += 1)
	b2.burst.connect(func(_b, _i): chain[0] += 1)
	b1.take_damage(1000.0, Vector3(0, 1.2, 0), false, shooter)
	await secs(1.5)
	check(chain[0] == 2, "chain: a Bloater killed by another's burst bursts too (%d bursts)" % chain[0])
	for p in get_nodes_in_group("bile_puddles"):
		p.queue_free()
	pl.dead = true
	pl.global_position = Vector3(0, 0, 30)
	await secs(2.6) # dead zombies sink + free


# ------------------------------------------------------------------ PlayerStatus
func _player_status() -> void:
	var p := CharacterBody3D.new()
	world.add_child(p)
	check(PS.move_mult(p) == 1.0 and not PS.is_rooted(p) and not PS.pin(p), "no status: move_mult 1")
	PS.slow(p, 0.3, 5.0, world)
	PS.slow(p, 0.5, 5.0, pl)
	check(is_equal_approx(PS.move_mult(p), 0.5), "strongest slow wins")
	PS.slow(p, 0.3, 5.0, world)
	check(is_equal_approx(PS.slow_amp(p), 0.5) and (p.get_meta(PS.META).slows as Dictionary).size() == 2, "one slow per source (refresh, no pile-up)")
	PS.root(p, 5.0, world)
	check(PS.is_rooted(p) and PS.move_mult(p) == 0.0, "root -> move_mult 0")
	PS.release(p, world)
	check(not PS.is_rooted(p), "release(source) ends it")
	PS.root(p, -1.0, world)
	check(not PS.is_rooted(p), "expired roots drop out")
	PS.clear(p)
	check(not p.has_meta(PS.META), "clear()")
	p.queue_free()


# ------------------------------------------------------------------ bloater burst on the player, per difficulty (tuning pass)
## Round-n zombie swing damage on a profile, exactly as main.gd gets it (Difficulty.apply_to_main on main's exports).
func _contact(prof: String, n: int) -> int:
	var gs := GDScript.new()
	gs.source_code = "extends Node\nvar map_id := \"arena\"\nvar base_damage := 10\nvar damage_per_round := 2\n"
	gs.reload()
	var m: Node = gs.new()
	D.apply_to_main(m, prof)
	var dmg: int = m.base_damage + m.damage_per_round * (n - 1)
	m.free()
	return dmg


func _burst_once(contact: int, flat_d: float) -> Dictionary:
	var bl = _z("bloated", Vector3(0, 0, 0))
	bl.contact_damage = contact
	bl.speed = 0.0
	pl.dead = false
	pl.health = 1000.0
	pl.hits = 0
	pl.global_position = Vector3(-flat_d, 0, 0)
	await frames(3) # turns to face the player
	var out := {}
	bl.burst.connect(func(_b, i): out.merge(i))
	bl.take_damage(100000.0, Vector3.ZERO, false, null)
	for i in 10:
		if not out.is_empty():
			break
		await physics_frame
	out["taken"] = 1000.0 - pl.health
	out["hits"] = pl.hits
	pl.dead = true
	pl.global_position = Vector3(0, 0, 30)
	await frames(1)
	return out


func _burst_table() -> void:
	var caps := {"easy": 40, "medium": 40, "hard": 65}
	var rows := ["profile  round contact | 1.5 m raw -> capped | point-blank raw -> capped"]
	var all_ok := true
	var any_capped := {}
	for prof in ["easy", "medium", "hard"]:
		D.set_active(prof)
		for n in [1, 5, 10, 15, 20, 30]:
			var cd := _contact(prof, n)
			var a: Dictionary = await _burst_once(cd, 1.5)
			var p: Dictionary = await _burst_once(cd, 0.0)
			rows.append("%-7s  r%-3d  %3d     | %3d -> %3d          | %3d -> %3d" % [prof, n, cd, a.player_damage_raw, a.player_damage, p.player_damage_raw, p.player_damage])
			for e in [a, p]:
				all_ok = all_ok and e.hits == 1 and int(e.player_damage) == mini(int(e.player_damage_raw), caps[prof]) \
					and is_equal_approx(float(e.taken), float(e.player_damage)) and e.player_cap == caps[prof]
				if int(e.player_damage_raw) > caps[prof]:
					any_capped[prof] = true
	D.set_active("")
	print("BURST_TABLE\n  " + "\n  ".join(rows))
	check(all_ok, "burst on the player: one hit per burst = min(raw, profile cap) at 1.5 m and point-blank, rounds 1-30")
	check(any_capped.has("easy") and any_capped.has("medium") and any_capped.has("hard"), "the cap bites on every profile by the late rounds")
	check(caps.easy < 100 and caps.medium < 100 and caps.hard < 100 and caps.hard >= 60 and caps.hard <= 70
		and caps.easy >= 35 and caps.easy <= 45 and caps.medium >= 35 and caps.medium <= 45,
		"caps: a full-HP (100) player survives one burst on every profile (40 / 40 / 65)")
	check(int(D.variant_knob("bloater_burst_player_cap", 0, "hard")) == 65 and int(ZombieVariants.behavior("bloated").player_damage_cap) == 40,
		"caps live in difficulty.json (per profile) with the zombies.json fallback")
	# chained bursts: each burst caps on its own (two hits), never stacked inside one burst
	D.set_active("easy")
	pl.dead = false
	pl.health = 1000.0
	pl.hits = 0
	pl.global_position = Vector3(-0.6, 0, 0)
	var b1 = _z("bloated", Vector3(0, 0, 0))
	var b2 = _z("bloated", Vector3(0.9, 0, 0), 20)
	b1.contact_damage = 200
	b2.contact_damage = 200
	await frames(3)
	var got := []
	b1.burst.connect(func(_b, i): got.append(i.player_damage))
	b2.burst.connect(func(_b, i): got.append(i.player_damage))
	b1.take_damage(100000.0, Vector3.ZERO, false, null)
	await secs(0.3)
	check(got == [40, 40] and pl.hits == 2 and is_equal_approx(pl.health, 920.0), "chain on Easy: two bursts, each capped at 40 (%s, %d hits, took %.0f)" % [got, pl.hits, 1000.0 - pl.health])
	D.set_active("")
	pl.dead = true
	pl.global_position = Vector3(0, 0, 30)
	await secs(2.6)
