extends "res://scripts/enemies/boss_base.gd"
## Bellwether — tank bruiser boss (Skillz). Boss rework 2026-10-22 (playtest #15).
## Three HP stages (100-75 / 75-50 / <50 %, data stages[]):
##   0  Bell Slam (circle telegraph, hits EVERY player inside in co-op) + Charge (red lane). Punish window after the slam.
##   1  + Aftershock (a donut that follows the slam: stand in the middle or >7 m out), Bell Toll (shockwave + echo adds
##        and an ARMOR GATE: x0.4 damage until the adds die, then a staggered x1.35 window), Knell (lingering zones).
##   2  Enraged: Double Slam, chained Charge, shorter windups / stuns. Frenzy (soft enrage timer): +30 % damage, -30 % cooldowns.
## Art (Desi, bellwether.glb): SlamWindup -> SlamImpact (damage lands anims.slam_hit_time = 0.17 s in) -> Stun;
## ChargeWindup -> ChargeRun (looped in code). Enrage = no clip: clips x fx.enrage_speed_scale + bell crack emission boost.
## Every attack is a threat shape (BossBase.telegraph / resolve), so the telegraph, the damage and the sim bot agree.

enum Phase { IDLE, SLAM_WINDUP, SLAM_IMPACT, STUNNED, CHARGE_WINDUP, CHARGING, TOLL_WINDUP, KNELL_WINDUP }

var phase: Phase = Phase.IDLE
var _cd: float = 2.0
var _phase_t: float = 0.0
var _enraged: bool = false
var _charge_dir: Vector3 = Vector3.FORWARD
var _slam_center: Vector3 = Vector3.ZERO
var _slam_shape: Dictionary = {}
var _stun_clip_t: float = -1.0 ## seconds until the Stun clip starts (after SlamImpact's follow-through), -1 = played
var _combo_left: int = 0
var _combo_second: bool = false
var _chain_left: int = 0
var _last_attack: String = ""
var _charge_hit: Array = []
var _stun_mult: float = 1.0
var _gate_armed: bool = false
var _gate_t: float = 0.0
var _gate_poll: float = 0.0
var gates_broken: int = 0


func _configured() -> void:
	attack_range = maxf(attack_range, float(_tg.get("slam_radius", 3.5)) * 0.45)
	_cd = 1.5


func is_enraged() -> bool:
	return _enraged


## Seconds into SlamImpact when the smash connects (hands bottom out, frame 4 of 24 fps).
func slam_hit_time() -> float:
	return float(_an.get("slam_hit_time", 0.17))


func _clip_speed() -> float:
	return float(_fx.get("enrage_speed_scale", 1.25)) if _enraged else 1.0


func is_gated() -> bool:
	return _gate_armed


func _extra_taken_mult() -> float:
	var m := 1.0
	if phase == Phase.STUNNED:
		m *= _stun_mult
	if _gate_armed:
		m *= float(_tg.get("toll_gate_mult", 0.4))
	return m


func _bell_glow(mult: float) -> void:
	Art.set_emission(self, str(_fx.get("bell_material", "Bellwether_Bell")), mult)


func _set_enraged() -> void:
	_enraged = true
	_bell_glow(float(_fx.get("enrage_emission_mult", 4.0)))


func _on_stage(s: int) -> void:
	if s >= 2 and not _enraged:
		_set_enraged()


func _on_frenzy() -> void:
	if not _enraged:
		_set_enraged()


func _play_event(ev: Dictionary, auth: bool) -> void:
	super._play_event(ev, auth)
	match str(ev.k):
		"cast":
			sfx(str(ev.id) + "_windup")
		"gate_on":
			sfx("gate_on")
			_bell_glow(2.2)
		"gate_break":
			sfx("gate_break")
			_bell_glow(float(_fx.get("enrage_emission_mult", 4.0)) if _enraged else 1.0)


func _physics_process(delta: float) -> void:
	if _dead or not is_authority(): # NET B1: co-op client puppet -> phases come from the host (net_apply_boss_state); solo: always authority
		super._physics_process(delta)
		return
	base_tick(delta)
	_gate_tick(delta)
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
					_play_fit("stun", maxf(_phase_t, 0.3))
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.IDLE
				_cd = tgs("slam_cooldown_stage", float(_tg.get("slam_cooldown", 5.0))) * cd_scale()
				if _anim:
					_anim.speed_scale = 1.0
		Phase.CHARGE_WINDUP:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.CHARGING
				_phase_t = float(_tg.get("charge_duration", 0.85))
				_charge_hit.clear()
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
			var hit := _try_charge_hit()
			_phase_t -= delta
			if _phase_t <= 0.0 or hit:
				_end_charge(hit)
		Phase.TOLL_WINDUP:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_resolve_toll()
		Phase.KNELL_WINDUP:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_resolve_knell()


