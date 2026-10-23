extends "res://scripts/enemy.gd"
## Gallspitter (zombies.json "gallspitter", Skillz DESIGN §22 / MAIN_HOOKS §22): the ranged special that stops camping.
## Keeps engage_min..engage_max m from its target and lobs slow, visible bile globs (ThrownProjectile type bile_glob,
## data/projectiles.json) that leave a gall puddle. Telegraph: Desi's Spit clip (0.7 s wind-up, release marker, 0.4 s
## recovery), the GallSac swells and glows, a mouth light ramps up, gallspitter_windup plays. Aimed at where the target
## stands (no lead), so moving players dodge it and campers eat it.
## Targeting (host only): campers first (static camp tracker), then players melee zombies can't path to (perches /
## pits), else the nearest (ZombieNav.players, co-op aware). Picks standpoints with line of sight and a clear arc,
## prefers high ground and spreads out from other Gallspitters; backs off when rushed; weak in melee.
## Movement: APPROACH uses ZombieNav.direction (full stuck recovery); MOVE / RETREAT to a standpoint follow their own
## navmesh path (ZombieNav's progress watch measures the distance to the target, which a retreat grows on purpose)
## with their own stuck check; both drive the body through nav.tick (avoidance, move_and_slide).
## Knobs: zombies.json variants.gallspitter.behavior. Tests: tests/ranged_enemy_test.gd, ai_nav_test ranged checkpoints.

const VC := preload("res://scripts/enemies/variants/variant_common.gd")
const PlaceholderScr := preload("res://scripts/enemies/variants/gallspitter_placeholder.gd")
const ProjScr := preload("res://scripts/projectiles/thrown_projectile.gd") ## = class ThrownProjectile
const VARIANT := "gallspitter"
const WORLD_MASK := 1
const ARC_END_FRAC := 0.75

enum Mode {APPROACH, HOLD, MOVE, RETREAT, SPIT}
const MODE_NAMES := ["approach", "hold", "move", "retreat", "spit"]

signal spit_started(spitter: Node, target: Node3D)
signal spit_released(spitter: Node, projectile: Node, info: Dictionary)

static var _camp: Dictionary = {} ## player instance id -> {anchor: Vector3, since: float}
static var _camp_frame: int = -1
static var _clock: float = 0.0 ## physics seconds, advanced once per frame by whichever Gallspitter ticks first
static var _spots: Dictionary = {} ## instance id -> claimed standpoint (spread between Gallspitters)
static var _seq: int = 0

var b: Dictionary = {}
var mode: int = Mode.APPROACH
var spot: Vector3 = Vector3.INF
var spits: int = 0 ## total releases (tests)
var spits_here: int = 0
var last_shot: Dictionary = {} ## {target, from, aim, vel, flight_t, range}
var last_pick: Dictionary = {} ## why the current target was chosen {id, camping, unreachable, dist}
var cancelled_spits: int = 0
var blocked_releases: int = 0 ## spits whose line of sight / arc was gone at the release moment (aborted, nothing fired; tests)
var blocked_starts: int = 0 ## wind-ups refused because the fresh line-of-sight check failed (it repositions instead; tests)
var searches: int = 0
var retreats: int = 0
var placeholder: bool = false
var rng := RandomNumberGenerator.new()
var _spit_t: float = -1.0
var _released: bool = false
var _release_at: float = 0.7
var _spit_len: float = 1.1
var _cd: float = 1.0
var _retarget_t: float = 0.0
var _search_t: float = 0.0
var _good_t: float = 0.0
var _good: bool = false
var _path: PackedVector3Array = PackedVector3Array()
var _pi: int = 0
var _stuck_pos: Vector3 = Vector3.INF
var _stuck_t: float = 0.0
var _stuck_hits: int = 0
var _chase_t: float = 0.0 ## > 0: plain ZombieNav chase (fallback after a stuck standpoint walk)
var _reach_cache: Dictionary = {} ## player id -> {t, unreachable}
var _sac_mats: Array = [] ## [[material, base emission energy]] driven by the wind-up
var _mouth_light: OmniLight3D
var _rot_before: float = 0.0
var _approaching: bool = false
var _spot_hops: int = 0
var _bad_spots: Array = [] ## [{p, until}]: standpoints it failed to walk to (skipped for 10 s)
var hops: int = 0
var _last_spit_pos: Vector3 = Vector3.INF
var _spit_frame: int = -1


