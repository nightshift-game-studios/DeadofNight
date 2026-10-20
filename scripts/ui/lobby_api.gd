extends Node
## Co-op lobby API: thin factory + every Net name the UI uses, in one place (Gooey).
##
##   var net = preload("res://scripts/ui/lobby_api.gd").create(tree_node)
##
## create() returns Netz's real `Net` autoload (/root/Net, scripts/net/net.gd, contract /workspace/netz/DESIGN.md §2.1)
## when it exists, else this script's STUB (a Node added under /root as "LobbyStub"). The lobby / HUD only call through
## LobbyAPI.call_api(net, key, args) / LobbyAPI.sig(net, key, cb) / LobbyAPI.prop(net, key), so a renamed method,
## signal or party key is a one-line change below. NETZ_GAPS.md lists the stub-only extensions (EXT_*).

const REAL_SCRIPT := "res://scripts/net/net.gd"
const REAL_AUTOLOAD := "Net" ## /root/Net
const STUB_NAME := "LobbyStub"
const SettingsAutoload := preload("res://scripts/autoload/settings.gd") ## static validate_player_name (= Netz NetNames)

## §2.1 method names.
const METHODS := {
	"is_networked": "is_networked", "is_host": "is_host", "local_peer_id": "local_peer_id",
	"get_player_name": "get_player_name", "is_leader": "is_leader", "get_party": "get_party",
	"set_local_profile": "set_local_profile",
	"host_party": "host_party", "join_by_address": "join_by_address", "join_by_code": "join_by_code",
	"make_join_code": "make_join_code", "decode_join_code": "decode_join_code", "get_share_address": "get_share_address",
	"leave_party": "leave_party",
	"set_ready": "set_ready", "select_map": "select_map", "select_difficulty": "select_difficulty",
	"can_start": "can_start", "start_match": "start_match", "return_to_lobby": "return_to_lobby",
	# Netz net.gd extras (present in /workspace/netz/scripts/net/net.gd; optional: every call is has_method-guarded)
	"port": "port", "max_players": "max_players", "match_difficulty_id": "match_difficulty_id",
	"needs_name_prompt": "needs_name_prompt", "local_name": "local_name", "get_points": "get_points",
	"get_slot": "get_slot", "lan_ip": "lan_ip", "sanitize_name": "sanitize_name", "request_spend": "request_spend",
	"is_match_running": "is_match_running", "players": "players",
	# Netz cb5e52a (NET_HOOKS §9): kick, start block reason, one validator
	"kick": "kick", "start_block_reason": "start_block_reason", "not_ready_names": "not_ready_names",
	"validate_name": "validate_name", "is_valid_name": "is_valid_name",
}
## Net.match_players (NetPlayers, /root/Net/Players) and Net.world (NetWorld, /root/Net/World): downed / revive + spends.
const PLAYERS_PROP := "match_players"
const PLAYERS_NODE := "Players"
const WORLD_PROP := "world"
const WORLD_NODE := "World"
const PLAYERS_METHODS := {"life_of": "life_of", "set_revive_hold": "set_revive_hold"}
const PLAYERS_SIGNALS := {"life_changed": "life_changed", "revive_changed": "revive_changed", "all_down": "all_down"}
const WORLD_SIGNALS := {"spend_result": "spend_result", "door_refused": "door_refused"}
## NetPlayers life states.
const LIFE_ALIVE := "alive"
const LIFE_DOWNED := "downed"
const LIFE_DEAD := "dead"
## §2.1 properties (+ Netz: last_error, auto_change_scene).
const PROPS := {"state": "state", "lobby_map_id": "lobby_map_id", "lobby_difficulty_id": "lobby_difficulty_id",
	"DEFAULT_PORT": "DEFAULT_PORT", "MAX_PLAYERS": "MAX_PLAYERS", "last_error": "last_error",
	"auto_change_scene": "auto_change_scene"}
