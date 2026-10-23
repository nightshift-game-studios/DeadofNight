extends "res://scripts/enemies/boss_base.gd"
## Choir Host — summoner support boss (Skillz). Boss rework 2026-10-22 (playtest #15).
## Channels behind a breakable resonance shield (a pool worth shield_secs of reference fire, scaled by stage and party).
## While it channels a CRESCENDO ring (radius 8+ m) fills on the ground: if the shield is not broken before the channel
## ends the ring detonates for 70 % of a player's health, so break the shield (from outside the ring is fine) or leave
## it. Echo adds pour out the whole time. Break the shield -> the Host staggers (x1.4 damage).
##   stage 0  Channel + Crescendo + echoes.
##   stage 1  + Dirge Blast (blue cone, 0.95 s windup) between channels, + Discord zones under players while channeling.
##   stage 2  Requiem: bigger shield, faster echoes, more zones, the Dirge Blast fires twice (second one re-aimed).
## Frenzy (soft enrage): +30 % damage, -30 % cooldowns, Crescendo +2 m.
## Art (Desi, choir_host.glb): Channel (looped in code) while channeling; ChannelHit stagger when the shield breaks; the
## rib cavity (ChoirHost_Cavity emission) glows while channeling and dims when the shield breaks.

enum Phase { WALK, CHANNEL, STAGGER, PULSE_WINDUP }

var phase: Phase = Phase.WALK
var shield_hp: float = 0.0
var shield_max: float = 0.0
var channeling: bool = false
var _cd: float = 3.0
var _pulse_cd: float = 3.0
var _phase_t: float = 0.0
var _echo_acc: float = 0.0
var _discord_acc: float = 0.0
var _dim_t: float = 0.0 ## seconds left of the dimmed cavity after a shield break
var _cres: Dictionary = {}
var _pulse_shape: Dictionary = {}
var _pulse_second: bool = false
var shields_broken: int = 0
var crescendos: int = 0


func _configured() -> void:
	_cd = 2.5
	_pulse_cd = 4.0


func _cavity(mult: float) -> void:
	Art.set_emission(self, str(_fx.get("cavity_material", "ChoirHost_Cavity")), mult)


func _extra_taken_mult() -> float:
	return float(_tg.get("stagger_damage_mult", 1.4)) if phase == Phase.STAGGER else 1.0


## Shield pool for this channel: shield_secs of reference fire (ref_dps x party factor), x stage mult.
func shield_pool() -> float:
	return Catalog.ref_dps(round_n) * float(_tg.get("shield_secs", 3.4)) * tgs("shield_stage_mult", 1.0) * Catalog.party_hp_mult(party)


func take_damage(amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, source: Node = null) -> bool:
	if channeling and shield_hp > 0.0 and is_multiplayer_authority(): # NET B4: a co-op puppet's hit goes to the host whole (its shield absorbs there)
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
	if _dim_t > 0.0:
		_dim_t -= delta
		if _dim_t <= 0.0 and not channeling:
			_cavity(1.0)
	if not is_multiplayer_authority(): # NET B1: co-op client puppet -> phases come from the host (net_apply_boss_state); solo: always authority
		super._physics_process(delta)
		return
	base_tick(delta)
	match phase:
		Phase.WALK:
			_cd = maxf(_cd - delta, 0.0)
			_pulse_cd = maxf(_pulse_cd - delta, 0.0)
			super._physics_process(delta)
			if _cd <= 0.0:
				_begin_channel()
			elif _pulse_cd <= 0.0 and stage >= int(_tg.get("pulse_from_stage", 1)) and target != null and is_instance_valid(target) \
					and Kit.flat_dist(global_position, target.global_position) <= float(_tg.get("pulse_length", 12.0)) * 0.9:
				_start_pulse()
		Phase.CHANNEL:
			_channel_tick(delta)
		Phase.STAGGER:
			_attack_anim_t = maxf(_attack_anim_t, 0.1)
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.WALK
		Phase.PULSE_WINDUP:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_resolve_pulse()