func _ready() -> void:
	if variant_id == "": # main.gd / tests call set_variant() only when the GLB exists: apply the data ourselves
		set_variant(VARIANT, ZombieVariants.get_variant(VARIANT), null)
	b = VC.behavior(self)
	_seq += 1
	rng.seed = hash([int(get_meta("net_seed")) if has_meta("net_seed") else -1, _seq, VARIANT])
	attack_range = VC.num(b, "attack_range", 1.3)
	model_faces_plus_z = bool(b.get("model_faces_plus_z", false))
	placeholder = ZombieVariants.scene(VARIANT) == null
	if placeholder:
		models = [] # enemy._spawn_model() skips; the placeholder below has the same nodes and clips
		size_variety = 0.0
	VC.hook_bus(get_tree())
	super._ready()
	if placeholder:
		_build_placeholder()
	_setup_clips()
	_setup_telegraph()
	_cd = VC.num(b, "first_spit_delay", 1.0)
	add_to_group("gallspitters")


func _exit_tree() -> void:
	_spots.erase(get_instance_id())


# ------------------------------------------------------------------ model / clips

func _build_placeholder() -> void:
	var m := PlaceholderScr.build()
	model_root.add_child(m)
	var a := ModelUtil.get_aabb(m)
	var s: float = model_height / maxf(a.size.y, 0.01)
	m.scale = Vector3.ONE * s
	m.position.y = -a.position.y * s
	if model_faces_plus_z:
		model_root.rotation.y = 0.0 # the placeholder is built facing -Z already
	_anim = m.get_node("AnimationPlayer") as AnimationPlayer
	var head := m.get_node("Head") as Node3D
	head_hitbox = StaticBody3D.new()
	head_hitbox.name = "HeadHitbox"
	head_hitbox.collision_layer = HITBOX_LAYER
	head_hitbox.collision_mask = 0
	head_hitbox.set_meta("hit_owner", self)
	head_hitbox.set_meta("is_head", true)
	_head_shape = CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = head_radius / maxf(s, 0.01)
	_head_shape.shape = sph
	head_hitbox.add_child(_head_shape)
	head.add_child(head_hitbox)


func _setup_clips() -> void:
	if _anim == null:
		return
	var want := {"walk": "Walk", "idle": "Idle", "death": "Death", "hit": str(b.get("hit_clip", "Hit")), "spit": str(b.get("spit_clip", "Spit"))}
	for k in want:
		var n := VC.BossArt.find_clip(_anim, want[k])
		if n == "":
			n = _find_anim(want[k])
		if n != "":
			_anims[k] = n
	for k in ["walk", "idle"]:
		if _anims.has(k):
			_anim.get_animation(_anims[k]).loop_mode = Animation.LOOP_LINEAR
	_release_at = VC.num(b, "spit_windup", 0.7)
	_spit_len = _release_at + VC.num(b, "spit_recovery", 0.4)
	if _anims.has("spit"):
		var clip := _anim.get_animation(_anims.spit)
		if clip.has_marker("release"): # a release-time marker in the clip wins over the data value
			_release_at = clip.get_marker_time("release")
		elif _release_at < clip.length:
			clip.add_marker("release", _release_at) # glTF carries no markers: stamp the locked 0.7 s on the clip
		_spit_len = maxf(clip.length, _release_at + 0.05)
	_play("idle")


