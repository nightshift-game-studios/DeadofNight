extends CharacterBody3D
## Zombie: animated glTF model (random variant), navmesh chase, melee attacks,
## precision (head) hits, knockback, and a death animation.
## Spawned by main.gd each round; call setup() before adding it to the tree.
## Head shots: a small sphere hitbox rides the skeleton's head bone (BoneAttachment3D) on
## physics layer 6 (value 32), which only weapon rays and rockets query. The ray resolves it back
## to this zombie through the "hit_owner" meta. Audio: own 3D voice + feet players; vocals go
## through Sfx.zombie_voice(), which caps how many zombies talk at once.
## Statuses (skills): apply_status(id, {dur, amp, dps, source}) with ids
##   "mark" / "rot"  +amp damage taken (damage_taken_mult)
##   "burn"          dps, ticked every 0.5 s through the source player (source "dot"); refresh keeps the higher dps
##   "slow"          move speed x (1 - amp), strongest wins

signal hit(enemy: Node, amount: int)
signal died(enemy: Node)

@export var models: Array[PackedScene] = []
@export var model_height: float = 1.795 ## real height of the model (m); the model is auto-scaled to this
@export var size_variety: float = 0.06 ## random +/- scale per zombie (0 = exact model_height)
@export var speed: float = 3.2
@export var max_health: int = 100
@export var contact_damage: int = 10
@export var attack_interval: float = 1.0 ## seconds between hits
@export var attack_range: float = 1.4
@export var attack_max_dy: float = 1.6 ## max vertical gap (m) for a swing to start or land (no hitting through decks)
@export var attack_windup: float = 0.35 ## delay between starting a swing and the hit landing
@export var aggro_range: float = 80.0
@export var head_height: float = 1.2 ## fallback when the model has no head bone: hits above this (local Y) are precision hits
@export var model_faces_plus_z: bool = false ## true for models authored facing +Z (they get turned 180 degrees)
@export var head_bone: String = "Head"
@export var head_radius: float = 0.16 ## metres, world space
@export var head_offset: float = 0.09 ## metres along the head bone from its origin to the skull centre
@export var groan_interval: Vector2 = Vector2(4.0, 11.0) ## random seconds between idle groans

const HITBOX_LAYER := 32 ## physics layer 6: head hitboxes (weapon rays only)

var health: float
var target: Node3D
var knockback: Vector3 = Vector3.ZERO
var _attack_cd: float = 0.0
var _dead: bool = false
var _anim: AnimationPlayer
var _anims: Dictionary = {} ## "walk"/"run"/"attack"/"death"/"hit" -> animation name
var _attack_anim_t: float = 0.0
var _hit_delay: float = 0.0
var health_bar: ZombieHealthBar ## created in _ready, shown once damaged
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var head_hitbox: StaticBody3D ## null if the model has no head bone
var _head_shape: CollisionShape3D
var voice: AudioStreamPlayer3D
var feet: AudioStreamPlayer3D
var _chasing: bool = false
var _groan_t: float = 0.0
var _step_t: float = 0.0
var _hurt_cd: float = 0.0
var _statuses: Dictionary = {} ## id -> {t (seconds left), amp, dps, source}
var _burn_acc: float = 0.0
var _status_tick: bool = false ## true while a burn tick deals damage: no "hit" signal, so ticks pay no points per hit
const BURN_TICK := 0.5
var variant_id: String = "" ## data/zombies.json variant ("city" / "worker" / "soldier"), "" = scene default
const ZombieNavScr := preload("res://scripts/enemies/ai/zombie_nav.gd") ## MAIN_HOOKS §17: pathing, avoidance, step-up, stuck
var nav: RefCounted ## ZombieNav component (null = old direct/agent chase)

@onready var agent: NavigationAgent3D = $NavigationAgent3D
@onready var model_root: Node3D = $ModelRoot


## Configure per-round stats (called by the wave spawner before add_child).
func setup(new_health: int, new_speed: float, new_damage: int) -> void:
	max_health = new_health
	speed = new_speed
	contact_damage = new_damage


## Apply a data/zombies.json variant (call after setup() and before add_child): model, height, stat multipliers.
func set_variant(id: String, v: Dictionary, scene: PackedScene = null) -> void:
	variant_id = id
	if scene:
		models = [scene]
	model_height = float(v.get("model_height", model_height))
	max_health = maxi(int(round(max_health * float(v.get("health_mult", 1.0)))), 1)
	speed *= float(v.get("speed_mult", 1.0))
	contact_damage = maxi(int(round(contact_damage * float(v.get("damage_mult", 1.0)))), 1)


