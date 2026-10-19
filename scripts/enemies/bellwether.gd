extends "res://scripts/enemy.gd"
## Bellwether — tank bruiser boss (Skillz).
## Wind-up bell slam (glowing ground circle) → AoE smash → brief stun.
## At 50% HP enrages: shorter slam cooldown + linear charge with a red telegraph line.

const Catalog := preload("res://scripts/enemies/boss_catalog.gd")
const Common := preload("res://scripts/enemies/boss_common.gd")
const Telegraph := preload("res://scripts/enemies/boss_telegraph.gd")

enum Phase { IDLE, SLAM_WINDUP, STUNNED, CHARGE_WINDUP, CHARGING }

var boss_id: String = "bellwether"
var round_n: int = 1
var phase: Phase = Phase.IDLE
var _cd: float = 2.0
var _phase_t: float = 0.0
var _enraged: bool = false
var _charge_dir: Vector3 = Vector3.FORWARD
var _slam_center: Vector3 = Vector3.ZERO
var _tg: Dictionary = {}


func configure_boss(id: String, n: int, difficulty_id: String = "") -> void:
	boss_id = id
	round_n = n
	_tg = Catalog.telegraph(id)
	Common.apply_identity(self, id, n, difficulty_id)
	attack_range = maxf(attack_range, float(_tg.get("slam_radius", 3.5)) * 0.45)
	_cd = 1.5


func _physics_process(delta: float) -> void:
	if _dead:
		super._physics_process(delta)
		return
	if not _enraged and health <= float(max_health) * float(_tg.get("enrage_hp_frac", 0.5)):
		_enraged = true
	match phase:
		Phase.IDLE:
			_cd = maxf(_cd - delta, 0.0)
			super._physics_process(delta)
			if _cd <= 0.0 and target != null and is_instance_valid(target):
				_start_special()
		Phase.SLAM_WINDUP:
			velocity.x = 0.0
			velocity.z = 0.0
			if not is_on_floor():
				velocity.y -= _gravity * delta
			move_and_slide()
			_phase_t -= delta
			if _phase_t <= 0.0:
				_resolve_slam()
		Phase.STUNNED:
			velocity.x = 0.0
			velocity.z = 0.0
			if not is_on_floor():
				velocity.y -= _gravity * delta
			move_and_slide()
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.IDLE
				_cd = float(_tg.get("enrage_slam_cooldown" if _enraged else "slam_cooldown", 5.0))
		Phase.CHARGE_WINDUP:
			velocity.x = 0.0
			velocity.z = 0.0
			if not is_on_floor():
				velocity.y -= _gravity * delta
			move_and_slide()
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.CHARGING
				_phase_t = float(_tg.get("charge_duration", 0.85))
				_play("run", 0.05)
		Phase.CHARGING:
			if not is_on_floor():
				velocity.y -= _gravity * delta
			var spd := speed * float(_tg.get("charge_speed_mult", 2.4))
			velocity.x = _charge_dir.x * spd
			velocity.z = _charge_dir.z * spd
			move_and_slide()
			_try_charge_hit()
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.IDLE
				_cd = float(_tg.get("charge_cooldown", 4.5))


func _start_special() -> void:
	if target == null or not is_instance_valid(target):
		return
	# Enraged: alternate charge / slam. Pre-enrage: slam only.
	if _enraged and randf() < 0.45:
		_start_charge()
	else:
		_start_slam()


func _start_slam() -> void:
	phase = Phase.SLAM_WINDUP
	_phase_t = float(_tg.get("slam_windup", 1.2))
	_slam_center = global_position
	if target:
		_slam_center = Vector3(target.global_position.x, global_position.y, target.global_position.z)
	Telegraph.spawn_circle(get_parent() if get_parent() else self, _slam_center, float(_tg.get("slam_radius", 3.5)), _phase_t)
	_play("attack", 0.1)
	_say("zombie_aggro_scream", 2)


func _resolve_slam() -> void:
	var rad := float(_tg.get("slam_radius", 3.5))
	var dmg := Catalog.attack_damage(boss_id, round_n, 10, 2, float(_tg.get("slam_damage_mult", 2.2)))
	if target and is_instance_valid(target) and target.is_in_group("player"):
		var flat := Vector3(target.global_position.x, 0, target.global_position.z) - Vector3(_slam_center.x, 0, _slam_center.z)
		if flat.length() <= rad and absf(target.global_position.y - _slam_center.y) < 2.5:
			target.call("take_damage", dmg, self)
	phase = Phase.STUNNED
	_phase_t = float(_tg.get("slam_stun", 1.0))


func _start_charge() -> void:
	phase = Phase.CHARGE_WINDUP
	_phase_t = float(_tg.get("charge_windup", 0.7))
	_charge_dir = Common.flat_dir_to(global_position, target.global_position)
	var look := atan2(-_charge_dir.x, -_charge_dir.z)
	rotation.y = look
	Telegraph.spawn_line(get_parent() if get_parent() else self, global_position, _charge_dir, 9.0, _phase_t, Color(1.0, 0.12, 0.08, 0.6))
	_say("zombie_aggro_scream", 2)


func _try_charge_hit() -> void:
	if target == null or not is_instance_valid(target):
		return
	var dist := global_position.distance_to(target.global_position)
	if dist <= attack_range * 1.2:
		var dmg := Catalog.attack_damage(boss_id, round_n, 10, 2, float(_tg.get("charge_damage_mult", 1.4)))
		target.call("take_damage", dmg, self)
		phase = Phase.IDLE
		_cd = float(_tg.get("charge_cooldown", 4.5))
