extends SceneTree
## Player standing on a zombie's head (Skillz, playtest 2026-10-22 #18: "zombies must be able to hit you when you stand on their heads").
##   godot --headless --path . -s res://tests/head_stand_test.gd
## On the synthetic AI course (tests/ai_nav_course.tscn), open NE corner. Covers scripts/enemies/ai/head_stand.gd + data/ai.json head_stand:
##   GEOMETRY   (no scene hooks needed) reach is true for feet at the capsule top (centered / off-centre / the swing's landing slack), false when
##              jumping well above, far to the side, or at ground level far away; per-variant capsules; ai.json overrides (kinds.boss: no hold /
##              no shake); enabled=false -> never in reach
##   MELEE      a player on a zombie's head is hit (health drops at attack_interval pace); jumping well above / enabled=false -> no hits
##   NO PUSH    the zombie stands still under the player (< 0.1 m in 3 s) and the player, left to real physics, stays on the head; the
##              control (head_stand disabled) walks about
##   SHAKE      after shake.after s: telegraph (meta head_shake), then one shove + lurch; the player leaves the head; cooldown holds the
##              next one back; leaving the head during the telegraph cancels it; shake.enabled=false -> never shakes
##   GALLSPITTER line of sight / lob arc from a spitter to a player on top of another zombie is clear (the zombie body is not a world
##              surface), it spits and the glob hits them; a spitter stood on does not back off and swipes
## The MELEE / NO PUSH / SHAKE / GALLSPITTER parts need the enemy.gd hooks (head_stand_tick, in_attack_reach -> nav.head_reach); without
## them they are skipped (SKIP) and only GEOMETRY runs. Exit code = number of failures.

const COURSE_SCENE := "res://tests/ai_nav_course.tscn"
const MAIN := "res://scenes/main.tscn"
const SPOT := Vector3(28, 0.1, -16)
const HS := preload("res://scripts/enemies/ai/head_stand.gd")

var _passes := 0
var _fails := 0
var main: Node
var pl: CharacterBody3D
var ZN: GDScript
var G: GDScript


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
	return int(ceil(t * 60.0)) # 240 physics ticks / s x time_scale 4: each tick's delta is 1/60 s of game time


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	ZN = load("res://scripts/enemies/ai/zombie_nav.gd")
	G = load("res://scripts/enemies/variants/gallspitter.gd")
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_head_stand_test.cfg"
	progress.reset_skills()
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 16
	main = load(MAIN).instantiate()
	main.map_scene = load(COURSE_SCENE)
	root.add_child(main)
	current_scene = main
	await wait(3)
	main._break_timer = 1.0e9
	main.field_cards_enabled = false
	await _wait_bake(main.nav_region)
	Engine.time_scale = 4.0
	pl = main.player
	await _geometry_checks()
	var hooked: bool = (load("res://scripts/enemy.gd") as GDScript).source_code.contains("head_stand_tick")
	if hooked:
		await _melee_checks()
		await _hold_checks()
		await _shake_checks()
		await _spitter_checks()
	else:
		print("SKIP  melee / no-push / shake / gallspitter parts: enemy.gd does not call nav.head_stand_tick yet (patch head_stand_enemy.gd.diff)")
	await _clear()
	ZN.reload_data({})
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 60
	print("head_stand_test: %d passed, %d failed" % [_passes, _fails])
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

func _spawn(pos: Vector3, vid: String = "") -> Node:
	var z = main.make_zombie({"kind": "zombie", "vid": vid, "health": 1000, "speed": 3.2, "damage": 10})
	main.zombies_root.add_child(z)
	z.global_position = pos
	return z


func _clear() -> void:
	for z in get_nodes_in_group("enemies"):
		z.queue_free()
	for n in get_nodes_in_group("thrown_projectiles") + get_nodes_in_group("gall_puddles"):
		n.queue_free()
	G.reset_camping()
	pl.set_physics_process(false)
	pl.velocity = Vector3.ZERO
	await wait(3)


## Player held still (no physics of its own) at `p`, full health.
func _hold_player(p: Vector3) -> void:
	pl.set_physics_process(false)
	pl.global_position = p
	pl.velocity = Vector3.ZERO
	pl.health = pl.max_health
	pl.dead = false
	pl.set("invulnerable_t", 0.0)


## Re-pin a held player (position only: health is left alone so damage can be measured).
func _pin(p: Vector3) -> void:
	pl.global_position = p
	pl.velocity = Vector3.ZERO


