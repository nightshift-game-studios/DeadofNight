extends SceneTree
## Multi-instance lobby test peer (Netz). One process per peer, using the real /root/Net autoload.
## Run through tests/net/run_lobby.sh. Prints "NETTEST: PASS|FAIL [name] ..." and exits 0 / 1.
## Args (after --): --role=host|client --scenario=lobby|reject --name=N --port=P [--clients=3] [--proto=99]
##   [--expect-fail=reason] [--leave-after=callout|match_started] [--max=2] [--timeout=45]

var role := "client"
var scenario := "lobby"
var pname := "Peer"
var port := 7777
var n_clients := 3
var expect_fail := ""
var leave_after := ""
var timeout_s := 45.0
var Net: Node
var _done := false
var _log: Array = []

# client observations
var seen_names := {}
var max_party := 0
var settings := []
var starting := []
var started := false
var callouts: Array = []
var events: Array = []
var left_names: Array = []
var leader_select_refused := false
# host observations
var rejections: Array = []
var host_left_names: Array = []
var left_reasons: Array = [] ## [name, reason] from peer_left (both sides)
var hp_events: Array = [] ## [peer, hp, max]
var disc_reason := ""
var my_id := 0


class FakeMain:
	## Just what Net's teammate-HP sampler reads (main.player.health / max_health).
	extends Node
	var player: Node


class FakePlayer:
	extends Node
	var health := 100
	var max_health := 100


class FakeDriver:
	## Stand-in for Audi-0's callout_driver: 3 kills by the same peer -> "massacre", routed like the real one.
	extends Node
	var counts := {}
	func on_kill(peer_id: int, _hs := false, _boss := false) -> Array:
		counts[peer_id] = int(counts.get(peer_id, 0)) + 1
		if counts[peer_id] == 3:
			root_net().broadcast_callout("massacre", peer_id)
			return ["massacre"]
		return []
	func on_damage(_p: int) -> void:
		pass
	func remove_peer(p: int) -> void:
		counts.erase(p)
	func root_net() -> Node:
		return get_node("/root/Net")


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var k := a.get_slice("=", 0)
		var v := a.get_slice("=", 1) if a.contains("=") else ""
		match k:
			"--role": role = v
			"--scenario": scenario = v
			"--name": pname = v
			"--port": port = int(v)
			"--clients": n_clients = int(v)
			"--expect-fail": expect_fail = v
			"--leave-after": leave_after = v
			"--timeout": timeout_s = float(v)
			"--max": NetConfig.override({"max_players": int(v)})
			"--proto": pass
			"--peer-timeout-ms": NetConfig.override({"peer_timeout_min_ms": int(v) / 2, "peer_timeout_max_ms": int(v)})
	_run.call_deferred()


func log_line(s: String) -> void:
	print("[%s] %s" % [pname, s])


func finish(ok: bool, msg: String) -> bool:
	if _done:
		return ok
	_done = true
	print("NETTEST: %s [%s] %s" % ["PASS" if ok else "FAIL", pname, msg])
	Net.leave_party()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Net.profile_path))
	quit(0 if ok else 1)
	return ok


func until(cond: Callable, secs: float) -> bool:
	var end := Time.get_ticks_msec() + int(secs * 1000.0)
	while not cond.call():
		if _done or Time.get_ticks_msec() > end:
			return false
		await process_frame
	return true


func sleep(secs: float) -> void:
	await create_timer(secs).timeout


func _run() -> void:
	Engine.max_fps = 60 # headless runs uncapped otherwise
	Net = root.get_node("Net")
	Net.auto_change_scene = false
	Net.profile_path = "user://net_profile_test_%s_%d.cfg" % [pname, port]
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--proto="):
			Net.proto_version_override = int(a.get_slice("=", 1))
	Net.set_local_profile(pname)
	create_timer(timeout_s).timeout.connect(func(): finish(false, "timeout"))
	if role == "host":
		if scenario == "lobby":
			await _host_lobby()
		elif scenario == "ui":
			await _host_ui()
		elif scenario == "crash":
			await _host_crash()
		else:
			await _host_reject()
	else:
		_client()


