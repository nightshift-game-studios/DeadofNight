extends Node
## Sfx autoload: the one place that plays sound.
##  - Builds the sound bank by scanning res://assets/audio/ (sfx/*, music, ambience). A "key" is a
##    file name without its variation number, e.g. sfx/weapons/smg_fire_02.wav -> "smg_fire".
##    play() picks a random variation and applies slight pitch randomisation.
##  - Buses: Master, Music, SFX, UI, Ambience (default_bus_layout.tres; created here if missing).
##  - 2D one-shots (play), positional one-shots (play_at), loops that follow a node (attach_loop),
##    a capped pool of zombie voices (zombie_voice), music with crossfades (set_music), an always-on
##    ambience loop and the low-health heartbeat (set_low_health).
## Missing files are silently ignored, so the game never errors because of audio.

const ROOT := "res://assets/audio/"
const FOLDERS := ["sfx/weapons", "sfx/zombies", "sfx/player", "sfx/world", "sfx/ui", "music", "ambience"]
const BUS_DEFAULTS := {"Music": -9.0, "SFX": 0.0, "UI": -4.0, "Ambience": -12.0}
const MUSIC := {
	"menu": "music_main_menu_loop", ## before round 1 and on the game-over screen
	"break": "music_between_rounds_loop", ## between rounds
	"combat": "music_combat_loop", ## while a round is running
}
const MUSIC_DB := -4.0
const AMBIENCE_DB := -10.0
const CROSSFADE := 1.6
const MAX_ZOMBIE_VOICES := 4  # Audi-0 mix pass: was 6
const POOL_2D := 12
const POOL_3D := 28

## Per-key mix: volume_db, pitch jitter (+/-), bus. Matched by exact key first, then by prefix.
## Guns and zombie vocals are mastered hottest, so they sit at ~0 dB; foley and reloads are lower.
const MIX := {
	"_fire": [0.0, 0.05, "SFX"], "pulse_rifle_burst": [0.0, 0.04, "SFX"],
	"rocket_explosion": [2.0, 0.06, "SFX"], "frag_explode": [2.0, 0.07, "SFX"],
	"reload_mag": [-10.0, 0.05, "SFX"], "dry_fire": [-8.0, 0.05, "SFX"], "weapon_swap": [-9.0, 0.06, "SFX"],
	"impact_flesh": [-6.0, 0.10, "SFX"], "impact_concrete": [-9.0, 0.10, "SFX"], "impact_metal": [-8.0, 0.10, "SFX"],
	"zombie_idle_groan": [-8.0, 0.08, "SFX"], "zombie_aggro_scream": [-4.0, 0.07, "SFX"],
	"zombie_attack_swipe": [-6.0, 0.07, "SFX"], "zombie_hurt": [-5.5, 0.08, "SFX"], "zombie_death": [-3.0, 0.06, "SFX"],
	"zombie_footstep": [-14.0, 0.10, "SFX"], "zombie_shuffle": [-15.0, 0.10, "SFX"],
	"footstep_concrete": [-15.0, 0.08, "SFX"], "jump": [-11.0, 0.05, "SFX"], "land": [-9.0, 0.05, "SFX"],
	"slide": [-8.0, 0.05, "SFX"], "wall_jump_push": [-8.0, 0.05, "SFX"], "player_hurt": [-4.0, 0.05, "SFX"],
	"player_death": [-2.0, 0.0, "SFX"], "melee_swing": [-6.0, 0.06, "SFX"], "dash": [-6.0, 0.05, "SFX"],
	"adrenaline_boost": [-4.0, 0.0, "SFX"], "frag_throw": [-8.0, 0.06, "SFX"], "frag_bounce": [-9.0, 0.10, "SFX"],
	"tremor_charge_pulse_loop": [-3.0, 0.0, "SFX"], "heartbeat_low_health_loop": [-5.0, 0.0, "SFX"],
	"hitmarker": [-4.0, 0.04, "UI"],
	"round_start_stinger": [-2.0, 0.0, "UI"], "round_end_stinger": [-2.0, 0.0, "UI"], "game_over_sting": [-1.0, 0.0, "UI"],
	"menu_open": [-7.0, 0.02, "UI"], "menu_close": [-7.0, 0.02, "UI"], "ui_hover": [-15.0, 0.04, "UI"],
	"ui_equip": [-6.0, 0.02, "UI"], "ui_scrap_dismantle": [-6.0, 0.02, "UI"], "ui_skill_unlock": [-4.0, 0.0, "UI"],
	"points_tick": [-17.0, 0.06, "UI"], "loot_drop": [-6.0, 0.0, "UI"], "chest_open": [-4.0, 0.03, "UI"],
}
## Loot chime per rarity id (Rarity.IDS). loot_drop_epic.wav exists in the pack but has no rarity yet.
const LOOT_CHIME := {"common": "loot_drop_common", "uncommon": "loot_drop_uncommon", "rare": "loot_drop_rare",
	"legendary": "loot_drop_legendary", "mythic": "loot_drop_mythic"}

