extends Node
## Autoload "Net" (NetworkManager, Netz). Transport, party / lobby, profile name, game-event broadcasts, and the
## host-side match API used by the main.gd hooks (NET_HOOKS.md). See DESIGN.md §2.1 for the public API.
##
## Solo = no peer: SceneTree.multiplayer keeps its OfflineMultiplayerPeer (unique id 1, is_server() true), so
## is_networked() is false, is_host() is true, local_peer_id() is 1 and every main.gd hook takes the old code path.
## Net never changes anything in solo: _ready only reads data/net.json and the profile file.
##
## Authority: the host (peer 1) owns party state and the match. Clients send requests (_rpc_hello, _rpc_set_ready,
## _rpc_set_profile, _rpc_scene_ready); the host answers with _rpc_welcome / _rpc_party_update / ... .
## The transport is swappable behind NetTransport (ENet today; GodotSteam later, DESIGN.md §4.4).

const EnetTransportScr := preload("res://scripts/net/enet_transport.gd")
const CalloutAdapterScr := preload("res://scripts/net/callout_adapter.gd")
const UpnpScr := preload("res://scripts/net/upnp_helper.gd")
const JoinCodeScr := preload("res://scripts/net/join_code.gd")
const MAIN_SCENE := "res://scenes/main.tscn"
const HOME_SCENE := "res://scenes/ui/home.tscn"

enum State { OFFLINE, HOSTING_LOBBY, JOINING, IN_LOBBY, IN_MATCH }

const DEFAULT_PORT := 7777 ## data/net.json default_port overrides at runtime (port())
const IN_MATCH_KEYS := ["hp", "max_hp", "hp_frac", "life", "late_join"] ## party entry keys that only exist during a match
const MAX_PLAYERS := 4 ## data/net.json max_players overrides at runtime (max_players())

# ------------------------------------------------------------------ signals (Gooey builds the lobby against these)
signal state_changed(new_state: int)
signal hosting_started(share_address: String, join_code: String)
signal upnp_started() ## host_party is trying UPnP (deferred: arrives after host_party returns)
signal upnp_result(ok: bool, external_ip: String, message: String) ## always once per host_party; message "skipped" when not tried (upnp_info.why)
signal connected_to_party()
signal connection_failed(reason: String) ## timeout | unreachable | bad_address | bad_code | busy | version_mismatch | party_full | in_progress
signal party_changed(party: Array)
signal peer_joined(peer_id: int, player_name: String)
signal peer_left(peer_id: int, player_name: String, reason: String) ## left | lost | kicked (or the kick reason); same on host and clients
signal peer_rejected(peer_id: int, player_name: String, reason: String) ## host: a join was refused (version_mismatch | party_full | in_progress)
signal lobby_settings_changed(map_id: String, difficulty_id: String)
signal match_starting(map_id: String, difficulty_id: String)
signal match_started() ## every peer finished loading (or the host's scene_ready timeout ran out)
signal returned_to_lobby()
signal host_left()
signal disconnected(reason: String) ## left | host_left | kicked (or the host's kick reason)
signal game_event(event_id: StringName, peer_id: int, data: Dictionary)
signal callout_received(event_id: String, player_name: String, is_local: bool)
signal profile_changed(player_name: String)
signal teammate_health_changed(peer_id: int, hp: int, max_hp: int, hp_frac: float) ## in match, every peer, any party member (local too); ~5 Hz max, on change; hp_frac = hp / max_hp (0..1)

# ------------------------------------------------------------------ state
var state: int = State.OFFLINE
var lobby_map_id: String = ""
var lobby_difficulty_id: String = "" ## "" = the map's own difficulty (maps.json)
var match_seed: int = 0
var auto_change_scene: bool = true ## tests: false (no scene changes; call report_scene_ready() by hand)
var proto_version_override: int = -1 ## tests: pretend to be another protocol version
var profile_path: String = "" ## "" = data/net.json profile.path (tests point it at a scratch file)
var share_address: String = ""
var external_ip: String = ""
var upnp_info: Dictionary = {}
var last_error: String = ""

var _transport: NetTransport
var _upnp: NetUpnp
var _callouts := CalloutAdapterScr.new()
var _party: Dictionary = {} ## peer_id -> {peer_id, name, class_id, ready, is_leader, ping_ms, slot, state}
var _port: int = 0
var _local_name: String = ""
var _local_class: String = ""
var _name_set: bool = false
var _connect_timer: SceneTreeTimer
var _loaded: Dictionary = {} ## host: peer_id -> true once its match scene is ready
var _match_go: bool = false
var _refresh_t: float = 0.0
var _match: Node = null ## the running main.gd (attach_match)
var match_players: NetPlayers ## /root/Net/Players: avatars, player state, downed / revive (milestone B)
var world: NetWorld ## /root/Net/World: zombie / drop replication, spend requests, client round state


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	load_profile()
	match_players = NetPlayers.new()
	match_players.name = "Players"
	add_child(match_players)
	world = NetWorld.new()
	world.name = "World"
	add_child(world)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _exit_tree() -> void:
	if _upnp:
		_upnp.close()


var _linger: Array = [] ## client transports closing after leave_party: [{t, until}]


func _process(delta: float) -> void:
	if not _linger.is_empty():
		_linger_tick()
	_hp_tick(delta)
	if not is_host() or not is_networked():
		return
	_refresh_t -= delta
	if _refresh_t <= 0.0:
		_refresh_t = float(NetConfig.get_value("lobby.party_refresh_s", 2.0))
		_refresh_pings()

# ================================================================== helpers (public)

## False for solo / OfflineMultiplayerPeer.
func is_networked() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) and state != State.OFFLINE


## True in solo.
func is_host() -> bool:
	return not is_networked() or multiplayer.is_server()


## 1 in solo.
func local_peer_id() -> int:
	return multiplayer.get_unique_id() if is_networked() else 1


## Solo: the local profile name. Unknown peers: "Player <id>".
func get_player_name(peer_id: int) -> String:
	if not is_networked():
		return local_name()
	if _party.has(peer_id):
		return str(_party[peer_id].name)
	return local_name() if peer_id == local_peer_id() else "Player %d" % peer_id


func is_leader(peer_id: int = -1) -> bool:
	if peer_id < 0:
		peer_id = local_peer_id()
	if not is_networked():
		return true
	return peer_id == 1 ## v1: the host is always the leader


func get_party() -> Array:
	var out: Array = []
	var ids := _party.keys()
	ids.sort()
	for id in ids:
		out.append((_party[id] as Dictionary).duplicate())
	return out


func party_size() -> int:
	return _party.size() if is_networked() else 1


## Party slot 0..3 (tint, spawn offset). Solo: 0.
func get_slot(peer_id: int) -> int:
	return int(_party.get(peer_id, {}).get("slot", 0))


