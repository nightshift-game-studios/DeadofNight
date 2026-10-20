extends SceneTree
## Net autoload unit suite (Netz): config + fallbacks, join codes, address parsing, IP classes / double-NAT,
## solo helpers (offline peer), profile name, lobby rules in solo, broadcasts in solo, callout driver seam,
## difficulty override, co-op scaling, transport host/close, host-only party basics.
##   godot --headless --path . -s res://tests/net_test.gd   (exit code = failures)

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


class FakeDriver:
	extends Node
	var kills: Array = []
	var damages: Array = []
	var removed: Array = []
	func on_kill(peer_id: int, hs: bool = false, boss: bool = false) -> Array:
		kills.append([peer_id, hs, boss])
		return ["massacre"] if kills.size() == 3 else []
	func on_damage(peer_id: int) -> void:
		damages.append(peer_id)
	func remove_peer(peer_id: int) -> void:
		removed.append(peer_id)


class FakeCallouts:
	extends Node
	var got: Array = []
	func announce(event_id: String, player_name: String, is_local: bool) -> bool:
		got.append([event_id, player_name, is_local])
		return true


func _run() -> void:
	# Once Gooey's Settings (player_name) is merged, Net would use it as the name store: park it so this suite's
	# net_profile.cfg cases see the fallback store (the Settings path is covered with a stub in net_ui_api_test).
	var parked_settings = root.get_node_or_null("Settings")
	if parked_settings and "player_name" in parked_settings:
		parked_settings.name = "SettingsParkedForNetTest"
		await process_frame
	else:
		parked_settings = null
	var Net = root.get_node("Net")
	var NC = load("res://scripts/net/net_config.gd")
	var JC = load("res://scripts/net/join_code.gd")
	var UP = load("res://scripts/net/upnp_helper.gd")
	var D = load("res://scripts/world/difficulty.gd")
	var prof := "user://net_profile_net_test.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))
	Net.profile_path = prof
	Net.load_profile()

	# ------------------------------------------------------------ config
	NC.reload()
	check(NC.get_int("default_port") == 7777 and NC.get_int("max_players") == 4, "net.json: port 7777, max 4 players")
	check(NC.get_float("downed.bleed_out_s") == 30.0 and NC.get_float("downed.revive_time_s") == 3.0 and NC.get_bool("downed.enabled"),
		"downed + revive on, bleed-out 30 s, revive 3 s")
	check(NC.get_float("scaling.per_extra_player") == 0.5 and NC.get_int("scaling.max_alive_cap") == 24, "scaling +50%/extra player, cap 24")
	check(NC.get_bool("points.host_authoritative") and NC.get_bool("drops.shared_world_drops") and NC.get_bool("drops.powerups_team_wide"),
		"host-authoritative points, shared drops, team-wide power-ups")
	var prog = root.get_node("Progress")
	check(NC.points("per_hit") == int(prog.points_per_hit) and NC.points("kill_bonus") == int(prog.points_per_kill) and NC.points("revive") == 100,
		"co-op point values: per-hit / kill bonus = solo economy (%d / %d), revive 100" % [prog.points_per_hit, prog.points_per_kill])
	check(NC.get_value("no.such.key", 42) == 42 and NC.get_value("lobby.allow_late_join") == false, "missing keys fall back (arg, then DEFAULTS)")
	NC.override({"downed.bleed_out_s": 5.0})
	check(NC.get_float("downed.bleed_out_s") == 5.0, "override() for tests")
	NC.reload()
	check(NC.get_float("downed.bleed_out_s") == 30.0, "reload() clears overrides")
	for k in NC.DEFAULTS:
		if not (k in NC.data()):
			check(false, "net.json has every DEFAULTS key (missing %s)" % k)
	check(NC.scaling(1, 16).max_alive == 16 and is_equal_approx(NC.scaling(1, 16).count_mult, 1.0), "1 player: no scaling")
	check(NC.scaling(2, 16).max_alive == 24 and is_equal_approx(NC.scaling(2, 16).count_mult, 1.5), "2 players: x1.5, max_alive 24")
	check(NC.scaling(4, 16).max_alive == 24 and is_equal_approx(NC.scaling(4, 16).count_mult, 2.5), "4 players: x2.5, max_alive capped at 24")
	check(NC.scaling(4, 30).max_alive == 30, "cap never lowers a profile that is already above it (Hard max_alive_add)")

	# ------------------------------------------------------------ join codes / addresses
	var code: String = JC.encode("203.0.113.5", 7777)
	check(code.begins_with("GC-") and code.length() == 14, "join code format GC-XXXXX-XXXXX (%s)" % code)
	var d: Dictionary = JC.decode(code)
	check(d.ok and d.address == "203.0.113.5" and d.port == 7777 and d.kind == "direct", "decode(encode(ip, port)) round trip")
	var rt := true
	for ip in ["0.0.0.1", "255.255.255.255", "192.168.1.20", "8.8.8.8", "100.64.3.4"]:
		for p in [1, 7777, 65535]:
			var dd: Dictionary = JC.decode(JC.encode(ip, p))
			rt = rt and dd.ok and dd.address == ip and dd.port == p
	check(rt, "round trip over edge IPs and ports")
	var sloppy := code.to_lower().replace("-", " ").replace("dn", "")
	check(JC.decode(sloppy).ok and JC.decode(sloppy).address == "203.0.113.5", "decode forgives case, spaces, missing prefix ('%s')" % sloppy)
	check(not JC.decode("GC-12345").ok and not JC.decode("DN-UUUUU-UUUUU").ok and not JC.decode("").ok, "bad length / bad chars rejected")
	var legacy: Dictionary = JC.decode("DN-" + code.substr(3))
	check(legacy.ok and legacy.address == "203.0.113.5" and legacy.port == 7777, "legacy DN- codes (pre-Gravecrew) still decode")
	check(JC.encode("1.2.3", 7777) == "" and JC.encode("1.2.3.4", 0) == "" and JC.encode("1.2.3.999", 80) == "", "encode rejects bad IP / port")
	var pa: Dictionary = JC.parse_address("10.0.0.5", 7777)
	var pb: Dictionary = JC.parse_address(" 10.0.0.5:9000 ", 7777)
	var pc: Dictionary = JC.parse_address("[::1]:7000", 7777)
	check(pa.ok and pa.port == 7777 and pb.ok and pb.port == 9000 and pb.address == "10.0.0.5" and pc.ok and pc.address == "::1" and pc.port == 7000,
		"parse_address: ip, ip:port, [ipv6]:port")
	check(not JC.parse_address("", 7777).ok and not JC.parse_address("1.2.3.4:abc", 7777).ok and not JC.parse_address("1.2.3.4:70000", 7777).ok,
		"parse_address rejects empty / bad port")

	# ------------------------------------------------------------ IP classes / double NAT
	check(UP.ip_class("8.8.8.8") == "public" and UP.ip_class("192.168.0.2") == "private" and UP.ip_class("10.1.2.3") == "private"
		and UP.ip_class("172.20.0.1") == "private" and UP.ip_class("172.32.0.1") == "public" and UP.ip_class("100.64.0.1") == "cgnat"
		and UP.ip_class("100.128.0.1") == "public" and UP.ip_class("127.0.0.1") == "loopback" and UP.ip_class("x") == "invalid",
		"ip_class: public / private / CGNAT / loopback / invalid")
	var dn: Dictionary = UP.describe(true, "100.70.1.2")
	var dn2: Dictionary = UP.describe(true, "192.168.1.1")
	var okr: Dictionary = UP.describe(true, "203.0.113.9")
	var fail: Dictionary = UP.describe(false, "", "no gateway")
	check(dn.double_nat and not dn.ok and dn.message.contains("double NAT") and dn2.double_nat, "UPnP external IP in CGNAT / private range -> double-NAT warning")
	check(okr.ok and not okr.double_nat and fail.ok == false and fail.message.contains("Forward UDP"), "public IP -> ok; failure -> manual port-forward hint")

	# ------------------------------------------------------------ solo / offline helpers
	check(not Net.is_networked() and Net.is_host() and Net.local_peer_id() == 1 and Net.state == Net.State.OFFLINE,
		"solo: not networked, is host, local id 1, OFFLINE")
	check(get_multiplayer().multiplayer_peer is OfflineMultiplayerPeer, "solo uses Godot's OfflineMultiplayerPeer (Net never replaced it)")
	check(Net.needs_name_prompt() and Net.local_name() == "Survivor", "first launch: name prompt needed, default name 'Survivor'")
	check(Net.get_player_name(1) == "Survivor" and Net.get_player_name(77) == "Survivor", "solo get_player_name returns the local profile name")
	check(not Net.set_local_profile("  Jason[bad]\n  ") and Net.needs_name_prompt(), "set_local_profile refuses a name the validator rejects ([ ])")
	check(Net.set_local_profile("  Jason  ") and Net.local_name() == "Jason" and not Net.needs_name_prompt(), "set_local_profile trims + saves")
	check(not Net.set_local_profile("   "), "empty name refused")
	check(not Net.set_local_profile("AVeryLongPlayerNameIndeed") and Net.local_name() == "Jason", "names over 16 chars refused (validator), name unchanged")
	Net.set_local_profile("Jason")
	Net.load_profile()
	check(Net.local_name() == "Jason" and not Net.needs_name_prompt(), "name persists in the profile file (reload)")
	check(Net.is_leader() and Net.party_size() == 1 and Net.get_slot(1) == 0, "solo: leader, party of 1, slot 0")
	check(Net.select_map("rustwell_foundry") and Net.lobby_map_id == "rustwell_foundry" and not Net.select_map("no_such_map"), "select_map validates ids")
	check(Net.match_difficulty_id() == D.for_map("rustwell_foundry"), "difficulty default = the map's own (%s)" % D.for_map("rustwell_foundry"))
	check(Net.select_difficulty("hard") and Net.match_difficulty_id() == "hard" and not Net.select_difficulty("nightmare"), "difficulty override, validated")
	check(Net.select_difficulty("") and Net.match_difficulty_id() == D.for_map("rustwell_foundry"), "'' clears the override")
	check(not Net.can_start() and not Net.start_match() and not Net.return_to_lobby(), "solo: lobby start / return are no-ops")
	Net.set_ready(true) # no-op offline
	check(not Net.is_ready(), "solo: set_ready is a no-op")
	check(Net.runs_waves() and Net.min_distance_to_players(Vector3(3, 0, 4), _dummy_player()) == 5.0, "solo: runs waves; distance = old local-player check")
	var t := Transform3D(Basis(), Vector3(1, 2, 3))
	check(Net.spawn_slot_transform(t) == t, "solo: spawn slot = the map's PlayerSpawn")
	Net.leave_party() # offline: safe no-op
	check(Net.state == Net.State.OFFLINE, "leave_party offline is a no-op")

	# ------------------------------------------------------------ first-launch name prompt (placeholder UI)
	var NP = load("res://scripts/net/name_prompt.gd")
	NP.gooey_prompt_path = "" # this suite covers the fallback prompt; net_ui_api_test covers the defer-to-Gooey path
	var host_ui := Control.new()
	root.add_child(host_ui)
	check(NP.open_if_needed(host_ui) == null, "name prompt: not shown once a name is saved")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))
	Net.load_profile()
	var pr = NP.open_if_needed(host_ui)
	check(pr != null and Net.needs_name_prompt(), "name prompt: shown on first launch (no saved name)")
	if pr:
		await process_frame
		var named: Array = []
		pr.name_confirmed.connect(func(n): named.append(n))
		pr.line_edit.text = "[]\\"
		check(pr.confirm() == false and pr.error_label.visible and Net.needs_name_prompt(), "name prompt: unusable name refused, stays open")
		pr.line_edit.text = "  Jason  "
		check(pr.confirm() and named == ["Jason"] and not Net.needs_name_prompt() and Net.local_name() == "Jason", "name prompt: saves the trimmed name")
		Net.load_profile()
		check(Net.local_name() == "Jason" and not Net.needs_name_prompt(), "name prompt: name persists in the profile file")
	host_ui.queue_free()
	await process_frame

	# ------------------------------------------------------------ broadcasts in solo
	var real_callouts = root.get_node_or_null("Callouts") # Audi-0's autoload: park it so the fake takes /root/Callouts
	if real_callouts:
		real_callouts.name = "CalloutsAutoloadParked"
	var fc := FakeCallouts.new()
	fc.name = "Callouts"
	root.add_child(fc)
	var got_sig: Array = []
	Net.callout_received.connect(func(e, n, l): got_sig.append([e, n, l]))
	Net.broadcast_callout("massacre", 1)
	check(fc.got.size() == 1 and fc.got[0] == ["massacre", "Jason", true], "solo broadcast_callout -> Callouts.announce(id, local name, true), no RPC")
	check(got_sig.size() == 1 and got_sig[0][2] == true, "callout_received signal for UI/tests")
	var ev: Array = []
	Net.game_event.connect(func(e, p, dd): ev.append([e, p, dd]))
	Net.broadcast_event(&"door_opened", 1, {"cost": 750})
	check(ev.size() == 1 and ev[0][0] == &"door_opened" and ev[0][2].cost == 750, "solo broadcast_event -> game_event locally")
	root.remove_child(fc)
	fc.queue_free()
	if real_callouts:
		real_callouts.name = "Callouts"
		var real_played: Array = []
		real_callouts.callout_played.connect(func(e, n, l): real_played.append([e, n, l]))
		Net.broadcast_callout("boss_kill", 1)
		check(real_played.size() == 1 and real_played[0] == ["boss_kill", "Jason", true], "solo broadcast_callout -> the real Callouts autoload plays it (local name, is_local)")

	# ------------------------------------------------------------ callout driver seam
	var drv := FakeDriver.new()
	root.add_child(drv)
	Net.set_callout_driver(drv)
	Net.report_kill(1, true, false)
	Net.report_kill(1)
	var evs: Array = Net.report_kill(2, false, true)
	Net.report_damage(2)
	check(drv.kills == [[1, true, false], [1, false, false], [2, false, true]] and evs == ["massacre"] and drv.damages == [2],
		"report_kill / report_damage forward to the callout driver (on_kill / on_damage), routed ids returned")
	Net.set_callout_driver(null)
	check(Net.report_kill(1) == [], "no driver bound -> facts dropped, no errors")
	Net.set_callout_driver(drv)

	# ------------------------------------------------------------ transport + host-only party
	check(Net.transport_kind() == "none", "no transport while offline")
	var err: int = Net.host_party(30000 + randi() % 20000, false)
	check(err == OK and Net.is_networked() and Net.is_host() and Net.state == Net.State.HOSTING_LOBBY and Net.transport_kind() == "enet",
		"host_party: ENet server up, HOSTING_LOBBY")
	var party: Array = Net.get_party()
	check(party.size() == 1 and party[0].name == "Jason" and party[0].is_leader and party[0].ready and party[0].slot == 0, "host is leader, slot 0, ready")
	check(Net.get_share_address().ends_with(":%d" % Net._port) and JC.decode(Net.make_join_code()).port == Net._port, "share address + join code carry the port")
	check(Net.host_party() == ERR_ALREADY_IN_USE and Net.join_by_address("127.0.0.1") == ERR_ALREADY_IN_USE, "can't host / join twice")
	check(Net.can_start(), "host alone in the lobby may start")
	Net.auto_change_scene = false
	var started: Array = []
	Net.match_starting.connect(func(m, dd): started.append([m, dd]))
	var go := [false]
	Net.match_started.connect(func(): go[0] = true)
	Net.select_map("arena")
	check(Net.start_match() and Net.state == Net.State.IN_MATCH and started == [["arena", ""]], "start_match -> match_starting(map, diff) locally")
	Net.report_scene_ready()
	check(go[0] and Net.is_match_running(), "all (1) loaded -> match_started")
	check(not Net.select_map("arena"), "map can't change mid-match")
	var main_stub := Node.new()
	main_stub.set_script(_main_stub_script())
	Net.apply_scaling(main_stub, 3)
	check(main_stub.first_round_zombies == 12 and main_stub.zombies_per_round == 6 and main_stub.max_alive == 24, "apply_scaling(3 players): 6->12, 3->6, max_alive 16->24")
	Net.apply_scaling(main_stub, 1)
	check(main_stub.first_round_zombies == 12, "apply_scaling(1) is a no-op")
	main_stub.free()
	var lefts: Array = []
	Net.disconnected.connect(func(r): lefts.append(r))
	Net.leave_party()
	check(Net.state == Net.State.OFFLINE and not Net.is_networked() and get_multiplayer().multiplayer_peer is OfflineMultiplayerPeer and lefts == ["left"],
		"leave_party: back to OfflineMultiplayerPeer, disconnected('left')")
	check(Net.join_by_address("") != OK and Net.last_error == "bad_address" and Net.join_by_code("nope") != OK and Net.last_error == "bad_code",
		"join with bad address / code fails cleanly")
	Net.auto_change_scene = true
	drv.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))
	print("NET TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	if parked_settings:
		parked_settings.name = "Settings"
	quit(_fails)


func _dummy_player() -> Node3D:
	var n := Node3D.new()
	root.add_child(n)
	n.global_position = Vector3.ZERO
	return n


func _main_stub_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nvar first_round_zombies := 6\nvar zombies_per_round := 3\nvar max_alive := 16\n"
	s.reload()
	return s
