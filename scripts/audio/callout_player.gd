extends Node
## Autoload "Callouts": announcer voice lines for rapid-kill bursts, no-damage streaks and boss kills.
## Register in project.godot [autoload]:  Callouts="*res://scripts/audio/callout_player.gd"
##
##   Callouts.announce(event_id, player_name := "", is_local := true) -> bool (true = played/queued)
##
## Rules (all numbers live in data/callouts.json):
## - Unknown ids are ignored. Per-event cooldown_s and the GLOBAL cooldown (global_cooldown_s, measured
##   from the start of the last callout of any kind) both apply; events blocked by a cooldown are DROPPED,
##   never queued. Events with bypass_global_cooldown=true skip only the global cooldown.
## - If something is playing: higher priority interrupts it; equal/lower priority waits in a small
##   priority queue (queue_max, expires after queue_max_wait_s).
## - Never the same clip twice in a row for an event (2 variants alternate).
## - Teammate events (is_local=false) use teammate_clips (lighter sting baked in) at teammate_duck_db.
##   Player names cannot be pre-voiced: show them from the callout_played signal in the HUD.
## - Plays on the "Announcer" bus if it exists, else "UI", else Master.
## Networking: the network layer only calls announce() on every peer (see Net.broadcast_callout).

signal callout_played(event_id: String, player_name: String, is_local: bool)
signal callout_dropped(event_id: String, reason: String) ## reason: unknown | event_cooldown | global_cooldown | queue_full | expired | no_clip

const CONFIG_PATH := "res://data/callouts.json"

var config: Dictionary = {}
var events: Dictionary = {}
var global_cooldown_s := 20.0
var teammate_duck_db := -4.0
var queue_max := 2
var queue_max_wait_s := 3.0
var bus_name := "Master"

## Clock: real time by default; tests set manual_time >= 0 and advance it.
var manual_time := -1.0

var current_event := ""
var current_clip := ""
var current_is_local := true
var _current_end := -INF
var _last_any := -INF
var _last_event_time: Dictionary = {} ## event_id -> time last played
var _last_clip: Dictionary = {} ## event_id -> clip last played (local and teammate tracked separately)
var _queue: Array = [] ## [{id, name, local, prio, t}]
var _streams: Dictionary = {} ## path -> AudioStream
var _player: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	_player.name = "AnnouncerPlayer"
	add_child(_player)
	if config.is_empty():
		configure(load_config())
	_rng.randomize()


static func load_config(path: String = CONFIG_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("Callouts: missing %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func configure(cfg: Dictionary) -> void:
	config = cfg
	events = cfg.get("events", {})
	global_cooldown_s = float(cfg.get("global_cooldown_s", 20.0))
	teammate_duck_db = float(cfg.get("teammate_duck_db", -4.0))
	queue_max = int(cfg.get("queue_max", 2))
	queue_max_wait_s = float(cfg.get("queue_max_wait_s", 3.0))
	bus_name = _pick_bus(str(cfg.get("bus", "Announcer")), str(cfg.get("fallback_bus", "UI")))
	if _player:
		_player.bus = bus_name
	reset_state()


func reset_state() -> void:
	current_event = ""
	current_clip = ""
	_current_end = -INF
	_last_any = -INF
	_last_event_time.clear()
	_last_clip.clear()
	_queue.clear()
	if _player:
		_player.stop()


func now() -> float:
	return manual_time if manual_time >= 0.0 else Time.get_ticks_msec() / 1000.0


func is_busy() -> bool:
	return current_event != "" and now() < _current_end


func priority_of(event_id: String) -> int:
	return int(events.get(event_id, {}).get("priority", 0))


## Main entry point. Returns true if the event played now or was queued behind a higher-priority line.
func announce(event_id: String, player_name: String = "", is_local: bool = true) -> bool:
	if not events.has(event_id):
		callout_dropped.emit(event_id, "unknown")
		return false
	var e: Dictionary = events[event_id]
	var t := now()
	if t - float(_last_event_time.get(event_id, -INF)) < float(e.get("cooldown_s", 0.0)):
		callout_dropped.emit(event_id, "event_cooldown")
		return false
	if not bool(e.get("bypass_global_cooldown", false)) and t - _last_any < global_cooldown_s:
		callout_dropped.emit(event_id, "global_cooldown")
		return false
	if is_busy():
		if priority_of(event_id) > priority_of(current_event):
			return _play(event_id, player_name, is_local) # interrupt
		if _queue.size() >= queue_max:
			callout_dropped.emit(event_id, "queue_full")
			return false
		_queue.append({"id": event_id, "name": player_name, "local": is_local, "prio": priority_of(event_id), "t": t})
		_queue.sort_custom(func(a, b): return a.prio > b.prio)
		return true
	return _play(event_id, player_name, is_local)


## Pick a clip for event (never the previous one for that event/side). Exposed for tests.
func pick_clip(event_id: String, is_local: bool) -> String:
	var e: Dictionary = events.get(event_id, {})
	var list: Array = e.get("clips", []) if is_local else e.get("teammate_clips", e.get("clips", []))
	if list.is_empty():
		return ""
	var key := event_id + ("" if is_local else "#tm")
	var prev := str(_last_clip.get(key, ""))
	var options := list.filter(func(c): return str(c) != prev)
	if options.is_empty():
		options = list
	var clip := str(options[_rng.randi() % options.size()])
	_last_clip[key] = clip
	return clip


func clip_path(clip: String) -> String:
	return str(config.get("clip_dir", "res://data/audio/callouts/")) + clip


func volume_for(is_local: bool) -> float:
	return 0.0 if is_local else teammate_duck_db


func _play(event_id: String, player_name: String, is_local: bool) -> bool:
	var clip := pick_clip(event_id, is_local)
	if clip == "":
		callout_dropped.emit(event_id, "no_clip")
		return false
	var stream := _stream(clip_path(clip))
	var t := now()
	var length := stream.get_length() if stream else 2.5
	current_event = event_id
	current_clip = clip
	current_is_local = is_local
	_current_end = t + length
	_last_any = t
	_last_event_time[event_id] = t
	if _player:
		_player.stop()
		_player.stream = stream
		_player.volume_db = volume_for(is_local)
		_player.bus = bus_name
		if stream and _player.is_inside_tree():
			_player.play()
	callout_played.emit(event_id, player_name, is_local)
	return true


func _process(_delta: float) -> void:
	tick()


## Drains the queue when the current line is over (called every frame; tests call it directly).
func tick() -> void:
	if current_event != "" and now() >= _current_end:
		current_event = ""
	if current_event != "" or _queue.is_empty():
		return
	var t := now()
	while not _queue.is_empty():
		var q: Dictionary = _queue.pop_front()
		if t - float(q.t) > queue_max_wait_s:
			callout_dropped.emit(q.id, "expired")
			continue
		var e: Dictionary = events.get(q.id, {})
		if t - float(_last_event_time.get(q.id, -INF)) < float(e.get("cooldown_s", 0.0)):
			callout_dropped.emit(q.id, "event_cooldown")
			continue
		_play(q.id, q.name, q.local)
		return


func _stream(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path)
	elif FileAccess.file_exists(path):
		s = AudioStreamOggVorbis.load_from_file(ProjectSettings.globalize_path(path))
	_streams[path] = s
	return s


func _pick_bus(preferred: String, fallback: String) -> String:
	if AudioServer.get_bus_index(preferred) >= 0:
		return preferred
	if AudioServer.get_bus_index(fallback) >= 0:
		return fallback
	return "Master"
