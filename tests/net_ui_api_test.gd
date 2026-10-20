extends SceneTree
## Gooey lobby-UI API suite (Netz, NETZ_GAPS.md decisions 1-7), single process:
## one name store (Settings.player_name + one-time net_profile.cfg migration), one validator (= Gooey's
## Settings.validate_player_name, compared against Gooey's actual file when it's on this box), name prompt defers to
## Gooey's, upnp_started / upnp_result always (skipped), start_block_reason offline, busy join reason.
## Kick, peer_left reasons and teammate HP are multi-process: tests/net/run_lobby.sh scenario "ui".
##   godot --headless --path . -s res://tests/net_ui_api_test.gd   (exit code = failures)

var _fails := 0
var _passes := 0
const GOOEY_SETTINGS := "/workspace/gooey-ui/coop/files/scripts/autoload/settings.gd"


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


## Gooey's Settings shape: player_name, set_player_name (validates + saves), changed(key).
class StubSettings:
	extends Node
	signal changed(key: String)
	var player_name := ""
	var saves := 0
	func set_player_name(raw: String) -> Dictionary:
		var v := NetNames.validate(raw)
		if v.ok:
			player_name = str(v.name)
			saves += 1
			changed.emit("player_name")
		return v


func _wait(cond: Callable, s: float) -> bool:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > end:
			return false
		await process_frame
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
	var prof := "user://net_ui_api_test_profile.cfg"
	Net.profile_path = prof
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))

	# ------------------------------------------------------------ 1. one validator
	var cases := ["Jason", "  Jason  ", "a", "ab", "Jo  Jo", "x$y", "<b>", "J[a]", "back\\slash", "dot.name_ok-1", "___",
		"1234567890123456", "12345678901234567", "émile", "tab\tname", "  ", "", "Ünïcødé", "a b", "-.-"]
	var ok_all := true
	for c in cases:
		var v: Dictionary = Net.validate_name(c)
		ok_all = ok_all and v.ok == Net.is_valid_name(c) and v.has("reason") and v.has("name")
	check(ok_all, "validate_name / is_valid_name agree, {ok, name, reason} shape")
	check(not Net.is_valid_name("x$y") and not Net.is_valid_name("<b>") and not Net.is_valid_name("J[a]") and not Net.is_valid_name("émile"), "no $ < [ or non-ASCII (Gooey's rule)")
	check(Net.is_valid_name("dot.name_ok-1") and Net.is_valid_name("1234567890123456") and not Net.is_valid_name("12345678901234567") and not Net.is_valid_name("a") and not Net.is_valid_name("___"), "2..16 chars, _ - . allowed, needs a letter or number")
	check(Net.validate_name("  Jo   Jo ").name == "Jo Jo", "trim + collapse spaces")
	check(Net.sanitize_name("Ja$on<3") == "Jaon3" and Net.sanitize_name("$$") == "", "sanitize_name (wire names): drops disallowed chars, '' if nothing valid")
	if FileAccess.file_exists(GOOEY_SETTINGS):
		var gs := GDScript.new()
		gs.source_code = FileAccess.get_file_as_string(GOOEY_SETTINGS)
		if gs.reload() == OK:
			var same := true
			var diffs: Array = []
			for c in cases:
				var a: Dictionary = gs.validate_player_name(c)
				var b: Dictionary = Net.validate_name(c)
				if a.ok != b.ok or a.name != b.name or a.reason != b.reason:
					same = false
					diffs.append([c, a, b])
			check(same, "Net.validate_name == Gooey's Settings.validate_player_name on %d cases %s" % [cases.size(), diffs])
		else:
			print("NOTE  Gooey's settings.gd doesn't compile standalone here; compared rules by hand")
	else:
		print("NOTE  %s not on this box: skipped the side-by-side validator check" % GOOEY_SETTINGS)

	# ------------------------------------------------------------ 1. one name store (no Settings.player_name: legacy file)
	check(Net._settings() == null, "staging Settings has no player_name yet -> net_profile.cfg fallback")
	check(Net.set_local_profile("Legacy") and FileAccess.file_exists(prof), "fallback store: net_profile.cfg written")
	# with Gooey's Settings: park the real Settings, add the stub
	var real_st = root.get_node_or_null("Settings")
	if real_st:
		real_st.name = "SettingsParked"
	var st := StubSettings.new()
	st.name = "Settings"
	root.add_child(st)
	var mtime0 := FileAccess.get_modified_time(prof)
	Net.load_profile()
	check(Net.name_migrated and st.player_name == "Legacy" and st.saves == 1 and Net.local_name() == "Legacy" and not Net.needs_name_prompt(), "first launch with Settings: net_profile.cfg name migrated into Settings.player_name once")
	Net.load_profile()
	check(not Net.name_migrated and st.saves == 1, "second launch: no migration (Settings owns the name)")
	await create_timer(1.1).timeout # mtime resolution
	check(Net.set_local_profile("Newname") and st.player_name == "Newname" and st.saves == 2 and Net.local_name() == "Newname", "set_local_profile writes Settings.player_name")
	check(FileAccess.get_modified_time(prof) == mtime0 and _cfg_name(prof) == "Legacy", "net_profile.cfg no longer written once Settings has the name")
	check(Net.set_local_profile("Newname") and st.saves == 2, "same name again: Settings not re-saved")
	var pc: Array = []
	Net.profile_changed.connect(func(n): pc.append(n))
	st.set_player_name("Edited") # settings menu / Gooey's prompt
	check(Net.local_name() == "Edited" and pc == ["Edited"], "Settings.changed('player_name') -> Net follows (profile_changed)")
	check(not Net.set_local_profile("bad$") and st.player_name == "Edited", "invalid name: neither store touched")
	st.player_name = ""
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))
	Net.load_profile()
	check(Net.needs_name_prompt() and Net.local_name() == "Survivor", "no name anywhere -> prompt needed")
	st.queue_free()
	await process_frame
	if real_st:
		real_st.name = "Settings"
	Net.load_profile()

	# ------------------------------------------------------------ 7. prompt defers to Gooey's
	var NP = load("res://scripts/net/name_prompt.gd")
	var ui := Control.new()
	root.add_child(ui)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))
	Net.load_profile()
	NP.gooey_prompt_path = "res://scripts/net/net.gd" # any existing script stands in for scripts/ui/name_prompt.gd
	check(NP.open_if_needed(ui) == null, "Gooey's name_prompt.gd present -> the Netz fallback never opens")
	NP.gooey_prompt_path = "res://scripts/ui/no_such_prompt.gd"
	var pr = NP.open_if_needed(ui)
	check(pr != null, "no Gooey prompt -> fallback opens")
	if pr:
		await process_frame
		pr.line_edit.text = "a$"
		check(not pr.confirm() and pr.error_label.text == Net.validate_name("a$").reason, "fallback shows the validator's reason")
		pr.queue_free()
	NP.gooey_prompt_path = NP.GOOEY_PROMPT
	ui.queue_free()

	# ------------------------------------------------------------ 5. start_block_reason offline
	check(Net.start_block_reason() == "offline" and not Net.can_start(), "start_block_reason offline")

	# ------------------------------------------------------------ 4. upnp always answers
	var ev: Array = []
	Net.upnp_started.connect(func(): ev.append(["started"]))
	Net.upnp_result.connect(func(ok, ip, msg): ev.append(["result", ok, ip, msg]))
	var port := 30000 + randi() % 9000
	check(Net.host_party(port, false) == OK, "host_party (try_upnp=false)")
	check(ev.is_empty(), "upnp signals are deferred (after host_party returns, so the UI's TRYING state is set first)")
	await _wait(func(): return ev.size() >= 1, 2.0)
	check(ev == [["result", false, "", "skipped"]] and Net.upnp_info.get("status") == "skipped" and Net.upnp_info.get("why") == "not_requested", "not tried -> upnp_result(false, '', 'skipped'), upnp_info.why = not_requested (%s)" % [ev])
	check(Net.start_block_reason() == "", "hosting alone: start allowed")
	var mid: String = Net.lobby_map_id
	Net.lobby_map_id = "no_such_map"
	check(Net.start_block_reason() == "no_map", "start_block_reason no_map")
	Net.lobby_map_id = mid
	var fails: Array = []
	Net.connection_failed.connect(func(r): fails.append(r))
	check(Net.join_by_address("127.0.0.1:%d" % (port + 1)) == ERR_ALREADY_IN_USE and fails == ["busy"] and Net.last_error == "busy", "join while in a party -> connection_failed('busy')")
	check(not Net.kick(1) and not Net.kick(4242), "kick: never the host itself / unknown peer")
	Net.leave_party()
	ev.clear()
	NetConfig.override({"upnp.enabled": false})
	Net.host_party(port, true)
	await _wait(func(): return ev.size() >= 1, 2.0)
	check(ev == [["result", false, "", "skipped"]] and Net.upnp_info.get("why") == "disabled", "upnp.enabled false -> skipped (disabled)")
	Net.leave_party()
	NetConfig.override({"upnp.enabled": true, "upnp.discover_ms": 300})
	ev.clear()
	Net.host_party(port, true)
	await _wait(func(): return ev.size() >= 2, 8.0)
	check(ev.size() == 2 and ev[0] == ["started"] and ev[1][0] == "result" and Net.upnp_info.get("status") in ["ok", "failed"], "UPnP tried -> upnp_started, then upnp_result (%s)" % [ev])
	Net.leave_party()
	await _wait(func(): return Net._upnp == null, 2.0)
	NetConfig.reload()
	# hp_frac (Gooey phase-3 ask): next to the hp / max_hp ints, in the signal and the entry
	var sig_args: Array = []
	for sg in Net.get_signal_list():
		if sg.name == "teammate_health_changed":
			for a in sg.args:
				sig_args.append(str(a.name))
	check(sig_args == ["peer_id", "hp", "max_hp", "hp_frac"], "teammate_health_changed(peer_id, hp, max_hp, hp_frac) (%s)" % [sig_args])
	check(is_equal_approx(Net.hp_frac_of(60, 100), 0.6) and Net.hp_frac_of(5, 0) == 0.0 and Net.hp_frac_of(150, 100) == 1.0 and Net.hp_frac_of(-3, 100) == 0.0, "hp_frac_of: hp / max_hp clamped 0..1, 0 for max_hp 0")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(prof))
	print("NET UI API TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	if parked_settings:
		parked_settings.name = "Settings"
	quit(_fails)


func _cfg_name(path: String) -> String:
	var c := ConfigFile.new()
	return str(c.get_value("profile", "name", "")) if c.load(path) == OK else ""