## Player under real physics (gravity, floor, collisions with the zombie), no input.
func _free_player(p: Vector3) -> void:
	_hold_player(p)
	pl.set_physics_process(true)


func _data_with(over: Dictionary) -> void:
	var d: Dictionary = ZN.data().duplicate(true)
	d["head_stand"] = (d.get("head_stand", {}) as Dictionary).duplicate(true)
	for k in over:
		if over[k] is Dictionary and d.head_stand.get(k) is Dictionary:
			d.head_stand[k].merge(over[k], true)
		else:
			d.head_stand[k] = over[k]
	ZN.reload_data(d)


func _top(z: Node) -> float:
	return z.nav.head.head_top()


func _head_pos(z: Node, lift: float = 0.0) -> Vector3:
	return z.global_position + Vector3(0, _top(z) + lift, 0)


# ------------------------------------------------------------------ geometry

func _geometry_checks() -> void:
	ZN.reload_data({})
	var z = _spawn(SPOT)
	await wait(3)
	var h = z.nav.head
	var top: float = _top(z)
	check(is_equal_approx(top, 1.8), "walker capsule top comes from its CollisionShape3D (%.2f m)" % top)
	var r: float = h.head_radius(pl)
	check(r > 0.7 and r < 1.1, "head radius = zombie 0.35 + player 0.40 + slack 0.15 = %.2f m" % r)
	check(not z.in_attack_reach(0.0, top) or z.nav != null, "(sanity) in_attack_reach callable")
	check(h.reach(0.0, top, 0.0, pl), "feet on the capsule top, centred: in reach")
	check(h.reach(0.55, top, 0.0, pl) and h.reach(r - 0.01, top, 0.0, pl), "off-centre on the head (0.55 m .. just inside the head radius): in reach")
	check(not h.reach(r + 0.1, top, 0.0, pl) and h.reach(r + 0.1, top, 0.5, pl), "just past the head radius: out, but inside the swing's landing slack (extra 0.5 m): in")
	check(h.reach(0.0, top - 0.3) and not h.reach(0.0, top - 0.5), "feet a little inside the capsule (0.3 m): in reach; 0.5 m below the top: only the ordinary reach test applies")
	check(h.reach(0.0, top + 0.5), "a small hop (feet 0.5 m over the head): still in reach")
	check(not h.reach(0.0, top + 1.0) and not h.reach(0.0, top + 2.5), "jumping well above (1.0 m / 2.5 m over the head): out of reach")
	check(not h.reach(3.0, top) and not h.reach(1.5, top, 0.0, pl), "beside the zombie at head height (1.5 m / 3 m away): out of reach")
	var base_ok: bool = z.attack_range > 0.0
	check(base_ok and not z.in_attack_reach(0.5, 4.0), "enemy.in_attack_reach: a far overhead target is still out of reach (%s)" % [str(z.in_attack_reach(0.5, 4.0))])
	# per-variant capsule: a crawler's head is lower (top comes from its own capsule, no constant)
	var c = _spawn(SPOT + Vector3(6, 0, 0), "crawler")
	await wait(3)
	var ctop: float = _top(c)
	check(ctop < top - 0.3 and c.nav.head.reach(0.0, ctop, 0.0, pl) and not c.nav.head.reach(0.0, top + 0.3), "crawler: its own capsule top (%.2f m) is used, not the walker's %.2f m" % [ctop, top])
	# data: kinds.boss override, enabled = false
	var m: Dictionary = HS.merged(ZN.data(), "boss")
	var m2: Dictionary = HS.merged(ZN.data(), "city")
	check(m.hold == false and m.shake.enabled == false and m2.hold == true and m2.shake.enabled == true, "ai.json: bosses reach but neither hold nor shake; walkers hold and shake")
	check(float(m2.shake.after) > 0.0 and float(m2.shake.cooldown) >= float(m2.shake.after) and float(m2.shake.telegraph) >= 0.4 and float(m2.shove_speed if m2.has("shove_speed") else m2.shake.shove_speed) <= 8.0,
		"shake is modest: %.1f s before, %.1f s telegraph, %.0f s cooldown, shove %.1f m/s" % [m2.shake.after, m2.shake.telegraph, m2.shake.cooldown, m2.shake.shove_speed])
	await _clear()
	_data_with({"enabled": false})
	z = _spawn(SPOT)
	await wait(3)
	check(not z.nav.head.reach(0.0, _top(z), 0.0, pl) and not z.nav.head_reach(0.0, _top(z)), "head_stand.enabled = false: never in reach")
	await _clear()
	ZN.reload_data({})