## §2.1 signals.
const SIGNALS := {
	"state_changed": "state_changed", "hosting_started": "hosting_started", "upnp_result": "upnp_result",
	"connected_to_party": "connected_to_party", "connection_failed": "connection_failed",
	"party_changed": "party_changed", "peer_joined": "peer_joined", "peer_left": "peer_left",
	"lobby_settings_changed": "lobby_settings_changed", "match_starting": "match_starting",
	"host_left": "host_left", "disconnected": "disconnected", "game_event": "game_event",
	# Netz net.gd extras
	"peer_rejected": "peer_rejected", # host: (peer_id, name, reason) a join was refused
	"returned_to_lobby": "returned_to_lobby", "match_started": "match_started",
	"profile_changed": "profile_changed", "points_changed": "points_changed", # (peer_id, total)
	"round_state_changed": "round_state_changed", # (round_number, phase pre|combat|break, enemies_left)
	"callout_received": "callout_received", # (event_id, player_name, is_local), every peer, before Callouts.announce
	"upnp_started": "upnp_started", # host_party is trying UPnP (deferred); upnp_result always follows ("skipped" when not tried)
	"teammate_health_changed": "teammate_health_changed", # (peer_id, hp, max_hp[, hp_frac]) in match, ~5 Hz on change
}
## get_party() entry keys. §2.1: peer_id, name, class_id, ready, is_leader, ping_ms, state (+ Netz slot).
## Optional (UI uses them when present; Netz doesn't send them): tint, hp, bleed_out_s, points.
const K_PEER := "peer_id"
const K_NAME := "name"
const K_CLASS := "class_id"
const K_READY := "ready"
const K_LEADER := "is_leader"
const K_PING := "ping_ms"
const K_STATE := "state"
const K_SLOT := "slot" ## Netz: party slot 0..3 (tint, spawn offset)
const K_POINTS := "points" ## optional: in-match points (Netz: get_points(peer) / points_changed)
const K_TINT := "tint" ## optional: Color or "#rrggbb"; UI falls back to slot_tints()[slot] (net.json avatar.tints)
const K_HP := "hp" ## Netz: int hp with K_MAX_HP (in match); the stub / hud.set_party may send a 0..1 fraction
const K_MAX_HP := "max_hp" ## Netz: int max health; hp_fraction() divides when present
const K_HP_FRAC := "hp_frac" ## Netz 78e0682: hp / max_hp (0..1); hp_fraction() prefers it
const K_BLEED := "bleed_out_s" ## optional: seconds left while downed
## Fallback route only: Net.game_event ids (DESIGN §3.2 candidates). The primary route is Net.match_players.
const EV_DOWNED := "player_downed"
const EV_REVIVED := "player_revived"
const EV_REVIVE_PROGRESS := "revive_progress"
## data/net.json downed.* fallbacks (NetConfig wins when scripts/net is installed).
const BLEED_FALLBACK_S := 30.0
const REVIVE_TIME_FALLBACK_S := 3.0
const REVIVE_RANGE_FALLBACK_M := 2.0
## Player states in party entries (strings; §6.5 HUD wording).
const P_ALIVE := "alive"
const P_DOWNED := "downed"
const P_SPECTATING := "spectating"
const P_DISCONNECTED := "disconnected"
const P_DEAD := "dead" ## NetPlayers: bled out, respawns at the next round
## Net.state values (§2.1 order).
enum { OFFLINE, HOSTING_LOBBY, JOINING, IN_LOBBY, IN_MATCH }
const STATE_NAMES := ["OFFLINE", "HOSTING_LOBBY", "JOINING", "IN_LOBBY", "IN_MATCH"]
const DEFAULT_PORT_FALLBACK := 7777
const MAX_PLAYERS_FALLBACK := 4
## Fallback slot tints (bone / olive / rust / steel family, readable on the dark panels).
const TINTS := [Color("#D9601F"), Color("#C9D12B"), Color("#1E9FC8"), Color("#C2307A")] ## = Netz avatar.tints
## connection_failed / disconnected / peer_left reasons -> player-facing text.
const REASON_TEXT := {
	"timeout": "No answer from the host. Check the code or IP, and that the host forwarded port 7777.",
	"unreachable": "Couldn't reach that address. Check the code or IP.",
	"bad_address": "That address isn't valid.",
	"bad_code": "That join code isn't valid.",
	"busy": "Already in a party. Leave it first.",
	"version_mismatch": "Version mismatch: you and the host need the same game build.",
	"party_full": "That party is full (4/4).",
	"in_progress": "Match in progress. Join when they're back in the lobby.",
	"invalid_code": "That join code isn't valid.",
	"kicked": "You were removed from the party by the host.",
	"host_left": "The host closed the party.",
	"left": "left the party",
	"lost": "lost connection",
	"disconnected": "lost connection",
}


# ================================================================== factory + helpers

## Tests: true = always the stub (UI suites park the real Net autoload; lobby_net_test covers the real one).
static var force_stub: bool = false


static func create(from: Node = null) -> Node:
	var tree := (from.get_tree() if from and from.is_inside_tree() else Engine.get_main_loop()) as SceneTree
	if tree == null:
		return null
	var r := tree.root
	if force_stub:
		if not r.has_node(STUB_NAME):
			var st: Node = load("res://scripts/ui/lobby_api.gd").new()
			st.name = STUB_NAME
			r.add_child(st)
		return r.get_node(STUB_NAME)
	if r.has_node(REAL_AUTOLOAD):
		return r.get_node(REAL_AUTOLOAD)
	if ResourceLoader.exists(REAL_SCRIPT):
		var s = load(REAL_SCRIPT)
		if s and s.can_instantiate():
			var n: Node = s.new()
			n.name = REAL_AUTOLOAD
			r.add_child(n)
			return n
	if r.has_node(STUB_NAME):
		return r.get_node(STUB_NAME)
	var stub: Node = load("res://scripts/ui/lobby_api.gd").new()
	stub.name = STUB_NAME
	r.add_child(stub)
	return stub


## The live API if one is already up (never creates a stub): HUD binding in a match.
static func existing(from: Node) -> Node:
	if from == null or not from.is_inside_tree():
		return null
	var r := from.get_tree().root
	if r.has_node(REAL_AUTOLOAD) and not force_stub:
		return r.get_node(REAL_AUTOLOAD)
	return r.get_node_or_null(STUB_NAME)


static func is_stub(net: Object) -> bool:
	return net != null and net.get_script() == load("res://scripts/ui/lobby_api.gd")


static func call_api(net: Object, key: String, args: Array = []):
	var m: String = METHODS.get(key, key)
	if net == null or not net.has_method(m):
		return null
	return net.callv(m, args)


static func prop(net: Object, key: String, fallback = null):
	if net == null:
		return fallback
	var v = net.get(PROPS.get(key, key))
	return fallback if v == null else v


