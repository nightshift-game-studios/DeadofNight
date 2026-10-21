extends "res://scripts/enemy.gd"
## Bellwether — tank bruiser boss (Skillz).
## Wind-up bell slam (glowing ground circle) → AoE smash → brief stun.
## At 50% HP enrages: shorter slam cooldown + linear charge with a red telegraph line.
## Art (Desi, bellwether.glb): SlamWindup → SlamImpact (damage lands anims.slam_hit_time = 0.17 s in) → Stun;
## ChargeWindup → ChargeRun (looped in code). Enrage = no clip: clips x fx.enrage_speed_scale + bell crack emission boost.

const Catalog := preload("res://scripts/enemies/boss_catalog.gd")
const Common := preload("res://scripts/enemies/boss_common.gd")
const Telegraph := preload("res://scripts/enemies/boss_telegraph.gd")
const Art := preload("res://scripts/enemies/boss_art.gd")

enum Phase { IDLE, SLAM_WINDUP, SLAM_IMPACT, STUNNED, CHARGE_WINDUP, CHARGING }

var boss_id: String = "bellwether"
var round_n: int = 1
var phase: Phase = Phase.IDLE
var _cd: float = 2.0
var _phase_t: float = 0.0
var _enraged: bool = false
var _charge_dir: Vector3 = Vector3.FORWARD
var _slam_center: Vector3 = Vector3.ZERO
var _tg: Dictionary = {}
var _an: Dictionary = {}
var _fx: Dictionary = {}
var _stun_clip_t: float = -1.0 ## seconds until the Stun clip starts (after SlamImpact's follow-through), -1 = played


func configure_boss(id: String, n: int, difficulty_id: String = "") -> void:
	boss_id = id
	round_n = n
	_tg = Catalog.telegraph(id)
	_an = Catalog.anims(id)
	_fx = Catalog.fx(id)
	Common.apply_identity(self, id, n, difficulty_id)
	attack_range = maxf(attack_range, float(_tg.get("slam_radius", 3.5)) * 0.45)
	_cd = 1.5


func _ready() -> void:
	super._ready()
	if _an.is_empty():
		_an = Catalog.anims(boss_id)
		_fx = Catalog.fx(boss_id)
	Art.setup_anims(self, _an)


func is_enraged() -> bool:
	return _enraged


## Seconds into SlamImpact when the smash connects (hands bottom out, frame 4 of 24 fps).
func slam_hit_time() -> float:
	return float(_an.get("slam_hit_time", 0.17))


func _clip_speed() -> float:
	return float(_fx.get("enrage_speed_scale", 1.25)) if _enraged else 1.0


## Plays `key` stretched to last exactly `duration` seconds (telegraphed clips stay in sync with data timing).
func _play_fit(key: String, duration: float) -> void:
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	var clip_len := Art.clip_length(self, key, duration)
	Art.play(self, key, float(_an.get("blend", 0.15)), clip_len / maxf(duration, 0.05) if clip_len > 0.0 else 1.0)


func _set_enraged() -> void:
	_enraged = true
	Art.set_emission(self, str(_fx.get("bell_material", "Bellwether_Bell")), float(_fx.get("enrage_emission_mult", 4.0)))


func _hold_still(delta: float) -> void:
	_attack_anim_t = maxf(_attack_anim_t, 0.1) # no random HitReact over a telegraphed clip (enemy.take_damage)
	velocity.x = 0.0
	velocity.z = 0.0
	if not is_on_floor():
		velocity.y -= _gravity * delta
	move_and_slide()


func _physics_process(delta: float) -> void:
	if _dead or not is_multiplayer_authority(): # NET B1: co-op client puppet -> phases come from the host (net_apply_boss_state); solo: always authority
		super._physics_process(delta)
		return
	if not _enraged and health <= float(max_health) * float(_tg.get("enrage_hp_frac", 0.5)):
		_set_enraged()
	match phase:
		Phase.IDLE:
			_cd = maxf(_cd - delta, 0.0)
			super._physics_process(delta)
			if _cd <= 0.0 and target != null and is_instance_valid(target):
				_start_special()
		Phase.SLAM_WINDUP:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_start_impact()
		Phase.SLAM_IMPACT:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_resolve_slam()
		Phase.STUNNED:
			_hold_still(delta)
			if _stun_clip_t >= 0.0:
				_stun_clip_t -= delta
				if _stun_clip_t <= 0.0:
					_stun_clip_t = -1.0
					_play_fit("stun", float(_tg.get("slam_stun", 1.0)))
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.IDLE
				_cd = float(_tg.get("enrage_slam_cooldown" if _enraged else "slam_cooldown", 5.0))
				if _anim:
					_anim.speed_scale = 1.0
		Phase.CHARGE_WINDUP:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.CHARGING
				_phase_t = float(_tg.get("charge_duration", 0.85))
				if not Art.play(self, "charge_run", 0.05, _clip_speed()):
					_play("run", 0.05)
		Phase.CHARGING:
			_attack_anim_t = maxf(_attack_anim_t, 0.1)
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
	_show_slam_windup()