func _setup_telegraph() -> void:
	var sac := VC.node(self, "GallSac") as MeshInstance3D
	if sac and sac.material_override is StandardMaterial3D: # placeholder
		var m := (sac.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
		sac.material_override = m
		_sac_mats.append([m, m.emission_energy_multiplier])
	elif sac and sac.mesh: # Desi's GLB: per-surface materials (Gallspitter_Sac / _Gland), own copies so only this one glows
		for i in sac.mesh.get_surface_count():
			var am := sac.get_active_material(i) as StandardMaterial3D
			if am and am.emission_enabled:
				var m := am.duplicate() as StandardMaterial3D
				sac.set_surface_override_material(i, m)
				_sac_mats.append([m, m.emission_energy_multiplier])
	_mouth_light = OmniLight3D.new()
	_mouth_light.name = "SpitGlow"
	_mouth_light.light_color = Color(0.6, 0.9, 0.2)
	_mouth_light.light_energy = 0.0
	_mouth_light.omni_range = 2.5
	_mouth_light.shadow_enabled = false
	var mouth := VC.node(self, str(b.get("spawn_socket", "ProjectileSpawn")))
	if mouth:
		mouth.add_child(_mouth_light)
	else:
		_mouth_light.position = Vector3(0, VC.num(b, "mouth_height", 1.45), -0.3)
		add_child(_mouth_light)


## Telegraph strength 0..1 (the sac glow, the mouth light; Netz can mirror it on puppets, MAIN_HOOKS §22 P2).
func telegraph() -> float:
	if mode != Mode.SPIT or _released:
		return 0.0
	return clampf(_spit_t / maxf(_release_at, 0.01), 0.0, 1.0)


func _apply_telegraph(t: float) -> void:
	if _mouth_light:
		_mouth_light.light_energy = 2.5 * t
	for e in _sac_mats:
		(e[0] as StandardMaterial3D).emission_energy_multiplier = float(e[1]) * (1.0 + 4.0 * t)


## Read live every time (Desi: the muzzle moves fast at the 0.7 s release).
func mouth_pos() -> Vector3:
	var m := VC.node(self, str(b.get("spawn_socket", "ProjectileSpawn")))
	return m.global_position if m else global_position + Vector3(0, VC.num(b, "mouth_height", 1.45), 0) - global_basis.z * 0.3


# ------------------------------------------------------------------ audio (falls back to the generic zombie keys)

const VOICE_KEYS := {"zombie_idle_groan": "gallspitter_idle", "zombie_hurt": "gallspitter_hurt", "zombie_death": "gallspitter_death",
	"zombie_aggro_scream": "gallspitter_aggro", "zombie_attack_swipe": "gallspitter_swipe"}


func _say(key: String, priority: int) -> bool:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx and VOICE_KEYS.has(key) and sfx.has(VOICE_KEYS[key]):
		key = VOICE_KEYS[key]
	return super._say(key, priority)


func _sfx_at(key: String, pos: Vector3) -> void:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx:
		sfx.play_at(key, pos)


# ------------------------------------------------------------------ camping / targeting (host only)

static func _tick_camp(players: Array, delta: float, radius: float) -> void:
	var f := Engine.get_physics_frames()
	if f == _camp_frame:
		return
	_camp_frame = f
	_clock += delta
	var seen := {}
	for p in players:
		if not (p is Node3D) or not is_instance_valid(p):
			continue
		var id: int = p.get_instance_id()
		seen[id] = true
		var pos: Vector3 = (p as Node3D).global_position
		var c: Dictionary = _camp.get(id, {})
		if c.is_empty() or VC.flat_dist(pos, c.anchor) > radius or absf(pos.y - float(c.anchor.y)) > 1.5:
			_camp[id] = {"anchor": pos, "since": _clock}
	for id in _camp.keys():
		if not seen.has(id):
			_camp.erase(id)


## Seconds this player has stayed inside camp_radius of one spot (0 = moving / unknown).
static func camp_time(p: Node) -> float:
	if p == null or not is_instance_valid(p):
		return 0.0
	var c: Dictionary = _camp.get(p.get_instance_id(), {})
	return _clock - float(c.since) if not c.is_empty() else 0.0


static func reset_camping() -> void:
	_camp.clear()


func is_camping(p: Node) -> bool:
	return camp_time(p) >= VC.num(b, "camp_seconds", 6.0)


func _nav_map() -> RID:
	return agent.get_navigation_map() if agent else get_world_3d().navigation_map


func _map_ready() -> bool:
	var m := _nav_map()
	return m.is_valid() and NavigationServer3D.map_get_iteration_id(m) > 0


## True if walkers can't get to this player: their navmesh path ends away from them (a perch, a pit, a roof).
func melee_unreachable(p: Node3D) -> bool:
	if not _map_ready():
		return false
	var id := p.get_instance_id()
	var c: Dictionary = _reach_cache.get(id, {})
	if not c.is_empty() and _clock - float(c.t) < 1.0:
		return bool(c.unreachable)
	var m := _nav_map()
	var feet := p.global_position
	var near := NavigationServer3D.map_get_closest_point(m, feet)
	var un := VC.flat_dist(near, feet) > 1.0 or absf(near.y - feet.y) > 1.3
	if not un:
		var path := NavigationServer3D.map_get_path(m, NavigationServer3D.map_get_closest_point(m, global_position), near, true)
		un = path.is_empty() or path[path.size() - 1].distance_to(near) > 1.0
	_reach_cache[id] = {"t": _clock, "unreachable": un}
	return un


func _pick_target() -> void:
	var best: Node3D = null
	var best_s := -INF
	var info := {}
	for p in ZombieNavScr.players(self):
		if not (p is Node3D) or not is_instance_valid(p) or p.get("dead"):
			continue
		var d := VC.flat_dist(p.global_position, global_position)
		if d > aggro_range:
			continue
		var camping := is_camping(p)
		var un := melee_unreachable(p)
		var s := -d + (VC.num(b, "camp_priority", 40.0) if camping else 0.0) + (VC.num(b, "unreachable_priority", 25.0) if un else 0.0) \
			+ (VC.num(b, "stickiness", 3.0) if p == target else 0.0)
		if s > best_s:
			best_s = s
			best = p
			info = {"id": p.get_instance_id(), "camping": camping, "unreachable": un, "dist": d}
	if best != null:
		if best != target:
			_good_t = 0.0
			if mode in [Mode.MOVE, Mode.HOLD]:
				spot = Vector3.INF
				if mode == Mode.MOVE:
					mode = Mode.HOLD
		target = best
		last_pick = info


# ------------------------------------------------------------------ geometry checks

func _ray_clear(a: Vector3, c: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(a, c, WORLD_MASK)
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _aim_point(t: Node3D) -> Vector3:
	return t.global_position + Vector3(0, VC.num(b, "aim_height", 0.5), 0)


## Line of sight from a mouth at `feet` to the target's chest, and a lob arc that clears the world.
func can_shoot_from(feet: Vector3, t: Node3D) -> bool:
	var mouth := feet + Vector3(0, VC.num(b, "mouth_height", 1.45), 0)
	var chest := t.global_position + Vector3(0, 1.2, 0)
	if not _ray_clear(mouth, chest):
		return false
	var aim := _aim_point(t)
	var proj_id := StringName(str(b.get("projectile", "bile_glob")))
	var v := ProjScr.lob_velocity(mouth, aim, proj_id)
	var ft := VC.flat_dist(mouth, aim) / maxf(float(ProjScr.type_def(proj_id).get("launch_speed", 9.0)), 0.1)
	return _arc_clear(mouth, v, ft, proj_id)


## The lob arc from `from` clears the world (walls, props, floors: layer 1). The last stretch is checked to
## ARC_END_FRAC of the final segment (the glob lands on the floor at the target, so the very end may graze it).
func _arc_clear(from: Vector3, vel: Vector3, flight_t: float, proj_id: StringName) -> bool:
	var pts := ProjScr.lob_points(from, vel, flight_t, proj_id, 8)
	for i in range(1, pts.size()):
		var e := pts[i] if i < pts.size() - 1 else pts[i - 1].lerp(pts[i], ARC_END_FRAC)
		if not _ray_clear(pts[i - 1], e):
			return false
	return true


func in_band(feet: Vector3, t: Node3D) -> bool:
	var d := VC.flat_dist(feet, t.global_position)
	return d >= VC.num(b, "engage_min", 8.0) and d <= VC.num(b, "engage_max", 22.0)


# ------------------------------------------------------------------ standpoints

## Best standpoint around the target, or Vector3.INF. retreat = getting away from a rusher (farther, not past them).
func find_spot(retreat: bool = false) -> Vector3:
	searches += 1
	if target == null or not _map_ready():
		return Vector3.INF
	var m := _nav_map()
	var tp := target.global_position
	var me := global_position
	var lo := VC.num(b, "engage_min", 8.0)
	var hi := VC.num(b, "engage_max", 22.0)
	var pref := VC.num(b, "preferred_range", 14.0)
	var n_ang := int(VC.num(b, "search_angles", 14))
	var off := rng.randf() * TAU
	var cands: Array = []
	for f in [0.12, 0.38, 0.62, 0.88]:
		var r := lerpf(lo, hi, f)
		for i in n_ang:
			var ang := off + TAU * float(i) / float(n_ang)
			var c := tp + Vector3(sin(ang), 0.0, cos(ang)) * r
			for h in [0.0, 2.5]:
				var q := NavigationServer3D.map_get_closest_point(m, c + Vector3(0, h, 0))
				if VC.flat_dist(q, c) > 1.2:
					continue
				var dup := false
				for e in cands:
					if (e.p as Vector3).distance_to(q) < 1.0:
						dup = true
						break
				if dup:
					continue
				cands.append({"p": q, "s": _spot_heuristic(q, tp, me, pref, retreat)})
	cands.sort_custom(func(x, y): return x.s > y.s)
	var start := NavigationServer3D.map_get_closest_point(m, me)
	var best := Vector3.INF
	var best_s := -INF
	var checked := 0
	for e in cands:
		if checked >= 8:
			break
		var q: Vector3 = e.p
		if not in_band(q, target) or not can_shoot_from(q, target):
			continue
		checked += 1
		var path := NavigationServer3D.map_get_path(m, start, q, true)
		if path.is_empty() or path[path.size() - 1].distance_to(q) > 0.8:
			continue
		var plen := 0.0
		var past := false
		for i in range(1, path.size()):
			plen += path[i - 1].distance_to(path[i])
			if retreat and VC.flat_dist(path[i], tp) < 3.0:
				past = true # the way out runs through the rusher
		if past:
			continue
		var s: float = float(e.s) - plen * 0.12
		if s > best_s:
			best_s = s
			best = q
	return best


func _spot_heuristic(q: Vector3, tp: Vector3, me: Vector3, pref: float, retreat: bool) -> float:
	var d := VC.flat_dist(q, tp)
	var s := -absf(d - pref) * 0.3
	s += clampf(q.y - tp.y, -1.0, 4.0) * VC.num(b, "elevation_weight", 0.6) # high ground
	s -= VC.flat_dist(q, me) * 0.1
	var sr := VC.num(b, "spread_radius", 5.0)
	for id in _spots:
		if id != get_instance_id() and (_spots[id] as Vector3).distance_to(q) < sr:
			s -= 4.0
	if retreat:
		s += d * 0.4
		var away := Vector3(me.x - tp.x, 0, me.z - tp.z).normalized()
		var go := Vector3(q.x - me.x, 0, q.z - me.z).normalized()
		s += away.dot(go) * 4.0
	for e in _bad_spots:
		if float(e.until) > _clock and (e.p as Vector3).distance_to(q) < 3.0:
			s -= 10.0
	if spits_here > 0 and spot != Vector3.INF and q.distance_to(spot) < 4.0:
		s -= 6.0 # relocating: somewhere new
	return s + rng.randf() * 0.5


func _go_to(p: Vector3, retreat: bool) -> void:
	spot = p
	_spots[get_instance_id()] = p
	var m := _nav_map()
	_path = NavigationServer3D.map_get_path(m, NavigationServer3D.map_get_closest_point(m, global_position), p, true)
	_pi = 0
	_stuck_pos = global_position
	_stuck_t = 0.0
	_spot_hops = 0
	if agent: # the agent only posts avoidance velocities while it has a target (Godot NavigationAgent3D)
		agent.target_position = p
	mode = Mode.RETREAT if retreat else Mode.MOVE
	if retreat:
		retreats += 1
		if not voice.playing:
			_say("zombie_aggro_scream", 1) # -> gallspitter_aggro once Audi-0 ships one (VOICE_KEYS), else the walker scream


func _path_dir() -> Vector3:
	var pos := global_position
	while _pi < _path.size():
		var w := _path[_pi]
		if VC.flat_dist(w, pos) < 0.5 and absf(w.y - pos.y) < 1.2:
			_pi += 1
		else:
			break
	if _pi >= _path.size():
		return Vector3.ZERO
	var to := _path[_pi] - pos
	to.y = 0.0
	return to.normalized() if to.length() > 0.05 else Vector3.ZERO


# ------------------------------------------------------------------ per frame

## The mode logic runs here (host / solo only: enemy._physics_process returns early on puppets before calling it).
func _chase_direction(to_player: Vector3) -> Vector3:
	match mode:
		Mode.SPIT, Mode.HOLD:
			_approaching = false
			return Vector3.ZERO
		Mode.MOVE, Mode.RETREAT:
			_approaching = false
			var d := _path_dir()
			if d == Vector3.ZERO:
				return Vector3.ZERO
			return d * (VC.num(b, "retreat_speed_mult", 1.15) if mode == Mode.RETREAT else 1.0)
	if nav == null:
		return to_player.normalized()
	if not _approaching and target: # back from a standpoint walk: ZombieNav's path / agent target point at the player again
		nav.repath(target.global_position)
	_approaching = true
	return nav.direction(to_player) # APPROACH: ZombieNav chase


## True while it means to walk (tests: a Gallspitter that wants to move must not stand still).
func wants_move() -> bool:
	if target and is_instance_valid(target) and VC.flat_dist(target.global_position, global_position) <= attack_range \
			and absf(target.global_position.y - global_position.y) < attack_max_dy:
		return false # in arm's reach it fights (enemy.gd melee), it doesn't walk
	return mode == Mode.APPROACH or mode == Mode.MOVE or mode == Mode.RETREAT


func mode_name() -> String:
	return MODE_NAMES[mode]


func _physics_process(delta: float) -> void:
	var authority := is_multiplayer_authority()
	if authority and not _dead:
		_net_retarget_t = 1.0 # NET E1 stays off: the Gallspitter picks its own target below (host only)
		var players := ZombieNavScr.players(self)
		_tick_camp(players, delta, VC.num(b, "camp_radius", 3.5))
		_retarget_t -= delta
		if _retarget_t <= 0.0 or target == null or not is_instance_valid(target) or target.get("dead"):
			_retarget_t = VC.num(b, "retarget", 0.5)
			_pick_target()
		_decide(delta)
		if mode == Mode.SPIT:
			_attack_anim_t = maxf(_spit_len - _spit_t, 0.05) # keeps enemy.gd off the walk / idle clips (ZombieNav: busy)
		elif (mode == Mode.MOVE or mode == Mode.RETREAT) and nav and nav.has_method("_try_step_up"):
			nav._try_step_up(delta) # ZombieNav only steps up for its own chase; a standpoint walk needs it too (MAIN_HOOKS §22 N1)
	_rot_before = rotation.y
	super._physics_process(delta)
	if not authority or _dead:
		return
	if mode == Mode.MOVE: # face where it walks (enemy.gd turned it to the target)
		var v := Vector3(velocity.x, 0, velocity.z)
		if v.length() > 0.4:
			rotation.y = lerp_angle(_rot_before, atan2(-v.x, -v.z), clampf(8.0 * delta, 0.0, 1.0))
	if mode == Mode.SPIT and _spit_frame != Engine.get_physics_frames():
		_spit_tick(delta)
	_apply_telegraph(telegraph())


func _decide(delta: float) -> void:
	_cd = maxf(_cd - delta, 0.0)
	_search_t = maxf(_search_t - delta, 0.0)
	_chase_t = maxf(_chase_t - delta, 0.0)
	if target == null or not is_instance_valid(target) or target.get("dead"):
		if mode == Mode.SPIT:
			_cancel_spit()
		mode = Mode.HOLD
		return
	if mode == Mode.SPIT:
		return
	var d := VC.flat_dist(target.global_position, global_position)
	var rushed := d < VC.num(b, "retreat_range", 6.0)
	if rushed and mode != Mode.RETREAT and _search_t <= 0.0:
		_search_t = VC.num(b, "search_interval", 0.6)
		var r := find_spot(true)
		if r != Vector3.INF:
			_go_to(r, true)
			return
		mode = Mode.HOLD # cornered: stands and swipes (enemy.gd melee, weak)
	if mode == Mode.MOVE or mode == Mode.RETREAT:
		if VC.flat_dist(spot, global_position) < 0.7 and absf(spot.y - global_position.y) < 1.3 or _pi >= _path.size():
			mode = Mode.HOLD
			spits_here = 0
			_good_t = 0.0
		else:
			_watch_stuck(delta)
			# on the way: a shot opens up (in band, clear arc, away from the last spot) -> take it here
			if mode == Mode.MOVE and _cd <= 0.0:
				_good_t -= delta
				if _good_t <= 0.0:
					_good_t = 0.25
					if global_position.distance_to(_last_spit_pos) > 4.0 and in_band(global_position, target) and can_shoot_from(global_position, target):
						mode = Mode.HOLD
						spits_here = 0
						_good = true
						_spots[get_instance_id()] = global_position
		return
	if _chase_t > 0.0:
		mode = Mode.APPROACH
		return
	_good_t -= delta
	if _good_t <= 0.0:
		_good_t = 0.25
		_good = in_band(global_position, target) and can_shoot_from(global_position, target)
	var relocate := spits_here >= int(VC.num(b, "spits_per_spot", 2))
	if _good and not relocate:
		mode = Mode.HOLD
		if _cd <= 0.0 and is_on_floor():
			if can_shoot_from(global_position, target): # fresh check: the cached _good can be 0.25 s old (playtest #11)
				_start_spit()
				return
			_good = false # the target slipped behind cover: no spit, find a standpoint with a clear shot instead
			_good_t = 0.25
			blocked_starts += 1
		else:
			return
	if _search_t <= 0.0:
		_search_t = VC.num(b, "search_interval", 0.6)
		var p := find_spot(false)
		if p != Vector3.INF:
			_go_to(p, false)
			return
		if relocate:
			spits_here = 0 # nowhere new to go: keep shooting from here
			return
	if not _good:
		mode = Mode.APPROACH


func _watch_stuck(delta: float) -> void:
	_stuck_t += delta
	if _stuck_t < VC.num(b, "stuck_window", 0.8):
		return
	var moved := global_position.distance_to(_stuck_pos)
	_stuck_pos = global_position
	_stuck_t = 0.0
	if moved >= VC.num(b, "stuck_min", 0.35):
		_stuck_hits = 0
		return
	if _spot_hops < 2 and _try_hop(): # a ledge the navmesh cuts across (a ramp's side): hop it like ZombieNav does
		_spot_hops += 1
		return
	_stuck_hits += 1
	_spots.erase(get_instance_id())
	_bad_spots.append({"p": spot, "until": _clock + 10.0})
	if _stuck_hits >= 2: # standpoint walking keeps failing: let ZombieNav (sidestep / detour / teleport) take over a while
		_stuck_hits = 0
		_chase_t = VC.num(b, "fallback_chase", 2.0)
		mode = Mode.APPROACH
		return
	var p := find_spot(mode == Mode.RETREAT)
	if p != Vector3.INF:
		_go_to(p, mode == Mode.RETREAT)
	else:
		_chase_t = VC.num(b, "fallback_chase", 2.0)
		mode = Mode.APPROACH


func _try_hop() -> bool:
	if not is_on_floor() or not is_on_wall():
		return false
	var fwd := _path_dir() * 0.35
	if fwd == Vector3.ZERO:
		return false
	var h := float(nav.body_cfg.get("hop_height", 0.7)) if nav and nav.get("body_cfg") is Dictionary else 0.7
	var xf := global_transform
	if test_move(xf, Vector3.UP * (h + 0.05)) or test_move(xf.translated(Vector3.UP * (h + 0.05)), fwd):
		return false
	velocity.y = sqrt(2.0 * _gravity * (h + 0.1))
	hops += 1
	return true


# ------------------------------------------------------------------ spit

func _start_spit() -> void:
	mode = Mode.SPIT
	_spit_t = 0.0
	_spit_frame = Engine.get_physics_frames() # the wind-up clock starts next frame
	_released = false
	if _anims.has("spit"):
		_play("spit", 0.08)
	_sfx_at("gallspitter_windup", global_position + Vector3.UP * 1.6) # play_at, not a voice: the voice cap must never eat the telegraph
	spit_started.emit(self, target)


func _spit_tick(delta: float) -> void:
	_spit_t += delta
	if not _released and _spit_t >= _release_at - 0.0001:
		_release()
	if _spit_t >= _spit_len:
		_spit_t = -1.0
		mode = Mode.HOLD
		_attack_anim_t = 0.0
		_cd = VC.num(b, "spit_cooldown", 2.6) + rng.randf_range(-1.0, 1.0) * VC.num(b, "cooldown_jitter", 0.6)


func _cancel_spit() -> void:
	if mode != Mode.SPIT:
		return
	cancelled_spits += 1
	_spit_t = -1.0
	_released = false
	mode = Mode.HOLD
	_attack_anim_t = 0.0
	_cd = VC.num(b, "spit_cooldown", 2.6) * 0.5


## The release found no clear shot: nothing is fired, short cooldown, and the next _decide() looks for a new standpoint now.
func _abort_blocked() -> void:
	blocked_releases += 1
	_spit_t = -1.0
	_released = false
	mode = Mode.HOLD
	_attack_anim_t = 0.0
	_good = false
	_good_t = 0.0
	_search_t = 0.0
	_cd = VC.num(b, "spit_cooldown", 2.6) * 0.25
	_apply_telegraph(0.0)


func projectile_damage(_type_id: StringName = &"") -> int:
	return maxi(int(round(float(contact_damage) * VC.num(b, "glob_damage_mult", 3.0))), 1)


func _release() -> void:
	_released = true
	if target == null or not is_instance_valid(target):
		return
	var from := mouth_pos()
	var aim := _aim_point(target)
	var dist := VC.flat_dist(from, aim)
	var spread := VC.num(b, "aim_spread", 0.5) * clampf(dist / VC.num(b, "engage_max", 22.0), 0.0, 1.0)
	aim += Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0)) * spread
	var proj_id := StringName(str(b.get("projectile", "bile_glob")))
	var vel := ProjScr.lob_velocity(from, aim, proj_id)
	# Playtest #11: re-check at the moment of release, with the same test the wind-up start used (line of sight + lob arc,
	# fresh), and the mouth must be outside geometry (a spitter pressed against a wall would spawn the glob inside it).
	# If either fails nothing fires and it repositions. (The jittered aim isn't re-tested: a glob that clips a corner stops there.)
	if not _ray_clear(global_position + Vector3(0, VC.num(b, "mouth_height", 1.45), 0), from) \
			or not can_shoot_from(global_position, target):
		_abort_blocked()
		return
	var p = ProjScr.spawn({"type_id": proj_id, "variant": &"", "rarity": 0, "pos": from, "vel": vel,
		"owner_id": get_instance_id(), "seed": rng.randi()})
	spits += 1
	spits_here += 1
	_last_spit_pos = global_position
	var hs := float(ProjScr.type_def(proj_id).get("launch_speed", 9.0))
	last_shot = {"target": target, "from": from, "aim": aim, "vel": vel, "flight_t": dist / maxf(hs, 0.1), "range": dist}
	_sfx_at("gallspitter_spit", from)
	spit_released.emit(self, p, last_shot)


func take_damage(amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, source: Node = null) -> bool:
	if is_multiplayer_authority() and not _dead and mode == Mode.SPIT and not _released \
			and amount >= float(max_health) * VC.num(b, "stagger_frac", 0.25):
		_cancel_spit() # a heavy hit during the wind-up chokes the spit
		var killed := super.take_damage(amount, hit_pos, crit, source)
		if not killed and _anims.has("hit"):
			_play("hit", 0.05)
			_attack_anim_t = 0.35
		return killed
	return super.take_damage(amount, hit_pos, crit, source)


func _die() -> void:
	if mode == Mode.SPIT:
		_cancel_spit()
	_spots.erase(get_instance_id())
	_apply_telegraph(0.0)
	super._die()