# ------------------------------------------------------------------ channel / shield / Crescendo
func _channel_tick(delta: float) -> void:
	_attack_anim_t = maxf(_attack_anim_t, 0.1) # keep HitReact off the Channel loop
	_hold_still(delta)
	_phase_t -= delta
	_echo_acc += delta
	if _echo_acc >= tgs("echo_interval_stage", float(_tg.get("echo_interval", 2.0))) * (0.8 if frenzy else 1.0):
		_echo_acc = 0.0
		summon(tgs("echo_count_stage", 2.0) + (1.0 if frenzy else 0.0))
	if stage >= int(_tg.get("discord_from_stage", 1)):
		_discord_acc += delta
		if _discord_acc >= float(_tg.get("discord_burst_interval", 2.5)):
			_discord_acc = 0.0
			_discord_burst()
	if _phase_t <= 0.0:
		_end_channel(false)


func crescendo_radius() -> float:
	return float(_tg.get("crescendo_radius", 8.0)) + tgs("crescendo_radius_stage", 0.0) + (2.0 if frenzy else 0.0)


func _begin_channel() -> void:
	phase = Phase.CHANNEL
	channeling = true
	_phase_t = float(_tg.get("channel_duration", 5.5))
	_echo_acc = tgs("echo_interval_stage", float(_tg.get("echo_interval", 2.0))) # first wave soon
	_discord_acc = 0.0
	shield_max = shield_pool()
	shield_hp = shield_max
	_cres = telegraph({"id": "crescendo", "kind": "circle", "c": global_position, "r": crescendo_radius()}, _phase_t,
		hit_damage("crescendo"), color_of("main", Color(0.45, 0.6, 1.0, 0.5)))
	_channel_visuals()


func _channel_visuals() -> void:
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	if not Art.play(self, "channel", float(_an.get("blend", 0.18)), 1.0):
		_play("idle", 0.1)
	_dim_t = 0.0
	_cavity(float(_fx.get("channel_emission_mult", 2.5)))


func _discord_burst() -> void:
	var n := int(_tg.get("discord_per_burst_stage", [0, 2, 3])[mini(stage, 2)]) + (party - 1)
	var col := color_of("zone", Color(0.6, 0.4, 1.0, 0.5))
	for i in n:
		var victim := random_player()
		if victim == null:
			return
		var pos := victim.global_position + Vector3(randf_range(-1.5, 1.5), 0.0, randf_range(-1.5, 1.5))
		pos.y = global_position.y
		spawn_zone("discord", pos, float(_tg.get("discord_radius", 2.1)), float(_tg.get("discord_arm", 1.2)), float(_tg.get("discord_life", 5.0)),
			hit_damage("discord_tick"), float(_tg.get("discord_tick", 0.5)), 0, col)


func _interrupt_channel() -> void:
	shields_broken += 1
	_end_channel(true)


func _end_channel(interrupted: bool) -> void:
	channeling = false
	shield_hp = 0.0
	phase = Phase.WALK
	_cd = float(_tg.get("channel_cooldown_stage", [6.5, 5.2, 4.0])[mini(stage, 2)]) * cd_scale() * (0.7 if interrupted else 1.0)
	_phase_t = 0.0
	if not _cres.is_empty():
		if interrupted:
			cancel_threat(_cres)
		else:
			crescendos += 1
			resolve(_cres)
		_cres = {}
	_end_visuals(interrupted)
	if interrupted:
		phase = Phase.STAGGER # shield break: ChannelHit + a x1.4 window
		_phase_t = float(_tg.get("stagger_duration", 2.4))
		_attack_anim_t = maxf(_attack_anim_t, 0.1)