var bank: Dictionary = {} ## key -> Array[AudioStream]
var music_state: String = ""
var _pool2d: Array[AudioStreamPlayer] = []
var _pool3d: Array[AudioStreamPlayer3D] = []
var _next2d: int = 0
var _next3d: int = 0
var _music: Array[AudioStreamPlayer] = []
var _music_cur: int = 0
var _music_tweens: Array = [null, null]
var _ambience: AudioStreamPlayer
var _heartbeat: AudioStreamPlayer
var _voices: Array = [] ## active zombie voice players: [player, priority]
var _last_tick: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ensure_buses()
	scan()
	for i in POOL_2D:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool2d.append(p)
	for i in POOL_3D:
		var p3 := AudioStreamPlayer3D.new()
		_setup_3d(p3)
		add_child(p3)
		_pool3d.append(p3)
	for i in 2:
		var m := AudioStreamPlayer.new()
		m.bus = "Music"
		m.volume_db = -80.0
		add_child(m)
		_music.append(m)
	_ambience = AudioStreamPlayer.new()
	_ambience.bus = "Ambience"
	_ambience.volume_db = AMBIENCE_DB
	_ambience.stream = stream("ambience_wind_industrial_loop")
	add_child(_ambience)
	if _ambience.stream:
		_ambience.play()
	_heartbeat = AudioStreamPlayer.new()
	_heartbeat.bus = "SFX"
	_heartbeat.stream = stream("heartbeat_low_health_loop")
	_heartbeat.volume_db = -80.0
	add_child(_heartbeat)


# ------------------------------------------------------------------ setup

## Makes sure the five buses exist (the project ships default_bus_layout.tres; this is a fallback).
func ensure_buses() -> void:
	for b in BUS_DEFAULTS:
		if AudioServer.get_bus_index(b) < 0:
			AudioServer.add_bus()
			var i := AudioServer.bus_count - 1
			AudioServer.set_bus_name(i, b)
			AudioServer.set_bus_send(i, "Master")
			AudioServer.set_bus_volume_db(i, BUS_DEFAULTS[b])


## (Re)builds the bank from the audio folders. Loop flags are set in the .import files; they are
## enforced here too so a re-import with different settings can't break the music.
func scan() -> void:
	bank.clear()
	for folder in FOLDERS:
		var dir: String = ROOT + folder + "/"
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for f in ResourceLoader.list_directory(dir):
			if not (f.ends_with(".wav") or f.ends_with(".ogg")):
				continue
			var st := load(dir + f) as AudioStream
			if st == null:
				continue
			var key := _key_of(f.get_basename())
			if key.ends_with("_loop"):
				_force_loop(st)
			if not bank.has(key):
				bank[key] = []
			bank[key].append(st)


## "smg_fire_02" -> "smg_fire"; "loot_drop_rare" stays as is.
static func _key_of(base: String) -> String:
	var parts := base.split("_")
	if parts.size() > 1 and parts[-1].is_valid_int():
		parts.remove_at(parts.size() - 1)
	return "_".join(parts)


static func _force_loop(st: AudioStream) -> void:
	if st is AudioStreamOggVorbis:
		(st as AudioStreamOggVorbis).loop = true
	elif st is AudioStreamWAV:
		var w := st as AudioStreamWAV
		if w.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(w.get_length() * w.mix_rate)


