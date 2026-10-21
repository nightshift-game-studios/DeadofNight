extends SceneTree
## Lobby UI against Netz's REAL Net autoload (Gooey). Two processes on 127.0.0.1:
##   godot --headless --path . -s res://tests/lobby_net_test.gd -- --role=host --port=P   (headless party host "Jason")
##   godot --headless --path . -s res://tests/lobby_net_test.gd -- --role=ui --port=P     (home → lobby UI joins it)
## Runner: /workspace/gooey-ui/coop/run_lobby_net.sh <project>. Without /root/Net (plain fps-starter) it prints SKIP
## and exits 0. Exit code = number of failures. Scratch settings / profile files only.

var _fails := 0
var _passes := 0
var role := "ui"
var port := 7777
var Net: Node
var LAPI


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await process_frame


func wait_until(cond: Callable, secs: float) -> bool:
	var t := 0.0
	while t < secs:
		if cond.call():
			return true
		await create_timer(0.1, true).timeout
		t += 0.1
	return bool(cond.call())


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := Array(OS.get_cmdline_user_args())
	if not args.any(func(a): return str(a).begins_with("--role=")):
		# two-process test: a bare single-process run (suite lists) has no host to join
		print("lobby_net_test: SKIP (two-process; run /workspace/gooey-ui/coop/run_lobby_net.sh <project>)")
		quit(0)
		return
	for a in args:
		if a.begins_with("--role="):
			role = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
	Net = root.get_node_or_null("Net")
	if Net == null:
		print("lobby_net_test: SKIP (no Net autoload in this build)")
		quit(0)
		return
	LAPI = load("res://scripts/ui/lobby_api.gd")
	var NC = load("res://scripts/net/net_config.gd")
	NC.override({"connect_timeout_s": 3.0})
	Net.auto_change_scene = false
	Net.profile_path = "user://net_profile_lobby_net_%s.cfg" % role
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Net.profile_path))
	# Netz cb5e52a keeps the name in Settings.player_name: park Settings on a scratch file first (no real settings.cfg writes)
	var st = root.get_node("Settings")
	st.save_path = "user://settings_lobby_net_%s.cfg" % role
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.save_path))
	st.player_name = ""
	Net.load_profile()
	if role == "host":
		await _host()
	else:
		await _ui()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Net.profile_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.save_path))
	print("lobby_net_test[%s]: %d passed, %d failed" % [role, _passes, _fails])
	quit(_fails)


# ------------------------------------------------------------------ host process (no UI)
func _host() -> void:
	Net.set_local_profile("Jason", "soldier")
	check(Net.host_party(port, false) == OK, "host: party open on %d" % port)
	Net.select_map("arena")
	Net.select_difficulty("hard")
	var got := await wait_until(func(): return Net.get_party().size() >= 2, 40.0)
	check(got, "host: the UI client joined")
	var ready := await wait_until(func():
		for e in Net.get_party():
			if not bool(e.ready):
				return false
		return true, 20.0)
	check(ready, "host: client readied up")
	check(Net.can_start() and Net.start_match(), "host: START")
	var cid := 0
	for e in Net.get_party():
		if int(e.peer_id) != 1:
			cid = int(e.peer_id)
	await create_timer(2.0, true).timeout # client builds its HUD
	# in-match events through Netz's real RPCs (no main.tscn here: NetPlayers' host_tick is idle, so no bleed-out)
	Net.match_players.host_down(cid) # -> _rpc_life(cid, "downed") on every peer
	Net.award_points(1, 1250, "test") # -> points_changed(1, 1250) everywhere
	Net.broadcast_callout("massacre", 1) # -> callout_received + Callouts.announce on every peer
	Net._host_set_hp(1, 60, 100) # what the host's own _hp_tick does on a health change -> teammate_health_changed
	await create_timer(1.0, true).timeout
	Net.match_players._rpc_reviving.rpc(cid, 1, true) # Jason starts reviving the client
	await create_timer(1.5, true).timeout
	Net.match_players._rpc_reviving.rpc(cid, 1, false)
	Net.match_players.downed.erase(cid)
	Net.match_players._rpc_life.rpc(cid, "alive")
	check(cid > 1, "host: drove downed / points / callout / revive for peer %d" % cid)
	await create_timer(3.0, true).timeout # client checks its HUD meanwhile
	Net.leave_party()
	check(true, "host: closed the party")