## Windup visuals (host and co-op puppets, NET B3). The circle stays up until the smash connects (windup +
## slam_hit_time into SlamImpact).
func _show_slam_windup() -> void:
	var t := float(_tg.get("slam_windup", 1.2))
	Telegraph.spawn_circle(get_parent() if get_parent() else self, _slam_center, float(_tg.get("slam_radius", 3.5)),
		t + slam_hit_time() / _clip_speed())
	if not Art.has_clip(self, "slam_windup"):
		_play("attack", 0.1)
	else:
		_play_fit("slam_windup", t)
	_say("zombie_aggro_scream", 2)


func _start_impact() -> void:
	phase = Phase.SLAM_IMPACT
	_phase_t = slam_hit_time() / _clip_speed()
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	Art.play(self, "slam_impact", 0.05, _clip_speed())


func _resolve_slam() -> void:
	var rad := float(_tg.get("slam_radius", 3.5))
	var dmg := Catalog.attack_damage(boss_id, round_n, 10, 2, float(_tg.get("slam_damage_mult", 2.2)))
	# NET B4: co-op = every player body in the circle (remote avatars forward the hit to their owner); solo: the target.
	var bodies = NetGate.players_or_null()
	if bodies == null:
		bodies = [target] if target and is_instance_valid(target) and target.is_in_group("player") else []
	for b in bodies:
		if b == null or not is_instance_valid(b) or not b.has_method("take_damage"):
			continue
		var flat := Vector3(b.global_position.x, 0, b.global_position.z) - Vector3(_slam_center.x, 0, _slam_center.z)
		if flat.length() <= rad and absf(b.global_position.y - _slam_center.y) < 2.5:
			b.call("take_damage", dmg, self)
	phase = Phase.STUNNED
	_phase_t = _stun_rest() + float(_tg.get("slam_stun", 1.0))
	_stun_clip_t = _stun_rest() if Art.has_clip(self, "stun") else -1.0


## SlamImpact plays out its follow-through (ends low), then Stun (slam_stun seconds) - the punish window.
func _stun_rest() -> float:
	if not Art.has_clip(self, "slam_impact"):
		return 0.0
	return maxf(Art.clip_length(self, "slam_impact") - slam_hit_time(), 0.0) / _clip_speed()


func _start_charge() -> void:
	phase = Phase.CHARGE_WINDUP
	_phase_t = float(_tg.get("charge_windup", 0.7))
	_charge_dir = Common.flat_dir_to(global_position, target.global_position)
	_show_charge_windup()


## Charge windup visuals (host and co-op puppets, NET B3).
func _show_charge_windup() -> void:
	var t := float(_tg.get("charge_windup", 0.7))
	rotation.y = atan2(-_charge_dir.x, -_charge_dir.z)
	Telegraph.spawn_line(get_parent() if get_parent() else self, global_position, _charge_dir, 9.0, t, Color(1.0, 0.12, 0.08, 0.6))
	_play_fit("charge_windup", t)
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


# ------------------------------------------------------------------ NET B2 / B3: co-op boss state (Netz phase 3b)
## B2 (host): what a client puppet needs to show this boss's attacks. NetWorld polls it every physics frame and
## sends it on change. [phase, enraged, slam center, charge dir]
func net_boss_state() -> Array:
	return [int(phase), _enraged, _slam_center, _charge_dir]


## B3 (client puppet): play the phase the host just entered. Clips, telegraphs, bell glow, voice; never damage
## (B1 keeps the phase machine off on puppets). The puppet's position / yaw / hp still come from the snapshots.
func net_apply_boss_state(st: Array) -> void:
	if st.size() < 4:
		return
	if bool(st[1]) and not _enraged:
		_set_enraged()
	var ph := int(st[0])
	if ph == int(phase):
		return
	phase = ph as Phase
	_slam_center = st[2] if st[2] is Vector3 else global_position
	_charge_dir = st[3] if st[3] is Vector3 else Vector3.FORWARD
	match phase:
		Phase.SLAM_WINDUP:
			_show_slam_windup()
			_attack_anim_t = float(_tg.get("slam_windup", 1.2))
		Phase.SLAM_IMPACT:
			Art.play(self, "slam_impact", 0.05, _clip_speed())
			_attack_anim_t = slam_hit_time() / _clip_speed() + 0.05
		Phase.STUNNED:
			var rest := _stun_rest()
			_attack_anim_t = rest + float(_tg.get("slam_stun", 1.0))
			if Art.has_clip(self, "stun"):
				get_tree().create_timer(rest).timeout.connect(func():
					if is_instance_valid(self) and phase == Phase.STUNNED and not _dead:
						_play_fit("stun", float(_tg.get("slam_stun", 1.0)))
						_attack_anim_t = float(_tg.get("slam_stun", 1.0)))
		Phase.CHARGE_WINDUP:
			_show_charge_windup()
			_attack_anim_t = float(_tg.get("charge_windup", 0.7))
		Phase.CHARGING:
			if not Art.play(self, "charge_run", 0.05, _clip_speed()):
				_play("run", 0.05)
			_attack_anim_t = float(_tg.get("charge_duration", 0.85))
		_:
			_attack_anim_t = 0.0
			if _anim:
				_anim.speed_scale = 1.0
