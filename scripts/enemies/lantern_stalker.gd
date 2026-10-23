extends "res://scripts/enemies/boss_base.gd"
## Lantern Stalker — ambusher ranged boss (Skillz). Boss rework 2026-10-22 (playtest #15).
## Cycle: goes dark (speed buff, lantern dimmed, DarkSneak crouch) -> lantern beam telegraph (a LOCKED yellow lane) -> the
## blight spit flies down exactly that lane -> sidestep. Dodge = leave the lane.
##   stage 0  the base cycle (faster than before: shorter windup/cooldown).
##   stage 1  + Fan (three lanes), Gloam puddles where spit lands, Lantern Bombs (delayed blasts on players), Blink
##            (marks a spot 0.7 s ahead, then jumps there and fires), Pack Call (echo adds), Flare when you hug it.
##   stage 2  Double Volley (a second, re-aimed lane 0.5 s after the first), 4 bombs, wider fan, faster everything.
## Frenzy (soft enrage): +30 % damage, -30 % cooldowns, 0.85x windups, faster spit.
## Contact damage is off: its melee range was 12 m (it "hit" from across the room). Close-in players get the Flare instead.
## Art (Desi, lantern_stalker.glb): DarkSneak (looped in code) -> LanternRaise (fit to beam_windup) -> Spit -> SidestepL/R
## (in place: code moves the root telegraph.sidestep_distance over anims.sidestep_time). Code OmniLight3D on the
## Lantern socket; beam telegraph from BeamOrigin; projectile from SpitMuzzle (fallbacks: fixed offsets).

const Spit := preload("res://scripts/enemies/blight_spit.gd")

enum Phase { HUNT, DARK, BEAM, SPIT, SIDESTEP, BLINK, CAST }

var phase: Phase = Phase.HUNT
var _cd: float = 2.0
var _phase_t: float = 0.0
var _sidestep_dir: Vector3 = Vector3.RIGHT
var _dark: bool = false
var _loco: Dictionary = {} ## walk/run clip names saved while DarkSneak stands in for them
var lantern_light: OmniLight3D ## code light on the Lantern socket (glb has no lights)
var _beam_dir: Vector3 = Vector3.FORWARD ## NET B2: last beam / spit aim, for co-op puppets
var _spit_dir: Vector3 = Vector3.FORWARD
var _pitch: float = 0.0
var _volley_left: int = 0
var _volley_short: bool = false
var _blink_to: Vector3 = Vector3.ZERO
var _blink_cd: float = 4.0
var _bomb_cd: float = 7.0
var _flare_cd: float = 0.0
var _cast_kind: String = ""
var _flare_shape: Dictionary = {}
var _beam_from: Vector3 = Vector3.ZERO
var spits_fired: int = 0
var blinks: int = 0
var bombs_dropped: int = 0


func _configured() -> void:
	attack_range = 11.0 # prefers ranged
	contact_damage = 0 # no 12 m "melee": the Flare punishes anyone who hugs it
	_cd = 1.8


func _ready() -> void:
	super._ready()
	_make_light()


func _make_light() -> void:
	lantern_light = OmniLight3D.new()
	lantern_light.name = "LanternLight"
	var c: Array = _fx.get("light_color", [0.72, 0.95, 0.35])
	lantern_light.light_color = Color(float(c[0]), float(c[1]), float(c[2]))
	lantern_light.omni_range = float(_fx.get("light_range", 6.0))
	lantern_light.light_energy = float(_fx.get("light_energy", 1.6))
	lantern_light.shadow_enabled = false
	var sock := Art.socket(self, str(_fx.get("lantern_socket", "Lantern")))
	if sock:
		sock.add_child(lantern_light)
	else:
		add_child(lantern_light)
		lantern_light.position = Vector3(0.45, 1.45, 0.0)


func _light(energy_key: String, fallback: float) -> void:
	if lantern_light:
		lantern_light.light_energy = float(_fx.get(energy_key, fallback))