func _setup_3d(p: AudioStreamPlayer3D) -> void:
	p.bus = "SFX"
	p.unit_size = 6.0
	p.max_distance = 60.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.attenuation_filter_cutoff_hz = 6000.0
	p.attenuation_filter_db = -12.0


# ------------------------------------------------------------------ lookups

func has(key: String) -> bool:
	return bank.has(key) and not (bank[key] as Array).is_empty()


## A random variation for `key` (null if missing).
func stream(key: String) -> AudioStream:
	var pool: Array = bank.get(key, [])
	return pool.pick_random() if pool.size() else null


## [volume_db, pitch_jitter, bus] for a key.
func mix(key: String) -> Array:
	if MIX.has(key):
		return MIX[key]
	for k in MIX:
		if key.begins_with(k) or (k.begins_with("_") and key.ends_with(k)):
			return MIX[k]
	return [-6.0, 0.05, "SFX"]


func _pitch(jitter: float) -> float:
	return 1.0 + randf_range(-jitter, jitter)


# ------------------------------------------------------------------ playback

## Non-positional one-shot. Returns the player (or null if the key is missing).
func play(key: String, volume_offset: float = 0.0, pitch: float = 1.0) -> AudioStreamPlayer:
	var st := stream(key)
	if st == null or _pool2d.is_empty():
		return null
	var p := _free_2d()
	var m := mix(key)
	p.stream = st
	p.bus = m[2]
	p.volume_db = float(m[0]) + volume_offset
	p.pitch_scale = pitch * _pitch(float(m[1]))
	p.play()
	return p


## Positional one-shot at a world position.
func play_at(key: String, pos: Vector3, volume_offset: float = 0.0) -> AudioStreamPlayer3D:
	var st := stream(key)
	if st == null or _pool3d.is_empty():
		return null
	var p := _free_3d()
	var m := mix(key)
	p.stream = st
	p.bus = m[2]
	p.volume_db = float(m[0]) + volume_offset
	p.pitch_scale = _pitch(float(m[1]))
	p.global_position = pos
	p.play()
	return p


## A looping positional sound that follows `node` until stopped or the node is freed.
func attach_loop(key: String, node: Node3D, volume_offset: float = 0.0) -> AudioStreamPlayer3D:
	var st := stream(key)
	if st == null or node == null:
		return null
	var p := AudioStreamPlayer3D.new()
	_setup_3d(p)
	var m := mix(key)
	p.stream = st
	p.volume_db = float(m[0]) + volume_offset
	node.add_child(p)
	p.play()
	return p


## Zombie vocals through the zombie's own AudioStreamPlayer3D, capped at MAX_ZOMBIE_VOICES
## at once. Higher priority (death 3 > aggro/attack 2 > hurt 1 > idle groan 0) steals the
## lowest-priority active voice when full. Returns true if the sound plays.
func zombie_voice(p: AudioStreamPlayer3D, key: String, priority: int = 0) -> bool:
	if p == null or not is_instance_valid(p) or not p.is_inside_tree():
		return false
	var st := stream(key)
	if st == null:
		return false
	_voices = _voices.filter(func(v): return is_instance_valid(v[0]) and v[0].playing and v[0] != p)
	if _voices.size() >= MAX_ZOMBIE_VOICES:
		var lowest := 0
		for i in _voices.size():
			if _voices[i][1] < _voices[lowest][1]:
				lowest = i
		if _voices[lowest][1] >= priority:
			return false
		(_voices[lowest][0] as AudioStreamPlayer3D).stop()
		_voices.remove_at(lowest)
	var m := mix(key)
	p.stream = st
	p.bus = m[2]
	p.volume_db = float(m[0])
	p.pitch_scale = _pitch(float(m[1]))
	p.play()
	_voices.append([p, priority])
	return true


func active_zombie_voices() -> int:
	_voices = _voices.filter(func(v): return is_instance_valid(v[0]) and v[0].playing)
	return _voices.size()


func _free_2d() -> AudioStreamPlayer:
	for i in _pool2d.size():
		var p := _pool2d[(_next2d + i) % _pool2d.size()]
		if not p.playing:
			_next2d = (_next2d + i + 1) % _pool2d.size()
			return p
	var q := _pool2d[_next2d] # all busy: steal the oldest
	_next2d = (_next2d + 1) % _pool2d.size()
	return q