# ------------------------------------------------------------------ host: lobby scenario
func _host_lobby():
	# Audi-0's real CalloutDriver (one KillTracker per peer, data/callouts.json) when it's in main; else the fake.
	var drv: Node
	if ResourceLoader.exists("res://scripts/audio/callout_driver.gd"):
		drv = load("res://scripts/audio/callout_driver.gd").new()
		drv.name = "CalloutDriver"
		log_line("using the real callout_driver.gd")
	else:
		drv = FakeDriver.new()
	root.add_child(drv)
	Net.set_callout_driver(drv)
	Net.peer_left.connect(func(_id, n, r): host_left_names.append(n); left_reasons.append([n, r]))
	var callout_seen: Array = []
	Net.callout_received.connect(func(e, n, l): callout_seen.append([e, n, l]))
	if Net.host_party(port, false) != OK:
		return finish(false, "host_party failed")
	log_line("hosting on %d, code %s" % [port, Net.make_join_code()])
	if not await until(func(): return Net.party_size() == n_clients + 1, 20.0):
		return finish(false, "only %d/%d joined" % [Net.party_size(), n_clients + 1])
	var names: Array = Net.get_party().map(func(e): return str(e.name))
	log_line("party: %s" % [names])
	var slots: Array = Net.get_party().map(func(e): return int(e.slot))
	slots.sort()
	if slots != range(n_clients + 1):
		return finish(false, "slots not unique: %s" % [slots])
	if not (Net.select_map("rustwell_foundry") and Net.select_difficulty("hard")):
		return finish(false, "leader could not select map/difficulty")
	if not await until(func(): return Net.can_start(), 10.0):
		return finish(false, "clients never all ready")
	if not Net.start_match():
		return finish(false, "start_match refused")
	Net.report_scene_ready()
	if not await until(func(): return Net.is_match_running(), 10.0):
		return finish(false, "match never went (scene_ready)")
	log_line("match running")
	var bob := -1
	for e in Net.get_party():
		if e.name == "Bob":
			bob = int(e.peer_id)
	var n_kills := 3 if drv is FakeDriver else 10 # massacre = 10 kills inside 6 s (data/callouts.json)
	for i in n_kills:
		Net.report_kill(bob, false, false) # host accepted kills by Bob -> driver -> Net.broadcast_callout -> every peer
	Net.broadcast_event(&"test_ping", bob, {"n": 7})
	if not await until(func(): return host_left_names.has("Dan") and Net.party_size() == n_clients, 15.0):
		return finish(false, "Dan's leave not seen (party %d)" % Net.party_size())
	if callout_seen != [["massacre", "Bob", false]]:
		return finish(false, "host callout wrong: %s" % [callout_seen])
	if left_reasons != [["Dan", "left"]]:
		return finish(false, "host: Dan's peer_left reason %s (want left)" % [left_reasons])
	await sleep(1.0)
	finish(true, "4-peer lobby: join, names, slots, leader map+difficulty, ready, start, loaded, callout, event, client leave")


# ------------------------------------------------------------------ host: reject scenario (max 2 players)
func _host_reject():
	NetConfig.override({"lobby.allow_late_join": false}) # Late2 must see in_progress (late join is on by default)
	Net.peer_rejected.connect(func(_id, n, r): rejections.append([n, r]); log_line("rejected %s: %s" % [n, r]))
	Net.peer_left.connect(func(_id, n, _r): host_left_names.append(n))
	if Net.host_party(port, false) != OK:
		return finish(false, "host_party failed")
	if not await until(func(): return Net.party_size() == 2 and rejections.size() >= 2, 20.0):
		return finish(false, "expected Ann joined + 2 rejections, got party %d, %s" % [Net.party_size(), rejections])
	if not await until(func(): return Net.can_start(), 10.0):
		return finish(false, "Ann never ready")
	Net.start_match()
	Net.report_scene_ready()
	if not await until(func(): return Net.is_match_running(), 10.0):
		return finish(false, "match never went")
	if not await until(func(): return host_left_names.has("Ann") and rejections.size() >= 3, 20.0):
		return finish(false, "expected Ann to leave and a 3rd rejection, got %s / %s" % [host_left_names, rejections])
	var want := [["Old", "version_mismatch"], ["Late", "party_full"], ["Late2", "in_progress"]]
	if rejections != want:
		return finish(false, "rejections %s != %s" % [rejections, want])
	await sleep(1.0)
	finish(true, "rejections: version_mismatch, party_full, in_progress")


# ------------------------------------------------------------------ host: crash scenario (client process killed)
func _host_crash():
	var drv := FakeDriver.new()
	root.add_child(drv)
	Net.set_callout_driver(drv)
	Net.peer_left.connect(func(_id, n, r): host_left_names.append([n, r]))
	if Net.host_party(port, false) != OK:
		return finish(false, "host_party failed")
	if not await until(func(): return Net.party_size() == 2, 15.0):
		return finish(false, "Eve never joined")
	var eve := int(Net.get_party()[1].peer_id)
	Net.report_kill(eve)
	print("CRASH_READY") # the runner kill -9s Eve now
	var t0 := Time.get_ticks_msec()
	if not await until(func(): return host_left_names.size() == 1, 20.0):
		return finish(false, "crashed client never timed out")
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	if host_left_names[0] != ["Eve", "lost"] or Net.party_size() != 1 or drv.counts.has(eve):
		return finish(false, "bad cleanup %s party %d driver %s" % [host_left_names, Net.party_size(), drv.counts])
	finish(true, "crashed client dropped after %.1fs: peer_left, party cleaned, callout_driver.remove_peer" % secs)