# ------------------------------------------------------------------ attack choice
func _pick_attack() -> String:
	var w := {"slam": [65.0, 35.0, 25.0][mini(stage, 2)], "charge": [35.0, 20.0, 20.0][mini(stage, 2)]}
	if (stage >= int(_tg.get("toll_from_stage", 1)) or frenzy) and not _gate_armed and Kit.adds_alive(get_tree()) == 0:
		w["toll"] = [0.0, 20.0, 15.0][mini(stage, 2)] + (25.0 if frenzy else 0.0)
	if stage >= int(_tg.get("knell_from_stage", 1)):
		w["knell"] = 25.0
	if w.size() > 1 and w.has(_last_attack):
		w.erase(_last_attack)
	var total := 0.0
	for k in w:
		total += float(w[k])
	var r := randf() * total
	for k in w:
		r -= float(w[k])
		if r <= 0.0:
			return str(k)
	return "slam"


func _start_special() -> void:
	if target == null or not is_instance_valid(target):
		return
	var pick := _pick_attack()
	_last_attack = pick
	match pick:
		"charge":
			_chain_left = int(_tg.get("charge_chain_stage2", 1)) if stage >= 2 else 0
			_start_charge()
		"toll":
			_start_toll()
		"knell":
			_start_knell()
		_:
			_combo_left = 1 if stage >= int(_tg.get("double_slam_from_stage", 2)) else 0
			_start_slam()


func _attack_target() -> Node3D:
	if party > 1 and stage >= 1:
		return random_player() # co-op: later stages pick any player, not just the nearest
	return target as Node3D


# ------------------------------------------------------------------ slam (+ aftershock, double slam)
func _start_slam() -> void:
	phase = Phase.SLAM_WINDUP
	var t := float(_tg.get("double_slam_windup", 0.85)) if _combo_second else tgs("slam_windup_stage", float(_tg.get("slam_windup", 1.2)))
	_combo_second = false
	_phase_t = t
	_slam_center = global_position
	var tgt := _attack_target()
	if tgt:
		_slam_center = Vector3(tgt.global_position.x, global_position.y, tgt.global_position.z)
	_slam_shape = telegraph({"id": "slam", "kind": "circle", "c": _slam_center, "r": float(_tg.get("slam_radius", 3.5))},
		t, hit_damage("slam"), color_of("main", Color(1.0, 0.35, 0.1, 0.5)), slam_hit_time() / _clip_speed())
	if not Art.has_clip(self, "slam_windup"):
		_play("attack", 0.1)
	else:
		_play_fit("slam_windup", t)


func _start_impact() -> void:
	phase = Phase.SLAM_IMPACT
	_phase_t = slam_hit_time() / _clip_speed()
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	Art.play(self, "slam_impact", 0.05, _clip_speed())


func _resolve_slam() -> void:
	resolve(_slam_shape)
	if stage >= int(_tg.get("aftershock_from_stage", 1)):
		var w := float(_tg.get("aftershock_width", 3.5))
		var r0 := float(_tg.get("slam_radius", 3.5))
		var wind := float(_tg.get("aftershock_windup", 0.9))
		var sh := telegraph({"id": "aftershock", "kind": "ring", "c": _slam_center, "r0": r0, "r1": r0 + w}, wind,
			hit_damage("aftershock"), color_of("danger", Color(1.0, 0.15, 0.1, 0.5)))
		later(wind, func(): resolve(sh))
	if _combo_left > 0:
		_combo_left -= 1
		_combo_second = true
		_start_slam()
		return
	phase = Phase.STUNNED
	_stun_mult = float(_tg.get("stun_damage_mult", 1.25))
	_phase_t = _stun_rest() + tgs("slam_stun_stage", float(_tg.get("slam_stun", 1.0)))
	_stun_clip_t = _stun_rest() if Art.has_clip(self, "stun") else -1.0