func port() -> int:
	return int(NetConfig.get_value("default_port", DEFAULT_PORT))


func max_players() -> int:
	return clampi(int(NetConfig.get_value("max_players", MAX_PLAYERS)), 1, 16)


func proto_version() -> int:
	return proto_version_override if proto_version_override >= 0 else int(NetConfig.get_value("proto_version", 1))


func game_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "dev"))


func transport_kind() -> String:
	return _transport.kind() if _transport else "none"

# ================================================================== profile

func _profile_file() -> String:
	return profile_path if profile_path != "" else str(NetConfig.get_value("profile.path", "user://net_profile.cfg"))


## Name store: Settings.player_name (Gooey's settings.cfg) when the Settings autoload has that field; else
## net_profile.cfg (older builds / tests). On the first launch with Settings, a valid net_profile.cfg name is migrated
## into Settings once; after that net_profile.cfg is never written again.
func _settings() -> Node:
	var st := get_node_or_null("/root/Settings")
	return st if st and "player_name" in st else null


func load_profile() -> void:
	_name_set = false
	name_migrated = false
	_local_name = str(NetConfig.get_value("profile.default_name", "Survivor"))
	var st := _settings()
	if st:
		if st.has_signal("changed") and not st.changed.is_connected(_on_settings_changed):
			st.changed.connect(_on_settings_changed)
		var sn := str(st.player_name)
		if sn == "": # migrate a net_profile.cfg name once (Settings then owns it)
			var old := _profile_cfg_name()
			if old != "" and is_valid_name(old):
				_store_in_settings(st, validate_name(old).name)
				sn = str(st.player_name)
				name_migrated = true
		if is_valid_name(sn):
			_local_name = validate_name(sn).name
			_name_set = true
		return
	var n := _profile_cfg_name()
	if n != "":
		var v := validate_name(n)
		n = str(v.name) if v.ok else sanitize_name(n)
	if n != "":
		_local_name = n
		_name_set = true


var name_migrated := false ## tests / debug: load_profile moved a net_profile.cfg name into Settings.player_name
var _writing_settings := false


func _profile_cfg_name() -> String:
	var cfg := ConfigFile.new()
	return str(cfg.get_value("profile", "name", "")) if cfg.load(_profile_file()) == OK else ""


func _store_in_settings(st: Node, n: String) -> void:
	_writing_settings = true
	if st.has_method("set_player_name"):
		st.set_player_name(n)
	else:
		st.player_name = n
	_writing_settings = false


## Settings.player_name edited elsewhere (settings menu / Gooey's prompt): follow it and push it to the party.
func _on_settings_changed(key: String) -> void:
	if key != "player_name" or _writing_settings:
		return
	var st := _settings()
	if st and is_valid_name(str(st.player_name)) and validate_name(str(st.player_name)).name != _local_name:
		_adopt_name(str(validate_name(str(st.player_name)).name))


func local_name() -> String:
	return _local_name


## Class id for the lobby: explicit set_local_profile() value, else Progress.selected_class.
func local_class() -> String:
	if _local_class != "":
		return _local_class
	var prog := get_node_or_null("/root/Progress")
	return str(prog.selected_class) if prog and "selected_class" in prog else "soldier"


## First launch: true until a name was saved. Home calls this and opens Gooey's name prompt
## (scripts/ui/name_prompt.gd). NetNamePrompt (scripts/net/name_prompt.gd) is only a fallback for builds without it.
func needs_name_prompt() -> bool:
	return not _name_set


## Single validator (NetNames = Gooey's Settings.validate_player_name rules): {ok, name, reason}.
func validate_name(n: String) -> Dictionary:
	return NetNames.validate(n)


func is_valid_name(n: String) -> bool:
	return NetNames.is_valid(n)


## Repairs a name from the wire / an old profile (drops disallowed characters); "" if nothing valid is left.
func sanitize_name(n: String) -> String:
	return NetNames.sanitize(n)


## Saves the name (Settings.player_name, or net_profile.cfg without it) and class (this session; the real class
## lives in Progress). Pushes it to the party. false (nothing changed) if validate_name() rejects it.
func set_local_profile(player_name: String, class_id: String = "") -> bool:
	var v := validate_name(player_name)
	if not v.ok:
		return false
	var n := str(v.name)
	var same := _name_set and n == _local_name and (class_id == "" or class_id == _local_class)
	if class_id != "":
		_local_class = class_id
	var st := _settings()
	if st:
		if str(st.player_name) != n:
			_store_in_settings(st, n)
	else:
		var cfg := ConfigFile.new()
		cfg.load(_profile_file())
		cfg.set_value("profile", "name", n)
		cfg.save(_profile_file())
	if not same: # Gooey's prompt: Settings.set_player_name (Net already followed it) then set_local_profile(same name)
		_adopt_name(n)
	return true


func _adopt_name(n: String) -> void:
	_local_name = n
	_name_set = true
	profile_changed.emit(n)
	if is_networked():
		if is_host():
			_apply_profile(1, n, local_class())
		else:
			_rpc_set_profile.rpc_id(1, n, local_class())

# ================================================================== host / join / leave

func _make_transport() -> NetTransport:
	match str(NetConfig.get_value("transport", "enet")):
		_:
			return EnetTransportScr.new() ## "steam" plugs in here later (DESIGN.md §4.4)


func host_party(p: int = -1, try_upnp: bool = true) -> Error:
	if state != State.OFFLINE:
		last_error = "busy"
		return ERR_ALREADY_IN_USE
	_port = p if p > 0 else port()
	_transport = _make_transport()
	# one spare transport slot beyond the party, so a 5th player gets a polite "party_full" instead of a dead socket
	var err := _transport.host(_port, maxi(max_players(), 1))
	if err != OK:
		last_error = error_string(err)
		_transport = null
		return err
	multiplayer.multiplayer_peer = _transport.peer()
	_party.clear()
	_party[1] = _entry(1, local_name(), local_class(), 0)
	_party[1].ready = true # the leader's Start is its ready
	if lobby_map_id == "" or not MapRegistry.is_valid(lobby_map_id):
		lobby_map_id = MapRegistry.current_id()
	external_ip = ""
	share_address = "%s:%d" % [lan_ip(), _port]
	_set_state(State.HOSTING_LOBBY)
	hosting_started.emit(share_address, make_join_code())
	party_changed.emit(get_party())
	var why := "" if try_upnp else "not_requested"
	if why == "" and not bool(NetConfig.get_value("upnp.enabled", true)):
		why = "disabled"
	if why == "" and not _transport.needs_port_forward():
		why = "not_needed"
	if why == "":
		_upnp = UpnpScr.new()
		upnp_started.emit.call_deferred()
		_upnp.open_async(_port, _on_upnp_done)
	else:
		upnp_info = {"ok": false, "status": "skipped", "why": why, "message": "skipped"}
		_emit_upnp_skipped.call_deferred(_port)
	return OK