## True if a target this far away can be hit: horizontal reach plus a vertical limit, so a zombie
## under a deck can't swipe the player standing on it.
func in_attack_reach(dist_h: float, dy: float, extra: float = 0.0) -> bool:
	return dist_h <= attack_range + extra and absf(dy) < attack_max_dy


func _ready() -> void:
	add_to_group("enemies")
	health = max_health
	target = get_tree().get_first_node_in_group("player") as Node3D
	_spawn_model()
	_setup_audio()
	health_bar = ZombieHealthBar.make(model_height - 0.14) # sits just above the hunched head
	add_child(health_bar)
	nav = ZombieNavScr.attach(self) # §17a: one-time setup; avoidance switches on with the first nav.tick()


func _spawn_model() -> void:
	if models.is_empty():
		return
	var m: Node3D = models.pick_random().instantiate()
	model_root.add_child(m)
	var a := ModelUtil.get_aabb(m)
	var s: float = model_height / max(a.size.y, 0.01) * randf_range(1.0 - size_variety, 1.0 + size_variety) # slight size variety
	m.scale = Vector3.ONE * s
	m.position.y = -a.position.y * s
	if model_faces_plus_z:
		model_root.rotation.y = PI # our forward is -Z
	_attach_head_hitbox(m, s)
	_anim = m.find_children("*", "AnimationPlayer", true, false).front() if m.find_children("*", "AnimationPlayer", true, false).size() else null
	if _anim:
		var wanted := {"walk": ["Walk"], "run": ["Run"], "attack": ["Attack", "Punch"], "death": ["Death"], "hit": ["HitRecieve", "HitReact"], "idle": ["Idle"]}
		for key in wanted:
			for suffix in wanted[key]:
				var n := _find_anim(suffix)
				if n != "":
					_anims[key] = n
					break
		for k in ["walk", "run", "idle"]:
			if _anims.has(k):
				_anim.get_animation(_anims[k]).loop_mode = Animation.LOOP_LINEAR
		_anim.speed_scale = 1.0
		_play("walk")


## Sphere hitbox on the head bone, so headshots follow the hunched, animated head.
func _attach_head_hitbox(m: Node3D, s: float) -> void:
	var skels := m.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		return
	var sk: Skeleton3D = skels[0]
	var bi := sk.find_bone(head_bone)
	if bi < 0:
		return
	var att := BoneAttachment3D.new()
	att.name = "HeadAttachment"
	sk.add_child(att)
	att.bone_name = head_bone
	head_hitbox = StaticBody3D.new()
	head_hitbox.name = "HeadHitbox"
	head_hitbox.collision_layer = HITBOX_LAYER
	head_hitbox.collision_mask = 0
	head_hitbox.set_meta("hit_owner", self)
	head_hitbox.set_meta("is_head", true)
	_head_shape = CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = head_radius / max(s, 0.01) # the attachment inherits the model scale
	_head_shape.shape = sph
	_head_shape.position = Vector3(0, head_offset / max(s, 0.01), 0)
	head_hitbox.add_child(_head_shape)
	att.add_child(head_hitbox)


## World-space centre of the head hitbox (or the fallback head height).
func head_center() -> Vector3:
	if _head_shape and _head_shape.is_inside_tree():
		return _head_shape.global_position
	return global_position + Vector3(0, head_height + 0.12, 0)


func _setup_audio() -> void:
	voice = AudioStreamPlayer3D.new()
	voice.name = "Voice"
	voice.position = Vector3(0, 1.35, 0)
	voice.unit_size = 5.0
	voice.max_distance = 45.0
	voice.bus = "SFX"
	add_child(voice)
	feet = AudioStreamPlayer3D.new()
	feet.name = "Feet"
	feet.position = Vector3(0, 0.1, 0)
	feet.unit_size = 3.0
	feet.max_distance = 22.0
	feet.bus = "SFX"
	add_child(feet)
	_groan_t = randf_range(1.0, groan_interval.y)


func _say(key: String, priority: int) -> bool:
	var sfx := get_node_or_null("/root/Sfx")
	return sfx != null and sfx.zombie_voice(voice, key, priority)


