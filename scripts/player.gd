extends CharacterBody3D
## First-person player.
##  - Movement: walk / sprint / jump, crouch, sprint-slide (+ slide-jump), wall jumping.
##  - Combat: inventory weapons (hitscan + rockets), perks, melee (V), grenades (G), class ability (Q).
##  - Stats: class + skill tree + armor stats (Agility, Toughness, Vitality, Ordnance, Focus, Brawn).
##  - Audio goes through the Sfx autoload (scripts/audio/sfx.gd): gunfire per weapon (weapons.json
##    "fire_sfx"), reloads, dry fire, swaps, impacts by surface, footsteps, jump/land/slide/wall jump,
##    hurt/death, melee, abilities, grenade throw and the low-health heartbeat.
##  - Skills: a SkillRunner child (scripts/skills/skill_runner.gd) runs meta-tree + Field Card effects.
##    The player emits gameplay events on the GameEvents bus (hit, enemy_killed, shot_fired, slide_started,
##    wall_jumped, landed, damage_taken, ...) and asks mod_stat(stat, base, ctx) at every tunable number.
##    Overshield absorbs damage before health; grenade and ability have charges (default 1).

signal health_changed(current: int, maximum: int)
signal ammo_changed(in_mag: int, reserve: int, reloading: bool)
signal died
signal points_changed(points: int)
signal ability_changed(ability_name: String, cooldown_left: float, cooldown_total: float)
signal grenade_changed(grenade_name: String, cooldown_left: float, cooldown_total: float)
signal melee_changed(cooldown_left: float, cooldown_total: float)
signal weapon_changed(weapon: WeaponItem)
signal weapons_updated
signal stats_changed
signal pickup_prompt_changed(text: String, key_action: String) ## routed to hud.show_hint()
signal loot_received(item: Item)
## Every hit the player lands (hitscan, melee, explosions they caused). The HUD draws hit
## markers from it and HitSfx plays the matching hitmarker sound.
signal hit_registered(target: Node, damage: float, is_headshot: bool, is_kill: bool)
signal overshield_changed(current: float, cap: float)
signal grenade_charges_changed(charges: int, max_charges: int)
signal ability_charges_changed(charges: int, max_charges: int)

enum Move { NORMAL, CROUCH, SLIDE }

# ADS (Skillz MAIN_HOOKS §8): AdsProfile tables, Settings.ads_mode hold|toggle, RMB action "ads".
const AdsProfileScr := preload("res://scripts/combat/ads_profile.gd")
const PlayerStatusScr := preload("res://scripts/combat/player_status.gd") ## MAIN_HOOKS §15b: Crawler root, Bloater bile slow
signal ads_changed(active: bool) ## Gooey sniper scope overlay listens when AdsProfile.wants_scope_overlay(archetype)
var ads_active: bool = false
## Optics pass (Skillz MAIN_HOOKS §18): 0 = hip .. 1 = fully aimed, stepped over the build's ADS time
## (AdsProfile.ads_time: class base x optic/part ads_time_mult). FOV, spread and the gun pose follow it.
var ads_blend: float = 0.0
var _ads_sway_t: float = 0.0
var _hip_fov: float = 75.0
const ArmoryScr := preload("res://scripts/armory/armory.gd")
const WeaponRigScr := preload("res://scripts/gear/weapon_rig.gd") ## Armory attachments on the view model (Skillz art pass)
var _gun_model: Node3D ## current first-person gun model (re-fitted when the Armory loadout changes)
var _gun_rig: Dictionary = {} ## last WeaponRig.apply() result: attached / hidden / missing / muzzle / sight / lamp
const FPArmsScr := preload("res://scripts/gear/fp_arms.gd") ## Desi fp_arms v2: first-person arms on the view model
const ADS_NEAR := 0.002 ## camera near plane while aiming (fp_arms v2: stops stocks / tubes clipping the ADS eye black)
var _fp_arms: Node3D ## arms instance under _gun_model (null without a gun / arms clips)
var arms_tint = "P1" ## forearm band colour: "P1".."P4" or a Color (co-op sets the local player's own colour)
var _hip_near: float = 0.02 ## camera.near outside ADS (read from the scene in _ready)
## Mine Lamp (Skillz §10 + Mapz): camera SpotLight3D, F to toggle, gated on Armory.has_flashlight(archetype) (Mine Lamp or Lantern Rail).
var _flashlight: SpotLight3D
var _flashlight_on: bool = false
const HEAD_HITBOX_LAYER := 32 ## zombie head hitboxes (enemy.gd); only weapon rays query it

## Class (stats + Q ability + grenade). If empty, the class chosen in Progress is loaded.
@export var player_class: PlayerClass

@export_group("Movement")
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var crouch_speed: float = 2.8
@export var jump_velocity: float = 5.0
@export var acceleration: float = 12.0
@export var air_acceleration: float = 10.0
@export var mouse_sensitivity: float = 0.0025
var invert_y: bool = false

@export_group("Slide")
@export var slide_boost: float = 1.25 ## speed multiplier when a slide starts
@export var slide_friction: float = 2.5 ## constant deceleration (m/s^2)
@export var slide_drag: float = 0.7 ## extra deceleration proportional to speed
@export var slide_steer: float = 1.5

@export_group("Wall Jump")
@export var wall_jump_push: float = 6.5
@export var wall_jump_up: float = 5.6
@export var max_wall_jumps: int = 3 ## resets when you touch the ground
@export var wall_jump_cooldown: float = 0.25
@export var wall_check_distance: float = 0.75
@export var floor_probe_distance: float = 0.12 ## a jump this close above the floor is a ground jump (never a wall kick)
@export var ground_jump_kick_lock: float = 0.15 ## no wall kick for this long after a ground jump (one press can't do both)

@export_group("Heights")
@export var stand_height: float = 1.8
@export var crouch_height: float = 1.1
@export var slide_height: float = 1.0
@export var head_stand: float = 1.6
@export var head_crouch: float = 0.95
@export var head_slide: float = 0.8

@export_group("Health")
@export var max_health: int = 100

var health: int
var points: int = 0
var dead: bool = false
var input_enabled: bool = true
var ability: Ability
var grenade_data: Dictionary = {}
var speed_multiplier: float = 1.0 ## abilities can change this
var movement_locked_time: float = 0.0 ## >0 while a dash etc. overrides movement
var reload_multiplier: float = 1.0 ## from skills (<1 = faster)
var move_state: int = Move.NORMAL
var armor_stats: Dictionary = {}

# Derived from armor stats (see recalc_stats)
var damage_reduction: float = 0.0
var regen_delay: float = 4.0
var regen_rate: float = 6.0
var grenade_cooldown: float = 20.0
var melee_damage: float = 70.0
var melee_cooldown: float = 1.6

var _base_max_health: int = 100
var _base_walk: float = 5.0
var _base_sprint: float = 8.5
var _ability_base_cd: float = 5.0
var _ability_cd: float = 0.0
var _ability_active: float = 0.0
var _grenade_cd: float = 0.0
var _melee_cd: float = 0.0
var _cooldown: float = 0.0
var _swap_t: float = 0.0
var _reloading: bool = false
var _reload_tween: Tween
var _since_damage: float = 99.0
var _regen_acc: float = 0.0
var _wall_jumps_left: int = 3
var _wall_cd: float = 0.0
var _coyote: float = 0.0
var _crouch_was: bool = false
var _jump_was: bool = false
var _shake: float = 0.0
var _bob_t: float = 0.0
var _gun_rest: Vector3
var _gun_kick: Vector3
var _nearby: Array = []
var _shape: CapsuleShape3D
var _burst_left: int = 0 ## rounds still to fire in the current burst (weapons.json "burst")
var _burst_t: float = 0.0
var _burst_w: WeaponItem
var _dry_t: float = 0.0
var _hurt_sfx_t: float = 0.0
var _step_acc: float = 0.0
var _was_on_floor: bool = true
var _fall_speed: float = 0.0
var _audio_ready: bool = false ## no swap sound for the starting loadout