func _emit_upnp_skipped(for_port: int) -> void:
	if state != State.OFFLINE and _port == for_port:
		upnp_result.emit(false, "", "skipped")


func _on_upnp_done(res: Dictionary) -> void:
	upnp_info = res.duplicate()
	upnp_info["status"] = "ok" if bool(res.get("ok", false)) else "failed"
	if state == State.OFFLINE:
		return
	if bool(res.get("ok", false)):
		external_ip = str(res.external_ip)
		share_address = "%s:%d" % [external_ip, _port]
	upnp_result.emit(bool(res.get("ok", false)), str(res.get("external_ip", "")), str(res.get("message", "")))
	if bool(res.get("ok", false)):
		hosting_started.emit(share_address, make_join_code())


## "1.2.3.4" or "1.2.3.4:7777" (or [ipv6]:port).
func join_by_address(address: String, p: int = -1) -> Error:
	var a := JoinCodeScr.parse_address(address, p if p > 0 else port())
	if not a.ok:
		return _fail_join("bad_address")
	return _join({"kind": "direct", "address": a.address, "port": a.port})


func join_by_code(code: String) -> Error:
	var d := decode_join_code(code)
	if not d.ok:
		return _fail_join("bad_code")
	return _join({"kind": d.get("kind", "direct"), "address": d.address, "port": d.port})


func _fail_join(reason: String) -> Error:
	last_error = reason
	connection_failed.emit(reason)
	return ERR_INVALID_PARAMETER


func _join(target: Dictionary) -> Error:
	if state != State.OFFLINE:
		_fail_join("busy")
		return ERR_ALREADY_IN_USE
	_transport = _make_transport()
	var err := _transport.join(target)
	if err != OK:
		_transport = null
		return _fail_join("unreachable")
	multiplayer.multiplayer_peer = _transport.peer()
	_party.clear()
	_set_state(State.JOINING)
	_connect_timer = get_tree().create_timer(float(NetConfig.get_value("connect_timeout_s", 8.0)), true)
	var t := _connect_timer
	t.timeout.connect(func():
		if _connect_timer == t and state == State.JOINING:
			_shutdown()
			last_error = "timeout"
			connection_failed.emit("timeout"))
	return OK


## Encodes the address friends should use: UPnP external IP once known, else the LAN IP.
func make_join_code() -> String:
	var ip := external_ip if external_ip != "" else lan_ip()
	return JoinCodeScr.encode(ip, _port if _port > 0 else port())


func decode_join_code(code: String) -> Dictionary:
	return JoinCodeScr.decode(code)


func get_share_address() -> String:
	return share_address


## First private IPv4 of this machine (LAN play / fallback share address).
func lan_ip() -> String:
	var best := "127.0.0.1"
	for a in IP.get_local_addresses():
		var c := UpnpScr.ip_class(a)
		if c == "private" and not a.begins_with("169.254"):
			return a
		if c == "public":
			best = a
	return best


## Leaves (client) or closes (host) the party. Safe to call when offline.
func leave_party() -> void:
	if state == State.OFFLINE:
		return
	if is_networked() and not is_host() and _transport:
		# Graceful leave: tell the host first so it reports "left" (not "lost"). The old transport lingers (polled
		# below) until the host drops us or 0.5 s pass; this side is OFFLINE right away.
		_rpc_leaving.rpc_id(1)
		_linger.append({"t": _transport, "until": Time.get_ticks_msec() + 500})
		_transport = null
	_shutdown()
	disconnected.emit("left")


func _shutdown() -> void:
	_connect_timer = null
	if _upnp:
		_upnp.close()
		_upnp = null
	if _transport:
		_transport.close()
		_transport = null
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_party.clear()
	_loaded.clear()
	_match_go = false
	_match = null
	_reset_match_state()
	_leave_reason.clear()
	_left_announced.clear()
	_hp_sent = Vector2i(-1, -1)
	share_address = ""
	external_ip = ""
	_set_state(State.OFFLINE)


func _set_state(s: int) -> void:
	if s != state:
		state = s
		state_changed.emit(s)

# ================================================================== transport callbacks

func _on_peer_connected(id: int) -> void:
	if is_host() and _transport and _transport.has_method("tune_peer"):
		_transport.tune_peer(id)


func _on_peer_disconnected(id: int) -> void:
	if not is_host() or not _party.has(id):
		return
	var n := str(_party[id].name)
	var reason := str(_leave_reason.get(id, "lost"))
	_leave_reason.erase(id)
	_party.erase(id)
	_loaded.erase(id)
	_callouts.remove_peer(id)
	peer_left.emit(id, n, reason)
	_rpc_peer_left.rpc(id, n, reason) # clients get the real reason before the party update drops the entry
	_broadcast_party()
	_check_all_loaded()


func _on_connected_to_server() -> void:
	_rpc_hello.rpc_id(1, proto_version(), game_version(), local_name(), local_class())


func _on_connection_failed() -> void:
	if state == State.JOINING:
		_shutdown()
		last_error = "unreachable"
		connection_failed.emit("unreachable")


func _on_server_disconnected() -> void:
	if state == State.JOINING:
		_shutdown()
		last_error = "unreachable"
		connection_failed.emit("unreachable")
		return
	_shutdown()
	host_left.emit()
	disconnected.emit("host_left")

# ================================================================== handshake / party (host side)

func _entry(id: int, n: String, cls: String, slot: int) -> Dictionary:
	return {"peer_id": id, "name": n, "class_id": cls, "ready": false, "is_leader": id == 1, "ping_ms": 0,
		"slot": slot, "state": "lobby"}


func _free_slot() -> int:
	var used := {}
	for e in _party.values():
		used[int(e.slot)] = true
	for s in max_players():
		if not used.has(s):
			return s
	return _party.size()


func _unique_name(n: String, self_id: int) -> String:
	var base := n
	var k := 2
	var taken := func(x: String) -> bool:
		for e in _party.values():
			if int(e.peer_id) != self_id and str(e.name) == x:
				return true
		return false
	while taken.call(n):
		n = "%s (%d)" % [base.substr(0, 12), k]
		k += 1
	return n


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello(proto: int, version: String, player_name: String, class_id: String) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	var reason := ""
	if proto != proto_version() or version != game_version():
		reason = "version_mismatch"
	elif _party.size() >= max_players():
		reason = "party_full"
	elif state == State.IN_MATCH and not bool(NetConfig.get_value("lobby.allow_late_join", false)):
		reason = "in_progress"
	if reason != "":
		peer_rejected.emit(id, player_name, reason)
		_reject(id, reason)
		return
	var n := sanitize_name(player_name)
	if n == "":
		n = "Player %d" % (_party.size() + 1)
	n = _unique_name(n, id)
	_party[id] = _entry(id, n, class_id, _free_slot())
	_rpc_welcome.rpc_id(id, get_party(), _lobby_dict())
	peer_joined.emit(id, n)
	_broadcast_party()