# ------------------------------------------------------------------ melee

func _melee_checks() -> void:
	ZN.reload_data({})
	var z = _spawn(SPOT)
	await wait(3)
	_hold_player(_head_pos(z))
	var hp0: int = pl.health
	for i in secs(2.6):
		await physics_frame
		_pin(_head_pos(z))
	var lost: int = hp0 - pl.health
	check(lost >= 20 and lost <= 40, "player on the head is hit at the zombie's pace: %d HP in 2.6 s (10 per swing, 1 s interval)" % lost)
	await _clear()
	# jumping well above: no swing, no damage
	z = _spawn(SPOT)
	await wait(3)
	_hold_player(_head_pos(z, 1.6))
	hp0 = pl.health
	for i in secs(3.0):
		await physics_frame
		_pin(_head_pos(z, 1.6))
	check(pl.health == hp0, "1.6 m above the head: not hit (%d -> %d)" % [hp0, pl.health])
	await _clear()
	# disabled: the old behaviour, no hit
	_data_with({"enabled": false})
	z = _spawn(SPOT)
	await wait(3)
	_hold_player(_head_pos(z))
	hp0 = pl.health
	for i in secs(3.0):
		await physics_frame
		_pin(_head_pos(z))
	check(pl.health == hp0, "head_stand.enabled = false: a player on the head is not hit (old behaviour) (%d -> %d)" % [hp0, pl.health])
	await _clear()
	ZN.reload_data({})


# ------------------------------------------------------------------ hold still / no push-off

func _hold_checks() -> void:
	_data_with({"shake": {"enabled": false}}) # isolate the hold from the shake-off
	var z = _spawn(SPOT)
	await wait(3)
	var p0: Vector3 = z.global_position
	_free_player(_head_pos(z, 0.3))
	var max_off := 0.0
	var min_y := INF
	var landed := false
	for i in secs(3.0):
		await physics_frame
		pl.health = pl.max_health
		max_off = maxf(max_off, Vector2(z.global_position.x - p0.x, z.global_position.z - p0.z).length())
		if i > secs(1.0):
			landed = landed or pl.is_on_floor()
			min_y = minf(min_y, pl.global_position.y - z.global_position.y)
	var rel: float = pl.global_position.y - z.global_position.y
	check(max_off < 0.1, "zombie holds still under the player: moved at most %.3f m in 3 s" % max_off)
	check(rel > _top(z) - 0.2 and min_y > _top(z) - 0.2, "player left to real physics stays on the head (feet %.2f m over the zombie origin, lowest %.2f, head %.2f)" % [rel, min_y, _top(z)])
	check(Vector2(pl.global_position.x - z.global_position.x, pl.global_position.z - z.global_position.z).length() < z.nav.head.head_radius(pl), "and is still over the head (%.2f m off-axis)" % Vector2(pl.global_position.x - z.global_position.x, pl.global_position.z - z.global_position.z).length())
	check(z.nav.head.on_head and z.nav.head.stood_t > 2.0, "head tracker: on_head, stood %.1f s" % z.nav.head.stood_t)
	await _clear()
	# control: the same set-up, head_stand disabled -> the zombie keeps chasing about (it is not holding)
	_data_with({"enabled": false})
	z = _spawn(SPOT)
	await wait(3)
	p0 = z.global_position
	_free_player(_head_pos(z, 0.3))
	var travelled := 0.0
	var last: Vector3 = p0
	for i in secs(3.0):
		await physics_frame
		pl.health = pl.max_health
		travelled += Vector2(z.global_position.x - last.x, z.global_position.z - last.z).length()
		last = z.global_position
	print("INFO  control (disabled): zombie travelled %.2f m, player %.2f m off-axis" % [travelled, Vector2(pl.global_position.x - z.global_position.x, pl.global_position.z - z.global_position.z).length()])
	check(not z.nav.head.on_head, "control: head tracker idle when disabled")
	await _clear()
	ZN.reload_data({})


# ------------------------------------------------------------------ shake-off

