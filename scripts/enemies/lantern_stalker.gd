extends "res://scripts/enemy.gd"
## Lantern Stalker — ambusher ranged boss (Skillz).
## Goes dark (speed buff, low-visibility stub via model scale/meta) → lantern beam telegraph → blight spit → sidestep.
## Never a pure sponge; projectile is dodgeable.

const Catalog := preload("res://scripts/enemies/boss_catalog.gd")
const Common := preload("res://scripts/enemies/boss_common.gd")
const Telegraph := preload("res://scripts/enemies/boss_telegraph.gd")
const Spit := preload("res://scripts/enemies/blight_spit.gd")

enum Phase { HUNT, DARK, BEAM, SIDESTEP }

var boss_id: String = "lantern_stalker"
var round_n: int = 1
var phase: Phase = Phase.HUNT
var _cd: float = 2.0
var _phase_t: float = 0.0
var _sidestep_dir: Vector3 = Vector3.RIGHT
var _tg: Dictionary = {}
var _dark: bool = false


func configure_boss(id: String, n: int, difficulty_id: String = "") -> void:
	boss_id = id
	round_n = n
	_tg = Catalog.telegraph(id)
	Common.apply_identity(self, id, n, difficulty_id)
	attack_range = 12.0 # prefers ranged; melee only if cornered
	_cd = 1.8


func _physics_process(delta: float) -> void:
	if _dead:
		_set_dark(false)
		super._physics_process(delta)
		return
	match phase:
		Phase.HUNT:
			_cd = maxf(_cd - delta, 0.0)
			super._physics_process(delta)
			if _cd <= 0.0 and target != null and is_instance_valid(target):
				_begin_dark()
		Phase.DARK:
			_phase_t -= delta
			var boost := float(_tg.get("dark_speed_mult", 1.45))
			var saved := speed
			speed *= boost
			super._physics_process(delta)
			speed = saved
			if _phase_t <= 0.0:
				_begin_beam()
		Phase.BEAM:
			velocity.x = 0.0
			velocity.z = 0.0
			if not is_on_floor():
				velocity.y -= _gravity * delta
			move_and_slide()
			if target:
				var look := Common.flat_dir_to(global_position, target.global_position)
				rotation.y = atan2(-look.x, -look.z)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_fire_spit()
				_begin_sidestep()
		Phase.SIDESTEP:
			if not is_on_floor():
				velocity.y -= _gravity * delta
			velocity.x = _sidestep_dir.x * speed * 1.3
			velocity.z = _sidestep_dir.z * speed * 1.3
			move_and_slide()
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.HUNT
				_cd = float(_tg.get("cycle_cooldown", 3.5))
				_set_dark(false)


func _begin_dark() -> void:
	phase = Phase.DARK
	_phase_t = float(_tg.get("dark_duration", 1.6))
	_set_dark(true)
	_say("zombie_aggro_scream", 1)


func _begin_beam() -> void:
	phase = Phase.BEAM
	_phase_t = float(_tg.get("beam_windup", 0.8))
	_set_dark(false)
	var dir := Vector3.FORWARD
	if target:
		dir = Common.flat_dir_to(global_position, target.global_position)
	Telegraph.spawn_line(get_parent() if get_parent() else self, global_position + Vector3(0, 1.2, 0), dir,
		float(_tg.get("beam_length", 18.0)), _phase_t, Color(1.0, 0.85, 0.25, 0.55), 0.7)


func _fire_spit() -> void:
	if target == null or not is_instance_valid(target):
		return
	var origin := global_position + Vector3(0, 1.3, 0)
	var aim := target.global_position + Vector3(0, 1.0, 0)
	var dir := (aim - origin).normalized()
	var dmg := Catalog.attack_damage(boss_id, round_n, 10, 2, float(_tg.get("spit_damage_mult", 1.8)))
	Spit.fire(self, origin, dir, dmg, float(_tg.get("spit_speed", 14.0)))


func _begin_sidestep() -> void:
	phase = Phase.SIDESTEP
	_phase_t = 0.45
	var away := Common.flat_dir_to(target.global_position, global_position) if target else Vector3.RIGHT
	_sidestep_dir = Vector3(-away.z, 0, away.x)
	if randf() < 0.5:
		_sidestep_dir = -_sidestep_dir


## Visibility stub until Desi ships a stealth material: shrink slightly + meta flag for VFX.
func _set_dark(on: bool) -> void:
	_dark = on
	set_meta("lantern_dark", on)
	if model_root:
		model_root.scale = Vector3.ONE * (0.92 if on else 1.0)


func is_dark() -> bool:
	return _dark