# ------------------------------------------------------------------ UI process
func _ui() -> void:
	var st = root.get_node("Settings")
	var prog = root.get_node_or_null("Progress")
	if prog and "save_path" in prog:
		prog.save_path = "user://progress_lobby_net_test.cfg"
		prog.armory_unequipped_on_load = []
	check(Net.needs_name_prompt(), "Net profile empty (scratch)")
	check(st._net_validator() != null and st.validate_player_name("Ash$").reason == Net.validate_name("Ash$").reason
		and LAPI.check_name(Net, " Ash   W ") == Net.validate_name(" Ash   W "), "one validator: Settings + LobbyAPI.check_name delegate to NetNames")
	var home = load("res://scripts/ui/home_menu.gd").new()
	home.dry_run = true
	root.add_child(home)
	await frames(4)
	var np = home.name_prompt
	check(np != null and is_instance_valid(np), "first launch prompt shown")
	np.edit.text = "Gooey"
	np.submit()
	await frames(2)
	check(st.player_name == "Gooey" and Net.local_name() == "Gooey" and not Net.needs_name_prompt(), "name saved: Settings.player_name = Net.local_name (one store)")
	st.player_name = ""
	check(home.maybe_prompt_name() == null and st.player_name == "Gooey", "Settings empty + Net has a name → adopted, no second prompt")

	var lobby = home.open_play()
	await frames(2)
	check(lobby.net == Net and not LAPI.is_stub(Net), "lobby bound to Netz's Net")
	check(not lobby.find_child("StubTag", true, false).visible, "no offline-preview tag with the real Net")
	var c: String = LAPI.encode_code("203.0.113.5", 7777)
	var d: Dictionary = Net.decode_join_code(c)
	check(d.ok and d.address == "203.0.113.5" and int(d.port) == 7777, "LobbyAPI codes decode with NetJoinCode (%s)" % c)
	check(load("res://scripts/net/join_code.gd").encode("203.0.113.5", 7777) == c, "identical encoding")

	# own party on another port
	lobby.port_override = port + 1
	lobby.choose_mode("host")
	await frames(2)
	check(int(Net.state) == LAPI.HOSTING_LOBBY and Net.is_host(), "HOST → Net.host_party")
	var code := str(lobby.find_child("JoinCode", true, false).text)
	check(code == Net.make_join_code() and LAPI.decode_code(code).ok, "join code from Net (%s)" % code)
	check(int(LAPI.decode_code(code).port) == port + 1, "code carries the chosen port")
	check(str(lobby.find_child("SlotName", true, false).text) == "GOOEY", "slot 0 = me")
	check(not (lobby.find_child("StartBtn", true, false) as Button).disabled, "alone: START allowed (Net.can_start)")
	var answered := await wait_until(func(): return lobby.upnp_state != "trying", lobby.UPNP_GIVE_UP_S + 3.0)
	check(answered and lobby.upnp_state in ["open", "failed", "cgnat"], "UPnP resolved: %s (%s)" % [lobby.upnp_state, lobby.upnp_message])
	if lobby.upnp_state == "failed":
		check(lobby.find_child("UpnpHelp", true, false).visible, "UPnP failed → help shown")
	lobby.leave_pressed()
	await frames(2)
	check(int(Net.state) == LAPI.OFFLINE and not lobby.notice_visible() and lobby.page == "coop", "LEAVE: offline, no notice, back on HOST / JOIN")
	lobby.port_override = 0

	# join a dead port → API error
	lobby.choose_mode("join")
	lobby.set_join_text("127.0.0.1:%d" % (port + 2))
	check(lobby.connect_pressed(), "CONNECT to a closed port")
	var failed := await wait_until(func(): return not lobby.connecting, 12.0)
	var je := str(lobby.find_child("JoinError", true, false).text)
	check(failed and (je == LAPI.reason_text("timeout") or je == LAPI.reason_text("unreachable")), "connection error shown: %s" % je)
	lobby.set_join_text("GC-ZZZZZ-ZZZZZ")
	check(not lobby.connect_pressed(), "out-of-range code refused before Net")

	# join the host process
	lobby.set_join_text(LAPI.encode_code("127.0.0.1", port))
	check(lobby.connect_pressed(), "CONNECT to the host")
	var joined := await wait_until(func(): return lobby.page == "lobby" and Net.get_party().size() >= 2, 20.0)
	check(joined, "connected → lobby with the host")
	await frames(2)
	var s0 = lobby.find_child("PartySlot_0", true, false)
	var s1 = lobby.find_child("PartySlot_1", true, false)
	check(str(s0.find_child("SlotName", true, false).text) == "JASON" and s0.find_child("LeaderCrown", true, false).visible, "host Jason in slot 0 with crown")
	check(str(s1.find_child("SlotName", true, false).text) == "GOOEY" and s1.find_child("YouTag", true, false) != null, "me in slot 1")
	var ok_ro := await wait_until(func(): return "ARENA" in str(lobby.find_child("MapReadOnly", true, false).text) and "HARD" in str(lobby.find_child("DiffReadOnly", true, false).text), 5.0)
	check(ok_ro, "member read-only map/difficulty from the leader (%s / %s)" % [lobby.find_child("MapReadOnly", true, false).text, lobby.find_child("DiffReadOnly", true, false).text])
	check(not lobby.find_child("StartBtn", true, false).visible and not lobby.find_child("MapPick", true, false).visible, "member: no START / pickers")
	var started := [false]
	Net.match_starting.connect(func(_m, _d): started[0] = true)
	lobby.toggle_ready()
	check(Net.is_ready(), "READY → Net.set_ready")
	var go := await wait_until(func(): return started[0], 15.0)
	check(go and home.last_coop_start.get("map") == "arena" and home.last_coop_start.get("difficulty") == "hard", "match_starting → home got arena / hard")
	check(not lobby.visible and int(Net.state) == LAPI.IN_MATCH, "lobby closed, Net IN_MATCH")
	# in-match HUD bound to the real Net
	var hud = load("res://scripts/hud.gd").new()
	root.add_child(hud)
	await frames(3)
	var coop = hud.coop_hud
	check(coop.net == Net and coop.visible, "co-op HUD visible in a networked match")
	var row = coop.mate_row(1)
	check(row != null and str(row.find_child("MateName", true, false).text) == "JASON" and row.find_child("MateState", true, false) == null, "teammate Jason listed (Netz state '%s' → alive)" % (str(row.get_meta("state")) if row else "?"))
	check(coop.mate_row(Net.local_peer_id()) == null, "local player not in the teammate list")
	var ban = hud.callout_banner
	ban._process(1.1)
	# Netz in-match signals from the host process
	var dn := await wait_until(func(): return coop.local_downed, 6.0)
	check(dn and Net.match_players.life_of(Net.local_peer_id()) == "downed", "Net.match_players.life_changed downed → my bleed-out overlay")
	var NCfg = load("res://scripts/net/net_config.gd")
	check(absf(coop.bleed_total - float(NCfg.get_float("downed.bleed_out_s"))) < 0.01, "bleed-out length = net.json downed.bleed_out_s (%.0f s)" % coop.bleed_total)
	var pts := await wait_until(func(): return _mate_points(coop, 1) == "1250", 4.0)
	check(pts and Net.get_points(1) == 1250, "points_changed → Jason's points in the party strip")
	var hpok := await wait_until(func(): return absf(coop.hp_of(1) - 0.6) < 0.01, 4.0)
	var hf: Node = coop.mate_row(1).find_child("HpFill", true, false) if coop.mate_row(1) else null
	check(hpok and hf != null and absf(hf.size.x - (coop.MATE_BAR - 2.0) * 0.6) < 0.5, "teammate_health_changed 60/100 → Jason's HP bar 60%")
	var cl := await wait_until(func(): return ban.shown_log.has("JASON — MASSACRE"), 4.0)
	check(cl and ban.shown_log.count("JASON — MASSACRE") == 1, "teammate callout via Net.callout_received, shown once (%s, deduped %d)" % [ban.shown_log, ban.deduped])
	var rv := await wait_until(func(): return coop.revive_role == "downed", 4.0)
	check(rv and "JASON IS REVIVING YOU" in str(coop.find_child("ReviveLabel", true, false).text), "revive_changed active → JASON IS REVIVING YOU")
	var up := await wait_until(func(): return not coop.local_downed and coop.revive_role == "", 5.0)
	check(up and Net.match_players.life_of(Net.local_peer_id()) == "alive", "revived (life alive) → overlays cleared")
	var gone := await wait_until(func(): return int(Net.state) == LAPI.OFFLINE, 15.0)
	check(gone and "HOST LEFT" in lobby.last_notice, "host closes → HOST LEFT notice (%s)" % lobby.last_notice)
	await frames(2)
	check(not coop.visible, "offline again → co-op HUD hidden")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(st.save_path))


func _mate_points(coop: Node, peer: int) -> String:
	var row: Node = coop.mate_row(peer)
	var lab: Node = row.find_child("MatePoints", true, false) if row else null
	return str(lab.text) if lab else ""