func _free_3d() -> AudioStreamPlayer3D:
	for i in _pool3d.size():
		var p := _pool3d[(_next3d + i) % _pool3d.size()]
		if not p.playing:
			_next3d = (_next3d + i + 1) % _pool3d.size()
			return p
	var q := _pool3d[_next3d]
	_next3d = (_next3d + 1) % _pool3d.size()
	return q


# ------------------------------------------------------------------ game helpers

## Bullet/pellet impact sound for whatever was hit.
func impact(collider: Object, pos: Vector3, is_flesh: bool) -> void:
	play_at("impact_" + ("flesh" if is_flesh else surface_of(collider)), pos)


## "metal" or "concrete": node meta `surface` wins, otherwise a guess from node names.
static func surface_of(collider: Object) -> String:
	var n := collider as Node
	var depth := 0
	while n != null and depth < 4:
		if n.has_meta("surface"):
			return str(n.get_meta("surface"))
		var nm := String(n.name).to_lower()
		for word in ["metal", "platform", "ramp", "ledge", "container", "car", "rack", "jerrycan", "barrel", "can", "box", "crate", "chest"]:
			if word in nm:
				return "metal"
		n = n.get_parent()
		depth += 1
	return "concrete"


func loot_chime(rarity_id: String) -> void:
	play(LOOT_CHIME.get(rarity_id, "loot_drop_common"))


## Points tick, throttled so a shotgun blast or multi-kill doesn't machine-gun it.
func points_tick() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_tick < 90:
		return
	_last_tick = now
	play("points_tick")


## Heartbeat loop fades in below the low-health threshold.
func set_low_health(on: bool, intensity: float = 1.0) -> void:
	if _heartbeat == null or _heartbeat.stream == null:
		return
	var target: float = float(mix("heartbeat_low_health_loop")[0]) - (1.0 - clampf(intensity, 0.0, 1.0)) * 8.0
	if on:
		if not _heartbeat.playing:
			_heartbeat.volume_db = -30.0
			_heartbeat.play()
		_heartbeat.volume_db = move_toward(_heartbeat.volume_db, target, 2.0)
	elif _heartbeat.playing:
		_heartbeat.stop()


func heartbeat_playing() -> bool:
	return _heartbeat != null and _heartbeat.playing


# ------------------------------------------------------------------ music

## "menu", "break", "combat" or "" (silence). Crossfades over CROSSFADE seconds.
func set_music(state: String) -> void:
	if state == music_state:
		return
	music_state = state
	var old := _music[_music_cur]
	_music_cur = 1 - _music_cur
	var new := _music[_music_cur]
	var st: AudioStream = stream(MUSIC.get(state, "")) if state != "" else null
	_fade(1 - _music_cur, old, -80.0, true)
	if st:
		new.stream = st
		new.volume_db = -40.0
		new.play()
		_fade(_music_cur, new, MUSIC_DB, false)


func _fade(slot: int, p: AudioStreamPlayer, to_db: float, stop_after: bool) -> void:
	if _music_tweens[slot] and (_music_tweens[slot] as Tween).is_valid():
		(_music_tweens[slot] as Tween).kill()
	if not p.playing:
		return
	var t := create_tween()
	t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	t.tween_property(p, "volume_db", to_db, CROSSFADE).set_trans(Tween.TRANS_SINE)
	if stop_after:
		t.tween_callback(p.stop)
	_music_tweens[slot] = t


## The stream that is (or is fading to) the current music, for tests.
func current_music_stream() -> AudioStream:
	return _music[_music_cur].stream if _music[_music_cur].playing else null


func _exit_tree() -> void:
	# Stop and drop every stream on shutdown so the AudioServer releases its playbacks (no leak warnings at exit).
	var all: Array = []
	all.append_array(_pool2d)
	all.append_array(_pool3d)
	all.append_array(_music)
	all.append(_ambience)
	all.append(_heartbeat)
	for p in all:
		if is_instance_valid(p):
			p.stop()
			p.stream = null
	_voices.clear()
	bank.clear()