static func sig(net: Object, key: String, cb: Callable) -> bool:
	var s: String = SIGNALS.get(key, key)
	if net and net.has_signal(s) and not net.is_connected(s, cb):
		net.connect(s, cb)
		return true
	return false


static func unsig(net: Object, key: String, cb: Callable) -> void:
	var s: String = SIGNALS.get(key, key)
	if net and net.has_signal(s) and net.is_connected(s, cb):
		net.disconnect(s, cb)


## Net.start_block_reason() codes -> START tooltip / reason line ("not_ready" adds not_ready_names()).
const START_BLOCK_TEXT := {
	"offline": "No party.",
	"not_leader": "Only the party leader can start.",
	"not_in_lobby": "Not in the lobby.",
	"no_map": "Pick a map first.",
	"not_ready": "Waiting on %s to ready up.",
}


static func start_block_text(code: String, names: Array = []) -> String:
	if code == "":
		return ""
	if code == "not_ready":
		return START_BLOCK_TEXT.not_ready % (", ".join(names) if not names.is_empty() else "everyone")
	return str(START_BLOCK_TEXT.get(code, "Can't start yet."))


## Party entry health as 0..1: Netz hp_frac (78e0682) when present, else int hp / max_hp, else a 0..1 hp (stub).
static func hp_fraction(e: Dictionary, fallback: float = 1.0) -> float:
	if e.has(K_HP_FRAC):
		return clampf(float(e[K_HP_FRAC]), 0.0, 1.0)
	if not e.has(K_HP):
		return fallback
	var mx := float(e.get(K_MAX_HP, 0))
	return clampf(float(e[K_HP]) / mx if mx > 0.0 else float(e[K_HP]), 0.0, 1.0)


static func reason_text(reason: String) -> String:
	return str(REASON_TEXT.get(reason, reason if reason != "" else "Connection lost."))


## Join-code prefix: Netz net.json join_code.prefix ("GC" since the Gravecrew rename); "DN" codes still decode.
const CODE_PREFIX_FALLBACK := "GC"
const LEGACY_PREFIX := "DN"
const NET_CONFIG := "res://scripts/net/net_config.gd"


static func _net_cfg(key: String, fallback):
	if ResourceLoader.exists(NET_CONFIG):
		var nc = load(NET_CONFIG)
		if nc:
			var v = nc.get_value(key, null)
			if v != null:
				return v
	return fallback


static func code_prefix() -> String:
	return str(_net_cfg("join_code.prefix", CODE_PREFIX_FALLBACK)).to_upper()


## Slot tints: Netz net.json avatar.tints (same colours as the 3P bodies), else TINTS.
static func slot_tints() -> Array:
	var out: Array = []
	var cfg = _net_cfg("avatar.tints", null)
	if cfg is Array:
		for c in cfg:
			if c is String and Color.html_is_valid(c):
				out.append(Color.html(c))
	return out if out.size() > 0 else TINTS


static func tint_of(entry: Dictionary, slot: int) -> Color:
	if entry.has(K_SLOT):
		slot = int(entry[K_SLOT])
	var t = entry.get(K_TINT)
	if t is Color:
		return t
	if t is String and Color.html_is_valid(t):
		return Color.html(t)
	var pal := slot_tints()
	return pal[posmod(slot, pal.size())]


## Difficulty the match will run: Netz match_difficulty_id() ("" lobby override = the map's own), else the stub field.
static func effective_difficulty(net: Object) -> String:
	if net and net.has_method("match_difficulty_id"):
		return str(net.match_difficulty_id())
	var d := str(prop(net, "lobby_difficulty_id", ""))
	if d != "" and Difficulty.is_valid(d):
		return d
	var m := str(prop(net, "lobby_map_id", ""))
	return Difficulty.for_map(m) if m != "" else ""


## True when Net itself changes to main.tscn on match_starting (Netz auto_change_scene); home must not do it too.
static func owns_scene_change(net: Object) -> bool:
	return net != null and not is_stub(net) and bool(prop(net, "auto_change_scene", false))


## Party state strings that mean "alive / playing" for the HUD (Netz uses lobby | loading | in_match).
static func is_alive_state(st: String) -> bool:
	return not (st in [P_DOWNED, P_SPECTATING, P_DISCONNECTED, P_DEAD])


## Net.match_players (NetPlayers) or the stub's; null when Net has none.
static func players_of(net: Object) -> Object:
	if net == null:
		return null
	var p = net.get(PLAYERS_PROP)
	if p is Object and is_instance_valid(p):
		return p
	return net.get_node_or_null(PLAYERS_NODE) if net is Node else null


## Net.world (NetWorld) or the stub's.
static func world_of(net: Object) -> Object:
	if net == null:
		return null
	var w = net.get(WORLD_PROP)
	if w is Object and is_instance_valid(w):
		return w
	return net.get_node_or_null(WORLD_NODE) if net is Node else null


static func psig(net: Object, key: String, cb: Callable) -> bool:
	var p := players_of(net)
	var s: String = PLAYERS_SIGNALS.get(key, key)
	if p and p.has_signal(s) and not p.is_connected(s, cb):
		p.connect(s, cb)
		return true
	return false


static func wsig(net: Object, key: String, cb: Callable) -> bool:
	var w := world_of(net)
	var s: String = WORLD_SIGNALS.get(key, key)
	if w and w.has_signal(s) and not w.is_connected(s, cb):
		w.connect(s, cb)
		return true
	return false