## Sidestep root speed so the in-place clip covers sidestep_distance (2.4 m) in sidestep_time (0.5 s).
func sidestep_speed() -> float:
	return float(_tg.get("sidestep_distance", 2.4)) / maxf(float(_an.get("sidestep_time", 0.5)), 0.05)


func spit_speed() -> float:
	return float(_tg.get("spit_speed", 14.0)) * (1.2 if frenzy else 1.0)


func _on_stage(s: int) -> void:
	if s >= 1 and is_authority() and not _dead:
		summon(float(_tg.get("pack_adds_stage", [0, 2, 3])[mini(s, 2)])) # Pack Call: it howls, echoes pour in


func _play_event(ev: Dictionary, auth: bool) -> void:
	super._play_event(ev, auth)
	match str(ev.k):
		"spit":
			if not auth:
				Spit.fire(self, ev.p, ev.d, 0, float(ev.a), true)
			sfx("spit_fire")
		"cast":
			sfx(str(ev.id) + "_windup")
		"blink":
			Kit.show_shape(_parent3d(), {"kind": "circle", "c": ev.p, "r": 1.3}, float(ev.a), color_of("blink", Color(0.8, 0.4, 1.0, 0.55)))
			sfx("blink_mark", ev.p)
		"blink_done":
			sfx("blink_jump")
			_light("beam_energy", 3.0)