## SlamImpact plays out its follow-through (ends low), then Stun (slam_stun seconds) - the punish window.
func _stun_rest() -> float:
	if not Art.has_clip(self, "slam_impact"):
		return 0.0
	return maxf(Art.clip_length(self, "slam_impact") - slam_hit_time(), 0.0) / _clip_speed()


# ------------------------------------------------------------------ charge
func charge_length() -> float:
	return speed * float(_tg.get("charge_speed_mult", 2.4)) * float(_tg.get("charge_duration", 0.85)) + 1.0


func _start_charge() -> void:
	phase = Phase.CHARGE_WINDUP
	var t := float(_tg.get("charge_windup_enraged" if stage >= 2 else "charge_windup", 0.75))
	_phase_t = t
	var tgt := _attack_target()
	_charge_dir = Common.flat_dir_to(global_position, (tgt if tgt else target).global_position)
	rotation.y = atan2(-_charge_dir.x, -_charge_dir.z)
	telegraph({"id": "charge", "kind": "line", "c": global_position, "d": _charge_dir, "len": charge_length(),
		"w": float(_tg.get("charge_width", 1.8))}, t, hit_damage("charge"), color_of("danger", Color(1.0, 0.12, 0.08, 0.6)))
	_play_fit("charge_windup", t)


## One hit per player per charge (co-op: it can clip several). True = it connected (the charge ends).
func _try_charge_hit() -> bool:
	var hit := false
	var reach := float(_tg.get("charge_width", 1.8)) * 0.5 + 0.7
	for p in Kit.players(self):
		if _charge_hit.has(p):
			continue
		if Kit.flat_dist(global_position, (p as Node3D).global_position) <= reach and absf(p.global_position.y - global_position.y) < 2.5:
			_charge_hit.append(p)
			p.call("take_damage", hit_damage("charge"), self)
			impacts += 1
			hit = true
	if hit:
		emit_event("impact", {"id": "charge", "p": global_position})
	return hit


func _end_charge(hit: bool) -> void:
	if _chain_left > 0 and not hit and target != null and is_instance_valid(target):
		_chain_left -= 1
		_start_charge()
		return
	_chain_left = 0
	phase = Phase.IDLE
	_cd = float(_tg.get("charge_cooldown", 4.5)) * cd_scale() * (0.8 if stage >= 1 else 1.0)


# ------------------------------------------------------------------ Bell Toll (adds + armor gate)
func _start_toll() -> void:
	phase = Phase.TOLL_WINDUP
	var t := float(_tg.get("toll_windup", 1.3))
	_phase_t = t
	_slam_shape = telegraph({"id": "toll", "kind": "circle", "c": global_position, "r": float(_tg.get("toll_radius", 5.0))},
		t, hit_damage("toll"), color_of("toll", Color(0.95, 0.8, 0.3, 0.5)))
	_play_fit("slam_windup", t)


func _resolve_toll() -> void:
	resolve(_slam_shape)
	var base := float(_tg.get("toll_adds_stage", [0, 2, 3])[mini(stage, 2)])
	if frenzy:
		base += 1.0
	if summon(base) > 0:
		_gate_armed = true
		_gate_t = 0.0
		_gate_poll = 0.0
		emit_event("gate_on", {})
	phase = Phase.IDLE
	_cd = 2.2 * cd_scale()


func _gate_tick(delta: float) -> void:
	if not _gate_armed:
		return
	_gate_t += delta
	_gate_poll -= delta
	if _gate_poll > 0.0:
		return
	_gate_poll = 0.2
	if _gate_t > 0.6 and Kit.adds_alive(get_tree()) == 0:
		_break_gate(true)
	elif _gate_t >= float(_tg.get("toll_gate_max", 14.0)):
		_break_gate(false)


func _break_gate(success: bool) -> void:
	_gate_armed = false
	emit_event("gate_break", {"a": 1.0 if success else 0.0})
	if success:
		gates_broken += 1
		if phase == Phase.IDLE:
			phase = Phase.STUNNED
			_stun_mult = float(_tg.get("toll_break_dmg_mult", 1.35))
			_phase_t = float(_tg.get("toll_break_stun", 1.8))
			_stun_clip_t = 0.0 if Art.has_clip(self, "stun") else -1.0