## NetPlayers.life_of(peer) ("alive" | "downed" | "dead"), "" when unknown / no Net.
static func life_of(net: Object, peer: int) -> String:
	var p := players_of(net)
	if p == null or not p.has_method(PLAYERS_METHODS.life_of):
		return ""
	var l = p.get("life")
	if l is Dictionary and not (l as Dictionary).has(peer):
		return ""
	return str(p.call(PLAYERS_METHODS.life_of, peer))


## data/net.json value through NetConfig (stub: its `cfg` overrides first).
static func net_value(net: Object, key: String, fallback):
	if net and is_stub(net):
		var c = net.get("cfg")
		if c is Dictionary and (c as Dictionary).has(key):
			return c[key]
	return _net_cfg(key, fallback)


static func bleed_out_s(net: Object) -> float:
	return float(net_value(net, "downed.bleed_out_s", BLEED_FALLBACK_S))


static func revive_time_s(net: Object) -> float:
	return maxf(float(net_value(net, "downed.revive_time_s", REVIVE_TIME_FALLBACK_S)), 0.01)


static func revive_range_m(net: Object) -> float:
	return float(net_value(net, "downed.revive_range_m", REVIVE_RANGE_FALLBACK_M))


## One validator (Netz NetNames = Settings.validate_player_name, byte-identical rules): {ok, name, reason}.
## (Named check_name: the stub half of this script has Net's own validate_name.)
static func check_name(net: Object, raw: String) -> Dictionary:
	if net and not is_stub(net) and net.has_method("validate_name"):
		var v = net.validate_name(raw)
		if v is Dictionary and v.has("ok"):
			return v
	return SettingsAutoload.validate_player_name(raw)


## Name store sync. Netz cb5e52a keeps ONE store (Settings.player_name; Net reads / writes it and follows
## Settings.changed), so this is a no-op there; it still bridges an older Net that kept user://net_profile.cfg. Returns true when a usable name now exists on both sides.
##  - Net has a name, Settings doesn't (or differs) -> Settings takes Net's (when it passes Settings' rules)
##  - Settings has a name, Net still needs one -> pushed to Net (no second prompt)
static func sync_names(settings: Node, net: Object) -> bool:
	if settings == null or not settings.has_method("has_player_name"):
		return false
	if net == null or is_stub(net) or not net.has_method("needs_name_prompt"):
		return settings.has_player_name()
	if not net.needs_name_prompt():
		var nn := str(net.local_name())
		if str(settings.player_name) != nn:
			var r: Dictionary = settings.validate_player_name(nn)
			if bool(r.ok):
				settings.set_player_name(str(r.name))
		return settings.has_player_name()
	if settings.has_player_name():
		return bool(net.set_local_profile(str(settings.player_name), ""))
	return false


## First-launch check: Net.needs_name_prompt() (after sync_names) when Net is installed, else no Settings name.
static func needs_name(settings: Node, net: Object) -> bool:
	var ok := sync_names(settings, net)
	if net and not is_stub(net) and net.has_method("needs_name_prompt"):
		return net.needs_name_prompt()
	return not ok


## Join box validation (UI side, before calling the API). Accepts a join code (DN-XXXXX-XXXXX or the 10 bare chars),
## an IPv4 "1.2.3.4[:port]" or a hostname "host.lan[:port]". -> {ok, kind: "code"|"address", address, port, code, reason}
static func validate_join_input(text: String, net: Object = null) -> Dictionary:
	var t := text.strip_edges()
	if t == "":
		return {"ok": false, "reason": "Enter a join code or the host's IP."}
	var port := DEFAULT_PORT_FALLBACK
	var up := t.to_upper().replace(" ", "")
	var bare := up.replace("-", "")
	var pre := ""
	for p in [code_prefix(), LEGACY_PREFIX]:
		if up.begins_with(p):
			pre = p
	if pre != "":
		bare = bare.substr(pre.length())
	var looks_code := pre != "" or (bare.length() == 10 and not t.contains(".") and not t.contains(":"))
	if looks_code:
		var d = call_api(net, "decode_join_code", [up]) if net else decode_code(up)
		if d is Dictionary and bool(d.get("ok", false)):
			return {"ok": true, "kind": "code", "code": up, "address": str(d.get("address", "")), "port": int(d.get("port", port))}
		return {"ok": false, "reason": "That join code isn't valid (it looks like %s-XXXXX-XXXXX)." % code_prefix()}
	var host := t
	if t.count(":") == 1:
		host = t.get_slice(":", 0)
		var ps := t.get_slice(":", 1)
		if not ps.is_valid_int() or int(ps) < 1 or int(ps) > 65535:
			return {"ok": false, "reason": "Port must be a number from 1 to 65535."}
		port = int(ps)
	elif t.count(":") > 1:
		return {"ok": false, "reason": "IPv6 isn't supported yet. Use an IPv4 address or a join code."}
	if _is_ipv4_shape(host):
		if not _is_ipv4(host):
			return {"ok": false, "reason": "That IP isn't valid (each part is 0-255)."}
		return {"ok": true, "kind": "address", "address": host, "port": port}
	var re := RegEx.create_from_string("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$")
	if host.length() <= 253 and re.search(host) and not host.is_valid_int():
		return {"ok": true, "kind": "address", "address": host, "port": port}
	return {"ok": false, "reason": "Enter a join code (%s-XXXXX-XXXXX) or an IP like 203.0.113.5:7777." % code_prefix()}