func _audio_tick(delta: float, moving: bool) -> void:
	_hurt_cd = max(_hurt_cd - delta, 0.0)
	_groan_t -= delta
	if _groan_t <= 0.0:
		_groan_t = randf_range(groan_interval.x, groan_interval.y)
		if not voice.playing:
			_say("zombie_idle_groan", 0)
	if moving and is_on_floor():
		_step_t -= delta
		if _step_t <= 0.0:
			var running := speed > 4.2
			_step_t = clampf(1.7 / max(speed, 0.5), 0.28, 0.75)
			var sfx := get_node_or_null("/root/Sfx")
			if sfx and not feet.playing:
				var key: String = "zombie_footstep" if running or randf() < 0.35 else "zombie_shuffle"
				var st: AudioStream = sfx.stream(key)
				if st:
					var mx: Array = sfx.mix(key)
					feet.stream = st
					feet.volume_db = float(mx[0])
					feet.pitch_scale = randf_range(0.9, 1.1)
					feet.play()


func _find_anim(suffix: String) -> String:
	for n in _anim.get_animation_list():
		if n == suffix or n.ends_with("|" + suffix) or n.ends_with("_" + suffix):
			return n
	return ""


func _play(key: String, blend: float = 0.2) -> void:
	if _anim and _anims.has(key) and _anim.current_animation != _anims[key]:
		_anim.play(_anims[key], blend)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	if _dead:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		return
	_attack_cd = max(_attack_cd - delta, 0.0)
	_attack_anim_t = max(_attack_anim_t - delta, 0.0)
	tick_statuses(delta)
	if _dead:
		return

	var move_dir := Vector3.ZERO
	var player_alive: bool = target != null and is_instance_valid(target) and not target.get("dead")
	if player_alive:
		var to_player := target.global_position - global_position
		var dy := to_player.y
		to_player.y = 0.0
		var dist := to_player.length()
		var level := absf(dy) < attack_max_dy
		if dist <= aggro_range and (dist > attack_range * 0.8 or not level): # keep pathing (stairs) if the player is above / below
			move_dir = _chase_direction(to_player)
			if not _chasing:
				_chasing = true
				_say("zombie_aggro_scream", 2)
		elif dist > aggro_range:
			_chasing = false
		if in_attack_reach(dist, dy) and _attack_cd <= 0.0:
			_attack_cd = attack_interval
			_attack_anim_t = 0.8
			_hit_delay = attack_windup
			_play("attack", 0.1)
			_say("zombie_attack_swipe", 2)
		if _hit_delay > 0.0:
			_hit_delay -= delta
			if _hit_delay <= 0.0 and in_attack_reach(dist, dy, 0.5):
				target.call("take_damage", contact_damage, self) # the swing lands mid-animation; back off to dodge it
		if dist > 0.01:
			var look := Vector3(to_player.x, 0, to_player.z)
			var desired := atan2(-look.x, -look.z)
			rotation.y = lerp_angle(rotation.y, desired, clamp(10.0 * delta, 0.0, 1.0))

	knockback = knockback.lerp(Vector3.ZERO, clamp(5.0 * delta, 0.0, 1.0))
	var spd := speed * slow_mult()
	if nav: # §17c: repath throttle + RVO avoidance + step-up + move_and_slide + stuck recovery (authority only)
		nav.tick(delta, move_dir * spd)
	else:
		velocity.x = move_dir.x * spd + knockback.x
		velocity.z = move_dir.z * spd + knockback.z
		if knockback.y > 0.5 and is_on_floor():
			velocity.y = knockback.y
			knockback.y = 0.0
		move_and_slide()
	_audio_tick(delta, move_dir != Vector3.ZERO)

	if _attack_anim_t <= 0.0:
		if move_dir != Vector3.ZERO:
			_play("run" if speed > 4.2 and _anims.has("run") else "walk")
			if _anim:
				_anim.speed_scale = clamp(speed / (5.0 if speed > 4.2 else 2.6), 0.6, 1.8)
		else:
			_play("idle")


## ZombieNav path (§17b); without it: the navmesh path if one is available, otherwise straight for the player.
func _chase_direction(to_player: Vector3) -> Vector3:
	if nav: # §17b: ZombieNav path (throttled repath, flat waypoint passing)
		return nav.direction(to_player)
	var map := agent.get_navigation_map()
	if map.is_valid() and NavigationServer3D.map_get_iteration_id(map) > 0:
		agent.target_position = target.global_position
		if not agent.is_navigation_finished():
			var next := agent.get_next_path_position()
			var dir := next - global_position
			dir.y = 0.0
			if dir.length() > 0.05:
				return dir.normalized()
	return to_player.normalized()