func _physics_process(delta: float) -> void:
	if _dead:
		_set_dark(false)
		if lantern_light:
			lantern_light.visible = false
		super._physics_process(delta)
		return
	if not is_authority(): # NET B1: co-op client puppet -> phases come from the host (net_apply_boss_state); solo: always authority
		super._physics_process(delta)
		return
	base_tick(delta)
	match phase:
		Phase.HUNT:
			_cd = maxf(_cd - delta, 0.0)
			_blink_cd = maxf(_blink_cd - delta, 0.0)
			_bomb_cd = maxf(_bomb_cd - delta, 0.0)
			_flare_cd = maxf(_flare_cd - delta, 0.0)
			super._physics_process(delta)
			if target != null and is_instance_valid(target):
				if _flare_cd <= 0.0 and Kit.flat_dist(global_position, target.global_position) < float(_tg.get("flare_trigger", 3.4)) \
						and stage >= int(_tg.get("flare_from_stage", 1)):
					_start_cast("flare")
				elif _bomb_cd <= 0.0 and stage >= int(_tg.get("bomb_from_stage", 1)):
					_start_cast("bombs")
				elif _cd <= 0.0:
					_begin_dark()
		Phase.DARK:
			_phase_t -= delta
			var boost := float(_tg.get("dark_speed_mult", 1.45))
			var saved := speed
			speed *= boost
			super._physics_process(delta)
			speed = saved
			if _phase_t <= 0.0:
				if not _try_blink():
					_begin_beam(false)
		Phase.BLINK:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_do_blink()
		Phase.CAST:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_resolve_cast()
		Phase.BEAM:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_fire_volley()
				phase = Phase.SPIT
				_phase_t = float(_an.get("spit_recover", 0.3))
				Art.play(self, "spit", 0.05, 1.0)
		Phase.SPIT:
			_hold_still(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
				if _volley_left > 0 and target != null and is_instance_valid(target):
					_volley_left -= 1
					_begin_beam(true)
				else:
					_begin_sidestep()
		Phase.SIDESTEP:
			_attack_anim_t = maxf(_attack_anim_t, 0.1)
			if not is_on_floor():
				velocity.y -= _gravity * delta
			var v := sidestep_speed()
			velocity.x = _sidestep_dir.x * v
			velocity.z = _sidestep_dir.z * v
			move_and_slide()
			_phase_t -= delta
			if _phase_t <= 0.0:
				phase = Phase.HUNT
				_cd = tgs("cycle_cooldown_stage", float(_tg.get("cycle_cooldown", 3.5))) * cd_scale()
				_set_dark(false)
				_light("light_energy", 1.6)


func _attack_target() -> Node3D:
	if party > 1 and stage >= 1:
		return random_player()
	return target as Node3D


func _begin_dark() -> void:
	phase = Phase.DARK
	_phase_t = tgs("dark_duration_stage", float(_tg.get("dark_duration", 1.6)))
	_volley_left = 1 if stage >= int(_tg.get("volley_from_stage", 2)) else 0
	_set_dark(true)
	sfx("dark_start")


# ------------------------------------------------------------------ beam / spit lanes
func beam_windup(short: bool) -> float:
	var t := float(_tg.get("volley_windup", 0.5)) if short else tgs("beam_windup_stage", float(_tg.get("beam_windup", 0.8)))
	return t * (0.85 if frenzy else 1.0)


func _begin_beam(short: bool = false) -> void:
	phase = Phase.BEAM
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	_volley_short = short
	var t := beam_windup(short)
	_phase_t = t
	var tgt := _attack_target()
	_beam_from = Art.socket_pos(self, str(_fx.get("beam_socket", "BeamOrigin")), global_position + Vector3(0, 1.2, 0))
	_beam_dir = Vector3.FORWARD
	_pitch = 0.0
	if tgt:
		_beam_dir = Common.flat_dir_to(global_position, tgt.global_position)
		var fd := maxf(Kit.flat_dist(global_position, tgt.global_position), 1.0)
		_pitch = clampf((tgt.global_position.y + 1.0 - _beam_from.y) / fd, -0.25, 0.25)
	rotation.y = atan2(-_beam_dir.x, -_beam_dir.z)
	_beam_from = Art.socket_pos(self, str(_fx.get("beam_socket", "BeamOrigin")), global_position + Vector3(0, 1.2, 0))
	_show_beam(t)
	var dirs := _lane_dirs()
	var dmg := hit_damage("spit")
	for i in dirs.size():
		var sh := telegraph({"id": "spit", "kind": "line", "c": _beam_from, "d": dirs[i], "len": float(_tg.get("beam_length", 18.0)),
			"w": float(_tg.get("beam_width", 1.0))}, t, dmg if i == 0 else hit_damage("spit_fan"), color_of("main", Color(1.0, 0.85, 0.25, 0.55)))
		sh["t_hit"] = float(sh["t_hit"]) + 0.35 # the spit needs ~0.35-0.8 s to fly down the lane: keep it "live" for the bot
	_spit_dir = _beam_dir


func _lane_dirs() -> Array:
	var out: Array = [_beam_dir]
	if stage >= int(_tg.get("fan_from_stage", 1)) and not _volley_short:
		var a := deg_to_rad(float(_tg.get("fan_half_angle_stage", [0, 16, 20])[mini(stage, 2)]))
		out.append(_beam_dir.rotated(Vector3.UP, a))
		out.append(_beam_dir.rotated(Vector3.UP, -a))
	return out


## LanternRaise + lantern glow (host and co-op puppets, NET B3). The lane telegraphs themselves are events.
func _show_beam(t: float) -> void:
	_set_dark(false)
	_light("beam_energy", 3.0)
	var clip_len := Art.clip_length(self, "raise", t)
	Art.play(self, "raise", float(_an.get("blend", 0.15)), clip_len / maxf(t, 0.05))


func _fire_volley() -> void:
	var origin := Art.socket_pos(self, str(_fx.get("spit_socket", "SpitMuzzle")), global_position + Vector3(0, 1.3, 0))
	var dirs := _lane_dirs()
	for i in dirs.size():
		var d: Vector3 = dirs[i]
		var dir := (d + Vector3(0, _pitch, 0)).normalized()
		var dmg := hit_damage("spit" if i == 0 else "spit_fan")
		Spit.fire(self, origin, dir, dmg, spit_speed(), false, _on_spit_landed)
		spits_fired += 1
		emit_event("spit", {"id": "spit", "p": origin, "d": dir, "a": spit_speed()})


func _on_spit_landed(pos: Vector3) -> void:
	if _dead or stage < int(_tg.get("gloam_from_stage", 1)):
		return
	var g := Vector3(pos.x, global_position.y, pos.z)
	spawn_zone("gloam", g, float(_tg.get("gloam_radius", 1.9)), 0.35, float(_tg.get("gloam_life", 4.5)),
		hit_damage("gloam_tick"), float(_tg.get("gloam_tick", 0.5)), 0, color_of("zone", Color(0.5, 0.9, 0.2, 0.5)))


# ------------------------------------------------------------------ blink
func _try_blink() -> bool:
	if stage < int(_tg.get("blink_from_stage", 1)) or _blink_cd > 0.0 or target == null or not is_instance_valid(target):
		return false
	var space := get_world_3d().direct_space_state
	for i in 8:
		var ang := randf() * TAU
		var d := randf_range(float(_tg.get("blink_min", 7.0)), float(_tg.get("blink_max", 10.0)))
		var p := Kit.polar(target.global_position, ang, d)
		var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 2.0, 0), p + Vector3(0, -3.0, 0), 1)
		var r := space.intersect_ray(q)
		if r.is_empty() or absf(float(r.position.y) - global_position.y) > 1.5:
			continue
		var dest: Vector3 = r.position
		if not Kit.clear_line(self, dest + Vector3(0, 1.3, 0), target.global_position + Vector3(0, 1.3, 0)):
			continue
		_blink_to = dest
		phase = Phase.BLINK
		_phase_t = float(_tg.get("blink_mark", 0.7))
		_blink_cd = float(_tg.get("blink_cooldown", 7.0)) * cd_scale()
		emit_event("blink", {"p": dest, "a": _phase_t})
		_set_dark(false)
		return true
	return false