static func _is_ipv4_shape(s: String) -> bool:
	return RegEx.create_from_string("^[0-9.]+$").search(s) != null and s.contains(".")


static func _is_ipv4(s: String) -> bool:
	var parts := s.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if p == "" or p.length() > 3 or not p.is_valid_int() or int(p) > 255:
			return false
	return true


# ------------------------------------------------------------------ v1 join code (§4.3): IPv4 + port, Crockford base32

const CROCKFORD := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


static func encode_code(ip: String, port: int) -> String:
	if not _is_ipv4(ip):
		return ""
	var v := 0
	for p in ip.split("."):
		v = (v << 8) | int(p)
	v = (v << 16) | (port & 0xFFFF)
	var s := ""
	for i in 10:
		s = CROCKFORD[v & 31] + s
		v >>= 5
	return "%s-%s-%s" % [code_prefix(), s.substr(0, 5), s.substr(5, 5)]


static func decode_code(code: String) -> Dictionary:
	var c := code.strip_edges().to_upper().replace("-", "").replace(" ", "")
	for pre in [code_prefix(), LEGACY_PREFIX]:
		if c.length() == 10 + pre.length() and c.begins_with(pre):
			c = c.substr(pre.length())
			break
	c = c.replace("O", "0").replace("I", "1").replace("L", "1")
	if c.length() != 10:
		return {"ok": false}
	var v := 0
	for ch in c:
		var i := CROCKFORD.find(ch)
		if i < 0:
			return {"ok": false}
		v = (v << 5) | i
	var port := v & 0xFFFF
	var ipn := (v >> 16) & 0xFFFFFFFF
	if port == 0 or (v >> 48) != 0:
		return {"ok": false}
	var ip := "%d.%d.%d.%d" % [(ipn >> 24) & 255, (ipn >> 16) & 255, (ipn >> 8) & 255, ipn & 255]
	return {"ok": true, "address": ip, "port": port}


# ================================================================== STUB (stands in for Net until scripts/net lands)

signal state_changed(new_state: int)
signal hosting_started(share_address: String, join_code: String)
signal upnp_result(ok: bool, external_ip: String, message: String)
signal connected_to_party
signal connection_failed(reason: String)
signal party_changed(party: Array)
signal peer_joined(peer_id: int, name: String)
signal peer_left(peer_id: int, name: String, reason: String)
signal lobby_settings_changed(map_id: String, difficulty_id: String)
signal match_starting(map_id: String, difficulty_id: String)
signal host_left
signal disconnected(reason: String)
signal game_event(event_id: StringName, peer_id: int, data: Dictionary)
signal peer_rejected(peer_id: int, player_name: String, reason: String)
signal match_started
signal returned_to_lobby
signal profile_changed(player_name: String)
signal points_changed(peer_id: int, total: int)
signal round_state_changed(round_number: int, phase: String, enemies_left: int)
signal callout_received(event_id: String, player_name: String, is_local: bool)
signal upnp_started
signal teammate_health_changed(peer_id: int, hp: int, max_hp: int, hp_frac: float)


## Stub of Net.match_players (NetPlayers): life + revive signals, life_of, set_revive_hold.
class StubPlayers extends Node:
	signal life_changed(peer_id: int, state: String)
	signal revive_changed(target_peer: int, reviver_peer: int, active: bool)
	signal all_down
	var life: Dictionary = {}
	var avatars: Dictionary = {} ## peer -> Node3D (tests: revive prompt range)
	var holds: Array = [] ## [[target, holding], ...] set_revive_hold calls (tests)

	func life_of(peer_id: int) -> String:
		return str(life.get(peer_id, "alive"))

	func set_revive_hold(target_peer: int, holding: bool) -> void:
		holds.append([target_peer, holding])

	func sim_life(peer_id: int, st: String) -> void:
		life[peer_id] = st
		life_changed.emit(peer_id, st)


## Stub of Net.world (NetWorld): spend results + door refusals.
class StubWorld extends Node:
	signal spend_result(ok: bool, amount: int, reason: String)
	signal door_refused(door_id: String, reason: String)

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4

var state: int = OFFLINE
var lobby_map_id: String = ""
var lobby_difficulty_id: String = ""
## Stub knobs (tests / screenshots).
var auto_sim: bool = true ## fake the network: UPnP answers after upnp_delay, joins succeed after join_delay
var upnp_should_fail: bool = false
var upnp_delay: float = 1.5
var join_delay: float = 1.2
var fake_public_ip: String = "203.0.113.5"
var fake_lan_ip: String = "192.168.1.42"
var auto_change_scene: bool = false ## Netz changes scene itself; the stub leaves it to home.start_match
var last_error: String = ""
var networked_match: bool = false ## sim: true while a co-op match runs (HUD shows the party)
var cfg: Dictionary = {} ## data/net.json overrides for the UI (e.g. "downed.bleed_out_s"); see LobbyAPI.net_value
var match_players: StubPlayers
var world: StubWorld
var _points: Dictionary = {}
var _name_set: bool = false