func _shake_checks() -> void:
	_data_with({"shake": {"enabled": true, "after": 1.0, "telegraph": 0.5, "cooldown": 5.0}})
	var z = _spawn(SPOT)
	await wait(3)
	var h = z.nav.head
	_free_player(_head_pos(z, 0.3))
	var saw_tele := false
	var lean := 0.0
	var t_tele := -1.0
	for i in secs(2.4):
		await physics_frame
		pl.health = pl.max_health
		if h.shaking and not saw_tele:
			saw_tele = true
			t_tele = float(i) / 60.0
			lean = (z.model_root as Node3D).rotation.x
		if h.shakes > 0:
			break
	check(saw_tele and z.has_meta("head_shake") == h.shaking, "telegraph before the shake: shaking true, meta head_shake set (seen at %.2f s sim)" % t_tele)
	check(t_tele >= 0.9 and t_tele <= 1.6, "it comes after the stand time (after 1.0 s: telegraph at %.2f s)" % t_tele)
	check(lean < -0.05, "the zombie rears back during the telegraph (lean %.2f rad)" % lean)
	check(h.shakes == 1 and h.last_shove.length() > 3.0, "one shake-off: shove %.1f m/s (flat %.1f, up %.1f)" % [h.last_shove.length(), Vector2(h.last_shove.x, h.last_shove.z).length(), h.last_shove.y])
	check(not h.shaking and not z.has_meta("head_shake"), "telegraph over, flag cleared")
	var left := false
	for i in secs(1.5):
		await physics_frame
		pl.health = pl.max_health
		if Vector2(pl.global_position.x - z.global_position.x, pl.global_position.z - z.global_position.z).length() > h.head_radius(pl) + 0.3:
			left = true
	check(left, "the shove takes the player off the head (%.2f m off-axis)" % Vector2(pl.global_position.x - z.global_position.x, pl.global_position.z - z.global_position.z).length())
	# cooldown: stand on it again straight away -> no second shake until cooldown + stand time have passed
	await wait(secs(0.3))
	_free_player(_head_pos(z, 0.3))
	for i in secs(2.0):
		await physics_frame
		pl.health = pl.max_health
	check(h.shakes == 1 and h.cooldown > 0.0, "cooldown holds the next shake back (shakes %d, cooldown left %.1f s)" % [h.shakes, h.cooldown])
	# ...and once the cooldown has run out the same stander is shaken again (cooldown 5 s: due ~1.2 s from now)
	_free_player(_head_pos(z, 0.3))
	var again := false
	for i in secs(3.0):
		await physics_frame
		pl.health = pl.max_health
		if h.shakes >= 2:
			again = true
			break
		if h.shakes == 1 and not h.shaking and Vector2(pl.global_position.x - z.global_position.x, pl.global_position.z - z.global_position.z).length() > h.head_radius(pl) + 0.3:
			_free_player(_head_pos(z, 0.3))
	check(again, "after the cooldown a stander is shaken again (shakes %d, cooldown left %.1f s)" % [h.shakes, h.cooldown])
	await _clear()
	# leaving the head during the telegraph cancels it
	_data_with({"shake": {"enabled": true, "after": 0.5, "telegraph": 1.2, "cooldown": 3.0}})
	z = _spawn(SPOT)
	await wait(3)
	h = z.nav.head
	_hold_player(_head_pos(z))
	for i in secs(1.0):
		await physics_frame
		_pin(_head_pos(z))
		if h.shaking:
			break
	var was: bool = h.shaking
	_hold_player(z.global_position + Vector3(4, 0, 0))
	for i in secs(1.0):
		await physics_frame
		_pin(z.global_position + Vector3(4, 0, 0))
	check(was and not h.shaking and h.shakes == 0 and h.cancelled >= 1 and not z.has_meta("head_shake"), "stepping off during the telegraph cancels it (shakes %d, cancelled %d)" % [h.shakes, h.cancelled])
	await _clear()
	# disabled shake: never
	_data_with({"shake": {"enabled": false, "after": 0.5}})
	z = _spawn(SPOT)
	await wait(3)
	_hold_player(_head_pos(z))
	for i in secs(3.0):
		await physics_frame
		_pin(_head_pos(z))
		pl.health = pl.max_health
	check(z.nav.head.shakes == 0 and not z.nav.head.shaking and z.nav.head.stood_t > 2.0, "shake.enabled = false: stood on %.1f s, never shakes" % z.nav.head.stood_t)
	await _clear()
	ZN.reload_data({})


