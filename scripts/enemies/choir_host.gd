extends "res://scripts/enemy.gd"
## Choir Host — summoner support boss (Skillz).
## Channels behind a breakable resonance shield (30% of max HP). While channeling, spawns
## 2–3 fragile "echo" adds. Interrupt by breaking the shield. No shield while walking.

signal request_echo(host: Node, count: int) ## main.gd spawns echoes (MAIN_HOOKS §7)

const Catalog := preload("res://scripts/enemies/boss_catalog.gd")
const Common := preload("res://scripts/enemies/boss_common.gd")
const Telegraph := preload("res://scripts/enemies/boss_telegraph.gd")

enum Phase { WALK, CHANNEL }

var boss_id: String = "choir_host"
var round_n: int = 1
var phase: Phase = Phase.WALK
var shield_hp: float = 0.0
var shield_max: float = 0.0
var channeling: bool = false
var _cd: float = 3.0
var _phase_t: float = 0.0
var _echo_acc: float = 0.0
var _tg: Dictionary = {}
var _echo: Dictionary = {}


func configure_boss(id: String, n: int, difficulty_id: String = "") -> void:
	boss_id = id
	round_n = n
	_tg = Catalog.telegraph(id)
	_echo = Catalog.echo_cfg(id)
	Common.apply_identity(self, id, n, difficulty_id)
	_cd = 2.5


func take_damage(amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, source: Node = null) -> bool:
	if channeling and shield_hp > 0.0:
		var absorbed: float = minf(shield_hp, amount)
		shield_hp -= absorbed
		amount -= absorbed
		if shield_hp <= 0.0:
			_interrupt_channel()
		if amount <= 0.0:
			if not _status_tick:
				hit.emit(self, 0)
			return false
	return super.take_damage(amount, hit_pos, crit, source)


func _physics_process(delta: float) -> void:
	if _dead:
		super._physics_process(delta)
		return
	match phase:
		Phase.WALK:
			_cd = maxf(_cd - delta, 0.0)
			super._physics_process(delta)
			if _cd <= 0.0:
				_begin_channel()
		Phase.CHANNEL:
			velocity.x = 0.0
			velocity.z = 0.0
			if not is_on_floor():
				velocity.y -= _gravity * delta
			move_and_slide()
			_phase_t -= delta
			_echo_acc += delta
			var interval := float(_tg.get("echo_interval", 2.0))
			if _echo_acc >= interval:
				_echo_acc = 0.0
				var mn := int(_tg.get("echo_count_min", 2))
				var mx := int(_tg.get("echo_count_max", 3))
				var n := mn if mx <= mn else randi_range(mn, mx)
				request_echo.emit(self, n)
			if _phase_t <= 0.0:
				_end_channel(false)


func _begin_channel() -> void:
	phase = Phase.CHANNEL
	channeling = true
	_phase_t = float(_tg.get("channel_duration", 4.0))
	_echo_acc = float(_tg.get("echo_interval", 2.0)) # first wave soon
	shield_max = float(max_health) * float(_tg.get("shield_hp_frac", 0.3))
	shield_hp = shield_max
	Telegraph.spawn_circle(get_parent() if get_parent() else self, global_position, 1.8, _phase_t, Color(0.55, 0.75, 1.0, 0.5))
	_play("idle", 0.1)
	_say("zombie_aggro_scream", 2)


func _interrupt_channel() -> void:
	_end_channel(true)


func _end_channel(interrupted: bool) -> void:
	channeling = false
	shield_hp = 0.0
	phase = Phase.WALK
	_cd = float(_tg.get("channel_cooldown", 6.0)) * (0.6 if interrupted else 1.0)
	_phase_t = 0.0


## Shield fraction remaining 0..1 (UI / tests).
func shield_frac() -> float:
	return 0.0 if shield_max <= 0.0 else clampf(shield_hp / shield_max, 0.0, 1.0)