var _party: Array = [] ## Array[Dictionary]
var _local_id: int = 1
var _name: String = ""
var _class_id: String = ""
var _port: int = DEFAULT_PORT
var _upnp_ok: bool = false
var _next_peer: int = 2
var _gen: int = 0 ## bumps on leave so late auto-sim timers are ignored


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_name = _settings_name()
	_name_set = _name != "Survivor"
	match_players = StubPlayers.new()
	match_players.name = PLAYERS_NODE
	add_child(match_players)
	world = StubWorld.new()
	world.name = WORLD_NODE
	add_child(world)


func _settings_name() -> String:
	var s := get_node_or_null("/root/Settings")
	return str(s.get("player_name")) if s and s.get("player_name") != null and str(s.get("player_name")) != "" else "Survivor"


func _set_state(s: int) -> void:
	if state == s:
		return
	state = s
	state_changed.emit(s)


func is_networked() -> bool:
	return networked_match or state in [HOSTING_LOBBY, JOINING, IN_LOBBY]


func is_host() -> bool:
	return state == OFFLINE or state == HOSTING_LOBBY or (_local_id == 1)


func local_peer_id() -> int:
	return _local_id


func get_player_name(peer_id: int) -> String:
	for e in _party:
		if int(e[K_PEER]) == peer_id:
			return str(e[K_NAME])
	return _name if peer_id == _local_id else ""


func is_leader(peer_id: int = -1) -> bool:
	if peer_id < 0:
		peer_id = _local_id
	if _party.is_empty():
		return peer_id == _local_id
	for e in _party:
		if int(e[K_PEER]) == peer_id:
			return bool(e[K_LEADER])
	return false


func players() -> Array:
	return []


func get_party() -> Array:
	var out := _party.duplicate(true)
	for i in out.size():
		if not out[i].has(K_SLOT):
			out[i][K_SLOT] = i
	return out


## Like Netz cb5e52a: an invalid name is refused (validate_name), not silently stripped.
func set_local_profile(n: String, class_id: String = "") -> bool:
	var v := validate_name(n)
	if not bool(v.ok):
		return false
	n = str(v.name)
	_name = n
	_name_set = true
	if class_id != "":
		_class_id = class_id
	for e in _party:
		if int(e[K_PEER]) == _local_id:
			e[K_NAME] = n
			e[K_CLASS] = _class_id
	profile_changed.emit(n)
	if not _party.is_empty():
		party_changed.emit(get_party())
	return true


func local_name() -> String:
	return _name


func needs_name_prompt() -> bool:
	return not _name_set


func validate_name(n: String) -> Dictionary:
	return SettingsAutoload.validate_player_name(n)


func is_valid_name(n: String) -> bool:
	return bool(validate_name(n).ok)


## Same rules as Netz net.gd sanitize_name (wire repair only).
## = NetNames.sanitize: drop disallowed characters, normalize, cut to 16; "" if nothing valid is left.
func sanitize_name(n: String) -> String:
	var out := ""
	var re := RegEx.create_from_string("^[A-Za-z0-9 _.\\-]+$")
	for ch in n:
		if re.search(ch) != null:
			out += ch
	var v := validate_name(out.substr(0, 64))
	var cut := str(v.name).substr(0, SettingsAutoload.NAME_MAX).strip_edges()
	return cut if is_valid_name(cut) else ""


func get_points(peer_id: int) -> int:
	return int(_points.get(peer_id, 0))


func request_spend(amount: int, reason: String) -> void:
	var ok := amount > 0 and get_points(_local_id) >= amount
	if ok:
		sim_points(_local_id, get_points(_local_id) - amount)
	world.spend_result.emit(ok, amount, reason)


func is_match_running() -> bool:
	return networked_match


func _entry(peer: int, n: String, leader: bool, ready: bool, ping: int) -> Dictionary:
	return {K_PEER: peer, K_NAME: n, K_CLASS: "", K_READY: ready, K_LEADER: leader, K_PING: ping, K_STATE: P_ALIVE,
		K_HP: 1.0}


func host_party(port: int = DEFAULT_PORT, try_upnp: bool = true) -> Error:
	if state != OFFLINE:
		return ERR_ALREADY_IN_USE
	_gen += 1
	_port = port
	_local_id = 1
	_name = _settings_name()
	_party = [_entry(1, _name, true, true, 0)] # like Netz: the leader's START is its ready
	lobby_map_id = MapRegistry.current_id() if MapRegistry.is_valid(MapRegistry.current_id()) else "arena"
	lobby_difficulty_id = Difficulty.for_map(lobby_map_id)
	_set_state(HOSTING_LOBBY)
	hosting_started.emit(get_share_address(), make_join_code())
	party_changed.emit(get_party())
	lobby_settings_changed.emit(lobby_map_id, lobby_difficulty_id)
	if try_upnp and auto_sim:
		var g := _gen
		upnp_started.emit.call_deferred()
		get_tree().create_timer(upnp_delay, true).timeout.connect(func():
			if g == _gen and state == HOSTING_LOBBY:
				sim_upnp(not upnp_should_fail))
	elif not try_upnp: # Netz: upnp_result always answers; "skipped" + upnp_info.why when not tried
		upnp_info = {"ok": false, "external_ip": "", "status": "skipped", "why": "not_requested", "double_nat": false}
		upnp_result.emit.call_deferred(false, "", "skipped")
	return OK


func join_by_address(address: String, port: int = DEFAULT_PORT) -> Error:
	if state != OFFLINE:
		return ERR_ALREADY_IN_USE
	if address.strip_edges() == "":
		return ERR_INVALID_PARAMETER
	_gen += 1
	_set_state(JOINING)
	if auto_sim:
		var g := _gen
		get_tree().create_timer(join_delay, true).timeout.connect(func():
			if g == _gen and state == JOINING:
				sim_connect_ok())
	return OK