func _end_visuals(interrupted: bool) -> void:
	if interrupted:
		# Shield break: ChannelHit stagger (stands still for the clip) + the cavity dims for a while.
		_cavity(float(_fx.get("broken_emission_mult", 0.2)))
		_dim_t = float(_fx.get("broken_dim_time", 2.5))
		Art.play(self, "channel_hit", 0.05, 1.0)
	else:
		_cavity(1.0)
		if _anim:
			_anim.speed_scale = 1.0
		_play("walk", float(_an.get("blend", 0.18)))


# ------------------------------------------------------------------ Dirge Blast (cone)
func _start_pulse() -> void:
	phase = Phase.PULSE_WINDUP
	var t := float(_tg.get("pulse_windup", 0.95))
	_phase_t = t
	_pulse_shape = _pulse_cone(target as Node3D, t)
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	_play("idle", 0.1)


func _pulse_cone(at: Node3D, windup: float) -> Dictionary:
	var dir := Common.flat_dir_to(global_position, at.global_position if at else global_position + Vector3.FORWARD)
	rotation.y = atan2(-dir.x, -dir.z)
	return telegraph({"id": "dirge", "kind": "cone", "c": global_position, "d": dir, "len": float(_tg.get("pulse_length", 12.0)),
		"half": float(_tg.get("pulse_half_angle", 28.0))}, windup, hit_damage("pulse"), color_of("main", Color(0.45, 0.6, 1.0, 0.5)))


func _resolve_pulse() -> void:
	if not _pulse_shape.is_empty():
		resolve(_pulse_shape)
		_pulse_shape = {}
	if stage >= 2 and not _pulse_second and target != null and is_instance_valid(target):
		_pulse_second = true # Requiem: a second blast, re-aimed at where the target ran to
		var w2 := float(_tg.get("pulse_windup", 0.95)) * 0.85
		_pulse_shape = _pulse_cone(target as Node3D, w2)
		_phase_t = w2
		return
	_pulse_second = false
	phase = Phase.WALK
	_pulse_cd = float(_tg.get("pulse_cooldown", 4.0)) * cd_scale()


## Shield fraction remaining 0..1 (UI / tests).
func shield_frac() -> float:
	return 0.0 if shield_max <= 0.0 else clampf(shield_hp / shield_max, 0.0, 1.0)


# ------------------------------------------------------------------ NET B2 / B3: co-op boss state (Netz phase 3b)
## B2 (host): [phase, channeling, shield left in 5% steps (0..20), stage, frenzy, events]. NetWorld sends it on change.
## Indices 0..2 are unchanged since v0.8.0; 3..5 = BossBase.net_common (events carry the Crescendo ring, Dirge cones, Discord zones).
func net_boss_state() -> Array:
	return [int(phase), channeling, int(round(shield_frac() * 20.0))] + net_common()


## B3 (client puppet): channel start (Channel loop, cavity glow), shield break (ChannelHit stagger, dimmed cavity) or a
## normal end, plus the shield fraction for the boss bar. Telegraphs/zones replay from the event list. Never spawns echoes
## (main.gd only wires request_echo on the host) and never damages.
func net_apply_boss_state(st: Array) -> void:
	if st.size() < 3:
		return
	net_apply_common(st, 3)
	var ph := int(st[0])
	if ph == Phase.CHANNEL and phase != Phase.CHANNEL:
		channeling = true
		_channel_visuals()
		_attack_anim_t = float(_tg.get("channel_duration", 5.5))
	elif phase == Phase.CHANNEL and ph != Phase.CHANNEL:
		channeling = false
		shield_hp = 0.0
		_end_visuals(ph == Phase.STAGGER)
		_attack_anim_t = float(_tg.get("stagger_duration", 2.4)) if ph == Phase.STAGGER else 0.0
	phase = ph as Phase
	if channeling:
		shield_max = maxf(shield_max, 1.0)
		shield_hp = shield_max * clampf(float(st[2]) / 20.0, 0.0, 1.0)
