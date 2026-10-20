extends SceneTree
## Announcer callouts: data/callouts.json, KillTracker (rolling-window rapid tiers, no-damage streaks,
## boss), Callouts player (global/per-event cooldown + bypass, priority interrupt + queue, no repeat,
## teammate duck/clips, bus) and CalloutDriver routing (solo vs Net, host authority, GameEvents hookup).
##   godot --headless --path . -s res://tests/callout_test.gd   (exit code = failures)
## Never writes settings or saves.

const KT := preload("res://scripts/audio/kill_tracker.gd")
const CP := preload("res://scripts/audio/callout_player.gd")
const CD := preload("res://scripts/audio/callout_driver.gd")
const EXPECTED_EVENTS := ["massacre", "slaughterhouse", "annihilation", "boss_kill", "streak_100", "streak_250", "streak_500"]

var _fails := 0
var _passes := 0
var cfg: Dictionary


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	cfg = KT.load_config()
	_test_json()
	_test_rapid_tiers()
	_test_streaks_and_boss()
	_test_json_drives_behavior()
	await _test_player()
	await _test_driver()
	print("callout_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


# ------------------------------------------------------------------ helpers
func cfg_copy() -> Dictionary:
	return cfg.duplicate(true)


## n kills spaced `dt` apart from t0; returns {kill_index(1-based): [events]} for kills that produced events.
func run_kills(kt, n: int, dt: float, t0: float = 0.0, headshot := false) -> Dictionary:
	var out := {}
	for i in n:
		var evs: Array = kt.register_kill(t0 + i * dt, headshot, false)
		if not evs.is_empty():
			out[i + 1] = evs
	return out


func fired(res: Dictionary, ev: String) -> Array:
	var at := []
	for k in res:
		if ev in res[k]:
			at.append(k)
	at.sort()
	return at


# ------------------------------------------------------------------ json
func _test_json() -> void:
	check(not cfg.is_empty(), "data/callouts.json parses")
	var evs: Dictionary = cfg.get("events", {})
	var ids := evs.keys()
	ids.sort()
	var exp := EXPECTED_EVENTS.duplicate()
	exp.sort()
	check(ids == exp, "event ids are exactly %s (got %s)" % [exp, ids])
	check(float(cfg.get("global_cooldown_s", -1)) == 20.0, "global_cooldown_s = 20")
	check(float(cfg.get("teammate_duck_db", 0)) == -4.0, "teammate_duck_db = -4")
	check(evs.massacre.count == 10 and evs.massacre.window_s == 6.0, "massacre = 10 kills / 6 s")
	check(evs.slaughterhouse.count == 20 and evs.slaughterhouse.window_s == 12.0, "slaughterhouse = 20 kills / 12 s")
	check(evs.annihilation.count == 35 and evs.annihilation.window_s == 18.0, "annihilation = 35 kills / 18 s")
	check(evs.streak_100.threshold == 100 and evs.streak_250.threshold == 250 and evs.streak_500.threshold == 500, "streak thresholds 100/250/500")
	check(evs.annihilation.bypass_global_cooldown and evs.streak_500.bypass_global_cooldown and evs.boss_kill.bypass_global_cooldown
		and not evs.massacre.bypass_global_cooldown and not evs.streak_100.bypass_global_cooldown, "bypass flags: annihilation, streak_500, boss_kill only")
	check(evs.streak_100.priority > evs.annihilation.priority and evs.annihilation.priority > evs.slaughterhouse.priority
		and evs.slaughterhouse.priority > evs.massacre.priority and evs.streak_500.priority > evs.streak_250.priority
		and evs.streak_250.priority > evs.streak_100.priority, "priority: streaks > rapid tiers, higher tier > lower")
	var dir := str(cfg.get("clip_dir", ""))
	var all_ok := true
	var n := 0
	var cp = CP.new()
	cp.configure(cfg)
	for id in evs:
		var e: Dictionary = evs[id]
		check((e.get("clips", []) as Array).size() >= 2 and (e.get("teammate_clips", []) as Array).size() >= 2, "%s has 2+ clips and 2+ teammate_clips" % id)
		for c in e.clips + e.teammate_clips:
			n += 1
			var p: String = dir + str(c)
			var s = cp._stream(p)
			if not FileAccess.file_exists(p) or not (s is AudioStreamOggVorbis) or s.get_length() < 0.8:
				all_ok = false
				print("   missing/bad clip ", p)
	cp.free()
	check(all_ok and n == 28, "every referenced clip exists and loads as OGG (%d clips)" % n)


# ------------------------------------------------------------------ rapid tiers
func _test_rapid_tiers() -> void:
	# 2 kills/s for 40 kills: massacre at kill 10 (t=4.5), slaughterhouse at 20 (t=9.5), annihilation at 35 (t=17.0)
	var kt = KT.new(cfg)
	var r := run_kills(kt, 40, 0.5)
	check(fired(r, "massacre") == [10], "massacre fires once at kill 10 of a 2/s burst (got %s)" % [fired(r, "massacre")])
	check(fired(r, "slaughterhouse") == [20], "slaughterhouse fires once at kill 20 (got %s)" % [fired(r, "slaughterhouse")])
	check(fired(r, "annihilation") == [35], "annihilation fires once at kill 35 (got %s)" % [fired(r, "annihilation")])
	# exact window edge: 10 kills spread over 5.99 s fire, over 6.0 s (first kill drops out) do not
	kt = KT.new(cfg)
	check(fired(run_kills(kt, 10, 5.99 / 9.0), "massacre") == [10], "10 kills inside 5.99 s -> massacre")
	kt = KT.new(cfg)
	check(fired(run_kills(kt, 10, 6.0 / 9.0), "massacre").is_empty(), "10 kills spanning exactly 6.0 s -> no massacre (rolling window)")
	# steady 0.7 s spacing never has 10 kills inside 6 s
	kt = KT.new(cfg)
	check(fired(run_kills(kt, 60, 0.7), "massacre").is_empty(), "60 kills at 0.7 s spacing never reach 10-in-6 s")
	# once per burst: keep killing at 1/s after the burst (window never empties) -> no refire
	kt = KT.new(cfg)
	var a := run_kills(kt, 10, 0.3)
	var b := run_kills(kt, 30, 1.0, 3.0)
	check(fired(a, "massacre") == [10] and fired(b, "massacre").is_empty(), "no massacre refire while the burst continues")
	# re-arm after the window empties, then a new burst fires again
	var c := run_kills(kt, 10, 0.3, 3.0 + 29.0 + 7.0)
	check(fired(c, "massacre") == [10], "massacre re-arms after a >6 s gap and fires on the next burst")
	# priority ordering of simultaneous events: a boss kill that also completes massacre
	kt = KT.new(cfg)
	run_kills(kt, 9, 0.2)
	var evs: Array = kt.register_kill(2.0, false, true)
	check(evs == ["boss_kill", "massacre"], "same-kill events sorted by priority (got %s)" % [evs])


# ------------------------------------------------------------------ streaks + boss
func _test_streaks_and_boss() -> void:
	var kt = KT.new(cfg)
	var r := run_kills(kt, 520, 10.0) # 10 s apart: no rapid tiers interfere
	check(fired(r, "streak_100") == [100] and fired(r, "streak_250") == [250] and fired(r, "streak_500") == [500],
		"no-damage streak fires at 100 / 250 / 500")
	check(fired(r, "massacre").is_empty(), "spaced kills trigger no rapid tier")
	kt = KT.new(cfg)
	run_kills(kt, 99, 10.0)
	kt.register_damage_taken()
	check(kt.streak == 0, "damage resets the streak to 0")
	var r2 := run_kills(kt, 100, 10.0, 2000.0)
	check(fired(r2, "streak_100") == [100], "after damage, streak_100 needs a fresh 100 kills (fires at kill 100 of the new run)")
	kt.register_damage_taken()
	var r3 := run_kills(kt, 260, 10.0, 5000.0)
	check(fired(r3, "streak_100") == [100] and fired(r3, "streak_250") == [250], "streak tiers fire again after reset")
	kt = KT.new(cfg)
	check(kt.register_kill(0.0, false, true) == ["boss_kill"], "boss kill -> boss_kill")
	check(kt.register_kill(30.0, true, false).is_empty(), "plain headshot kill -> nothing (headshot streak dropped)")


func _test_json_drives_behavior() -> void:
	var c := cfg_copy()
	c.events.massacre.count = 3
	c.events.massacre.window_s = 2.0
	c.events.streak_100.threshold = 5
	var kt = KT.new(c)
	var r := run_kills(kt, 3, 0.5)
	check(fired(r, "massacre") == [3], "json count/window change massacre to 3 kills / 2 s")
	kt = KT.new(c)
	check(fired(run_kills(kt, 3, 1.0), "massacre").is_empty(), "3 kills spanning 2.0 s with window_s 2 -> nothing")
	kt = KT.new(c)
	check(fired(run_kills(kt, 6, 10.0), "streak_100") == [5], "json streak threshold 5 -> streak_100 at kill 5")
	c.streak_resets_on_damage = false
	kt = KT.new(c)
	run_kills(kt, 3, 10.0)
	kt.register_damage_taken()
	check(kt.streak == 3, "streak_resets_on_damage=false keeps the streak")
	var cp = CP.new()
	var c2 := cfg_copy()
	c2.global_cooldown_s = 2.0
	cp.configure(c2)
	cp.manual_time = 100.0
	cp.announce("massacre")
	cp.manual_time = 103.0
	cp.tick()
	check(cp.announce("streak_100"), "json global_cooldown_s 2 lets a second callout through after 3 s")
	cp.free()


# ------------------------------------------------------------------ player
func _test_player() -> void:
	var cp = CP.new()
	cp.name = "CalloutsUnderTest"
	cp.configure(cfg)
	root.add_child(cp)
	await process_frame
	var played: Array = []
	var dropped: Array = []
	cp.callout_played.connect(func(e, n, l): played.append([e, n, l]))
	cp.callout_dropped.connect(func(e, why): dropped.append([e, why]))
	check(cp.bus_name in ["Announcer", "UI"], "plays on Announcer or UI bus (got %s)" % cp.bus_name)

	# ---- global cooldown + bypass
	cp.manual_time = 1000.0
	check(cp.announce("massacre") and cp.current_event == "massacre", "first callout plays")
	cp.manual_time = 1005.0
	cp.tick()
	check(not cp.announce("streak_100") and dropped.back() == ["streak_100", "global_cooldown"], "non-bypass event 5 s later is dropped by the 20 s global cooldown")
	cp.manual_time = 1006.0
	cp.tick()
	check(cp.announce("boss_kill") and cp.current_event == "boss_kill", "boss_kill bypasses the global cooldown")
	cp.manual_time = 1012.0
	cp.tick()
	check(cp.announce("annihilation"), "annihilation bypasses the global cooldown")
	cp.manual_time = 1019.0
	cp.tick()
	check(not cp.announce("slaughterhouse"), "slaughterhouse still blocked by the global cooldown (7 s after last)")
	cp.manual_time = 1040.0
	cp.tick()
	check(cp.announce("slaughterhouse"), "after 20 s idle a non-bypass event plays")
	check(cp._queue.is_empty(), "dropped events were never queued")

	# ---- per-event cooldown (global cooldown off to isolate)
	var c := cfg_copy()
	c.global_cooldown_s = 0.0
	cp.configure(c)
	played.clear()
	cp.manual_time = 2000.0
	cp.announce("massacre")
	cp.manual_time = 2010.0
	cp.tick()
	check(not cp.announce("massacre") and dropped.back() == ["massacre", "event_cooldown"], "massacre within its 30 s cooldown is dropped")
	cp.manual_time = 2031.0
	cp.tick()
	check(cp.announce("massacre"), "massacre plays again after its cooldown")

	# ---- priority: interrupt and queue
	cp.configure(c)
	cp.manual_time = 3000.0
	cp.announce("massacre") # prio 10
	cp.manual_time = 3000.5
	check(cp.announce("streak_100") and cp.current_event == "streak_100", "higher priority (streak_100) interrupts massacre")
	cp.manual_time = 3001.0
	check(cp.announce("slaughterhouse") and cp.current_event == "streak_100" and cp._queue.size() == 1, "lower priority waits in the queue")
	cp.manual_time = 3001.2
	check(cp.announce("annihilation") and cp._queue[0].id == "annihilation", "queue is ordered by priority")
	cp.manual_time = 3001.3
	check(not cp.announce("boss_kill") or cp._queue.size() <= cp.queue_max, "queue never exceeds queue_max")
	cp.manual_time = cp._current_end + 0.01
	cp.tick()
	check(cp.current_event == "annihilation", "when the line ends the best queued event plays")
	cp.manual_time = cp._current_end + 10.0
	cp.tick()
	check(cp.current_event == "" and dropped.back()[1] == "expired", "stale queued events expire instead of playing late")
	cp.manual_time = 3100.0
	cp.announce("streak_250")
	cp.manual_time = 3100.2
	check(cp.announce("streak_500") and cp.current_event == "streak_500", "streak_500 interrupts streak_250 (higher tier)")

	# ---- no immediate repeat
	var c3 := cfg_copy()
	c3.global_cooldown_s = 0.0
	for id in c3.events:
		c3.events[id].cooldown_s = 0.0
	cp.configure(c3)
	var prev := ""
	var repeats := 0
	var seen := {}
	for i in 30:
		cp.manual_time = 4000.0 + i * 10.0
		cp.tick()
		cp.announce("massacre")
		if cp.current_clip == prev:
			repeats += 1
		prev = cp.current_clip
		seen[prev] = true
	check(repeats == 0 and seen.size() == 2, "30 massacres: never the same clip twice in a row, both variants used")
	# a different event in between doesn't break per-event alternation
	cp.manual_time = 5000.0
	cp.announce("massacre")
	var m1: String = cp.current_clip
	cp.manual_time = 5010.0
	cp.tick()
	cp.announce("boss_kill")
	cp.manual_time = 5020.0
	cp.tick()
	cp.announce("massacre")
	check(cp.current_clip != m1, "per-event no-repeat survives other events in between")

	# ---- teammate duck + sting selection
	played.clear()
	cp.manual_time = 6000.0
	cp.tick()
	cp.announce("streak_100", "Netz", false)
	check(cp.current_clip.contains("_tm_") and str(c3.events.streak_100.teammate_clips).contains(cp.current_clip), "teammate event uses a teammate clip (teammate sting)")
	check(is_equal_approx(cp._player.volume_db, -4.0), "teammate event ducked to teammate_duck_db (-4 dB)")
	check(played.back() == ["streak_100", "Netz", false], "callout_played carries event, player name, is_local=false")
	cp.manual_time = 6010.0
	cp.tick()
	cp.announce("streak_100", "", true)
	check(not cp.current_clip.contains("_tm_") and is_equal_approx(cp._player.volume_db, 0.0), "local event uses the main clip at 0 dB")
	check(cp._player.stream is AudioStreamOggVorbis, "stream assigned to the AudioStreamPlayer")
	check(not cp.announce("double_kill") and dropped.back() == ["double_kill", "unknown"], "dropped events (double_kill) are unknown ids")
	cp.queue_free()
	await process_frame


# ------------------------------------------------------------------ driver
func _test_driver() -> void:
	# The real Callouts autoload (project.godot) owns /root/Callouts: park it so the driver finds the test instance.
	var real_callouts = root.get_node_or_null("Callouts")
	if real_callouts:
		real_callouts.name = "CalloutsAutoloadParked"
	var callouts = CP.new()
	callouts.name = "Callouts"
	callouts.configure(cfg)
	root.add_child(callouts)
	callouts.manual_time = 10000.0
	var played: Array = []
	callouts.callout_played.connect(func(e, n, l): played.append([e, n, l]))
	var drv = CD.new()
	drv.config = cfg
	drv.manual_time = 0.0
	root.add_child(drv)
	await process_frame
	check(drv.is_authority() and drv.local_peer_id() == 1, "no Net autoload: solo authority, peer 1")
	for i in 10:
		drv.on_kill(1, false, false, i * 0.4)
	check(played.size() == 1 and played[0] == ["massacre", "", true], "solo: tracker -> Callouts.announce(event, \"\", true)")

	# GameEvents hookup: kills/damage of the bound player only, duplicate kill reports counted once
	var ge = root.get_node_or_null("GameEvents")
	check(ge != null, "GameEvents autoload present")
	if ge:
		var p := Node.new()
		root.add_child(p)
		drv.trackers.clear()
		drv.bind_local_player(p)
		var z := Node.new()
		root.add_child(z)
		ge.emit_event(&"enemy_killed", {"player": p, "target": z, "is_headshot": true})
		ge.emit_event(&"enemy_killed", {"player": p, "target": z, "is_headshot": true})
		var other_p := Node.new()
		var other_z := Node.new()
		ge.emit_event(&"enemy_killed", {"player": other_p, "target": other_z})
		other_p.free()
		other_z.free()
		check(drv.tracker(1).total_kills == 1, "enemy_killed for the bound player counted once per target")
		var boss := Node.new()
		boss.set_meta("is_boss", true)
		root.add_child(boss)
		played.clear()
		callouts.manual_time = 20000.0
		ge.emit_event(&"enemy_killed", {"player": p, "target": boss})
		check(played.size() == 1 and played[0][0] == "boss_kill", "boss meta -> boss_kill callout")
		ge.emit_event(&"damage_taken", {"player": p, "dealt": 0, "absorbed": 0})
		check(drv.tracker(1).streak == 2, "zero damage does not reset the streak")
		ge.emit_event(&"damage_taken", {"player": p, "dealt": 7, "absorbed": 0})
		check(drv.tracker(1).streak == 0, "damage_taken resets the streak")
		for n in [p, z, boss]:
			n.queue_free()

	# Net present: host routes through Net.broadcast_callout; clients do not detect
	var net_src := GDScript.new()
	net_src.source_code = """extends Node
var calls: Array = []
var host := true
func is_networked() -> bool: return true
func is_host() -> bool: return host
func local_peer_id() -> int: return 7
func get_player_name(id: int) -> String: return "P%d" % id
func broadcast_callout(event_id: String, peer_id: int) -> void: calls.append([event_id, peer_id])
"""
	net_src.reload()
	var net = net_src.new()
	net.name = "Net"
	root.add_child(net)
	await process_frame
	drv.trackers.clear()
	played.clear()
	for i in 10:
		drv.on_kill(3, false, false, 100.0 + i * 0.4)
	check(net.calls == [["massacre", 3]] and played.is_empty(), "host: events go to Net.broadcast_callout(event, peer_id), not straight to Callouts")
	check(drv.trackers.has(3) and not drv.trackers.has(1), "one KillTracker per peer_id")
	check(drv.local_peer_id() == 7, "local peer id comes from Net")
	net.host = false
	net.calls.clear()
	for i in 12:
		drv.on_kill(4, false, false, 300.0 + i * 0.1)
	check(net.calls.is_empty() and not drv.trackers.has(4), "client: no local detection (host-authoritative)")
	net.queue_free()
	drv.queue_free()
	root.remove_child(callouts)
	callouts.queue_free()
	if real_callouts:
		real_callouts.name = "Callouts"
	await process_frame