func join_by_code(code: String) -> Error:
	var d := decode_join_code(code)
	if not d.ok:
		last_error = "bad_code"
		connection_failed.emit("bad_code")
		return ERR_INVALID_DATA
	return join_by_address(str(d.address), int(d.port))


func make_join_code() -> String:
	return encode_code(fake_public_ip, _port) # v1: public IPv4 + port (§4.3)


func decode_join_code(code: String) -> Dictionary:
	return decode_code(code)


func get_share_address() -> String:
	return "%s:%d" % [fake_public_ip if _upnp_ok else fake_lan_ip, _port]


func leave_party() -> void:
	var was := state
	_gen += 1
	_party.clear()
	_points.clear()
	if match_players:
		match_players.life.clear()
	_upnp_ok = false
	networked_match = false
	_set_state(OFFLINE)
	party_changed.emit([])
	if was != OFFLINE:
		disconnected.emit("left") # Netz does the same; the lobby ignores "left"


func set_ready(r: bool) -> void:
	for e in _party:
		if int(e[K_PEER]) == _local_id:
			e[K_READY] = r
	party_changed.emit(get_party())


func select_map(map_id: String) -> bool:
	if not is_leader() or not MapRegistry.is_valid(map_id):
		return false
	lobby_map_id = map_id
	lobby_difficulty_id = Difficulty.for_map(map_id)
	lobby_settings_changed.emit(lobby_map_id, lobby_difficulty_id)
	return true


func select_difficulty(difficulty_id: String) -> bool:
	if not is_leader() or not Difficulty.is_valid(difficulty_id):
		return false
	lobby_difficulty_id = difficulty_id
	lobby_settings_changed.emit(lobby_map_id, lobby_difficulty_id)
	return true


func start_block_reason() -> String:
	if state == OFFLINE or _party.is_empty():
		return "offline"
	if not is_leader():
		return "not_leader"
	if state != HOSTING_LOBBY and state != IN_LOBBY:
		return "not_in_lobby"
	if not MapRegistry.is_valid(lobby_map_id):
		return "no_map"
	return "not_ready" if not not_ready_names().is_empty() else ""


## Like Netz: the leader's START is its ready, so only the others are listed.
func not_ready_names() -> Array:
	var out: Array = []
	for e in _party:
		if int(e[K_PEER]) != _local_id and not bool(e[K_READY]):
			out.append(str(e[K_NAME]))
	return out


func can_start() -> bool:
	return start_block_reason() == ""


## Host only (Netz kick): the peer gets disconnected(reason); everyone else peer_left(id, name, reason).
func kick(peer_id: int, reason: String = "kicked") -> bool:
	if _local_id != 1 or peer_id == _local_id or _party.filter(func(e): return int(e[K_PEER]) == peer_id).is_empty():
		return false
	sim_peer_left(peer_id, reason)
	return true


func start_match() -> bool:
	if not can_start():
		return false
	_set_state(IN_MATCH)
	networked_match = _party.size() > 1
	match_starting.emit(lobby_map_id, lobby_difficulty_id)
	return true


func return_to_lobby() -> bool:
	if not networked_match and state != IN_MATCH:
		return false
	networked_match = false
	match_players.life.clear()
	_points.clear()
	for e in _party: # like Net.IN_MATCH_KEYS
		for k in [K_HP, K_MAX_HP, K_HP_FRAC]:
			e.erase(k)
	_set_state(HOSTING_LOBBY if _local_id == 1 else IN_LOBBY)
	returned_to_lobby.emit()
	party_changed.emit(get_party())
	return true


# ------------------------------------------------------------------ sim helpers (tests drive these; Net has none)

var upnp_info: Dictionary = {} ## like Net.upnp_info: {ok, external_ip, ip_class, message, double_nat}


func sim_upnp(ok: bool, double_nat: bool = false) -> void:
	_upnp_ok = ok and not double_nat
	if double_nat: # Netz upnp_helper: a private / CGNAT "external" address -> ok false + double_nat + message
		var ext := "100.72.1.9"
		var msg := "Your router reports %s as its internet address: double NAT / carrier-grade NAT. Friends can't reach you directly; use a VPN (Tailscale) for now." % ext
		upnp_info = {"ok": false, "external_ip": ext, "ip_class": "cgnat", "message": msg, "double_nat": true}
		upnp_result.emit(false, ext, msg)
	elif ok:
		upnp_info = {"ok": true, "external_ip": fake_public_ip, "ip_class": "public", "double_nat": false}
		upnp_result.emit(true, fake_public_ip, "Port %d opened on your router." % _port)
	else:
		upnp_info = {"ok": false, "external_ip": "", "ip_class": "invalid", "double_nat": false}
		upnp_result.emit(false, "", "Router didn't answer UPnP (no gateway found).")
	hosting_started.emit(get_share_address(), make_join_code())


func sim_connect_ok(host_name: String = "Jason", others: Array = []) -> void:
	_local_id = 1000 + randi() % 8000
	_party = [_entry(1, host_name, true, true, 0)]
	for o in others:
		_party.append(_entry(_next_peer, str(o), false, false, 40 + _next_peer * 7))
		_next_peer += 1
	_party.append(_entry(_local_id, _settings_name(), false, false, 38))
	lobby_map_id = "rustwell_foundry"
	lobby_difficulty_id = "medium"
	_set_state(IN_LOBBY)
	connected_to_party.emit()
	party_changed.emit(get_party())
	lobby_settings_changed.emit(lobby_map_id, lobby_difficulty_id)