func _do_blink() -> void:
	blinks += 1
	global_position = _blink_to
	velocity = Vector3.ZERO
	emit_event("blink_done", {"p": _blink_to})
	_begin_beam(false)


# ------------------------------------------------------------------ bombs / flare
func _start_cast(kind: String) -> void:
	phase = Phase.CAST
	_cast_kind = kind
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	if kind == "flare":
		_phase_t = float(_tg.get("flare_windup", 0.75))
		_flare_shape = telegraph({"id": "flare", "kind": "circle", "c": global_position, "r": float(_tg.get("flare_radius", 3.4))},
			_phase_t, hit_damage("melee"), color_of("main", Color(1.0, 0.85, 0.25, 0.55)))
		_light("beam_energy", 3.0)
	else:
		_phase_t = float(_tg.get("bomb_windup", 0.7))
		emit_event("cast", {"id": "bombs", "a": _phase_t})
		_light("beam_energy", 3.0)
	var clip_len := Art.clip_length(self, "raise", _phase_t)
	Art.play(self, "raise", float(_an.get("blend", 0.15)), clip_len / maxf(_phase_t, 0.05))


func _resolve_cast() -> void:
	if _cast_kind == "flare":
		resolve(_flare_shape)
		_flare_cd = float(_tg.get("flare_cooldown", 6.0)) * cd_scale()
		_cd = maxf(_cd, 1.0)
	else:
		var n := int(_tg.get("bomb_count_stage", [0, 3, 4])[mini(stage, 2)]) + (party - 1) + (1 if frenzy else 0)
		var col := color_of("bomb", Color(0.95, 0.6, 0.15, 0.55))
		for i in n:
			var victim := random_player() if i > 0 else (target as Node3D)
			if victim == null:
				break
			var pos := victim.global_position
			if i > 0:
				pos = Kit.polar(pos, randf() * TAU, randf_range(1.0, 3.5))
			pos.y = global_position.y
			if spawn_zone("bomb", pos, float(_tg.get("bomb_radius", 3.0)), float(_tg.get("bomb_arm", 1.5)), 0.0,
					0, 0.5, hit_damage("lantern_blast"), col):
				bombs_dropped += 1
		_bomb_cd = float(_tg.get("bomb_cooldown", 9.0)) * cd_scale()
		_cd = maxf(_cd, 1.2)
	phase = Phase.HUNT
	_light("light_energy", 1.6)
	if _anim:
		_anim.speed_scale = 1.0