# ------------------------------------------------------------------ client
func _client() -> void:
	Net.connection_failed.connect(func(r):
		if expect_fail != "":
			finish(r == expect_fail, "join refused: %s (expected %s)" % [r, expect_fail])
		else:
			finish(false, "connection_failed: " + r))
	Net.connected_to_party.connect(func():
		if expect_fail != "":
			return finish(false, "joined but expected '%s'" % expect_fail)
		leader_select_refused = not Net.select_map("arena") and not Net.select_difficulty("easy") and not Net.start_match()
		if scenario != "ui": # ui: the host first checks start_block_reason("not_ready")
			Net.set_ready(true))
	Net.party_changed.connect(func(p):
		max_party = maxi(max_party, p.size())
		for e in p:
			seen_names[str(e.name)] = true)
	Net.lobby_settings_changed.connect(func(m, d): settings = [m, d])
	Net.match_starting.connect(func(m, d):
		starting = [m, d]
		Net.report_scene_ready())
	Net.match_started.connect(func():
		started = true
		if leave_after == "match_started":
			_leave_soon("match_started"))
	Net.callout_received.connect(func(e, n, l):
		callouts.append([e, n, l])
		_maybe_leave())
	Net.game_event.connect(func(e, p, d):
		events.append([str(e), p, d, Net.get_player_name(p)])
		_maybe_leave())
	Net.peer_left.connect(func(_id, n, r): left_names.append(n); left_reasons.append([n, r]))
	Net.host_left.connect(_on_host_left)
	if scenario == "ui":
		_client_ui_setup()
	var err: int = Net.join_by_address("127.0.0.1:%d" % port)
	if err != OK:
		finish(false, "join_by_address error %d" % err)


func _maybe_leave() -> void:
	if leave_after == "callout" and callouts.size() >= 1 and events.size() >= 1:
		var ok := _lobby_checks()
		_leave_soon("callout" if ok == "" else "")
		if ok != "":
			finish(false, ok)


func _leave_soon(what: String) -> void:
	await sleep(0.3)
	if _done:
		return
	_done = true
	Net.leave_party()
	print("NETTEST: PASS [%s] left after %s" % [pname, what])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Net.profile_path))
	quit(0)


func _lobby_checks() -> String:
	if scenario != "lobby":
		return ""
	if max_party != n_clients + 1:
		return "max party %d" % max_party
	for n in ["Alice", "Bob", "Cara", "Dan"]:
		if not seen_names.has(n):
			return "never saw %s (%s)" % [n, seen_names.keys()]
	if not leader_select_refused:
		return "non-leader could change lobby settings"
	if settings != ["rustwell_foundry", "hard"] or starting != ["rustwell_foundry", "hard"]:
		return "settings %s / start %s" % [settings, starting]
	if not started:
		return "match_started not seen"
	if pname != "Dan" and left_reasons.size() > 0 and left_reasons[0] != ["Dan", "left"]:
		return "client peer_left reason %s (want Dan/left)" % [left_reasons]
	if callouts.size() != 1 or callouts[0][0] != "massacre" or callouts[0][1] != "Bob" or callouts[0][2] != (pname == "Bob"):
		return "callout %s" % [callouts]
	if events.size() != 1 or events[0][0] != "test_ping" or int(events[0][2].get("n", 0)) != 7 or events[0][3] != "Bob":
		return "event %s" % [events]
	return ""


func _on_host_left() -> void:
	if scenario == "ui":
		var e := _client_ui_checks()
		finish(e == "", "ui: kick reason, teammate hp, lobby reset" if e == "" else e)
		return
	if scenario == "lobby":
		var e := _lobby_checks()
		if e == "" and not left_names.has("Dan"):
			e = "Dan's leave not seen (%s)" % [left_names]
		finish(e == "", "host_left received; " + ("all lobby checks ok" if e == "" else e))
	else:
		finish(false, "unexpected host_left")


