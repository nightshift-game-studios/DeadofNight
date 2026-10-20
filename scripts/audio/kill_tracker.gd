extends RefCounted
class_name KillTracker
## Pure-logic kill-streak / rapid-kill detector for ONE player. No nodes, no clock, no audio:
## the caller passes timestamps (seconds) and gets back event ids to announce.
## All thresholds come from data/callouts.json ("events": kind rapid | streak | boss).
##
##   var kt := KillTracker.new(KillTracker.load_config())
##   for ev in kt.register_kill(now_s, is_headshot, is_boss): Callouts.announce(ev, "", true)
##   kt.register_damage_taken()          # breaks the no-damage streak
##
## Rapid tiers (kind "rapid"): a tier fires when >= count kills fall inside the last window_s seconds
## (rolling window, inclusive of the newest kill). Each tier fires once per burst: it re-arms only
## after its own window has emptied (a kill arrives with no other kill inside that tier's window).
## A higher tier in the same burst still fires. Streak tiers (kind "streak"): kills since the last
## damage taken; fires once when the count reaches threshold. Boss (kind "boss"): every boss kill.
## Returned events are sorted by priority, highest first (the player keeps the best one).

const DEFAULT_CONFIG_PATH := "res://data/callouts.json"

var rapid_tiers: Array = [] ## [{id, count, window_s, priority}] sorted by count asc
var streak_tiers: Array = [] ## [{id, threshold, priority}] sorted by threshold asc
var boss_event: String = ""
var priorities: Dictionary = {} ## event_id -> priority
var streak_resets_on_damage := true

var kill_times: Array = [] ## recent kill timestamps (pruned to the largest window)
var streak := 0 ## kills since last damage taken
var total_kills := 0
var headshots := 0
var _armed: Dictionary = {} ## rapid event_id -> bool (false once fired, until its window empties)
var _max_window := 0.0
var _last_time := -INF


static func load_config(path: String = DEFAULT_CONFIG_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("KillTracker: missing %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _init(config: Dictionary = {}) -> void:
	configure(config)


func configure(config: Dictionary) -> void:
	rapid_tiers.clear()
	streak_tiers.clear()
	boss_event = ""
	priorities.clear()
	streak_resets_on_damage = bool(config.get("streak_resets_on_damage", true))
	var events: Dictionary = config.get("events", {})
	for id in events:
		var e: Dictionary = events[id]
		var pr := int(e.get("priority", 0))
		priorities[str(id)] = pr
		match str(e.get("kind", "")):
			"rapid":
				rapid_tiers.append({"id": str(id), "count": int(e.get("count", 0)), "window_s": float(e.get("window_s", 0.0)), "priority": pr})
			"streak":
				streak_tiers.append({"id": str(id), "threshold": int(e.get("threshold", 0)), "priority": pr})
			"boss":
				boss_event = str(id)
	rapid_tiers.sort_custom(func(a, b): return a.count < b.count)
	streak_tiers.sort_custom(func(a, b): return a.threshold < b.threshold)
	_max_window = 0.0
	for t in rapid_tiers:
		_max_window = maxf(_max_window, t.window_s)
	reset()


func reset() -> void:
	kill_times.clear()
	streak = 0
	total_kills = 0
	headshots = 0
	_last_time = -INF
	_armed.clear()
	for t in rapid_tiers:
		_armed[t.id] = true


## Register one kill at time_s (seconds, monotonic). Returns event ids to announce, highest priority first.
func register_kill(time_s: float, is_headshot: bool = false, is_boss: bool = false) -> Array:
	var out: Array = []
	time_s = maxf(time_s, _last_time) # tolerate tiny clock jitter; never go backwards
	_last_time = time_s
	total_kills += 1
	if is_headshot:
		headshots += 1
	# rapid tiers: re-arm a tier whose window was empty before this kill, then count inside the window
	for t in rapid_tiers:
		if count_in_window(time_s, t.window_s) == 0:
			_armed[t.id] = true
	kill_times.append(time_s)
	_prune(time_s)
	for t in rapid_tiers:
		if t.count > 0 and _armed.get(t.id, true) and count_in_window(time_s, t.window_s) >= t.count:
			_armed[t.id] = false
			out.append(t.id)
	# no-damage streak
	streak += 1
	for t in streak_tiers:
		if t.threshold > 0 and streak == t.threshold:
			out.append(t.id)
	if is_boss and boss_event != "":
		out.append(boss_event)
	out.sort_custom(func(a, b): return int(priorities.get(a, 0)) > int(priorities.get(b, 0)))
	return out


## The player took damage: the no-damage streak starts over (rapid-kill bursts are unaffected).
func register_damage_taken() -> void:
	if streak_resets_on_damage:
		streak = 0


## Kills with timestamp t where now - window_s < t <= now.
func count_in_window(now_s: float, window_s: float) -> int:
	var n := 0
	for i in range(kill_times.size() - 1, -1, -1):
		if now_s - float(kill_times[i]) < window_s:
			n += 1
		else:
			break
	return n


func _prune(now_s: float) -> void:
	while not kill_times.is_empty() and now_s - float(kill_times[0]) >= _max_window:
		kill_times.pop_front()