# Skills (see scripts/skills/)
var skill_runner: SkillRunner
var overshield: float = 0.0
var overshield_cap: float = 50.0
var invulnerable_t: float = 0.0
var grenade_charges: int = 1
var grenade_charges_max: int = 1
var ability_charges: int = 1
var ability_charges_max: int = 1
var regen_disabled: bool = false
var slide_floor_time: float = 0.0
const REFUND_CAP_FRACTION := 0.6 ## max grenade-cooldown refunds per REFUND_WINDOW (fraction of one cooldown)
const REFUND_WINDOW := 5.0
var _refund_log: Array = [] ## [[time, fraction], ...] for the rolling refund cap
var _clock: float = 0.0 ## game seconds, drives the refund window
var _base_wall_jumps: int = 3
var _base_wall_jump_up: float = 5.6
var _slide_t: float = 0.0 ## seconds into the current slide
var _since_slide: float = 99.0 ## seconds since the last slide ended
var _still_t: float = 0.0
var _prev_move_state: int = Move.NORMAL
@export_group("Audio")
@export var stride_length: float = 2.1 ## metres per footstep (sprinting stretches it a bit)
@export var low_health_fraction: float = 0.3 ## heartbeat below this
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var gun: Node3D = $Head/Camera3D/Gun
@onready var gun_model_root: Node3D = $Head/Camera3D/Gun/Model
@onready var muzzle: Marker3D = $Head/Camera3D/Gun/Muzzle
@onready var flash: Node3D = $Head/Camera3D/Gun/Muzzle/Flash
@onready var inventory: Inventory = $Inventory
@onready var collision: CollisionShape3D = $CollisionShape3D


func _ready() -> void:
	add_to_group("player")
	_shape = collision.shape.duplicate()
	collision.shape = _shape
	_gun_rest = gun.position
	_hip_near = camera.near
	flash.visible = false
	_base_wall_jumps = max_wall_jumps
	_base_wall_jump_up = wall_jump_up
	_wall_jumps_left = max_wall_jumps
	skill_runner = SkillRunner.new()
	skill_runner.name = "SkillRunner"
	add_child(skill_runner)
	skill_runner.setup(self)
	inventory.weapon_equipped.connect(_on_weapon_equipped)
	inventory.armor_changed.connect(recalc_stats)
	inventory.changed.connect(func(): weapons_updated.emit())
	inventory.give_starter_loadout()
	apply_stats()
	health = max_health
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_apply_look_settings()
	_flashlight = SpotLight3D.new()
	_flashlight.name = "Flashlight"
	camera.add_child(_flashlight)
	_apply_flashlight_cfg(ArmoryScr.flashlight_values(ArmoryScr.attachment("mine_lamp"))) # data: attachments.json mine_lamp light_*
	_flashlight.shadow_enabled = false
	_flashlight.visible = false
	_flashlight.position = Vector3(0.12, -0.05, -0.1)
	var _pg := get_node_or_null("/root/Progress")
	if _pg and _pg.has_signal("armory_changed") and not _pg.armory_changed.is_connected(_on_armory_changed):
		_pg.armory_changed.connect(_on_armory_changed)
	var _st := get_node_or_null("/root/Settings")
	if _st and not _st.changed.is_connected(_on_settings_changed):
		_st.changed.connect(_on_settings_changed)
	_emit_status.call_deferred()
	set_deferred("_audio_ready", true)


## Sfx autoload, or null (e.g. when a script runs this scene without autoloads).
func _sfx() -> Node:
	return get_node_or_null("/root/Sfx")


func _snd(key: String, volume_offset: float = 0.0) -> void:
	var a := _sfx()
	if a:
		a.play(key, volume_offset)


# ------------------------------------------------------------------ stats

## Class + meta skill tree. Safe to call again (e.g. after unlocking a skill at round 0): rebuilds the
## SkillRunner, which resets effect state, so never call it for mid-match Field Cards (use recalc_stats()).
func apply_stats() -> void:
	if player_class == null:
		player_class = Progress.load_selected_class()
	var jump := 5.0
	var cd_template := 5.0
	if player_class:
		_base_max_health = player_class.max_health
		_base_walk = player_class.walk_speed
		_base_sprint = player_class.sprint_speed
		jump = player_class.jump_velocity
		# keep the live ability (and its cooldown) when stats are re-applied mid-session
		if player_class.ability == null:
			ability = null
		elif ability == null or ability.get_script() != player_class.ability.get_script():
			ability = player_class.ability.duplicate()
		if player_class.ability:
			cd_template = player_class.ability.cooldown # the template, so Focus never compounds
		grenade_data = GearDB.grenade(player_class.grenade_id)
	else:
		grenade_data = GearDB.grenade("frag")
		if ability:
			cd_template = ability.cooldown
	_base_jump_velocity = jump
	_ability_base_cd = cd_template
	var was_full: bool = health >= max_health or max_health <= 0
	if skill_runner:
		skill_runner.rebuild()
	recalc_stats()
	# refill only if already at full HP (start of game / pre-round), never heal a damaged player mid-match
	health = max_health if was_full else min(health, max_health)
	health_changed.emit(health, max_health)


var _base_jump_velocity: float = 5.0


## Stat modifier from skills: folds `base` through the SkillRunner (identity without skills).
func mod_stat(stat: String, base: float, ctx: Dictionary = {}) -> float:
	return skill_runner.modify(stat, base, ctx) if skill_runner else base


## Armor stats -> gameplay. Called whenever armor changes.
func recalc_stats() -> void:
	armor_stats = inventory.total_armor_stats()
	var mob: float = armor_stats.get("agility", 0)
	var res: float = armor_stats.get("toughness", 0)
	var rec: float = armor_stats.get("vitality", 0)
	var dis: float = armor_stats.get("ordnance", 0)
	var intl: float = armor_stats.get("focus", 0)
	var stre: float = armor_stats.get("brawn", 0)
	# skills: meta tree + Field Cards (stat names: see GOOEY_HANDOFF.md "Stats")
	max_health = maxi(int(round(mod_stat("max_health_mult", 1.0) * mod_stat("max_health", float(_base_max_health)))), 1)
	health = mini(health, max_health)
	var move := 1.0 + mod_stat("move_speed", 0.0)
	walk_speed = _base_walk * move * (1.0 + mob * 0.002) # 100 Agility = +20% speed
	sprint_speed = _base_sprint * move * (1.0 + mob * 0.002)
	damage_reduction = res * 0.003 # 100 Toughness = 30% damage reduction
	regen_delay = max(4.0 - rec * 0.02 + mod_stat("regen_delay_add", 0.0), 1.5) # 100 Vitality = regen after 2s
	regen_rate = 6.0 + rec * 0.2 + mod_stat("regen_rate_add", 0.0) # ... at 26 HP/s
	regen_disabled = mod_stat("regen_disabled", 0.0) > 0.0
	reload_multiplier = maxf((1.0 - mod_stat("reload_speed", 0.0)) * mod_stat("reload_time_mult", 1.0), 0.2)
	grenade_cooldown = float(grenade_data.get("cooldown", 20.0)) * (1.0 - dis * 0.005) * mod_stat("grenade_cd_mult", 1.0) # 100 = half cooldown
	if ability:
		var cd := (_ability_base_cd + mod_stat("ability_cooldown_add", 0.0)) * maxf(1.0 - mod_stat("ability_cooldown", 0.0), 0.2)
		ability.cooldown = maxf(cd * (1.0 - intl * 0.004) * mod_stat("ability_cd_mult", 1.0), 1.0) # 100 Focus = -40%, floor 1 s
	melee_damage = 70.0 * (1.0 + stre * 0.006) * mod_stat("melee_damage_mult", 1.0) # 100 Brawn = +60% melee damage
	melee_cooldown = 1.6 * (1.0 - stre * 0.004) # ... and -40% melee cooldown
	var jm := mod_stat("jump_mult", 1.0)
	jump_velocity = _base_jump_velocity * jm
	wall_jump_up = _base_wall_jump_up * jm
	max_wall_jumps = _base_wall_jumps + int(mod_stat("max_wall_jumps_add", 0.0))
	slide_floor_time = mod_stat("slide_floor_time", 0.0)
	overshield_cap = maxf(mod_stat("overshield_cap", 50.0), 0.0)
	overshield = minf(overshield, overshield_cap)
	Engine.set_meta(WeaponItem.MAG_BONUS_META, mod_stat("mag_size_mult", 1.0) - 1.0)
	var gmax := 1 + int(mod_stat("grenade_charges_add", 0.0))
	if gmax != grenade_charges_max:
		grenade_charges = clampi(grenade_charges + gmax - grenade_charges_max, 0, gmax)
		grenade_charges_max = gmax
	var amax := 1 + int(mod_stat("ability_charges_add", 0.0))
	if amax != ability_charges_max:
		ability_charges = clampi(ability_charges + amax - ability_charges_max, 0, amax)
		ability_charges_max = amax
	stats_changed.emit()
	_emit_status()


