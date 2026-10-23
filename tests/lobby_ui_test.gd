extends SceneTree
## Co-op lobby UI test (Gooey):  godot --headless --path . -s res://tests/lobby_ui_test.gd
## Home PLAY → SOLO / HOST / JOIN on the lobby_api.gd stub (auto_sim off, everything driven by stub signals):
## mode choice + solo map-picker flow, host join code + COPY, UPnP trying / open / failed help, join validation +
## connect spinner + API errors, 4 party slots + ready, leader-only map/difficulty/START, start gating reasons,
## member read-only view, kicked / host-left notices, first-launch + pre-host name prompt, Settings PROFILE edit,
## name persistence in settings.cfg, ESC / focus nav. Exit code = number of failures. Own save files.

const SETTINGS_SAVE := "user://settings_lobby_ui_test.cfg"
const PROG_SAVE := "user://progress_lobby_ui_test.cfg"
var _fails := 0
var _passes := 0
var st
var home
var lobby
var net
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


func _initialize() -> void:
	_run.call_deferred()


func press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await frames(2)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await frames(2)


func node(n: String) -> Node:
	return lobby.find_child(n, true, false)


func lbl(n: String) -> String:
	var l = node(n)
	return str(l.text) if l else "<none>"


func vis(n: String) -> bool:
	var c = node(n)
	return c != null and c.is_visible_in_tree()


func slot(i: int) -> Node:
	return node("PartySlot_%d" % i)


func slot_name(i: int) -> String:
	var l = slot(i).find_child("SlotName", true, false)
	return str(l.text) if l else "<none>"