## True if a hit at `world_pos` is on the head: inside the head-bone sphere (with a little
## slack for hits that land on the body capsule right next to it), or above head_height when
## the model has no head bone.
func is_precision_hit(world_pos: Vector3) -> bool:
	if head_hitbox:
		return world_pos.distance_to(head_center()) <= head_radius * 1.25
	return world_pos.y - global_position.y >= head_height


func apply_knockback(v: Vector3) -> void:
	if not _dead:
		knockback += v


## Returns true if this hit killed the zombie.
func take_damage(amount: float, _hit_pos: Vector3 = Vector3.ZERO, _crit: bool = false, _source: Node = null) -> bool:
	if _dead:
		return false
	amount *= damage_taken_mult()
	health -= amount
	if not _status_tick:
		hit.emit(self, int(amount))
	if health_bar:
		health_bar.show_damage(health / float(max(max_health, 1)))
	if health <= 0.0:
		_die()
		return true
	if _hurt_cd <= 0.0:
		_hurt_cd = 0.45
		_say("zombie_hurt", 1)
	if _attack_anim_t <= 0.0 and randf() < 0.3:
		_play("hit", 0.05)
		_attack_anim_t = 0.25
	return false


# ---------------------------------------------------------------- statuses (skills)

## Reapplying refreshes the duration (never shortens it) and keeps the stronger amp / dps.
func apply_status(id: String, p: Dictionary) -> void:
	if _dead:
		return
	var cur: Dictionary = _statuses.get(id, {})
	_statuses[id] = {"t": maxf(float(p.get("dur", 3.0)), float(cur.get("t", 0.0))),
		"amp": maxf(float(p.get("amp", 0.0)), float(cur.get("amp", 0.0))),
		"dps": maxf(float(p.get("dps", 0.0)), float(cur.get("dps", 0.0))),
		"source": p.get("source", cur.get("source"))}


func has_status(id: String) -> bool:
	return float(_statuses.get(id, {}).get("t", 0.0)) > 0.0


func status(id: String) -> Dictionary:
	return _statuses.get(id, {})


## Mark + Rot amplify all incoming damage.
func damage_taken_mult() -> float:
	var m := 1.0
	for id in ["mark", "rot"]:
		if has_status(id):
			m += float(_statuses[id].amp)
	return m


func slow_mult() -> float:
	return 1.0 - clampf(float(_statuses.get("slow", {}).get("amp", 0.0)), 0.0, 0.9) if has_status("slow") else 1.0


## Counts statuses down; burn deals dps every BURN_TICK through its source player (register_hit, source "dot").
func tick_statuses(delta: float) -> void:
	if _statuses.is_empty():
		return
	if has_status("burn"):
		_burn_acc += minf(delta, float(_statuses.burn.t))
		while _burn_acc >= BURN_TICK - 0.0001 and not _dead:
			_burn_acc -= BURN_TICK
			var b: Dictionary = _statuses.burn
			var dmg := float(b.dps) * BURN_TICK
			var src = b.get("source")
			_status_tick = true
			var killed := take_damage(dmg, global_position + Vector3(0, 1.0, 0), false, src)
			_status_tick = false
			if src != null and is_instance_valid(src) and src.has_method("register_hit"):
				src.register_hit(self, dmg, false, killed, {"source": "dot", "element": "blaze", "depth": 1})
	else:
		_burn_acc = 0.0
	for id in _statuses.keys():
		_statuses[id].t = float(_statuses[id].t) - delta
		if float(_statuses[id].t) <= 0.0:
			_statuses.erase(id)


func _die() -> void:
	_dead = true
	if health_bar:
		health_bar.hide_now()
	if head_hitbox:
		head_hitbox.collision_layer = 0
	_say("zombie_death", 3)
	remove_from_group("enemies")
	collision_layer = 0
	collision_mask = 1
	died.emit(self)
	if _anim and _anims.has("death"):
		_anim.speed_scale = 1.0
		_anim.play(_anims["death"], 0.1)
	var tween := create_tween()
	tween.tween_interval(1.6)
	tween.tween_property(model_root, "position:y", -1.2, 0.8)
	tween.tween_callback(queue_free)