func _emit_status() -> void:
	health_changed.emit(health, max_health)
	overshield_changed.emit(overshield, overshield_cap)
	grenade_charges_changed.emit(grenade_charges, grenade_charges_max)
	ability_charges_changed.emit(ability_charges, ability_charges_max)
	emit_ammo()
	points_changed.emit(points)
	_emit_ability()
	grenade_changed.emit(grenade_data.get("name", "Grenade"), _grenade_cd, grenade_cooldown)
	melee_changed.emit(_melee_cd, melee_cooldown)
	weapon_changed.emit(inventory.get_equipped_weapon())
	weapons_updated.emit()


func emit_ammo() -> void:
	var w := inventory.get_equipped_weapon()
	if w:
		ammo_changed.emit(w.ammo, w.reserve, _reloading)
	else:
		ammo_changed.emit(0, 0, false)
	weapons_updated.emit()


func _emit_ability() -> void:
	if ability:
		ability_changed.emit(ability.display_name, _ability_cd, ability.cooldown)
	else:
		ability_changed.emit("", 0.0, 0.0)


func is_crouched() -> bool:
	return move_state != Move.NORMAL


# ------------------------------------------------------------------ input

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_mouse"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif input_enabled:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if not input_enabled or dead:
		return
	if event is InputEventMouseButton and event.pressed \
			and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity * (-1.0 if invert_y else 1.0))
		head.rotation.x = clamp(head.rotation.x, deg_to_rad(-89.0), deg_to_rad(89.0))

	if event.is_action_pressed("reload"):
		reload()
	elif event.is_action_pressed("ability"):
		use_ability()
	elif event.is_action_pressed("grenade"):
		throw_grenade()
	elif event.is_action_pressed("melee"):
		melee()
	elif event.is_action_pressed("interact"):
		_interact()
	elif event.is_action_pressed("flashlight"):
		_toggle_flashlight()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		wheel_swap(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1)
	elif event.is_action_pressed("weapon_1"):
		inventory.equip_index(0)
	elif event.is_action_pressed("weapon_2"):
		inventory.equip_index(1)
	elif event.is_action_pressed("weapon_3"):
		inventory.equip_index(2)
	elif event.is_action_pressed("shoot"):
		shoot()


# ------------------------------------------------------------------ physics / movement

func _physics_process(delta: float) -> void:
	_tick_timers(delta)
	_tick_ads(delta)
	var on_floor := is_on_floor()
	if on_floor and not _was_on_floor:
		if _fall_speed > 3.5:
			_snd("land", clampf((_fall_speed - 8.0) * 0.8, -6.0, 3.0))
		_ev(&"landed", {"fall_speed": _fall_speed})
	_was_on_floor = on_floor
	_fall_speed = maxf(-velocity.y, 0.0)
	if on_floor:
		_wall_jumps_left = max_wall_jumps
		_coyote = 0.12
	else:
		velocity.y -= _gravity * delta

	var can_act := input_enabled and not dead
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back") if can_act else Vector2.ZERO
	var wish_dir := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var crouch_held := can_act and Input.is_action_pressed("crouch")
	var sprinting := can_act and Input.is_action_pressed("sprint") and input_dir.y < 0.0
	var hvel := Vector3(velocity.x, 0.0, velocity.z)
	var hspeed := hvel.length()
	# Edge detection (also catches presses injected with Input.action_press, e.g. by tests).
	var jump_held := can_act and Input.is_action_pressed("jump")
	var crouch_pressed := can_act and (Input.is_action_just_pressed("crouch") or (crouch_held and not _crouch_was))
	# One press = one jump: just_pressed can still read true on the frame after the edge, which used to turn a
	# ground jump next to a wall into ground jump + wall kick.
	var jump_pressed := can_act and not _jump_was and (jump_held or Input.is_action_just_pressed("jump"))
	_crouch_was = crouch_held
	_jump_was = jump_held

	# --- state transitions
	if crouch_pressed and on_floor and move_state == Move.NORMAL \
			and hspeed > walk_speed + 0.5:
		move_state = Move.SLIDE # sprint-slide
		_snd("slide")
		var dir := hvel.normalized()
		var sp: float = max(hspeed, sprint_speed) * slide_boost
		velocity.x = dir.x * sp
		velocity.z = dir.z * sp
		_slide_t = 0.0
		_ev(&"slide_started", {"speed": sp})
	elif crouch_held and move_state == Move.NORMAL and on_floor:
		move_state = Move.CROUCH
	elif not crouch_held and move_state != Move.NORMAL and _can_stand():
		move_state = Move.NORMAL

	# --- jumping (ground, coyote, slide-jump, wall jump)
	if jump_pressed:
		var kind := jump_kind(on_floor)
		if kind == "ground":
			velocity.y = jump_velocity
			_coyote = 0.0
			_wall_cd = maxf(_wall_cd, ground_jump_kick_lock)
			_snd("jump")
			_ev(&"jumped", {"from_slide": move_state == Move.SLIDE})
			if move_state == Move.SLIDE:
				velocity.x *= 1.05 # slide-jump keeps (and slightly boosts) momentum
				velocity.z *= 1.05
				move_state = Move.NORMAL if _can_stand() else Move.CROUCH
		elif kind == "wall":
			var n := _find_wall_normal()
			if n != Vector3.ZERO:
				var along := hvel - n * hvel.dot(n)
				velocity.x = n.x * wall_jump_push + along.x * 0.7
				velocity.z = n.z * wall_jump_push + along.z * 0.7
				velocity.y = wall_jump_up
				_wall_jumps_left -= 1
				_wall_cd = wall_jump_cooldown
				_snd("wall_jump_push")
				_ev(&"wall_jumped", {"jumps_left": _wall_jumps_left})

	# --- horizontal movement
	if movement_locked_time > 0.0:
		movement_locked_time -= delta # e.g. dashing
	elif move_state == Move.SLIDE and on_floor:
		hvel = Vector3(velocity.x, 0.0, velocity.z)
		var sp := hvel.length()
		sp = max(sp - (slide_friction + sp * slide_drag) * delta, 0.0) # friction-based decay
		_slide_t += delta
		if _slide_t < slide_floor_time:
			sp = maxf(sp, sprint_speed) # Undertow Glide: hold sprint speed early in the slide
		_ev(&"slide_tick", {"speed": sp, "t": _slide_t})
		var dir := hvel.normalized() if sp > 0.01 else -transform.basis.z
		if wish_dir != Vector3.ZERO:
			dir = dir.lerp(wish_dir, clamp(slide_steer * delta, 0.0, 1.0)).normalized()
		velocity.x = dir.x * sp
		velocity.z = dir.z * sp
		if sp < crouch_speed:
			move_state = Move.CROUCH if crouch_held or not _can_stand() else Move.NORMAL
	else:
		var speed := walk_speed
		if move_state == Move.CROUCH:
			speed = crouch_speed
		elif sprinting:
			speed = sprint_speed
		speed *= speed_multiplier
		speed *= AdsProfileScr.move_speed_mult(ads_active) # ~0.7 while aiming
		speed *= PlayerStatusScr.move_mult(self) # §15b: 0 while a Crawler holds you, -45% in Bloater bile
		var wish := wish_dir * speed
		if on_floor:
			velocity.x = lerp(velocity.x, wish.x, clamp(acceleration * delta, 0.0, 1.0))
			velocity.z = lerp(velocity.z, wish.z, clamp(acceleration * delta, 0.0, 1.0))
		elif wish_dir != Vector3.ZERO:
			# Air control: steer without bleeding momentum gained from slides / wall jumps.
			hvel = Vector3(velocity.x, 0.0, velocity.z)
			if hvel.length() > speed:
				var keep := hvel.length()
				hvel = (hvel + wish_dir * air_acceleration * delta).normalized() * keep
			else:
				hvel = hvel.move_toward(wish, air_acceleration * delta)
			velocity.x = hvel.x
			velocity.z = hvel.z

	PlayerStatusScr.pin(self) # §15b: rooted = no horizontal velocity (slides / momentum too); jumping still works
	move_and_slide()
	if _prev_move_state == Move.SLIDE and move_state != Move.SLIDE:
		_since_slide = 0.0
		_ev(&"slide_ended", {"t": _slide_t})
	_prev_move_state = move_state
	_since_slide += delta
	_still_t = _still_t + delta if on_floor and Vector2(velocity.x, velocity.z).length() < 0.3 else 0.0
	_footsteps(delta, sprinting)
	_update_body_height(delta)
	_update_view(delta, sprinting)
	_regen(delta)

	var w := inventory.get_equipped_weapon()
	if w and w.automatic() and can_act and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
			and Input.is_action_pressed("shoot"):
		shoot()