func sim_connect_fail(reason: String) -> void:
	_gen += 1
	_set_state(OFFLINE)
	connection_failed.emit(reason)


func sim_peer_join(n: String, ready: bool = false, ping: int = 55) -> int:
	var id := _next_peer
	_next_peer += 1
	_party.append(_entry(id, n, false, ready, ping))
	peer_joined.emit(id, n)
	party_changed.emit(get_party())
	return id


func sim_peer_ready(peer_id: int, r: bool) -> void:
	for e in _party:
		if int(e[K_PEER]) == peer_id:
			e[K_READY] = r
	party_changed.emit(get_party())


func sim_peer_left(peer_id: int, reason: String = "left") -> void:
	var n := get_player_name(peer_id)
	_party = _party.filter(func(e): return int(e[K_PEER]) != peer_id)
	peer_left.emit(peer_id, n, reason)
	party_changed.emit(get_party())


func sim_kicked(reason: String = "kicked") -> void:
	_gen += 1
	_party.clear()
	_set_state(OFFLINE)
	disconnected.emit(reason)


## Like Netz _rpc_hp_update: entries carry int hp / max_hp; party_changed is NOT re-emitted.
func sim_teammate_hp(peer_id: int, hp: int, max_hp: int = 100) -> void:
	for e in _party:
		if int(e[K_PEER]) == peer_id:
			e[K_HP] = hp
			e[K_MAX_HP] = max_hp
			e[K_HP_FRAC] = clampf(float(hp) / float(max_hp), 0.0, 1.0) if max_hp > 0 else 0.0
	teammate_health_changed.emit(peer_id, hp, max_hp, clampf(float(hp) / float(max_hp), 0.0, 1.0) if max_hp > 0 else 0.0)


func sim_host_left() -> void:
	_gen += 1
	_party.clear()
	_set_state(OFFLINE)
	host_left.emit()
	disconnected.emit("host_left")


func sim_lobby_settings(map_id: String, difficulty_id: String) -> void:
	lobby_map_id = map_id
	lobby_difficulty_id = difficulty_id
	lobby_settings_changed.emit(map_id, difficulty_id)


## In-match party (HUD): peers [{peer_id?, name, hp, state, tint?}] beside the local player.
func sim_match_party(entries: Array) -> void:
	networked_match = true
	_set_state(IN_MATCH)
	_party = [_entry(_local_id, _settings_name(), _local_id == 1, true, 0)]
	for e in entries:
		var d: Dictionary = _entry(int(e.get(K_PEER, _next_peer)), str(e.get(K_NAME, "Mate")), false, true, int(e.get(K_PING, 50)))
		if not e.has(K_PEER):
			_next_peer += 1
		d[K_HP] = float(e.get(K_HP, 1.0))
		d[K_STATE] = str(e.get(K_STATE, P_ALIVE))
		if e.has(K_TINT):
			d[K_TINT] = e[K_TINT]
		_party.append(d)
	party_changed.emit(get_party())


func sim_party_hp(peer_id: int, hp: float, st: String = "") -> void:
	for e in _party:
		if int(e[K_PEER]) == peer_id:
			e[K_HP] = hp
			if st != "":
				e[K_STATE] = st
	party_changed.emit(get_party())


## Like NetPlayers._rpc_life(peer, "downed"): bleed-out length comes from cfg / net.json downed.bleed_out_s.
func sim_downed(peer_id: int, bleed_out_s: float = -1.0) -> void:
	if bleed_out_s >= 0.0:
		cfg["downed.bleed_out_s"] = bleed_out_s
	match_players.sim_life(peer_id, LIFE_DOWNED)


func sim_revived(peer_id: int) -> void:
	match_players.sim_life(peer_id, LIFE_ALIVE)


func sim_dead(peer_id: int) -> void:
	match_players.sim_life(peer_id, LIFE_DEAD)


## Like NetPlayers._rpc_reviving(target, reviver, active): the UI animates progress over downed.revive_time_s.
func sim_revive(target_peer: int, reviver_peer: int, active: bool) -> void:
	match_players.revive_changed.emit(target_peer, reviver_peer, active)


func sim_all_down() -> void:
	match_players.all_down.emit()


func sim_points(peer_id: int, total: int) -> void:
	_points[peer_id] = total
	points_changed.emit(peer_id, total)


func sim_round_state(n: int, phase: String, enemies: int) -> void:
	round_state_changed.emit(n, phase, enemies)


## Like Net._announce: callout_received first, then /root/Callouts.announce (so callout_played may follow).
func sim_callout(event_id: String, peer_id: int) -> void:
	var n := get_player_name(peer_id)
	var loc := peer_id == _local_id
	callout_received.emit(event_id, n, loc)
	var c := get_node_or_null("/root/Callouts")
	if c and c.has_method("announce"):
		c.announce(event_id, n, loc)


func sim_match_started() -> void:
	match_started.emit()


func sim_peer_rejected(n: String, reason: String) -> void:
	peer_rejected.emit(_next_peer, n, reason)


func sim_end_match() -> void:
	networked_match = false
	leave_party()