func _begin_sidestep() -> void:
	phase = Phase.SIDESTEP
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	_phase_t = float(_an.get("sidestep_time", 0.5))
	var away := Common.flat_dir_to(target.global_position, global_position) if target else Vector3.RIGHT
	_sidestep_dir = Vector3(-away.z, 0, away.x)
	if randf() < 0.5:
		_sidestep_dir = -_sidestep_dir
	_show_sidestep()


## Sidestep clip toward _sidestep_dir (host and co-op puppets, NET B3; the puppet's motion comes from snapshots).
func _show_sidestep() -> void:
	var t := float(_an.get("sidestep_time", 0.5))
	# SidestepR = the character's right (+X local); faces -Z, so right = basis.x.
	var right := _sidestep_dir.dot(global_basis.x) >= 0.0
	Art.play(self, "sidestep_r" if right else "sidestep_l", 0.08, Art.clip_length(self, "sidestep_r", t) / maxf(t, 0.05))


## Dark phase: DarkSneak crouch replaces walk/run, the lantern dims. Meta "lantern_dark" for VFX/HUD.
func _set_dark(on: bool) -> void:
	if on == _dark:
		return
	_dark = on
	set_meta("lantern_dark", on)
	if on:
		_light("dark_energy", 0.15)
		if _anims.has("dark"):
			_loco = {"walk": _anims.get("walk", ""), "run": _anims.get("run", "")}
			_anims["walk"] = _anims["dark"]
			_anims["run"] = _anims["dark"]
	else:
		for k in _loco:
			if str(_loco[k]) != "":
				_anims[k] = _loco[k]
			else:
				_anims.erase(k)
		_loco = {}


func is_dark() -> bool:
	return _dark


# ------------------------------------------------------------------ NET B2 / B3: co-op boss state (Netz phase 3b)
## B2 (host): [phase, beam dir, spit dir, sidestep dir, stage, frenzy, events]. NetWorld sends it on change.
## 0..3 unchanged since v0.8.0 (phase enum only gained BLINK=5, CAST=6); 4..6 = BossBase.net_common (events carry the
## lanes, spits, bombs, gloam puddles, blink marks).
func net_boss_state() -> Array:
	return [int(phase), _beam_dir, _spit_dir, _sidestep_dir] + net_common()


## B3 (client puppet): dark sneak, beam windup, sidestep clip, back to hunting. Lanes, spits (visual-only), bombs,
## puddles and blink marks replay from the event list. Never damages.
func net_apply_boss_state(st: Array) -> void:
	if st.size() < 4:
		return
	net_apply_common(st, 4)
	var ph := int(st[0])
	if ph == int(phase):
		return
	phase = ph as Phase
	_beam_dir = st[1] if st[1] is Vector3 else Vector3.FORWARD
	_spit_dir = st[2] if st[2] is Vector3 else Vector3.FORWARD
	_sidestep_dir = st[3] if st[3] is Vector3 else Vector3.RIGHT
	match phase:
		Phase.DARK:
			_begin_dark_visual()
			_attack_anim_t = 0.0 # DarkSneak replaces walk/run: the puppet tick keeps animating locomotion
		Phase.BEAM:
			var t := beam_windup(false)
			rotation.y = atan2(-_beam_dir.x, -_beam_dir.z)
			_show_beam(t)
			_attack_anim_t = t
		Phase.SPIT:
			Art.play(self, "spit", 0.05, 1.0)
			_attack_anim_t = float(_an.get("spit_recover", 0.3))
		Phase.SIDESTEP:
			_show_sidestep()
			_attack_anim_t = float(_an.get("sidestep_time", 0.5))
		Phase.BLINK, Phase.CAST:
			_set_dark(false)
			_attack_anim_t = 0.7
		_:
			_set_dark(false)
			_light("light_energy", 1.6)
			_attack_anim_t = 0.0


func _begin_dark_visual() -> void:
	_set_dark(true)