func _run() -> void:
	LAPI = load("res://scripts/ui/lobby_api.gd")
	st = root.get_node("Settings")
	st.save_path = SETTINGS_SAVE
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_SAVE))
	st.player_name = ""
	var prog = root.get_node_or_null("Progress")
	if prog and "save_path" in prog:
		prog.save_path = PROG_SAVE
		prog.armory_unequipped_on_load = []
	LAPI = load("res://scripts/ui/lobby_api.gd")
	LAPI.force_stub = true # Netz tree: never instantiate the real net.gd here
	var real_net = root.get_node_or_null("Net")
	if real_net:
		real_net.name = "NetAutoloadParked" # Netz tree: park the real Net so this suite drives the stub (lobby_net_test covers Net)
	check(root.get_node_or_null("Net") == null, "stub path (Net %s)" % ("parked" if real_net else "not installed"))

	# ---------------------------------------------------------------- name validation (Settings)
	var SS = load("res://scripts/autoload/settings.gd")
	check(not SS.validate_player_name("a").ok, "name: 1 char rejected")
	check(not SS.validate_player_name("x".repeat(17)).ok, "name: 17 chars rejected")
	check(not SS.validate_player_name("Ja$on<3").ok, "name: bad characters rejected")
	check(not SS.validate_player_name("__").ok, "name: needs a letter or digit")
	var v: Dictionary = SS.validate_player_name("  Final   Girl ")
	check(v.ok and v.name == "Final Girl", "name: trimmed + spaces collapsed (%s)" % v.name)
	check(SS.validate_player_name("Ash_Williams-2.0").ok, "name: letters digits _ - . allowed")
	check(not st.has_player_name(), "fresh settings: no player name")

	# ---------------------------------------------------------------- first-launch prompt on home
	home = load("res://scripts/ui/home_menu.gd").new()
	home.dry_run = true
	root.add_child(home)
	home.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	home.size = Vector2(root.size)
	await frames(4)
	var np = home.name_prompt
	check(np != null and is_instance_valid(np) and np.is_inside_tree(), "first launch: name prompt shown on home")
	if np:
		check(not np.cancel_btn.visible, "first-launch prompt can't be cancelled")
		np.edit.text = "a"
		np._on_text_changed("a")
		check(np.ok_btn.disabled and "at least" in np.error_label.text, "prompt: too short → SAVE disabled + reason (%s)" % np.error_label.text)
		np.edit.text = "Bad$Name"
		np._on_text_changed("Bad$Name")
		check(np.ok_btn.disabled and "Use only" in np.error_label.text, "prompt: bad chars → reason")
		check(np.submit() == "", "prompt: submit refuses invalid")
		np.edit.text = "  Gooey  "
		np._on_text_changed(np.edit.text)
		check(not np.ok_btn.disabled, "prompt: valid name enables SAVE")
		check(np.submit() == "Gooey", "prompt: submit returns the trimmed name")
	await frames(3)
	check(st.player_name == "Gooey" and st.has_player_name(), "name saved to Settings")
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_SAVE)
	var saved := ""
	for sec in cfg.get_sections():
		if cfg.has_section_key(sec, "player_name"):
			saved = str(cfg.get_value(sec, "player_name"))
	check(saved == "Gooey", "player_name persisted in settings.cfg (%s)" % saved)
	st.player_name = ""
	st.load_from_disk()
	check(st.player_name == "Gooey", "player_name reloads from settings.cfg")
	check(home.maybe_prompt_name() == null, "no prompt once a name exists")

	# Settings PROFILE edit
	var sm = home.find_child("HomeSettings", true, false)
	sm.open()
	sm._select_tab("gameplay")
	await frames(2)
	check(sm.name_edit != null and sm.name_edit.text == "Gooey", "Settings PROFILE shows the current name")
	sm.name_edit.text = "!"
	check(not sm.save_profile_name() and st.player_name == "Gooey", "Settings PROFILE refuses invalid name")
	check("characters" in sm.name_error.text or "Use only" in sm.name_error.text, "Settings PROFILE shows the reason (%s)" % sm.name_error.text)
	sm.name_edit.text = "Gooey 2"
	check(sm.save_profile_name() and st.player_name == "Gooey 2", "Settings PROFILE saves an edited name")
	sm.close()
	await frames(2)

	# ---------------------------------------------------------------- Netz name API (stub mirrors it) + open_if_needed
	var NP = load("res://scripts/ui/name_prompt.gd")
	check(NP.open_if_needed(home) == null, "open_if_needed: null once a name exists (NetNamePrompt contract)")
	var nst = LAPI.create(root)
	check(nst.sanitize_name("  [Ash]\\Wil\tliams  ") == "AshWilliams" and nst.sanitize_name("x".repeat(30)).length() == 16, "stub sanitize_name = Netz rules ([ ] \\ control chars stripped, 16 max)")
	check(nst.set_local_profile("Gooey 2") and nst.local_name() == "Gooey 2" and not nst.needs_name_prompt(), "set_local_profile -> true, local_name, needs_name_prompt")
	check(not nst.set_local_profile("   "), "set_local_profile refuses an empty name")
	if ResourceLoader.exists("res://scripts/net/net_names.gd"):
		check(st._net_validator() != null and not bool(st.validate_player_name("x$").ok), "scripts/net present: Settings delegates to NetNames")
	else:
		check(st._net_validator() == null and not bool(st.validate_player_name("x$").ok), "no scripts/net here: Settings uses its fallback validator")
	check(not nst.set_local_profile("[Ash]") and nst.local_name() == "Gooey 2", "set_local_profile refuses an invalid name (Netz cb5e52a: no silent strip)")
	check(not bool(LAPI.check_name(nst, "x$")["ok"]) and bool(LAPI.check_name(nst, "  Ash   W ")["ok"]) and str(LAPI.check_name(nst, "  Ash   W ")["name"]) == "Ash W", "LobbyAPI.check_name = one validator (Settings rules = NetNames)")
	var pc_names: Array = []
	nst.profile_changed.connect(func(n): pc_names.append(n))
	nst.set_local_profile("Gooey 2")
	check(pc_names == ["Gooey 2"], "profile_changed emitted")
	check(LAPI.needs_name(st, nst) == false, "LobbyAPI.needs_name: stub → Settings has a name")

	# ---------------------------------------------------------------- PLAY → mode choice
	(home.find_child("Btn_play", true, false) as Button).pressed.emit()
	await frames(3)
	lobby = home.lobby()
	check(lobby != null and lobby.visible and lobby.page == "mode", "PLAY opens SOLO / CO-OP")
	net = lobby.net
	check(net != null and LAPI.is_stub(net), "lobby bound to the stub via LobbyAPI.create")
	net.auto_sim = false
	for m in ["solo", "host", "join", "coop"]:
		check(node("Mode_" + m) is Button, "mode button %s" % m)
	check(vis("Mode_solo") and vis("Mode_coop") and not vis("Mode_host") and not vis("Mode_join"), "first step: SOLO and CO-OP only")
	check(vis("StubTag"), "stub tag shown (offline preview)")
	var foc = lobby.get_viewport().gui_get_focus_owner()
	check(foc != null and str(foc.name) == "Mode_solo", "keyboard focus on SOLO (%s)" % (foc.name if foc else "none"))
	var mc := node("Mode_coop") as Button
	check(mc.get_node(mc.focus_neighbor_left) == node("Mode_solo") and mc.get_node(mc.focus_neighbor_right) == node("Mode_solo"), "SOLO ⇄ CO-OP wired left/right")
	lobby.choose_mode("coop")
	await frames(2)
	check(lobby.page == "coop" and vis("Mode_host") and vis("Mode_join") and not vis("Mode_solo"), "CO-OP → HOST / JOIN page")
	check(lbl("LobbyTitle") == "CO-OP", "CO-OP page title")
	foc = lobby.get_viewport().gui_get_focus_owner()
	check(foc == node("Mode_host"), "focus on HOST (%s)" % (foc.name if foc else "none"))
	var mh := node("Mode_host") as Button
	check(mh.get_node(mh.focus_neighbor_right) == node("Mode_join") and mh.get_node(mh.focus_neighbor_bottom) == node("CoopBack"), "HOST → JOIN right, BACK below")
	await press("ui_cancel")
	check(lobby.visible and lobby.page == "mode", "ESC on HOST / JOIN → back to SOLO / CO-OP")

	# SOLO keeps the map picker flow
	lobby.choose_mode("solo")
	await frames(3)
	var mp = home.find_child("HomeMapPicker", true, false)
	check(not lobby.visible and mp.visible, "SOLO → home map picker")
	mp.close()
	await frames(2)
	home.open_play()
	await frames(2)
	await press("ui_cancel")
	check(not lobby.visible, "ESC on mode page closes the choice")

	# ---------------------------------------------------------------- HOST (no name → prompt first)
	st.player_name = ""
	home.open_play()
	await frames(2)
	lobby.choose_mode("host")
	await frames(2)
	check(lobby.name_prompt != null and lobby.name_prompt.allow_cancel, "HOST without a name asks for one first")
	check(lobby.page == "mode", "still on the mode page while naming")
	lobby.name_prompt.edit.text = "Gooey"
	lobby.name_prompt.submit()
	await frames(3)
	check(lobby.page == "lobby" and int(net.state) == LAPI.HOSTING_LOBBY, "after naming, HOST opens the lobby (state HOSTING_LOBBY)")
	check(lobby.upnp_state == "trying" and vis("UpnpSpinner"), "UPnP: trying + spinner")
	check("TRYING" in lbl("UpnpStatus"), "UPnP status text trying (%s)" % lbl("UpnpStatus"))
	var code := lbl("JoinCode")
	check(code.begins_with(LAPI.code_prefix() + "-") and code.length() == 14, "join code shown large (%s)" % code)
	check(LAPI.decode_code("DN" + code.substr(2)).ok, "legacy DN- codes still decode")
	check(int((node("JoinCode") as Label).get_theme_font_size("font_size")) >= 40, "join code font is big")
	var dc: Dictionary = LAPI.decode_code(code)
	check(dc.ok and dc.address == net.fake_public_ip and int(dc.port) == 7777, "code decodes to public ip:7777")
	var copied: String = lobby.copy_code()
	check(copied == code and lobby.last_copied == code, "COPY puts the code on the clipboard")
	var cb := DisplayServer.clipboard_get()
	check(cb == code or cb == "", "clipboard_set used (headless clipboard: '%s')" % cb)
	check(lbl("CopyFeedback") == "COPIED", "COPY feedback")
	check(not vis("UpnpHelp"), "no help while trying")
	net.sim_upnp(false)
	await frames(1)
	check(lobby.upnp_state == "failed" and "FAILED" in lbl("UpnpStatus"), "UPnP failed status")
	check(vis("UpnpHelp"), "UPnP failure help shown")
	var help := lbl("UpnpHelp")
	check("7777" in help and "UDP" in help and "TCP" in help and "this PC" in help, "help: forward UDP/TCP 7777 to this PC")
	check("Share your IP" in help and "192.168.1.42" in help, "help: or share your IP (LAN ip shown)")
	check(not vis("UpnpSpinner"), "spinner gone after result")
	net.sim_upnp(true)
	await frames(1)
	check(lobby.upnp_state == "open" and "OPEN" in lbl("UpnpStatus") and not vis("UpnpHelp"), "UPnP open status, help hidden")
	check("203.0.113.5" in lbl("ShareAddress"), "share address shown (%s)" % lbl("ShareAddress"))
	lobby._on_upnp_result(true, "100.72.1.9", "ok")
	check(lobby.upnp_state == "cgnat" and vis("UpnpHelp"), "CGNAT external IP → warning + help")
	net.sim_upnp(false, true)
	await frames(1)
	check(lobby.upnp_state == "cgnat" and vis("UpnpHelp") and "DOUBLE NAT" in lbl("UpnpStatus"), "Netz double-NAT result (ok=false, upnp_info.double_nat) → warning (%s)" % lbl("UpnpStatus"))
	check("double NAT" in lbl("UpnpHelp") and "Tailscale" in lbl("UpnpHelp") and "won't be enough" in lbl("UpnpHelp"), "double-NAT help shows Netz's message + what to do")
	net.sim_upnp(true)
	lobby.upnp_state = "trying"
	lobby._arm_upnp_timeout()
	await create_timer(lobby.UPNP_GIVE_UP_S + 0.3, true).timeout
	check(lobby.upnp_state == "failed" and vis("UpnpHelp"), "no UPnP answer → failed + help after %.0f s" % lobby.UPNP_GIVE_UP_S)
	# Netz cb5e52a: upnp_started, then upnp_result always ("skipped" + upnp_info.why when not tried)
	lobby.upnp_state = "failed"
	net.upnp_started.emit()
	await frames(1)
	check(lobby.upnp_state == "trying" and vis("UpnpSpinner"), "upnp_started → TRYING spinner")
	net.upnp_info = {"ok": false, "external_ip": "", "status": "skipped", "why": "not_requested"}
	net.upnp_result.emit(false, "", "skipped")
	await frames(1)
	check(lobby.upnp_state == "skipped" and "UPnP OFF" in lbl("UpnpStatus") and vis("UpnpHelp") and not vis("UpnpSpinner"), "upnp_result skipped → UPnP OFF + port-forward help (%s)" % lbl("UpnpStatus"))
	net.upnp_info = {"ok": false, "status": "skipped", "why": "not_needed"}
	net.upnp_result.emit(false, "", "skipped")
	await frames(1)
	check(lobby.upnp_state == "skipped" and not vis("UpnpHelp"), "skipped (not_needed) → no help")
	net.sim_upnp(true)

	# ---------------------------------------------------------------- slots + ready + leader controls
	check(slot(0) != null and slot(3) != null and slot(4) == null, "4 party slots")
	check(slot_name(0) == "GOOEY" and slot(0).find_child("LeaderCrown", true, false).visible, "slot 0: me, leader crown")
	check(slot(0).find_child("YouTag", true, false) != null, "slot 0: YOU tag")
	check(bool(slot(1).get_meta("empty")) and slot_name(1) == "OPEN SLOT", "empty slots shown")
	check(lbl("PartyCount") == "1 / 4", "party count 1/4")
	var jid: int = net.sim_peer_join("Jason", false, 48)
	await frames(1)
	check(slot_name(1) == "JASON" and not bool(slot(1).get_meta("empty")), "peer join fills slot 1")
	check(str((slot(1).find_child("Ping", true, false) as Label).text) == "48 ms", "ping shown")
	check(slot(1).find_child("Swatch", true, false).color.is_equal_approx(LAPI.slot_tints()[1]), "tint swatch (palette fallback)")
	check(not slot(1).find_child("LeaderCrown", true, false).visible, "no crown on member")
	check(not bool(slot(1).find_child("ReadyBadge", true, false).get_meta("ready")), "Jason NOT READY badge")
	check("Jason joined" in lobby.last_toast, "join toast (%s)" % lobby.last_toast)
	check(vis("MapPick") and vis("DiffRow") and vis("StartBtn"), "leader sees map + difficulty pickers + START")
	check(not vis("MapReadOnly") and not vis("DiffReadOnly"), "leader: no read-only labels")
	var sb := node("StartBtn") as Button
	check(sb.disabled and "Waiting on Jason" in lbl("StartReason"), "START disabled: waiting on Jason (%s)" % lbl("StartReason"))
	net.sim_peer_ready(jid, true)
	await frames(1)
	check(bool(slot(1).find_child("ReadyBadge", true, false).get_meta("ready")), "Jason READY badge")
	check(not sb.disabled and lbl("StartReason") == "", "START enabled once every member is ready")
	# Netz 9c4f1ec: in a running match the badge shows the player's state (downed / spectating / late join)
	var jent: Dictionary = {}
	for pe in net._party:
		if int(pe.peer_id) == jid:
			jent = pe
	for st in [["downed", "downed", false, "DOWNED"], ["spectating", "dead", false, "BLED OUT  //  SPECTATING"], ["spectating", "dead", true, "JOINED LATE  //  SPECTATING"], ["in_match", "alive", false, "IN MATCH"]]:
		var keep_state = jent.get("state", "lobby")
		jent.state = st[0]
		jent.life = st[1]
		if st[2]:
			jent.late_join = true
		net.party_changed.emit(net.get_party())
		await frames(1)
		var bd = slot(1).find_child("ReadyBadge", true, false)
		check(str(bd.get_meta("status", "")) == st[3], "lobby badge for %s/%s%s → %s (%s)" % [st[0], st[1], " late" if st[2] else "", st[3], bd.get_meta("status", "")])
		jent.state = keep_state
		jent.erase("life")
		jent.erase("late_join")
	net.party_changed.emit(net.get_party())
	await frames(1)
	check(not slot(1).find_child("ReadyBadge", true, false).has_meta("status"), "back in the lobby: READY badge again")
	check(bool(lobby.my_entry().get("ready")) and "✓" in lbl("ReadyToggle"), "leader starts ready (Netz: START is the leader's ready)")
	lobby.toggle_ready()
	await frames(1)
	check(not bool(lobby.my_entry().get("ready")) and lbl("ReadyToggle") == "READY UP", "leader READY toggle flips")
	lobby.toggle_ready()
	await frames(1)
	net.sim_peer_ready(jid, false)
	await frames(1)
	check(sb.disabled and not lobby.start_pressed(), "START refused while a member is unready")
	net.sim_peer_ready(jid, true)
	await frames(1)
	var aid: int = net.sim_peer_join("Ash", false, 210)
	await frames(1)
	check(slot_name(2) == "ASH" and sb.disabled and "Ash" in lbl("StartReason"), "new unready peer blocks START")
	check((slot(2).find_child("Ping", true, false) as Label).get_theme_color("font_color").is_equal_approx(UIStyle.BAD), "high ping coloured bad")
	net.sim_peer_left(aid, "lost")
	await frames(1)
	check(bool(slot(2).get_meta("empty")) and "Ash" in lobby.last_toast, "peer left → slot empties + toast (%s)" % lobby.last_toast)
	check(not sb.disabled, "START enabled again")
	check(net.start_block_reason() == "" and LAPI.start_block_text("not_ready", ["Ash", "Cara"]) == "Waiting on Ash, Cara to ready up." and LAPI.start_block_text("no_map") == "Pick a map first.", "start_block_reason codes → text")
	# leader KICK (Netz kick(peer, reason)): ✕ arms KICK?, a second press removes
	var cid: int = net.sim_peer_join("Cara", true, 60)
	await frames(1)
	var kb := slot(2).find_child("KickBtn", true, false) as Button
	check(kb != null and slot(0).find_child("KickBtn", true, false) == null, "KICK button on members, not on me")
	kb.pressed.emit()
	await frames(1)
	check(str((slot(2).find_child("KickBtn", true, false) as Button).text) == "KICK?" and slot_name(2) == "CARA", "first press arms KICK?")
	check(lobby.kick_pressed(cid), "second press kicks")
	await frames(1)
	check(bool(slot(2).get_meta("empty")) and "Cara was removed by the host" in lobby.last_toast, "kicked peer leaves (%s)" % lobby.last_toast)
	net.sim_peer_left(jid, "afk")
	await frames(1)
	check("(afk)" in lobby.last_toast, "custom kick reason in the toast (%s)" % lobby.last_toast)
	jid = net.sim_peer_join("Jason", true, 48)
	await frames(1)
	# leader map + difficulty
	lobby.open_map_picker()
	await frames(2)
	var lmp = node("LobbyMapPicker")
	check(lmp.visible, "leader MAP opens the map picker")
	lobby._on_map_picked("drowned_cannery")
	await frames(2)
	check(not lmp.visible and lobby.visible and net.lobby_map_id == "drowned_cannery", "map pick → Net.select_map")
	check("DROWNED CANNERY" in (node("MapPick") as Button).text, "map button shows choice")
	check(net.lobby_difficulty_id == "hard", "difficulty follows map default (hard)")
	lobby.choose_difficulty("easy")
	check(net.lobby_difficulty_id == "easy" and (node("Diff_easy") as Button).button_pressed, "difficulty pick → Net.select_difficulty")
	check(paused, "tree stays paused under the lobby after map pick")
	# START
	check(lobby.start_pressed(), "START with all ready")
	await frames(2)
	check(home.last_coop_start.get("map") == "drowned_cannery" and home.last_coop_start.get("difficulty") == "easy", "match_starting → home gets map + difficulty")
	check(home.last_play_map == "drowned_cannery" and MapRegistry.current_id() == "drowned_cannery", "home.start_match selected the map")
	check(Difficulty.active_id() == "easy", "difficulty set active")
	check(not lobby.visible, "lobby closes on start")
	net.leave_party()
	Difficulty.set_active("")

	# ---------------------------------------------------------------- JOIN validation + errors
	home.open_play()
	await frames(2)
	lobby.choose_mode("join")
	await frames(2)
	check(lobby.page == "join" and vis("JoinPanel"), "JOIN page")
	var ji := node("JoinInput") as LineEdit
	var cbtn := node("ConnectBtn") as Button
	check(lobby.get_viewport().gui_get_focus_owner() == ji, "focus in the join field")
	lobby.set_join_text("")
	check(cbtn.disabled, "CONNECT disabled when empty")
	for bad in ["hello world!", "999.1.1.1", "192.168.1.5:99999", "GC-ABCDE", "::1", "10.0.0.1:0"]:
		lobby.set_join_text(bad)
		check(cbtn.disabled and lbl("JoinError") != "", "invalid '%s' → %s" % [bad, lbl("JoinError")])
	check(not lobby.connect_pressed(), "CONNECT refuses invalid input")
	var good: String = LAPI.encode_code("203.0.113.5", 7777)
	lobby.set_join_text(good.to_lower())
	check(not cbtn.disabled and "203.0.113.5:7777" in lbl("JoinError"), "valid code (lower-case ok) → decoded (%s)" % lbl("JoinError"))
	lobby.set_join_text("192.168.1.7")
	check(not cbtn.disabled and "7777" in lbl("JoinError"), "bare IP → default port")
	lobby.set_join_text("myhost.example.net:7780")
	check(not cbtn.disabled and "7780" in lbl("JoinError"), "hostname:port ok")
	lobby.set_join_text(good)
	check(lobby.connect_pressed(), "CONNECT starts joining")
	await frames(1)
	check(lobby.connecting and vis("ConnectingBox") and vis("ConnectSpinner"), "connecting spinner shown")
	check("203.0.113.5:7777" in lbl("ConnectingLabel") and lbl("JoinBack") == "CANCEL", "connecting label + CANCEL")
	check(cbtn.disabled and not ji.editable, "input locked while connecting")
	check(not lobby.connect_pressed(), "no double connect")
	for reason in ["party_full", "timeout", "version_mismatch", "refused", "in_progress"]:
		if not lobby.connecting:
			lobby.connect_pressed()
		net.sim_connect_fail(reason)
		await frames(1)
		check(not lobby.connecting and lbl("JoinError") == LAPI.reason_text(reason), "API error %s → %s" % [reason, lbl("JoinError")])
	check(LAPI.reason_text("party_full") != LAPI.reason_text("timeout"), "distinct error texts")
	for r in ["unreachable", "bad_code", "bad_address", "busy"]:
		check(LAPI.REASON_TEXT.has(r), "Netz reason has text: %s" % r)
	lobby._on_peer_rejected(7, "Freddy", "party_full")
	check("Freddy couldn't join" in lobby.last_toast, "peer_rejected toast (%s)" % lobby.last_toast)
	lobby.connect_pressed()
	lobby._on_join_back()
	check(not lobby.connecting and int(net.state) == LAPI.OFFLINE and lbl("JoinError") == "Cancelled.", "CANCEL aborts the join")

	# ---------------------------------------------------------------- member lobby view
	lobby.connect_pressed()
	net.sim_connect_ok("Jason", ["Ash"])
	await frames(2)
	check(lobby.page == "lobby" and not lobby.connecting, "connected → lobby")
	check(slot_name(0) == "JASON" and slot(0).find_child("LeaderCrown", true, false).visible, "host Jason has the crown")
	check(slot_name(2) == "GOOEY" and slot(2).find_child("YouTag", true, false) != null, "me in slot 2 with YOU tag")
	check(not vis("StartBtn") and not vis("MapPick") and not vis("DiffRow"), "member: no START / pickers")
	check(not vis("HostPanel"), "member: no host panel")
	check(vis("MapReadOnly") and "RUSTWELL FOUNDRY" in lbl("MapReadOnly"), "member: map read-only (%s)" % lbl("MapReadOnly"))
	check(vis("DiffReadOnly") and "MEDIUM" in lbl("DiffReadOnly"), "member: difficulty read-only (%s)" % lbl("DiffReadOnly"))
	check(vis("MemberNote"), "member: leader-picks note")
	net.sim_lobby_settings("arena", "hard")
	await frames(1)
	check("ARENA" in lbl("MapReadOnly") and "HARD" in lbl("DiffReadOnly"), "leader changes reflect read-only")
	lobby.open_map_picker()
	lobby.choose_difficulty("easy")
	check(not node("LobbyMapPicker").visible and net.lobby_difficulty_id == "hard", "member can't change map/difficulty")
	check(vis("ReadyToggle"), "member has READY toggle")
	check("Ready up" in lbl("StartReason"), "member reason: ready up (%s)" % lbl("StartReason"))
	lobby._on_disconnected("left")
	check(not lobby.notice_visible(), "own LEAVE ('left') shows no notice")
	lobby.toggle_ready()
	await frames(1)
	check(bool(lobby.my_entry().get("ready")) and "leader" in lbl("StartReason"), "member ready → waiting for leader")
	check(not lobby.start_pressed(), "member START refused")
	net.match_starting.emit("arena", "hard")
	await frames(2)
	check(home.last_coop_start.get("map") == "arena" and home.last_coop_start.get("difficulty") == "hard", "member follows match_starting")
	Difficulty.set_active("")
	net.leave_party()

	# kicked / host left notices
	home.open_play()
	await frames(1)
	lobby.choose_mode("join")
	lobby.set_join_text(good)
	lobby.connect_pressed()
	net.sim_connect_ok("Jason")
	await frames(1)
	net.sim_host_left()
	await frames(1)
	check(lobby.notice_visible() and "HOST LEFT" in lobby.last_notice, "host left notice")
	await press("ui_cancel")
	check(not lobby.notice_visible() and lobby.page == "coop", "ESC dismisses notice → HOST / JOIN page")
	lobby.choose_mode("join")
	lobby.set_join_text(good)
	lobby.connect_pressed()
	net.sim_connect_ok("Jason")
	await frames(1)
	net.sim_kicked()
	await frames(1)
	check(lobby.notice_visible() and "REMOVED FROM PARTY" in lobby.last_notice, "kicked notice (%s)" % lobby.last_notice)
	lobby.dismiss_notice()
	lobby._on_disconnected("afk")
	check("REMOVED FROM PARTY" in lobby.last_notice and "Reason: afk" in lobby.last_notice, "kick with the host's reason → REMOVED + reason")
	lobby.dismiss_notice()
	lobby._on_disconnected("lost")
	check("DISCONNECTED" in lobby.last_notice, "generic disconnect notice")
	lobby.dismiss_notice()
	# leave from the lobby (ESC)
	lobby.choose_mode("host")
	await frames(1)
	check(int(net.state) == LAPI.HOSTING_LOBBY, "host again")
	await press("ui_cancel")
	check(int(net.state) == LAPI.OFFLINE and lobby.page == "coop", "ESC in lobby → LEAVE (back to HOST / JOIN)")
	lobby.close()
	await frames(2)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_SAVE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROG_SAVE))
	print("lobby_ui_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