# ------------------------------------------------------------------ Knell (lingering zones)
func _start_knell() -> void:
	phase = Phase.KNELL_WINDUP
	var t := float(_tg.get("knell_windup", 0.9))
	_phase_t = t
	emit_event("cast", {"id": "knell", "a": t})
	_play_fit("slam_windup", t)


func _resolve_knell() -> void:
	var n := int(_tg.get("knell_zones_stage", [0, 3, 4])[mini(stage, 2)]) + (party - 1)
	var rad := float(_tg.get("knell_zone_radius", 2.4)) * (1.2 if frenzy else 1.0)
	var col := color_of("zone", Color(0.95, 0.5, 0.1, 0.5))
	for i in n:
		var victim := random_player() if i > 0 else (target as Node3D)
		if victim == null:
			break
		var pos := victim.global_position
		if i > 0:
			pos = Kit.polar(pos, randf() * TAU, randf_range(3.5, 6.5))
		pos.y = global_position.y
		spawn_zone("knell", pos, rad, float(_tg.get("knell_zone_arm", 1.1)), float(_tg.get("knell_zone_life", 5.5)),
			hit_damage("knell_tick"), float(_tg.get("knell_zone_tick", 0.5)), hit_damage("knell_burst"), col)
	phase = Phase.IDLE
	_cd = 2.0 * cd_scale()


# ------------------------------------------------------------------ NET B2 / B3: co-op boss state (Netz phase 3b)
## B2 (host): what a client puppet needs to show this boss's attacks. NetWorld polls it every physics frame and
## sends it on change. [phase, enraged, slam center, charge dir, stage, frenzy, events]  (0..3 unchanged since v0.8.0;
## 4..6 = BossBase.net_common: HP stage, soft-enrage flag, last 8 events - telegraph shapes, zones, impacts, adds)
func net_boss_state() -> Array:
	return [int(phase), _enraged, _slam_center, _charge_dir] + net_common()


## B3 (client puppet): play the phase the host just entered. Clips, bell glow, voice; telegraphs/zones come from the
## event list; never damage (B1 keeps the phase machine off on puppets). Position / yaw / hp still come from snapshots.
func net_apply_boss_state(st: Array) -> void:
	if st.size() < 4:
		return
	if bool(st[1]) and not _enraged:
		_set_enraged()
	net_apply_common(st, 4)
	var ph := int(st[0])
	if ph == int(phase):
		return
	phase = ph as Phase
	_slam_center = st[2] if st[2] is Vector3 else global_position
	_charge_dir = st[3] if st[3] is Vector3 else Vector3.FORWARD
	match phase:
		Phase.SLAM_WINDUP:
			if Art.has_clip(self, "slam_windup"):
				_play_fit("slam_windup", tgs("slam_windup_stage", float(_tg.get("slam_windup", 1.2))))
			else:
				_play("attack", 0.1)
			_attack_anim_t = tgs("slam_windup_stage", float(_tg.get("slam_windup", 1.2)))
		Phase.SLAM_IMPACT:
			Art.play(self, "slam_impact", 0.05, _clip_speed())
			_attack_anim_t = slam_hit_time() / _clip_speed() + 0.05
		Phase.STUNNED:
			var rest := _stun_rest()
			var stun := tgs("slam_stun_stage", float(_tg.get("slam_stun", 1.0)))
			_attack_anim_t = rest + stun
			if Art.has_clip(self, "stun"):
				get_tree().create_timer(rest).timeout.connect(func():
					if is_instance_valid(self) and phase == Phase.STUNNED and not _dead:
						_play_fit("stun", stun)
						_attack_anim_t = stun)
		Phase.CHARGE_WINDUP:
			rotation.y = atan2(-_charge_dir.x, -_charge_dir.z)
			_play_fit("charge_windup", float(_tg.get("charge_windup", 0.75)))
			_attack_anim_t = float(_tg.get("charge_windup", 0.75))
		Phase.CHARGING:
			if not Art.play(self, "charge_run", 0.05, _clip_speed()):
				_play("run", 0.05)
			_attack_anim_t = float(_tg.get("charge_duration", 0.85))
		Phase.TOLL_WINDUP, Phase.KNELL_WINDUP:
			var wt := float(_tg.get("toll_windup" if phase == Phase.TOLL_WINDUP else "knell_windup", 1.0))
			_play_fit("slam_windup", wt)
			_attack_anim_t = wt
		_:
			_attack_anim_t = 0.0
			if _anim:
				_anim.speed_scale = 1.0
