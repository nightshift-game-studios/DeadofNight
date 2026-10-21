extends "res://scripts/enemy.gd"
## Lantern Stalker — ambusher ranged boss (Skillz).
## Goes dark (speed buff, lantern dimmed, DarkSneak crouch) → lantern beam telegraph → blight spit → sidestep.
## Never a pure sponge; projectile is dodgeable.
## Art (Desi, lantern_stalker.glb): DarkSneak (looped in code) → LanternRaise (fit to beam_windup) → Spit → SidestepL/R
## (in place: code moves the root telegraph.sidestep_distance over anims.sidestep_time). Code OmniLight3D on the
## Lantern socket; beam telegraph from BeamOrigin; projectile from SpitMuzzle (fallbacks: fixed offsets).

const Catalog := preload("res://scripts/enemies/boss_catalog.gd")
const Common := preload("res://scripts/enemies/boss_common.gd")
const Telegraph := preload("res://scripts/enemies/boss_telegraph.gd")
const Spit := preload("res://scripts/enemies/blight_spit.gd")
const Art := preload("res://scripts/enemies/boss_art.gd")

enum Phase { HUNT, DARK, BEAM, SPIT, SIDESTEP }

var boss_id: String = "lantern_stalker"
var round_n: int = 1
var phase: Phase = Phase.HUNT
var _cd: float = 2.0
var _phase_t: float = 0.0
var _sidestep_dir: Vector3 = Vector3.RIGHT
var _tg: Dictionary = {}
var _an: Dictionary = {}
var _fx: Dictionary = {}
var _dark: bool = false
var _loco: Dictionary = {} ## walk/run clip names saved while DarkSneak stands in for them
var lantern_light: OmniLight3D ## code light on the Lantern socket (glb has no lights)
var _beam_dir: Vector3 = Vector3.FORWARD ## NET B2: last beam / spit aim, for co-op puppets
var _spit_dir: Vector3 = Vector3.FORWARD


func configure_boss(id: String, n: int, difficulty_id: String = "") -> void:
	boss_id = id
	round_n = n
	_tg = Catalog.telegraph(id)
	_an = Catalog.anims(id)
	_fx = Catalog.fx(id)
	Common.apply_identity(self, id, n, difficulty_id)
	attack_range = 12.0 # prefers ranged; melee only if cornered
	_cd = 1.8


func _ready() -> void:
	super._ready()
	if _an.is_empty():
		_an = Catalog.anims(boss_id)
		_fx = Catalog.fx(boss_id)
	Art.setup_anims(self, _an)
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


func _physics_process(delta: float) -> void:
	if _dead:
		_set_dark(false)
		if lantern_light:
			lantern_light.visible = false
		super._physics_process(delta)
		return
	if not is_multiplayer_authority(): # NET B1: co-op client puppet -> phases come from the host (net_apply_boss_state); solo: always authority
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
			_hold(delta)
			if target:
				var look := Common.flat_dir_to(global_position, target.global_position)
				rotation.y = atan2(-look.x, -look.z)
			_phase_t -= delta
			if _phase_t <= 0.0:
				_fire_spit()
				phase = Phase.SPIT
				_phase_t = float(_an.get("spit_recover", 0.3))
				Art.play(self, "spit", 0.05, 1.0)
		Phase.SPIT:
			_hold(delta)
			_phase_t -= delta
			if _phase_t <= 0.0:
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
				_cd = float(_tg.get("cycle_cooldown", 3.5))
				_set_dark(false)
				_light("light_energy", 1.6)


func _hold(delta: float) -> void:
	_attack_anim_t = maxf(_attack_anim_t, 0.1) # no random HitReact over LanternRaise / Spit
	velocity.x = 0.0
	velocity.z = 0.0
	if not is_on_floor():
		velocity.y -= _gravity * delta
	move_and_slide()


func _begin_dark() -> void:
	phase = Phase.DARK
	_phase_t = float(_tg.get("dark_duration", 1.6))
	_set_dark(true)
	_say("zombie_aggro_scream", 1)


func _begin_beam() -> void:
	phase = Phase.BEAM
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	_phase_t = float(_tg.get("beam_windup", 0.8))
	_beam_dir = Vector3.FORWARD
	if target:
		_beam_dir = Common.flat_dir_to(global_position, target.global_position)
	_show_beam()


## LanternRaise + beam telegraph along _beam_dir (host and co-op puppets, NET B3).
func _show_beam() -> void:
	var t := float(_tg.get("beam_windup", 0.8))
	_set_dark(false)
	_light("beam_energy", 3.0)
	var clip_len := Art.clip_length(self, "raise", t)
	Art.play(self, "raise", float(_an.get("blend", 0.15)), clip_len / maxf(t, 0.05))
	var from := Art.socket_pos(self, str(_fx.get("beam_socket", "BeamOrigin")), global_position + Vector3(0, 1.2, 0))
	Telegraph.spawn_line(get_parent() if get_parent() else self, from, _beam_dir,
		float(_tg.get("beam_length", 18.0)), t, Color(1.0, 0.85, 0.25, 0.55), 0.7)


func _fire_spit() -> void:
	if target == null or not is_instance_valid(target):
		return
	var origin := Art.socket_pos(self, str(_fx.get("spit_socket", "SpitMuzzle")), global_position + Vector3(0, 1.3, 0))
	var aim := target.global_position + Vector3(0, 1.0, 0)
	var dir := (aim - origin).normalized()
	_spit_dir = dir
	var dmg := Catalog.attack_damage(boss_id, round_n, 10, 2, float(_tg.get("spit_damage_mult", 1.8)))
	Spit.fire(self, origin, dir, dmg, float(_tg.get("spit_speed", 14.0)))


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
## B2 (host): [phase, beam dir, spit dir, sidestep dir]. NetWorld sends it on change.
func net_boss_state() -> Array:
	return [int(phase), _beam_dir, _spit_dir, _sidestep_dir]


## B3 (client puppet): dark sneak, beam windup + telegraph, a visual-only spit (no damage; the host's spit is the
## real one), sidestep clip, back to hunting. Never damages.
func net_apply_boss_state(st: Array) -> void:
	if st.size() < 4:
		return
	var ph := int(st[0])
	if ph == int(phase):
		return
	phase = ph as Phase
	_beam_dir = st[1] if st[1] is Vector3 else Vector3.FORWARD
	_spit_dir = st[2] if st[2] is Vector3 else Vector3.FORWARD
	_sidestep_dir = st[3] if st[3] is Vector3 else Vector3.RIGHT
	match phase:
		Phase.DARK:
			_begin_dark()
			_attack_anim_t = 0.0 # DarkSneak replaces walk/run: the puppet tick keeps animating locomotion
		Phase.BEAM:
			_show_beam()
			_attack_anim_t = float(_tg.get("beam_windup", 0.8))
		Phase.SPIT:
			var origin := Art.socket_pos(self, str(_fx.get("spit_socket", "SpitMuzzle")), global_position + Vector3(0, 1.3, 0))
			Spit.fire(self, origin, _spit_dir, 0, float(_tg.get("spit_speed", 14.0)), true)
			Art.play(self, "spit", 0.05, 1.0)
			_attack_anim_t = float(_an.get("spit_recover", 0.3))
		Phase.SIDESTEP:
			_show_sidestep()
			_attack_anim_t = float(_an.get("sidestep_time", 0.5))
		_:
			_set_dark(false)
			_light("light_energy", 1.6)
			_attack_anim_t = 0.0