# ------------------------------------------------------------------ Gallspitter

func _spitter_checks() -> void:
	ZN.reload_data({})
	_data_with({"shake": {"enabled": false}})
	# a player on top of a walker, a second walker in the line between them and the spitter
	var ppos := Vector3(28, 0.1, -32)
	var under = _spawn(ppos)
	await wait(3)
	var stand := _head_pos(under)
	_hold_player(stand)
	under.set_physics_process(false) # a prop for this part: LOS only
	var mid = _spawn(Vector3(28, 0.1, -19))
	mid.set_physics_process(false)
	var s = _spawn(SPOT + Vector3(0, 0, 0), "gallspitter")
	await wait(3)
	var chest: Vector3 = pl.global_position + Vector3(0, 1.2, 0)
	var q := PhysicsRayQueryParameters3D.create(s.global_position + Vector3(0, 1.45, 0), chest, 1)
	check(s.get_world_3d().direct_space_state.intersect_ray(q).is_empty(), "(setup) no world surface between the spitter's mouth and the head-standing player")
	var q2 := PhysicsRayQueryParameters3D.create(s.global_position + Vector3(0, 1.45, 0), chest, 4)
	check(not s.get_world_3d().direct_space_state.intersect_ray(q2).is_empty(), "(setup) the walker in between IS in the line physically (layer 4)")
	check(s.can_shoot_from(s.global_position, pl), "can_shoot_from: line of sight + lob arc are clear to a player on a walker's head (zombie bodies are not cover)")
	var started := [0]
	s.spit_started.connect(func(_s, _t): started[0] += 1)
	var hp0: int = pl.health
	for i in secs(6.0):
		await physics_frame
		_pin(stand)
		if pl.health < hp0:
			break
	check(started[0] >= 1 and s.spits >= 1, "it winds up and spits at the player on the head (%d started, %d spat)" % [started[0], s.spits])
	# glob direct-hit: same glob straight at the head-stander
	_hold_player(stand)
	await wait(2)
	hp0 = pl.health
	var TP: GDScript = load("res://scripts/projectiles/thrown_projectile.gd")
	var from: Vector3 = s.global_position + Vector3(0, 1.45, 0)
	var g = TP.spawn({"type_id": &"bile_glob", "variant": &"", "rarity": 0, "pos": from, "vel": TP.lob_velocity(from, stand + Vector3(0, 0.5, 0)), "owner_id": 0, "seed": 7})
	var res := {"hit": null}
	g.impacted.connect(func(_p, _w, hp): res.hit = hp)
	for i in secs(3.0):
		await physics_frame
		_pin(stand)
		if res.hit != null or not is_instance_valid(g):
			break
	check(res.hit == pl and pl.health < hp0, "a glob flies through the walkers' bodies and hits the head-standing player (%d -> %d)" % [hp0, pl.health])
	await _clear()
	# a world ceiling still blocks it (the head-stand does not make the check blind)
	under = _spawn(ppos)
	under.set_physics_process(false)
	await wait(3)
	stand = _head_pos(under)
	_hold_player(stand)
	var wall := StaticBody3D.new()
	wall.collision_layer = 1
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(30, 8, 0.6)
	cs.shape = bs
	wall.add_child(cs)
	main.add_child(wall)
	wall.global_position = Vector3(28, 4.0, -24)
	s = _spawn(SPOT, "gallspitter")
	await wait(3)
	check(not s.can_shoot_from(s.global_position, pl), "control: a real wall between spitter and head-standing player still blocks the shot")
	wall.queue_free()
	await _clear()
	# a spitter stood on: it does not back off, it swipes
	_data_with({"shake": {"enabled": false}})
	s = _spawn(SPOT, "gallspitter")
	await wait(3)
	var p0: Vector3 = s.global_position
	_hold_player(_head_pos(s))
	hp0 = pl.health
	for i in secs(3.0):
		await physics_frame
		_pin(_head_pos(s))
	var moved: float = Vector2(s.global_position.x - p0.x, s.global_position.z - p0.z).length()
	check(moved < 0.15 and s.mode_name() == "hold" and not s.wants_move(), "a Gallspitter stood on stays put (moved %.2f m, mode %s)" % [moved, s.mode_name()])
	check(pl.health < hp0, "and swipes the player on its head (%d -> %d)" % [hp0, pl.health])
	await _clear()
	ZN.reload_data({})