var _leave_reason: Dictionary = {} ## host: peer -> "left" / kick reason, until its disconnect arrives
var _left_announced: Dictionary = {} ## client: peers already reported by _rpc_peer_left


@rpc("any_peer", "call_remote", "reliable")
func _rpc_leaving() -> void:
	if is_host():
		var id := multiplayer.get_remote_sender_id()
		if not _leave_reason.has(id):
			_leave_reason[id] = "left"
		if _transport:
			_transport.kick(id) # graceful drop -> _on_peer_disconnected -> peer_left(id, name, "left")


func _linger_tick() -> void:
	var now := Time.get_ticks_msec()
	for l in _linger.duplicate():
		var p: MultiplayerPeer = l.t.peer() if l.t else null
		if p:
			p.poll()
		if p == null or p.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED or now >= int(l.until):
			if l.t:
				l.t.close()
			_linger.erase(l)


@rpc("authority", "call_remote", "reliable")
func _rpc_peer_left(id: int, player_name: String, reason: String) -> void:
	if _party.has(id):
		_left_announced[id] = true
		peer_left.emit(id, player_name, reason)


## Host only: remove a member. The client gets `reason` (disconnected(reason)) before the transport drops it; the
## host and the other clients see peer_left(id, name, reason). false: not host / unknown peer / the host itself.
func kick(peer_id: int, reason: String = "kicked") -> bool:
	if not is_networked() or not is_host() or peer_id == 1 or not _party.has(peer_id):
		return false
	var r := reason if reason != "" else "kicked"
	_leave_reason[peer_id] = r
	_rpc_kicked.rpc_id(peer_id, r)
	var t := get_tree().create_timer(0.3, true)
	t.timeout.connect(func():
		if _transport and _party.has(peer_id):
			_transport.kick(peer_id))
	return true


@rpc("authority", "call_remote", "reliable")
func _rpc_kicked(reason: String) -> void:
	_shutdown()
	last_error = reason
	disconnected.emit(reason)


func _reject(id: int, reason: String) -> void:
	_rpc_rejected.rpc_id(id, reason)
	var t := get_tree().create_timer(0.5, true)
	t.timeout.connect(func():
		if _transport:
			_transport.kick(id))


func _lobby_dict() -> Dictionary:
	return {"map_id": lobby_map_id, "difficulty_id": lobby_difficulty_id, "state": state}


func _broadcast_party() -> void:
	if not is_host() or not is_networked():
		return
	var arr := get_party()
	_rpc_party_update.rpc(arr)
	party_changed.emit(arr)


func _refresh_pings() -> void:
	var changed := false
	for id in _party:
		if id == 1:
			continue
		var p := _transport.ping_ms(id) if _transport else -1
		if p >= 0 and absi(p - int(_party[id].ping_ms)) > 5:
			_party[id].ping_ms = p
			changed = true
	if changed:
		_broadcast_party()


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_ready(r: bool) -> void:
	if not is_host():
		return
	var id := multiplayer.get_remote_sender_id()
	if _party.has(id):
		_party[id].ready = r
		_broadcast_party()


@rpc("any_peer", "call_remote", "reliable")
func _rpc_set_profile(player_name: String, class_id: String) -> void:
	if not is_host():
		return
	_apply_profile(multiplayer.get_remote_sender_id(), player_name, class_id)


func _apply_profile(id: int, player_name: String, class_id: String) -> void:
	if not _party.has(id):
		return
	var n := sanitize_name(player_name)
	if n != "":
		_party[id].name = _unique_name(n, id)
	if class_id != "":
		_party[id].class_id = class_id
	_broadcast_party()

# ================================================================== handshake / party (client side)