# ------------------------------------------------------------------ ui scenario (Gooey's NETZ_GAPS decisions)
func _host_ui():
	Net.peer_left.connect(func(_id, n, r): left_reasons.append([n, r]))
	Net.teammate_health_changed.connect(func(p, h, m, f): hp_events.append([p, h, m, f]))
	if Net.host_party(port, false) != OK:
		return finish(false, "host_party failed")
	if not await until(func(): return Net.party_size() == 3, 20.0):
		return finish(false, "only %d/3 joined" % Net.party_size())
	var ids := {}
	for e in Net.get_party():
		ids[str(e.name)] = int(e.peer_id)
	var nr: Array = Net.not_ready_names()
	nr.sort()
	if Net.start_block_reason() != "not_ready" or nr != ["Bob", "Cara"] or Net.can_start():
		return finish(false, "start_block_reason %s / not ready %s" % [Net.start_block_reason(), nr])
	Net.broadcast_event(&"t_ready", 0, {})
	if not await until(func(): return Net.start_block_reason() == "", 10.0):
		return finish(false, "start still blocked: %s" % Net.start_block_reason())
	if not Net.kick(ids.Cara, "afk") or Net.kick(1):
		return finish(false, "kick() return values")
	if not await until(func(): return left_reasons == [["Cara", "afk"]] and Net.party_size() == 2, 10.0):
		return finish(false, "kick: host peer_left %s, party %d" % [left_reasons, Net.party_size()])
	if not Net.start_match():
		return finish(false, "start_match refused")
	Net.report_scene_ready()
	if not await until(func(): return Net.is_match_running(), 10.0):
		return finish(false, "match never went")
	var fm := FakeMain.new()
	fm.player = FakePlayer.new()
	fm.add_child(fm.player)
	root.add_child(fm)
	Net._match = fm
	if not await until(func(): return hp_events.size() >= 2 and int(hp_events[-1][0]) == ids.Bob and int(hp_events[-1][1]) == 60, 8.0):
		return finish(false, "host: Bob's hp never reached 60: %s" % [hp_events])
	await sleep(0.5)
	var bob_ev := hp_events.filter(func(x): return int(x[0]) == ids.Bob)
	var e_bob: Dictionary = Net.get_party().filter(func(e): return int(e.peer_id) == ids.Bob)[0]
	if bob_ev.size() > 9 or int(e_bob.get("hp", -1)) != 60 or int(e_bob.get("max_hp", -1)) != 100 or not is_equal_approx(float(e_bob.get("hp_frac", -1.0)), 0.6):
		return finish(false, "host: hp throttle / entry: %d events, entry %s" % [bob_ev.size(), e_bob])
	if hp_events.filter(func(x): return int(x[0]) == 1).is_empty():
		return finish(false, "host: no teammate_health_changed for its own player")
	if hp_events.any(func(x): return not is_equal_approx(float(x[3]), float(x[1]) / float(x[2]))):
		return finish(false, "host: hp_frac != hp / max_hp in %s" % [hp_events])
	log_line("Bob hp events: %s" % [bob_ev])
	Net._match = null
	fm.queue_free()
	Net.return_to_lobby()
	await sleep(0.5)
	if Net.get_party().any(func(e): return e.has("hp") or e.has("max_hp") or e.has("hp_frac")):
		return finish(false, "hp keys still in lobby entries")
	await sleep(1.5)
	finish(true, "ui: start_block_reason, not_ready_names, kick(reason), peer_left reasons, teammate hp (throttled), lobby reset")


var _ui_fm: Node = null


func _client_ui_setup() -> void:
	Net.disconnected.connect(func(r):
		disc_reason = r
		if pname == "Cara":
			finish(r == "afk" and Net.state == Net.State.OFFLINE, "kicked: disconnected(%s)" % r))
	Net.teammate_health_changed.connect(func(p, h, m, f): hp_events.append([p, h, m, f]))
	Net.game_event.connect(func(e, _p, _d):
		if str(e) == "t_ready":
			Net.set_ready(true))
	Net.connected_to_party.connect(func(): my_id = Net.local_peer_id())
	Net.match_started.connect(func():
		if pname == "Bob":
			_bob_hp_drop())


func _bob_hp_drop() -> void:
	_ui_fm = FakeMain.new()
	_ui_fm.player = FakePlayer.new()
	_ui_fm.add_child(_ui_fm.player)
	root.add_child(_ui_fm)
	Net._match = _ui_fm
	await sleep(0.3)
	for i in 40: # a change every frame: Net must throttle to ~5 Hz
		_ui_fm.player.health -= 1
		await process_frame
	Net.returned_to_lobby.connect(func(): Net._match = null)


func _client_ui_checks() -> String:
	if pname != "Bob":
		return "unexpected host_left on %s" % pname
	if left_reasons != [["Cara", "afk"]]:
		return "Bob: peer_left %s (want Cara/afk)" % [left_reasons]
	var host_ev := hp_events.filter(func(x): return int(x[0]) == 1)
	var mine := hp_events.filter(func(x): return int(x[0]) == my_id)
	if host_ev.is_empty() or int(host_ev[-1][1]) != 100 or mine.is_empty() or int(mine[-1][1]) != 60 or not is_equal_approx(float(mine[-1][3]), 0.6):
		return "Bob: teammate hp events %s" % [hp_events]
	return ""
