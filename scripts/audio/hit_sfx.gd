class_name HitSfx
extends Node
## Hit-marker sounds. Listens to player.hit_registered and plays a random stream from
## res://assets/audio/sfx/ui/:  hitmarker_body_*.wav, hitmarker_head_*.wav, hitmarker_kill_*.wav
## Everything is optional: a missing folder or missing category just means silence (no errors).
## Call rescan() after new files are imported.

const SFX_DIR := "res://assets/audio/sfx/ui/"
const CATEGORIES := ["body", "head", "kill"]
const VOICES := 4

@export var volume_db: float = -4.0
@export var pitch_jitter: float = 0.04

var streams: Dictionary = {} ## "body"/"head"/"kill" -> Array[AudioStream]
var _players: Array[AudioStreamPlayer] = []
var _next: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.volume_db = volume_db
		if AudioServer.get_bus_index("SFX") >= 0:
			p.bus = "SFX"
		add_child(p)
		_players.append(p)
	rescan()


## (Re)load the hitmarker streams. Safe to call any time.
func rescan() -> void:
	streams.clear()
	for c in CATEGORIES:
		streams[c] = []
	var dir := DirAccess.open(SFX_DIR)
	if dir == null:
		return
	var seen := {}
	for f in dir.get_files():
		var name := f.trim_suffix(".import").trim_suffix(".remap") # exported builds list .import/.remap
		if seen.has(name) or not name.to_lower().ends_with(".wav"):
			continue
		seen[name] = true
		for c in CATEGORIES:
			if name.begins_with("hitmarker_%s_" % c):
				var path := SFX_DIR + name
				if ResourceLoader.exists(path):
					var st := load(path) as AudioStream
					if st:
						streams[c].append(st)


## Signal handler for player.hit_registered(target, damage, is_headshot, is_kill).
func on_hit(_target: Node, _damage: float, is_headshot: bool, is_kill: bool) -> void:
	var cat := "kill" if is_kill else ("head" if is_headshot else "body")
	var pool: Array = streams.get(cat, [])
	if pool.is_empty() and cat == "kill": # fall back so kills still click
		pool = streams.get("head" if is_headshot else "body", [])
	if pool.is_empty() or _players.is_empty():
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = pool.pick_random()
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.play()


## Number of streams found per category (for tests / debugging).
func counts() -> Dictionary:
	var out := {}
	for c in CATEGORIES:
		out[c] = (streams.get(c, []) as Array).size()
	return out