func _tick_timers(delta: float) -> void:
	_cooldown = max(_cooldown - delta, 0.0)
	_swap_t = max(_swap_t - delta, 0.0)
	_wall_cd = max(_wall_cd - delta, 0.0)
	_coyote = max(_coyote - delta, 0.0)
	_dry_t = max(_dry_t - delta, 0.0)
	_hurt_sfx_t = max(_hurt_sfx_t - delta, 0.0)
	invulnerable_t = maxf(invulnerable_t - delta, 0.0)
	_clock += delta
	if _burst_left > 0:
		_burst_t -= delta
		if _burst_t <= 0.0:
			_continue_burst()
	var a := _sfx()
	if a:
		var frac := float(health) / float(max(max_health, 1))
		a.set_low_health(not dead and frac < low_health_fraction, 1.0 - frac / low_health_fraction)
	_since_damage += delta
	_tick_ability(delta)
	if _grenade_cd > 0.0:
		_grenade_cd = max(_grenade_cd - delta, 0.0)
		if _grenade_cd <= 0.0:
			_grenade_recharged()
		grenade_changed.emit(grenade_data.get("name", "Grenade"), _grenade_cd, grenade_cooldown)
	if _melee_cd > 0.0:
		_melee_cd = max(_melee_cd - delta, 0.0)
		melee_changed.emit(_melee_cd, melee_cooldown)
	for w in inventory.weapons():
		PerkSystem.tick(w, delta)


## One footstep per `stride_length` metres on the ground (not while sliding).
func _footsteps(delta: float, sprinting: bool) -> void:
	var hs := Vector2(velocity.x, velocity.z).length()
	if not is_on_floor() or move_state == Move.SLIDE or hs < 0.8:
		_step_acc = stride_length * 0.6 # first step comes quickly after starting to move
		return
	_step_acc += hs * delta
	var stride := stride_length * (1.2 if sprinting else 1.0) * (0.8 if move_state == Move.CROUCH else 1.0)
	if _step_acc >= stride:
		_step_acc = 0.0
		_snd("footstep_concrete", (3.0 if sprinting else 0.0) - (6.0 if move_state == Move.CROUCH else 0.0))


func _can_stand() -> bool:
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, 0.5, 0),
		global_position + Vector3(0, stand_height + 0.05, 0))
	q.collision_mask = 1
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## What a jump press does right now: "ground", "wall" (spends one of the wall kicks) or "" (nothing).
## A ground jump always wins: is_on_floor() can flicker off for a frame while you push into a wall,
## so standing (not rising) within floor_probe_distance of a floor also counts as grounded.
func jump_kind(on_floor: bool) -> String:
	if on_floor or _coyote > 0.0 or (velocity.y <= 0.5 and _floor_below()):
		return "ground"
	if _wall_jumps_left > 0 and _wall_cd <= 0.0 and _find_wall_normal() != Vector3.ZERO:
		return "wall"
	return ""


## True if a floor (not a wall) is within floor_probe_distance under the feet.
func _floor_below() -> bool:
	var col := KinematicCollision3D.new()
	if not test_move(global_transform, Vector3(0.0, -floor_probe_distance, 0.0), col, 0.001):
		return false
	for i in col.get_collision_count():
		if col.get_normal(i).angle_to(up_direction) <= floor_max_angle + 0.01:
			return true
	return false


func _find_wall_normal() -> Vector3:
	if is_on_wall():
		var n := get_wall_normal()
		n.y = 0.0
		if n.length() > 0.1:
			return n.normalized()
	var space := get_world_3d().direct_space_state
	var best := Vector3.ZERO
	var best_d := INF
	var from := global_position + Vector3(0, 1.0, 0)
	for i in 8:
		var a := TAU * i / 8.0
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(cos(a), 0, sin(a)) * wall_check_distance)
		q.collision_mask = 1
		q.exclude = [get_rid()]
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var d: float = from.distance_to(hit.position)
			var n: Vector3 = hit.normal
			n.y = 0.0
			if d < best_d and n.length() > 0.5:
				best_d = d
				best = n.normalized()
	return best


func _update_body_height(delta: float) -> void:
	var target_h := stand_height
	var target_head := head_stand
	if move_state == Move.CROUCH:
		target_h = crouch_height
		target_head = head_crouch
	elif move_state == Move.SLIDE:
		target_h = slide_height
		target_head = head_slide
	_shape.height = move_toward(_shape.height, target_h, 6.0 * delta)
	collision.position.y = _shape.height * 0.5
	head.position.y = lerp(head.position.y, target_head, clamp(12.0 * delta, 0.0, 1.0))


func _update_view(delta: float, sprinting: bool) -> void:
	# Camera tilt while sliding, screen shake, gun bob/sway/kick.
	var tilt := deg_to_rad(4.0) if move_state == Move.SLIDE else 0.0
	camera.rotation.z = lerp(camera.rotation.z, tilt, clamp(8.0 * delta, 0.0, 1.0))
	_shake = max(_shake - delta * 1.5, 0.0)
	camera.h_offset = randf_range(-1, 1) * _shake * 0.3
	camera.v_offset = randf_range(-1, 1) * _shake * 0.3
	var hs := Vector2(velocity.x, velocity.z).length()
	if is_on_floor() and hs > 0.5 and move_state != Move.SLIDE:
		_bob_t += delta * hs * (1.6 if sprinting else 1.2)
	var bob: Vector3 = Vector3(sin(_bob_t) * 0.008, -absf(cos(_bob_t)) * 0.01, 0) * clamp(hs / 5.0, 0.0, 1.5)
	_gun_kick = _gun_kick.lerp(Vector3.ZERO, clamp(12.0 * delta, 0.0, 1.0))
	var swap_dip := Vector3(0, -0.25, 0) * (_swap_t / 0.4)
	var sprint_pose := Vector3(-0.05, -0.03, 0.05) if sprinting and hs > walk_speed else Vector3.ZERO
	var posed := _ads_posed()
	# §18: the pose lerp follows the build's ADS time (20/s at 0.25 s), plus the optic's breathing sway while aimed.
	var rate: float = AdsProfileScr.view_lerp_rate(_weapon_archetype()) if (ads_active or ads_blend > 0.0) else 20.0
	_ads_sway_t += delta
	var sway := AdsProfileScr.ads_sway_offset(_ads_sway_t, _weapon_archetype(), _ads_moving(), move_state == Move.CROUCH) \
		* ads_blend if posed else Vector3.ZERO
	gun.position = gun.position.lerp(_view_rest() + bob * (AdsProfileScr.ADS_BOB_MULT if posed else 1.0) \
		+ _gun_kick * (0.35 if posed else 1.0) + swap_dip + sprint_pose + sway, clamp(rate * delta, 0.0, 1.0))


func add_shake(amount: float) -> void:
	_shake = min(_shake + amount, 1.0)