@rpc("authority", "call_remote", "reliable")
func _rpc_welcome(party: Array, lobby: Dictionary) -> void:
	_connect_timer = null
	_set_party(party)
	lobby_map_id = str(lobby.get("map_id", ""))
	lobby_difficulty_id = str(lobby.get("difficulty_id", ""))
	_set_state(State.IN_LOBBY)
	connected_to_party.emit()
	lobby_settings_changed.emit(lobby_map_id, lobby_difficulty_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_rejected(reason: String) -> void:
	_shutdown()
	last_error = reason
	connection_failed.emit(reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_party_update(party: Array) -> void:
	_set_party(party)


func _set_party(party: Array) -> void:
	var old := _party.duplicate()
	_party.clear()
	for e in party:
		_party[int(e.peer_id)] = e
	for id in _party:
		if not old.has(id) and id != local_peer_id():
			peer_joined.emit(id, str(_party[id].name))
	for id in old:
		if not _party.has(id) and not _left_announced.has(id):
			peer_left.emit(id, str(old[id].name), "left")
		_left_announced.erase(id)
	party_changed.emit(get_party())

# ================================================================== lobby

func set_ready(r: bool) -> void:
	if not is_networked():
		return
	if is_host():
		if _party.has(1):
			_party[1].ready = r
			_broadcast_party()
	else:
		if _party.has(local_peer_id()):
			_party[local_peer_id()].ready = r
		_rpc_set_ready.rpc_id(1, r)


func is_ready(peer_id: int = -1) -> bool:
	return bool(_party.get(local_peer_id() if peer_id < 0 else peer_id, {}).get("ready", false))


## Leader only. Valid map ids come from data/maps.json.
func select_map(map_id: String) -> bool:
	if not is_leader() or not MapRegistry.is_valid(map_id) or state == State.IN_MATCH:
		return false
	lobby_map_id = map_id
	_push_lobby_settings()
	return true


## Leader only. "" = the map's own difficulty (maps.json); otherwise a data/difficulty.json profile id.
func select_difficulty(difficulty_id: String) -> bool:
	if not is_leader() or state == State.IN_MATCH:
		return false
	if difficulty_id != "" and not Difficulty.is_valid(difficulty_id):
		return false
	lobby_difficulty_id = difficulty_id
	_push_lobby_settings()
	return true


func _push_lobby_settings() -> void:
	if is_networked() and is_host():
		_rpc_lobby_settings.rpc(lobby_map_id, lobby_difficulty_id)
	lobby_settings_changed.emit(lobby_map_id, lobby_difficulty_id)


@rpc("authority", "call_remote", "reliable")
func _rpc_lobby_settings(map_id: String, difficulty_id: String) -> void:
	lobby_map_id = map_id
	lobby_difficulty_id = difficulty_id
	lobby_settings_changed.emit(map_id, difficulty_id)


## Difficulty the match will run: the leader's override, else the map's own (maps.json).
func match_difficulty_id() -> String:
	if lobby_difficulty_id != "" and Difficulty.is_valid(lobby_difficulty_id):
		return lobby_difficulty_id
	return Difficulty.for_map(lobby_map_id if lobby_map_id != "" else MapRegistry.current_id())


func can_start() -> bool:
	return start_block_reason() == ""


## Why START is blocked, "" when it's allowed: "offline" | "not_leader" | "not_in_lobby" | "no_map" | "not_ready"
## (start_requires_all_ready and someone isn't ready: names in not_ready_names()). The leader's own ready is implicit.
func start_block_reason() -> String:
	if not is_networked():
		return "offline"
	if not is_host():
		return "not_leader"
	if state != State.HOSTING_LOBBY:
		return "not_in_lobby"
	if not MapRegistry.is_valid(lobby_map_id):
		return "no_map"
	if bool(NetConfig.get_value("lobby.start_requires_all_ready", true)) and not not_ready_names().is_empty():
		return "not_ready"
	return ""


## Members (not the leader) who haven't readied up, in slot order.
func not_ready_names() -> Array:
	var out: Array = []
	for e in get_party():
		if int(e.peer_id) != 1 and not bool(e.ready):
			out.append(str(e.name))
	return out


## Leader only: everyone loads the map. Returns false if can_start() is false.
func start_match() -> bool:
	if not can_start():
		return false
	_loaded.clear()
	_match_go = false
	_rpc_start_match.rpc(lobby_map_id, lobby_difficulty_id, randi())
	var t := get_tree().create_timer(float(NetConfig.get_value("lobby.scene_ready_timeout_s", 20.0)), true)
	t.timeout.connect(func():
		if state == State.IN_MATCH and not _match_go:
			_go())
	return true


@rpc("authority", "call_local", "reliable")
func _rpc_start_match(map_id: String, difficulty_id: String, seed_value: int) -> void:
	lobby_map_id = map_id
	lobby_difficulty_id = difficulty_id
	match_seed = seed_value
	_reset_match_state()
	for id in _party:
		_party[id].state = "loading"
	_set_state(State.IN_MATCH)
	MapRegistry.select(map_id)
	match_starting.emit(map_id, difficulty_id)
	if auto_change_scene:
		get_tree().paused = false
		get_tree().change_scene_to_file(MAIN_SCENE)


## The match scene is ready on this machine (main.gd M1 via attach_match; tests call it by hand).
func report_scene_ready() -> void:
	if not is_networked() or state != State.IN_MATCH:
		return
	if is_host():
		_mark_loaded(1)
	else:
		_rpc_scene_ready.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_scene_ready() -> void:
	if is_host():
		_mark_loaded(multiplayer.get_remote_sender_id())


func _mark_loaded(id: int) -> void:
	if not _party.has(id):
		return
	_loaded[id] = true
	_party[id].state = "in_match"
	world.send_doors_to(id) # M13: doors opened before this peer's map was up (late join: same path)
	_check_all_loaded()


func _check_all_loaded() -> void:
	if not is_host() or state != State.IN_MATCH or _match_go:
		return
	for id in _party:
		if not _loaded.has(id):
			return
	_go()


func _go() -> void:
	_match_go = true
	_broadcast_party()
	_rpc_match_go.rpc()


@rpc("authority", "call_local", "reliable")
func _rpc_match_go() -> void:
	_match_go = true
	match_started.emit()


func is_match_running() -> bool:
	return _match_go


## Leader: everyone goes back to the lobby (home scene with the lobby open), ready flags cleared.
func return_to_lobby() -> bool:
	if not is_networked() or not is_leader() or state != State.IN_MATCH:
		return false
	_rpc_return_to_lobby.rpc()
	return true


@rpc("authority", "call_local", "reliable")
func _rpc_return_to_lobby() -> void:
	_match_go = false
	_loaded.clear()
	_match = null
	for id in _party:
		_party[id].ready = id == 1
		_party[id].state = "lobby"
		for k in IN_MATCH_KEYS: # in-match only
			_party[id].erase(k)
	_set_state(State.HOSTING_LOBBY if is_host() else State.IN_LOBBY)
	returned_to_lobby.emit()
	party_changed.emit(get_party())
	if auto_change_scene:
		get_tree().paused = false
		get_tree().change_scene_to_file(HOME_SCENE)

# ================================================================== game event broadcasts (host only)

## Callouts (Audi-0): the host-side callout_driver calls this; every peer then calls Callouts.announce.
func broadcast_callout(event_id: String, peer_id: int) -> void:
	if not is_networked():
		_announce(event_id, peer_id, true)
		return
	if not is_host():
		push_warning("Net.broadcast_callout is host-only")
		return
	_rpc_callout.rpc(event_id, peer_id)


@rpc("authority", "call_local", "reliable")
func _rpc_callout(event_id: String, peer_id: int) -> void:
	_announce(event_id, peer_id, peer_id == local_peer_id())


func _announce(event_id: String, peer_id: int, is_local: bool) -> void:
	var n := get_player_name(peer_id)
	callout_received.emit(event_id, n, is_local)
	var c := get_node_or_null("/root/Callouts")
	if c and c.has_method("announce"):
		c.announce(event_id, n, is_local)


## Any host-detected party-wide event (door_opened, player_downed, boss_spawned, ...). `data`: plain Variants only.
func broadcast_event(event_id: StringName, peer_id: int, data: Dictionary = {}) -> void:
	if not is_networked():
		game_event.emit(event_id, peer_id, data)
		return
	if not is_host():
		push_warning("Net.broadcast_event is host-only")
		return
	_rpc_game_event.rpc(event_id, peer_id, data)


@rpc("authority", "call_local", "reliable")
func _rpc_game_event(event_id: StringName, peer_id: int, data: Dictionary) -> void:
	game_event.emit(event_id, peer_id, data)

# ================================================================== callout driver seam (host reports facts)

## Bind Audi-0's CalloutDriver (or a test fake). main creates the driver; Net only forwards facts to it.
func set_callout_driver(driver: Object) -> void:
	_callouts.bind(driver)


func callout_driver() -> Object:
	if not _callouts.is_bound():
		var d := get_tree().get_first_node_in_group("callout_driver") if is_inside_tree() else null
		if d == null and get_tree() and get_tree().current_scene:
			d = get_tree().current_scene.find_child("CalloutDriver", true, false)
		if d:
			_callouts.bind(d)
	return _callouts.driver if _callouts.is_bound() else null


## Host: an accepted kill by peer_id. Returns the driver's routed event ids ([] without a driver).
func report_kill(peer_id: int, is_headshot: bool = false, is_boss: bool = false) -> Array:
	if not is_host():
		return []
	callout_driver()
	return _callouts.kill(peer_id, is_headshot, is_boss)


## Host: peer_id took damage (resets their no-damage streak).
func report_damage(peer_id: int) -> void:
	if is_host():
		callout_driver()
		_callouts.damage(peer_id)

# ================================================================== match API (main.gd hooks, NET_HOOKS.md)
# Solo: every function here is either a no-op or returns exactly what main computed before the hooks.

## M1: end of main._ready. Networked: difficulty override + co-op zombie scaling, report loaded.
func attach_match(main: Node) -> void:
	if not is_networked():
		return
	_match = main
	_hp_sent = Vector2i(-1, -1)
	if lobby_difficulty_id != "":
		Difficulty.apply_to_main(main, match_difficulty_id())
	apply_scaling(main, party_size())
	match_players.begin_match(main)
	world.apply_doors() # M13: doors the host already reported open (normally none at match start)
	var wallet := int(main.player.points) if main.get("player") else 0
	if is_host():
		_points[1] = wallet
	else:
		_rpc_wallet.rpc_id(1, wallet)
	report_scene_ready()


## Client -> host at match start: this player's starting wallet, so the host ledger matches it.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_wallet(points: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if is_host() and _party.has(id) and not _points.has(id):
		_points[id] = clampi(points, 0, 1000000)
		_rpc_points.rpc(id, 0, _points[id], "wallet")


## Co-op zombie scaling (data/net.json scaling): zombies per round x (1 + 0.5 x extra players), max_alive capped.
## No-op for 1 player.
func apply_scaling(main: Object, players: int) -> void:
	if players <= 1:
		return
	var s := NetConfig.scaling(players, int(main.get("max_alive")))
	main.set("first_round_zombies", maxi(int(round(int(main.get("first_round_zombies")) * float(s.count_mult))), 1))
	main.set("zombies_per_round", int(round(int(main.get("zombies_per_round")) * float(s.count_mult))))
	main.set("max_alive", int(s.max_alive))


## M2: only the host runs the wave state machine.
func runs_waves() -> bool:
	return is_host()


## M4: distance from pos to the nearest alive player. Solo: distance to `local_player` (exactly the old check).
func min_distance_to_players(pos: Vector3, local_player: Node3D) -> float:
	if not is_networked():
		return pos.distance_to(local_player.global_position)
	var best := INF
	for p in players():
		if p.get("dead") != true:
			best = minf(best, pos.distance_to(p.global_position))
	return best if best < INF else pos.distance_to(local_player.global_position)


## Every player body in this match: the local Player + remote avatars (group "net_avatar").
func players() -> Array:
	var out: Array = []
	if not is_inside_tree():
		return out
	var lp := get_tree().get_first_node_in_group("player")
	if lp:
		out.append(lp)
	for a in get_tree().get_nodes_in_group("net_avatar"):
		out.append(a)
	return out


## E1 (enemy.gd): nearest alive player. Solo: the "player" group's first node, like before.
func pick_target(enemy: Node3D) -> Node3D:
	var ps := players()
	if not is_networked() or ps.size() <= 1:
		return ps[0] if ps.size() else null
	var best: Node3D = null
	var bd := INF
	for p in ps:
		if p.get("dead") == true or p.get("downed") == true:
			continue
		var d := enemy.global_position.distance_squared_to(p.global_position)
		if d < bd:
			bd = d
			best = p
	return best if best else ps[0]


## M12: spawn slot for this peer around the map's PlayerSpawn (slot 0 = the spawn itself).
func spawn_slot_transform(base: Transform3D, peer_id: int = -1) -> Transform3D:
	var slot := get_slot(local_peer_id() if peer_id < 0 else peer_id)
	if slot <= 0:
		return base
	var offs := [Vector3.ZERO, Vector3(1.2, 0, 0), Vector3(-1.2, 0, 0), Vector3(0, 0, 1.2)]
	return Transform3D(base.basis, base.origin + base.basis * offs[slot % offs.size()])

# ------------------------------------------------------------------ match: host-side world (phase B fills in replication)
# Everything below runs only when networked (main.gd guards with Net.is_networked(), or the function no-ops in solo).

signal round_state_changed(round_number: int, phase: String, enemies_left: int)
signal points_changed(peer_id: int, total: int)

const ArmoryScr := preload("res://scripts/armory/armory.gd")

var _zombie_counter := 0
var _points: Dictionary = {} ## host: peer_id -> total points this match (host-authoritative)
var _offers_closed: Dictionary = {} ## host: peer_id -> true once that player's Field Card pick is done
var _offers_since := 0.0 ## host: msec when the current offer round began
var _offers_open := false ## host: a Field Card round is open (set at round_cleared when Field Cards are on)
var _match_over := false
var current_round := 0
var round_phase := "pre" ## pre | combat | break


## M3 (host): build the zombie from its spec, wire it to main, add it. Phase B: through the ZombieSpawner so
## every client builds the same zombie from the same spec (+ name + seed).
func spawn_zombie(main: Node, spec: Dictionary, base_pos: Vector3, jitter: float) -> Node:
	_zombie_counter += 1
	spec = spec.duplicate()
	spec["name"] = "Z%d" % _zombie_counter
	spec["seed"] = randi()
	var z: Node = main.make_zombie(spec)
	main.wire_zombie(z)
	main.zombies_root.add_child(z)
	z.global_position = base_pos + Vector3(randf_range(-jitter, jitter), 0.0, randf_range(-jitter, jitter))
	world.host_spawned(z, spec)
	return z


## Which peer the host credits for this zombie's last accepted hit (meta set by the hit-claim handler; host = 1).
## Host: the peer whose damage is being applied right now. A client's accepted hit claim sets it for the duration
## of take_damage (hit / died fire synchronously inside it); anything else on the host is the host's own damage.
## (DoT ticks from a client's burn / rot are credited to the host in A; phase B maps the status source avatar.)
func last_hitter(_zombie: Node = null) -> int:
	return _claim_peer if _claim_peer > 0 else local_peer_id()


func _last_hit_crit() -> bool:
	return _claim_peer > 0 and _claim_crit


## Host-authoritative points: credit, then replicate the new total to everyone.
func award_points(peer_id: int, amount: int, reason: String) -> void:
	if not is_host():
		return
	_points[peer_id] = int(_points.get(peer_id, 0)) + amount
	if is_networked():
		_rpc_points.rpc(peer_id, amount, int(_points[peer_id]), reason)
	else:
		_apply_points(peer_id, amount, int(_points[peer_id]), reason)


@rpc("authority", "call_local", "reliable")
func _rpc_points(peer_id: int, amount: int, total: int, reason: String) -> void:
	_apply_points(peer_id, amount, total, reason)


func _apply_points(peer_id: int, amount: int, total: int, reason: String) -> void:
	_points[peer_id] = total
	points_changed.emit(peer_id, total)
	if peer_id == local_peer_id():
		var p := get_tree().get_first_node_in_group("player")
		if p and amount < 0 and p.has_method("spend_points"):
			p.spend_points(-amount)
		elif p and amount > 0 and reason == "refund": # M13: give back a charge; not "earned", no points_gained
			p.points += amount
			p.points_changed.emit(p.points)
		elif p and amount > 0 and p.has_method("add_points"):
			p.add_points(amount, reason) # local wallet mirrors the host total; skills see points_gained


func get_points(peer_id: int) -> int:
	return int(_points.get(peer_id, 0))


## M5 (host): points for an accepted hit.
func on_zombie_hit_points(zombie: Node, amount: int) -> void:
	var v := NetConfig.points("per_hit") if amount > 0 else 0
	award_points(last_hitter(zombie), v, "hit")


## M5/M6 (host): kill bonus to the killer, Gravemark on the killer's own machine, shared drops, callout facts.
func on_zombie_killed(main: Node, zombie: Node, round_number: int, pay: int) -> void:
	var peer := last_hitter(zombie)
	var local := peer == local_peer_id()
	var is_boss := zombie.has_meta("is_boss") and bool(zombie.get_meta("is_boss"))
	var mult := float(main.player.mod_stat("points_kill_mult", 1.0)) if local else float(_peer_stat(peer, "points_kill_mult", 1.0))
	var base := pay if is_boss or pay != int(main.get("points_per_kill")) else NetConfig.points("kill_bonus")
	award_points(peer, int(round(base * mult)), "kill")
	if local:
		ArmoryScr.on_zombie_died(zombie, round_number)
	else:
		_rpc_kill_credit.rpc_id(peer, str(zombie.name), round_number)
	var drop_add := float(main.player.mod_stat("drop_chance_add", 0.0)) if local else float(_peer_stat(peer, "drop_chance_add", 0.0))
	for item in GearDB.roll_table("zombie", round_number, drop_add):
		main.spawn_pickup(item, (zombie as Node3D).global_position)
	if not local: # the host's own kills reach Audi-0's CalloutDriver through GameEvents (bind_local_player)
		report_kill(peer, _last_hit_crit(), is_boss)


## Killer's machine: award its own Gravemark from its puppet of the zombie (host never writes client saves).
@rpc("authority", "call_remote", "reliable")
func _rpc_kill_credit(zombie_name: String, round_number: int) -> void:
	var scene := get_tree().current_scene
	var z := scene.find_child(zombie_name, true, false) if scene else null
	if z:
		ArmoryScr.on_zombie_died(z, round_number)


## Per-peer stat mods the host needs for points / drops (phase B: sent by each client's link).
func _peer_stat(peer_id: int, stat: String, fallback: float) -> float:
	return float(_party.get(peer_id, {}).get("mods", {}).get(stat, fallback))


## M6 (host): shared first-grab world drop. Phase B replicates it through the PickupSpawner and returns true;
## until then the host spawns it locally (main continues with the old path).
func spawn_pickup(_main: Node, item: Item, pos: Vector3, chime: bool) -> bool:
	return world.host_drop(item, pos, chime)


## M7 (host): round state for every peer.
func on_round_started(n: int, enemies: int) -> void:
	if not is_networked() or not is_host():
		return
	_offers_closed.clear()
	_offers_open = false
	_rpc_round_state.rpc(n, "combat", enemies)
	match_players.on_round_started()


func on_round_cleared(n: int) -> void:
	if not is_networked() or not is_host():
		return
	_offers_closed.clear()
	_offers_since = Time.get_ticks_msec()
	_offers_open = _match != null and is_instance_valid(_match) and bool(_match.get("field_cards_enabled")) and n >= 1
	_rpc_round_state.rpc(n, "break", 0)


@rpc("authority", "call_local", "reliable")
func _rpc_round_state(n: int, phase: String, enemies: int) -> void:
	current_round = n
	round_phase = phase
	world.client_round_state(n, phase, enemies)
	round_state_changed.emit(n, phase, enemies)


## M8: this player's Field Card pick is done.
func report_offer_closed() -> void:
	if not is_networked():
		return
	if is_host():
		_offers_closed[1] = true
	else:
		_rpc_offer_closed.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_offer_closed() -> void:
	if is_host():
		_offers_closed[multiplayer.get_remote_sender_id()] = true


## M8 (host): true when every player closed their offer, or offers.wait_for_all_s ran out. Solo: always true.
func all_offers_closed() -> bool:
	if not is_networked():
		return true
	if not _offers_open:
		return true # pre-round / mid-round / Field Cards off: nothing to wait for
	if Time.get_ticks_msec() - _offers_since > int(float(NetConfig.get_value("offers.wait_for_all_s", 30.0)) * 1000.0):
		return true
	for id in _party:
		if not _offers_closed.has(id):
			return false
	return true


## M9: true once the host declared game over (everyone down). Solo: false (main runs its own game over).
func match_over() -> bool:
	return _match_over


## M9: the local player hit 0 HP in co-op. Phase B: downed + bleed-out + revive (data/net.json downed.*).
## Until then: behave like solo for this player (game over screen) so nothing hangs.
func report_local_down(_main: Node) -> void:
	match_players.report_local_down()


## Everyone is downed or dead (NetPlayers, from the host): the real game over on this machine.
func on_all_down() -> void:
	_match_over = true
	if _match and is_instance_valid(_match) and _match.has_method("_on_player_died"):
		_match._on_player_died()


## Host: a zombie hit a remote player's avatar.
func avatar_damaged(avatar: Node, amount: float, attacker: Node) -> void:
	match_players.avatar_damaged(avatar, amount, attacker)


## Spend this player's points through the host (doors, wall buys, boxes). Result: world.spend_result.
func request_spend(amount: int, reason: String) -> void:
	world.request_spend(amount, reason)


func _reset_match_state() -> void:
	_zombie_counter = 0
	_points.clear()
	_offers_closed.clear()
	_offers_since = 0.0
	_offers_open = false
	_match_over = false
	current_round = 0
	round_phase = "pre"

# ------------------------------------------------------------------ zombie seam (enemy.gd hooks E1-E5, patches/enemy_hooks_E1-E5.patch)

## E4: seeded RNG for a zombie's model pick / size variety when it came from a co-op spawn spec (meta net_seed);
## null otherwise, so solo keeps using the global RNG exactly as before.
func rng_for(enemy: Node) -> RandomNumberGenerator:
	if enemy == null or not enemy.has_meta("net_seed"):
		return null
	var r := RandomNumberGenerator.new()
	r.seed = int(enemy.get_meta("net_seed"))
	return r


## E2: a client's puppet zombie. No AI / nav / attacks: the synchronizer moves it; we pick the animation from its
## movement and play the death visual once when the replicated _dead flag flips.
func zombie_puppet_tick(enemy: Node, delta: float) -> void:
	var pos: Vector3 = (enemy as Node3D).global_position
	var last: Vector3 = enemy.get_meta("net_last_pos", pos)
	enemy.set_meta("net_last_pos", pos)
	if bool(enemy.get("_dead")):
		if not enemy.has_meta("net_death_shown"):
			enemy.set_meta("net_death_shown", true)
			if enemy.has_method("play_death_visual"):
				enemy.play_death_visual()
		return
	var spd := Vector2(pos.x - last.x, pos.z - last.z).length() / maxf(delta, 0.0001)
	var anim_key := "idle"
	if spd > 0.2:
		anim_key = "run" if float(enemy.get("speed")) > 4.2 else "walk"
	var forced := str(enemy.get_meta("net_anim", ""))
	if forced != "":
		anim_key = forced
	if enemy.has_method("_play"):
		enemy._play(anim_key)


## E3 (client puppet): send the damage claim to the host; return a predicted kill so local on-kill skills fire.
## The host's verdict wins (its zombie dies or not; the synchronizer shows the truth).
func forward_zombie_damage(enemy: Node, amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, _source: Node = null) -> bool:
	if enemy == null or bool(enemy.get("_dead")) or amount <= 0.0:
		return false
	var mult: float = enemy.damage_taken_mult() if enemy.has_method("damage_taken_mult") else 1.0
	var predicted := float(enemy.get("health")) - amount * mult <= 0.0
	if is_networked() and not is_host():
		_rpc_hit_claim.rpc_id(1, str(enemy.name), amount, hit_pos, crit)
	return predicted


## E3 (client puppet): statuses from skills (burn / slow / mark / rot) go to the host too. `source` is not sent.
func forward_zombie_status(enemy: Node, id: String, p: Dictionary) -> void:
	if enemy == null or not is_networked() or is_host():
		return
	var clean := {}
	for k in ["dur", "amp", "dps"]:
		if p.has(k):
			clean[k] = float(p[k])
	_rpc_status_claim.rpc_id(1, str(enemy.name), id, clean)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hit_claim(zombie_name: String, amount: float, hit_pos: Vector3, crit: bool) -> void:
	if is_host():
		handle_hit_claim(multiplayer.get_remote_sender_id(), zombie_name, amount, hit_pos, crit)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_status_claim(zombie_name: String, id: String, p: Dictionary) -> void:
	if not is_host():
		return
	var z := _find_zombie(zombie_name)
	if z and not bool(z.get("_dead")) and id in ["burn", "slow", "mark", "rot"]:
		p["source"] = _avatar_for(multiplayer.get_remote_sender_id())
		z.apply_status(id, p)


## Host: validate + apply a hit claim. Returns true if it was applied. (Phase B adds range / fire-rate checks
## against the shooter's avatar and weapon.)
func handle_hit_claim(sender: int, zombie_name: String, amount: float, hit_pos: Vector3, crit: bool) -> bool:
	if not _party.has(sender) and is_networked():
		return false
	if is_nan(amount) or is_inf(amount) or amount <= 0.0:
		return false
	var z := _find_zombie(zombie_name)
	if z == null or bool(z.get("_dead")):
		return false
	var cap := float(NetConfig.get_value("validation.max_hit_damage", 5000.0))
	_claim_peer = sender
	_claim_crit = crit
	z.take_damage(minf(amount, cap), hit_pos, crit, _avatar_for(sender))
	_claim_peer = 0
	_claim_crit = false
	return true


var _claim_peer := 0
var _claim_crit := false


func _find_zombie(zombie_name: String) -> Node:
	var scene := get_tree().current_scene if is_inside_tree() else null
	var root_z: Node = _match.get("zombies_root") if _match else (scene.get_node_or_null("Zombies") if scene else null)
	return root_z.get_node_or_null(NodePath(zombie_name)) if root_z else null


## The RemoteAvatar standing in for a peer on this machine (phase B), or null.
func _avatar_for(peer_id: int) -> Node:
	if match_players and match_players.avatars.has(peer_id):
		return match_players.avatars[peer_id]
	for a in get_tree().get_nodes_in_group("net_avatar"):
		if int(a.get("peer_id")) == peer_id:
			return a
	return null

# ------------------------------------------------------------------ teammate health (party entries hp / max_hp)
var _hp_t := 0.0
var _hp_sent := Vector2i(-1, -1)


## Every peer in a match: sample the local player's health at most every 0.2 s and report it when it changed.
func _hp_tick(delta: float) -> void:
	if state != State.IN_MATCH or _match == null or not is_instance_valid(_match):
		return
	_hp_t -= delta
	if _hp_t > 0.0:
		return
	_hp_t = 1.0 / maxf(float(NetConfig.get_value("tick.teammate_hp_hz", 5.0)), 0.5)
	var pl = _match.get("player")
	if pl == null or not is_instance_valid(pl):
		return
	var v := Vector2i(int(pl.get("health")), int(pl.get("max_health")))
	if v == _hp_sent:
		return
	_hp_sent = v
	if is_host():
		_host_set_hp(1, v.x, v.y)
	else:
		_rpc_hp.rpc_id(1, v.x, v.y)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_hp(hp: int, max_hp: int) -> void:
	if is_host():
		_host_set_hp(multiplayer.get_remote_sender_id(), hp, max_hp)


func _host_set_hp(id: int, hp: int, max_hp: int) -> void:
	if not _party.has(id):
		return
	var mx := clampi(max_hp, 1, 100000)
	var h := clampi(hp, 0, mx)
	_party[id].hp = h
	_party[id].max_hp = mx
	_party[id].hp_frac = hp_frac_of(h, mx)
	_rpc_hp_update.rpc(id, h, mx)
	teammate_health_changed.emit(id, h, mx, hp_frac_of(h, mx))


@rpc("authority", "call_remote", "reliable")
func _rpc_hp_update(id: int, hp: int, max_hp: int) -> void:
	if _party.has(id):
		_party[id].hp = hp
		_party[id].max_hp = max_hp
		_party[id].hp_frac = hp_frac_of(hp, max_hp)
	teammate_health_changed.emit(id, hp, max_hp, hp_frac_of(hp, max_hp))


## Party entry / teammate_health_changed health as 0..1 (hp / max_hp, clamped; 0 when max_hp <= 0).
static func hp_frac_of(hp: int, max_hp: int) -> float:
	return clampf(float(hp) / float(max_hp), 0.0, 1.0) if max_hp > 0 else 0.0