func get_move_direction() -> Vector3:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	return (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()


func _regen(delta: float) -> void:
	if dead or regen_disabled or health >= max_health or _since_damage < regen_delay:
		return
	_regen_acc += regen_rate * delta
	if _regen_acc >= 1.0:
		var amt := int(_regen_acc)
		_regen_acc -= amt
		heal(amt)


# ------------------------------------------------------------------ weapons

func _on_weapon_equipped(w: WeaponItem) -> void:
	_cancel_reload()
	if w == null:
		gun.visible = false
		weapon_changed.emit(null)
		_sync_flashlight()
		return
	_swap_t = w.swap_time()
	_cooldown = max(_cooldown, _swap_t)
	ads_blend = 0.0 # §18: a new gun is raised from the hip
	_burst_left = 0
	if _audio_ready:
		_snd("weapon_swap")
	_build_view_model(w)
	weapon_changed.emit(w)
	_sync_flashlight()
	emit_ammo()
	_swap_reload(w, _swap_t)


## Playtest #7: mouse wheel cycles weapons (down = next, up = previous) through the Inventory item API.
## WHEEL_SWAP_DEBOUNCE keeps one notch from skipping a gun. No optic zooms with the wheel today; if one ever does,
## give it uses_wheel() -> true and the wheel stays with it while aiming.
const WHEEL_SWAP_DEBOUNCE := 0.15
var _wheel_swap_at: float = -10.0
func wheel_swap(dir: int) -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _wheel_swap_at < WHEEL_SWAP_DEBOUNCE:
		return false
	if ads_active and _optic_uses_wheel():
		return false
	var nxt := inventory.cycle_weapon_item(dir)
	if nxt == null or not inventory.equip_weapon_item(nxt):
		return false
	_wheel_swap_at = now
	return true


func _optic_uses_wheel() -> bool:
	var n := get_tree().get_first_node_in_group("scope_overlay")
	return n != null and n.has_method("uses_wheel") and bool(n.uses_wheel())


## Playtest #6: swapping to a gun with an empty magazine and reserve ammo starts its reload once the swap
## (raise) time is over, if it's still the equipped gun.
func _swap_reload(w: WeaponItem, delay: float) -> void:
	if w == null or w.ammo > 0 or w.reserve <= 0:
		return
	if delay > 0.0:
		await get_tree().create_timer(delay, false).timeout
	if is_instance_valid(self) and not dead and w == inventory.get_equipped_weapon() and w.ammo <= 0 and not _reloading:
		reload()


## Scope overlay (Gooey, scripts/ui/scope_overlay.gd): hides the first-person viewmodel while scoped.
var viewmodel_hidden_by_scope: bool = false
func set_viewmodel_hidden(hidden: bool) -> void:
	viewmodel_hidden_by_scope = hidden
	gun.visible = (not hidden) and inventory.get_equipped_weapon() != null


## Loads the weapon's glTF model and fits it into the first-person view.
func _build_view_model(w: WeaponItem) -> void:
	for c in gun_model_root.get_children():
		c.queue_free()
	_fp_arms = null
	gun.visible = not viewmodel_hidden_by_scope
	var view: Dictionary = w.arch.get("view", {})
	var length: float = float(view.get("length", 0.4))
	var off: Array = view.get("offset", [0.2, -0.2, -0.45])
	_gun_rest = Vector3(off[0], off[1], off[2])
	var path: String = w.arch.get("model", "")
	if path == "" or not ResourceLoader.exists(path):
		return
	var model: Node3D = (load(path) as PackedScene).instantiate()
	var a := ModelUtil.get_aabb(model)
	var s: float = length / max(a.size.x, 0.001)
	var holder := Node3D.new()
	holder.rotation_degrees.y = 90.0 # Quaternius guns point along +X; turn them to -Z
	gun_model_root.add_child(holder)
	holder.add_child(model)
	model.scale = Vector3.ONE * s
	model.position = -a.get_center() * s
	ModelUtil.set_shadows(model, false)
	var top: float = (a.end.y - a.get_center().y) * s
	muzzle.position = Vector3(0, top * 0.55, -length * 0.5) # fallback for guns without a Muzzle socket
	_gun_model = model
	_fit_attachments(w)
	_fp_arms = FPArmsScr.attach(model, w.archetype, FPArmsScr.TINTS.get(arms_tint, FPArmsScr.TINTS.P1) if arms_tint is String else arms_tint)


## Forearm band colour of the first-person arms ("P1".."P4" or a Color).
func set_arms_tint(c) -> void:
	arms_tint = c
	FPArmsScr.set_tint(_fp_arms, c)


func _aim_point(max_dist: float) -> Vector3:
	var from := camera.global_position
	var to := from - camera.global_basis.z * max_dist
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	q.collision_mask = 1 | 4 | HEAD_HITBOX_LAYER
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position if not hit.is_empty() else to


func shoot() -> void:
	var w := inventory.get_equipped_weapon()
	if w == null or _cooldown > 0.0 or _reloading or _swap_t > 0.0 or _burst_left > 0:
		return
	if w.ammo <= 0:
		if _dry_t <= 0.0:
			_dry_t = 0.35
			_snd("dry_fire")
		reload()
		return
	var burst: int = max(int(w.arch.get("burst", 1)), 1)
	_cooldown = w.fire_interval() * burst / maxf(mod_stat("fire_rate_mult", 1.0), 0.1) # rpm is the average rate, bursts included
	_play_fire_sound(w)
	if burst > 1:
		_burst_left = burst - 1
		_burst_w = w
		_burst_t = float(w.arch.get("burst_interval", 0.075))
	_fire_round(w)


## Gunshot for a weapon: weapons.json "fire_sfx" (default "<archetype>_fire"). Burst weapons
## play their burst file once per burst.
func _play_fire_sound(w: WeaponItem) -> void:
	_snd(str(w.arch.get("fire_sfx", w.archetype + "_fire")))


func _continue_burst() -> void:
	var w := inventory.get_equipped_weapon()
	if w == null or w != _burst_w or _reloading or w.ammo <= 0 or dead:
		_burst_left = 0
		return
	_burst_left -= 1
	_burst_t = float(w.arch.get("burst_interval", 0.075))
	_fire_round(w)


## Fires one round (all pellets) of `w`: ammo, damage, impacts, tracers, flash and recoil.
func _fire_round(w: WeaponItem) -> void:
	w.ammo -= 1
	var last_round := w.ammo == 0
	_ev(&"shot_fired", {"weapon": w, "ammo_after": w.ammo, "last_round": last_round})
	emit_ammo()
	WeaponRigScr.on_fire(_gun_rig, w.ammo, minf(w.fire_interval(), 1.0)) # revolver cylinder turns, launcher Rocket hides
	FPArmsScr.on_fire(_fp_arms) # <arch>_Fire one-shot
	var any_hit := false

	var base_damage := w.damage() * PerkSystem.damage_mult(w, self)
	var tracer_color := GearDB.element_color(w.element)
	if w.is_projectile():
		var target := _aim_point(200.0)
		Rocket.fire(self, w, muzzle.global_position, (target - muzzle.global_position).normalized(), base_damage)
	else:
		var space := get_world_3d().direct_space_state
		var from := camera.global_position
		var cam_basis := camera.global_basis
		var max_range: float = float(w.arch.get("base_range", 20)) * 4.0
		var spread := deg_to_rad(w.spread_deg() * PerkSystem.spread_mult(w, self) * mod_stat("spread_mult", 1.0) \
			* AdsProfileScr.aim_spread_mult(ads_blend, _weapon_archetype(), _ads_moving()) \
			* (1.4 if not is_on_floor() else 1.0) * (0.7 if move_state != Move.NORMAL else 1.0))
		var impact_sounds := {} # one impact sound per surface per round (shotguns!)
		for i in w.pellets():
			var dir := -cam_basis.z
			if spread > 0.0:
				dir = (cam_basis * Vector3(randf_range(-spread, spread), randf_range(-spread, spread), -1.0)).normalized()
			var to := from + dir * max_range
			var query := PhysicsRayQueryParameters3D.create(from, to)
			query.exclude = [get_rid()]
			query.collision_mask = 1 | 4 | HEAD_HITBOX_LAYER
			var hit := space.intersect_ray(query)
			var end_point := to
			if not hit.is_empty():
				end_point = hit.position
				var collider: Object = hit.collider
				var on_head_box: bool = collider != null and collider.has_meta("hit_owner")
				if on_head_box: # head hitbox -> the zombie it belongs to
					collider = collider.get_meta("hit_owner")
				var is_enemy := collider != null and is_instance_valid(collider) and collider.has_method("take_damage")
				if is_enemy:
					any_hit = true
					var dist := from.distance_to(hit.position)
					var ctx := hit_ctx({"source": "gun", "weapon": w, "element": w.element, "target": collider,
						"distance": dist, "falloff_start": w.falloff_start(), "last_round": last_round, "pos": hit.position})
					var crit: bool = on_head_box or collider.is_precision_hit(hit.position) \
						or mod_stat("force_precision", 0.0, ctx) > 0.0
					ctx["is_headshot"] = crit
					var hs_mult := w.headshot_mult() + mod_stat("headshot_mult_add", 0.0, ctx)
					var fall := 1.0 if mod_stat("no_falloff", 0.0, ctx) > 0.0 else w.falloff(dist)
					var dmg := mod_stat("damage_out", base_damage * fall * (hs_mult if crit else 1.0), ctx)
					var killed: bool = collider.take_damage(dmg, hit.position, crit, self)
					register_hit(collider, dmg, crit, killed, ctx)
					PerkSystem.on_hit(w, self, hit.position, dmg)
					if killed:
						on_enemy_killed(collider, w)
				var a := _sfx()
				var surf: String = "flesh" if is_enemy else (a.surface_of(collider) if a else "concrete")
				if a and not impact_sounds.has(surf):
					impact_sounds[surf] = true
					a.play_at("impact_" + surf, hit.position)
				Effects.spawn_impact(get_tree().current_scene, hit.position, hit.normal, is_enemy)
			Effects.spawn_tracer(get_tree().current_scene, muzzle.global_position, end_point, tracer_color)

	if not w.is_projectile() and not any_hit:
		_ev(&"shot_missed", {"weapon": w})
	_show_flash(GearDB.element_color(w.element) if w.element != "ballistic" else Color(1, 0.75, 0.35))
	var r := w.recoil()
	_gun_kick += Vector3(0, 0.015, 0.07) * (1.0 + r * 4.0)
	head.rotation.x = clamp(head.rotation.x + r * 0.12, deg_to_rad(-89.0), deg_to_rad(89.0))
	if w.ammo == 0:
		_burst_left = 0
		reload()


## Report a landed hit (shooting, melee, explosions, skills) to listeners via hit_registered and to the
## skill bus as "hit" (+ "enemy_killed" on a kill). ctx keys: source (gun | melee | grenade | explosion |
## skill | arc | ray | dot | rot | hazard | reflect | dash), weapon, element, pos, distance, depth, ...
## Burn / hazard ticks skip hit_registered (no hit-marker spam) unless they kill.
func register_hit(target: Node, damage: float, is_headshot: bool, is_kill: bool, ctx: Dictionary = {}) -> void:
	var c := hit_ctx(ctx)
	c["target"] = target
	c["damage"] = damage
	c["is_headshot"] = is_headshot
	c["is_kill"] = is_kill
	if not c.has("source"):
		c["source"] = "gun"
	if is_kill or not (str(c.source) in ["dot", "hazard"]):
		hit_registered.emit(target, damage, is_headshot, is_kill)
	_ev(&"hit", c)
	if is_kill:
		_ev(&"enemy_killed", c.duplicate())


## Base ctx for hit/kill events: player state at the moment of the hit.
func hit_ctx(extra: Dictionary = {}) -> Dictionary:
	var c := {"player": self, "depth": 0, "airborne": is_airborne(), "sliding": is_sliding_recent(0.5), "element": ""}
	c.merge(extra, true)
	return c


## Emit on the skill bus (no-op without the GameEvents autoload).
func _ev(name: StringName, ctx: Dictionary = {}) -> Dictionary:
	ctx["player"] = self
	var bus := get_node_or_null("/root/GameEvents")
	return bus.emit_event(name, ctx) if bus else ctx


func current_weapon() -> WeaponItem:
	return inventory.get_equipped_weapon()


func is_airborne() -> bool:
	return not is_on_floor()


## True while sliding or within `grace` seconds after a slide ended.
func is_sliding_recent(grace: float = 0.5) -> bool:
	return move_state == Move.SLIDE or _since_slide <= grace


func is_still(min_time: float = 0.5) -> bool:
	return move_state == Move.CROUCH or _still_t >= min_time


## Area blast caused by a skill (chain explosions, Daisy Fuse, Reverb Core, Crater Drop, bomblets).
func skill_explosion(pos: Vector3, radius: float, damage: float, knockback: float, extra: Dictionary = {}, vfx: float = 0.7) -> int:
	var scene := get_tree().current_scene if is_inside_tree() else null
	var a := _sfx()
	if a:
		a.play_at("frag_explode", pos, -8.0)
	return Explosion.explode(scene, pos, radius, damage, knockback, Color(1.0, 0.6, 0.3), self, null, vfx, extra)


func on_enemy_killed(_enemy: Node, w: WeaponItem) -> void:
	if w:
		PerkSystem.on_kill(w, self)


func _show_flash(c: Color) -> void:
	flash.visible = true
	flash.rotation.z = randf() * TAU
	var light := flash.get_node_or_null("FlashLight") as OmniLight3D
	if light:
		light.light_color = c
	await get_tree().create_timer(0.05).timeout
	if is_instance_valid(flash):
		flash.visible = false


func reload() -> void:
	var w := inventory.get_equipped_weapon()
	if w == null or _reloading or w.ammo >= w.mag_size() or w.reserve <= 0 or dead:
		return
	_reloading = true
	_burst_left = 0
	emit_ammo()
	_snd("reload_mag_out")
	var t := w.reload_time() * reload_multiplier * PerkSystem.reload_mult(w)
	_ev(&"reload_started", {"weapon": w, "time": t})
	_reload_tween = create_tween()
	_reload_tween.tween_property(gun, "rotation_degrees:x", -35.0, t * 0.4)
	_reload_tween.tween_callback(_snd.bind("reload_mag_in"))
	_reload_tween.tween_callback(WeaponRigScr.on_reload.bind(_gun_rig, t * 0.4)) # Rocket back in, cylinder spin, tube rack
	_reload_tween.tween_interval(t * 0.2)
	_reload_tween.tween_property(gun, "rotation_degrees:x", 0.0, t * 0.4)
	_reload_tween.tween_callback(_finish_reload.bind(w))
	FPArmsScr.on_reload(_fp_arms, _gun_model, t) # <arch>_Reload at clip length / t + reload_parts.json part motions


func _finish_reload(w: WeaponItem) -> void:
	_reloading = false
	if dead or w != inventory.get_equipped_weapon():
		return
	var taken: int = min(w.mag_size() - w.ammo, w.reserve)
	w.ammo += taken
	w.reserve -= taken
	WeaponRigScr.on_reload(_gun_rig, 0.0) # Rocket visible even when the reload was finished early (Slide Loader)
	FPArmsScr.reset_parts(_gun_model)
	PerkSystem.on_reload(w)
	emit_ammo()
	_ev(&"reload_finished", {"weapon": w})


## Slide Loader: completes a reload in progress right now. Returns false if not reloading.
func finish_reload_now() -> bool:
	var w := inventory.get_equipped_weapon()
	if not _reloading or w == null:
		return false
	if _reload_tween and _reload_tween.is_valid():
		_reload_tween.kill()
	gun.rotation_degrees.x = 0.0
	_finish_reload(w)
	return true


## Undertow Glide: stops a reload so the skill can fill the magazine itself.
func cancel_reload_for_skill() -> void:
	if _reloading:
		_cancel_reload()


func _cancel_reload() -> void:
	if _reload_tween and _reload_tween.is_valid():
		_reload_tween.kill()
	_reloading = false
	if gun:
		gun.rotation_degrees.x = 0.0
	FPArmsScr.reset_parts(_gun_model)


## Top up primary/secondary reserves at round start (heavy ammo comes from drops).
func refill_ammo() -> void:
	for s in ["primary", "secondary"]:
		var w: WeaponItem = inventory.equipped.get(s)
		if w:
			w.reserve = max(w.reserve, w.max_reserve())
	emit_ammo()


# ------------------------------------------------------------------ grenade / melee / ability

func throw_grenade() -> void:
	if dead:
		return
	if _grenade_cd <= 0.0:
		grenade_charges = grenade_charges_max # cooldown idle = every charge ready
	if grenade_charges <= 0:
		return
	grenade_charges -= 1
	if _grenade_cd <= 0.0:
		_grenade_cd = grenade_cooldown
	var dir := -camera.global_basis.z
	_snd("frag_throw")
	Grenade.throw_from(self, grenade_data, camera.global_position + dir * 0.6 + Vector3(0, -0.15, 0), dir, velocity)
	grenade_changed.emit(grenade_data.get("name", "Grenade"), _grenade_cd, grenade_cooldown)
	grenade_charges_changed.emit(grenade_charges, grenade_charges_max)
	_ev(&"grenade_thrown", {"data": grenade_data, "charges_left": grenade_charges})


func _grenade_recharged() -> void:
	grenade_charges = mini(grenade_charges + 1, grenade_charges_max)
	if grenade_charges < grenade_charges_max:
		_grenade_cd = grenade_cooldown # next charge
	grenade_charges_changed.emit(grenade_charges, grenade_charges_max)
	_ev(&"grenade_ready", {"charges": grenade_charges})


## Refunds `fraction` of one grenade cooldown. All refunds (skills and perks) share a cap of
## REFUND_CAP_FRACTION (60%) of one cooldown per rolling REFUND_WINDOW (5 s). Returns the applied fraction.
func refund_grenade(fraction: float) -> float:
	if _grenade_cd <= 0.0 or fraction <= 0.0:
		return 0.0
	while not _refund_log.is_empty() and _clock - float(_refund_log[0][0]) >= REFUND_WINDOW:
		_refund_log.pop_front()
	var used := 0.0
	for e in _refund_log:
		used += float(e[1])
	var applied := minf(fraction, maxf(REFUND_CAP_FRACTION - used, 0.0))
	if applied <= 0.0:
		return 0.0
	_refund_log.append([_clock, applied])
	_grenade_cd = max(_grenade_cd - grenade_cooldown * applied, 0.0)
	return applied


## Refund fraction still allowed in the current 5 s window (HUD / tests).
func grenade_refund_room() -> float:
	var used := 0.0
	for e in _refund_log:
		if _clock - float(e[0]) < REFUND_WINDOW:
			used += float(e[1])
	return maxf(REFUND_CAP_FRACTION - used, 0.0)


func melee() -> void:
	if _melee_cd > 0.0 or dead:
		return
	_melee_cd = melee_cooldown
	melee_changed.emit(_melee_cd, melee_cooldown)
	_snd("melee_swing")
	_ev(&"melee_swung")
	var t := create_tween()
	t.tween_property(gun, "rotation_degrees:y", 40.0, 0.08)
	t.tween_property(gun, "rotation_degrees:y", 0.0, 0.18)
	# Hit the nearest zombie in a cone in front of us.
	var fwd := -camera.global_basis.z
	var best: Node = null
	var best_d := 2.4
	for e in get_tree().get_nodes_in_group("enemies"):
		var c: Vector3 = e.global_position + Vector3(0, 1.0, 0)
		var to := c - camera.global_position
		var d := to.length()
		if d < best_d and fwd.dot(to.normalized()) > 0.5:
			best = e
			best_d = d
	if best:
		var push := fwd
		push.y = 0.0
		best.apply_knockback(push.normalized() * 7.0 + Vector3.UP * 2.0)
		var mctx := hit_ctx({"source": "melee", "target": best, "pos": best.global_position + Vector3(0, 1.2, 0)})
		var mdmg := mod_stat("damage_out", melee_damage, mctx)
		var killed: bool = best.take_damage(mdmg, best.global_position + Vector3(0, 1.2, 0), false, self)
		register_hit(best, mdmg, false, killed, mctx)
		var a := _sfx()
		if a:
			a.play_at("impact_flesh", best.global_position + Vector3(0, 1.2, 0))
		add_shake(0.15)


func use_ability() -> void:
	if ability == null or dead:
		return
	if _ability_cd <= 0.0:
		ability_charges = ability_charges_max # cooldown idle = every charge ready
	if ability_charges <= 0:
		return
	if _ability_active > 0.0 and not ability.allow_recast_while_active():
		return
	if ability.activate(self):
		ability_charges -= 1
		if _ability_cd <= 0.0:
			_ability_cd = ability.cooldown
		_snd(ability_sfx())
		_ability_active = ability.duration
		_ev(&"ability_used", {"ability": ability, "charges_left": ability_charges})
		if _ability_active <= 0.0:
			ability.end(self)
			_ev(&"ability_ended", {"ability": ability})
		_emit_ability()
		ability_charges_changed.emit(ability_charges, ability_charges_max)


func is_ability_active() -> bool:
	return _ability_active > 0.0


func ability_active_time() -> float:
	return _ability_active


## Ability-duration skills (Redline, Fed Rush) extend or set the active time.
func set_ability_active_time(t: float) -> void:
	_ability_active = maxf(t, 0.0)


## Breacher's Rhythm: one charge back (a full refund when that makes every charge ready).
func refund_ability_charge() -> void:
	ability_charges = mini(ability_charges + 1, ability_charges_max)
	if ability_charges >= ability_charges_max:
		_ability_cd = 0.0
	_emit_ability()
	ability_charges_changed.emit(ability_charges, ability_charges_max)


## Grave Feast etc.: what = "melee" | "grenade" | "ability".
func reset_cooldown(what: String) -> void:
	match what:
		"melee":
			_melee_cd = 0.0
			melee_changed.emit(_melee_cd, melee_cooldown)
		"grenade":
			_grenade_cd = 0.0
			grenade_charges = grenade_charges_max
			grenade_changed.emit(grenade_data.get("name", "Grenade"), 0.0, grenade_cooldown)
		"ability":
			_ability_cd = 0.0
			ability_charges = ability_charges_max
			_emit_ability()


## Sound for the class ability: dash_ability.gd -> "dash", anything else (Adrenaline) -> "adrenaline_boost".
func ability_sfx() -> String:
	var path: String = ability.get_script().resource_path if ability and ability.get_script() else ""
	return "dash" if "dash" in path.get_file() else "adrenaline_boost"


func _tick_ability(delta: float) -> void:
	if ability == null:
		return
	if _ability_active > 0.0:
		ability.process_active(self, delta)
		_ev(&"ability_tick", {"ability": ability, "delta": delta})
		_ability_active -= delta
		if _ability_active <= 0.0:
			ability.end(self)
			_ev(&"ability_ended", {"ability": ability})
	if _ability_cd > 0.0:
		_ability_cd = max(_ability_cd - delta, 0.0)
		if _ability_cd <= 0.0:
			ability_charges = mini(ability_charges + 1, ability_charges_max)
			if ability_charges < ability_charges_max:
				_ability_cd = ability.cooldown
			ability_charges_changed.emit(ability_charges, ability_charges_max)
		_emit_ability()


# ------------------------------------------------------------------ interactables (pickups, chests)

## Called by Pickup / Chest areas when we walk in or out.
func set_nearby_interactable(node: Node, is_near: bool) -> void:
	if is_near and node not in _nearby:
		_nearby.append(node)
	elif not is_near:
		_nearby.erase(node)
	_update_prompt()


func _update_prompt() -> void:
	_nearby = _nearby.filter(func(n): return is_instance_valid(n) and n.can_interact())
	pickup_prompt_changed.emit("" if _nearby.is_empty() else _nearby[0].get_prompt(), "interact")


func _interact() -> void:
	_nearby = _nearby.filter(func(n): return is_instance_valid(n) and n.can_interact())
	if not _nearby.is_empty():
		_nearby[0].interact(self)
	_update_prompt()


## Pickups call this. Returns false (and shows a message) if there's no room.
func receive_item(item: Item) -> bool:
	var cons := item as ConsumableItem
	if cons and cons.auto_use:
		cons.use(self)
		loot_received.emit(item)
		_ev(&"pickup_collected", {"item": item})
		return true
	if inventory.add_item(item):
		loot_received.emit(item)
		_ev(&"pickup_collected", {"item": item})
		return true
	pickup_prompt_changed.emit(inventory.reject_message(), "")
	return false


# ------------------------------------------------------------------ health / points

## Zombies pass themselves as `attacker` (Bramble Hide). Order: damage_incoming (dodge can zero it)
## -> invulnerability -> armor -> "damage_in" skill mods -> overshield -> lethal_damage (cheat death
## can prevent it) -> health -> damage_taken.
func take_damage(amount: float, attacker: Node = null) -> void:
	if dead:
		return
	var pre := _ev(&"damage_incoming", {"raw": amount, "amount": float(amount), "attacker": attacker,
		"health_frac": float(health) / float(max(max_health, 1))})
	if invulnerable_t > 0.0 or float(pre.get("amount", amount)) <= 0.0:
		return
	_since_damage = 0.0
	var dealt_f := float(pre.amount) * (1.0 - damage_reduction)
	dealt_f = mod_stat("damage_in", dealt_f, pre)
	var dealt := int(ceil(dealt_f))
	var absorbed := 0
	if overshield > 0.0 and dealt > 0:
		absorbed = mini(int(ceil(overshield)), dealt)
		overshield = maxf(overshield - absorbed, 0.0)
		dealt -= absorbed
		overshield_changed.emit(overshield, overshield_cap)
	if dealt >= health:
		var lc := _ev(&"lethal_damage", {"raw": amount, "dealt": dealt, "attacker": attacker, "prevent": false})
		if lc.get("prevent", false):
			dealt = maxi(health - 1, 0)
	health = max(health - dealt, 0)
	health_changed.emit(health, max_health)
	add_shake(0.1)
	_ev(&"damage_taken", {"raw": amount, "dealt": dealt, "absorbed": absorbed, "attacker": attacker,
		"health_frac": float(health) / float(max(max_health, 1))})
	if health == 0:
		dead = true
		input_enabled = false
		_set_flashlight(false)
		_snd("player_death")
		var a := _sfx()
		if a:
			a.set_low_health(false)
		died.emit()
	elif _hurt_sfx_t <= 0.0 and dealt > 0:
		_hurt_sfx_t = 0.3
		_snd("player_hurt")


func heal(amount: int) -> void:
	var before := health
	health = min(health + amount, max_health)
	health_changed.emit(health, max_health)
	if health > before:
		_ev(&"healed", {"amount": health - before})


## Adds overshield up to `cap` (default: overshield_cap; a lower per-skill cap wins). Returns the gain.
func grant_overshield(amount: float, cap: float = -1.0) -> float:
	var c := overshield_cap if cap < 0.0 else cap
	var before := overshield
	overshield = clampf(overshield + amount, 0.0, maxf(c, overshield))
	if overshield != before:
		overshield_changed.emit(overshield, overshield_cap)
	return overshield - before


func add_points(amount: int, reason: String = "") -> void:
	points += amount
	points_changed.emit(points)
	_ev(&"points_gained", {"amount": amount, "reason": reason})


## Spend points (for future wall-buys / perks). Returns false if you can't afford it.
func spend_points(amount: int) -> bool:
	if points < amount:
		return false
	points -= amount
	points_changed.emit(points)
	return true


func _on_settings_changed(key: String) -> void:
	if key in ["mouse_sensitivity", "invert_y", "fov", "apply_all", "reset"]:
		_apply_look_settings()


func _apply_look_settings() -> void:
	var s := get_node_or_null("/root/Settings")
	if s == null:
		return
	mouse_sensitivity = float(s.mouse_sensitivity)
	invert_y = bool(s.invert_y)
	_hip_fov = float(s.fov) if s else AdsProfileScr.HIP_FOV
	if not ads_active and camera:
		camera.fov = _hip_fov


## ADS tick (Skillz MAIN_HOOKS §8d): hold or toggle per Settings.ads_mode, FOV lerps to the weapon family's ADS FOV.
func _tick_ads(_delta: float) -> void:
	var settings := get_node_or_null("/root/Settings")
	var mode := AdsProfileScr.resolve_mode(settings) # missing Settings -> "hold"
	var action := AdsProfileScr.input_action()
	# Ensure action exists even before project.godot lands:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event(action, mb)
	var can_aim := input_enabled and not dead
	var pressed := can_aim and Input.is_action_pressed(action)
	var just := can_aim and Input.is_action_just_pressed(action)
	var next := AdsProfileScr.next_ads_state(ads_active, mode, pressed, just)
	if dead: # §8g: drop ADS on death
		next = false
	if next != ads_active:
		ads_active = next
		ads_changed.emit(ads_active)
		WeaponRigScr.set_ads(_gun_rig, ads_active) # Ratchet Stock slider
	var arch := ""
	var w = inventory.get_equipped_weapon() if inventory else null
	if w and "archetype" in w:
		arch = str(w.archetype)
	AdsProfileScr.target_fov(ads_active, arch, _hip_fov) # keeps AdsProfile's last-archetype default current
	ads_blend = AdsProfileScr.step_blend(ads_blend, ads_active, _delta, arch) # §18: in over the build's ADS time
	if camera:
		camera.fov = AdsProfileScr.blend_fov(ads_blend, arch, _hip_fov)
		camera.near = ADS_NEAR if ads_blend > 0.0 else _hip_near # fp_arms v2: every gun, rocket launcher included
	FPArmsScr.set_ads(_fp_arms, ads_blend > 0.0)


# ------------------------------------------------------------------ Mine Lamp (Skillz §10)

func _weapon_archetype() -> String:
	var w = current_weapon()
	if w and "archetype" in w:
		return str(w.archetype)
	return ""


func _toggle_flashlight() -> void:
	if _flashlight == null or dead:
		return
	# Gate: only while Mine Lamp is on the weapon in hand (Armory loadout per archetype).
	if not ArmoryScr.has_flashlight(_weapon_archetype()):
		_set_flashlight(false)
		return
	_set_flashlight(not _flashlight_on)


func _set_flashlight(on: bool) -> void:
	if _flashlight == null:
		return
	var was := _flashlight_on
	_flashlight_on = on and ArmoryScr.has_flashlight(_weapon_archetype())
	if _flashlight_on:
		_apply_flashlight_cfg(ArmoryScr.flashlight_config(_weapon_archetype()))
	_flashlight.visible = _flashlight_on
	if was != _flashlight_on:
		var a := _sfx()
		if a and a.has_method("play"):
			a.play("ui_hover") # soft click; replace with a dedicated cue later if desired


## Call whenever the active weapon or Armory loadout changes so an unequipped lamp cannot stay on.
func _sync_flashlight() -> void:
	if not ArmoryScr.has_flashlight(_weapon_archetype()):
		_set_flashlight(false)


## Armory attachments on the view model (Skillz WeaponRig, MAIN_HOOKS §12): attachment GLBs on the gun's sockets,
## default parts they replace hidden, and the tracer/flash Muzzle moved to the effective bore exit
## (suppressor front > barrel Muzzle > gun Muzzle socket). Guns without sockets (rocket launcher) are left as they are.
func _fit_attachments(w: WeaponItem) -> void:
	if w == null or _gun_model == null or not is_instance_valid(_gun_model):
		return
	_gun_rig = WeaponRigScr.apply(_gun_model, w.archetype)
	# ADS pose: Gun position that puts the sight line (optic SightPoint > gun SightPoint) on the screen centre.
	_gun_rig["ads_pos"] = AdsProfileScr.ads_gun_position(WeaponRigScr.ads_offset(_gun_rig, gun), w.archetype)
	var mz = _gun_rig.get("muzzle")
	if mz is Node3D and (mz as Node3D).is_inside_tree():
		muzzle.position = gun.to_local((mz as Node3D).global_position)


func _on_armory_changed(_kind: String, _id: String) -> void:
	_fit_attachments(current_weapon())
	_sync_flashlight()


## Mine Lamp beam values from data (attachments.json -> mine_lamp light_*; Armory.flashlight_config), MAIN_HOOKS §13.
func _apply_flashlight_cfg(c: Dictionary) -> void:
	if _flashlight == null or c.is_empty():
		return
	_flashlight.light_energy = float(c.get("light_energy", 7.0))
	_flashlight.spot_range = float(c.get("light_range", 22.0))
	_flashlight.spot_angle = float(c.get("light_angle", 28.0))
	_flashlight.spot_attenuation = float(c.get("light_attenuation", 1.1))
	if c.get("color") is Color:
		_flashlight.light_color = c.color


## 0..1 of walk speed on the ground (§18: sway widens ADS spread on the move, AdsProfile.aim_spread_mult).
func _ads_moving() -> float:
	return clampf(Vector2(velocity.x, velocity.z).length() / maxf(walk_speed, 0.1), 0.0, 1.0)


## ADS view-model pose (Skillz MAIN_HOOKS §14c): sights on the screen centre while aiming (not mid-reload).
func _ads_posed() -> bool:
	return ads_active and not _reloading and _gun_rig.has("ads_pos")


func _view_rest() -> Vector3:
	return _gun_rig.ads_pos if _ads_posed() else _gun_rest
