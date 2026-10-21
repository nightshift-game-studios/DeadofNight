class_name NetProjectiles
extends Node
## Thrown projectile + grenade sync (Netz phase 3b + grenades). Lives at /root/Net/Projectiles on every peer.
## Contract (Skillz, locked): ThrownProjectile (scripts/projectiles/thrown_projectile.gd), created only through
## ThrownProjectile.spawn(spec), spec = {type_id: StringName, variant: StringName, rarity: int, pos: Vector3,
## vel: Vector3, owner_id: int, seed: int}; types by type_id in data/projectiles.json; a client copy is
## visual-only (spec "visual_only" = true -> ThrownProjectile.is_visual_only).
##   * host: hook P1 at the end of spawn() calls NetGate.projectile_spawned(spec, p) -> host_spawned() gives the
##     projectile a net id and broadcasts the spec; every client spawns a visual-only copy under the same id.
##     Children (Rookery bomblets) are just more host spawn() calls, so each one replicates the same way.
##   * host gameplay moments (detonate, stick, bounce, orbs, ...): NetGate.projectile_event(p, kind, data) ->
##     every copy of that projectile gets net_event(kind, data). Node values in data (zombies, players, avatars) are
##     mapped to the matching node on each machine. What a kind means is the projectile script's business.
##   * a client's own throw: request_throw(spec) shows a visual copy at once and asks the host; the host checks it
##     (known type/variant, rarity matches the variant, near the thrower, sane speed, rate / grenade interval) and
##     spawns the real one. Its P1 broadcast skips the thrower, whose local copy is bound to the same net id.
##   * heals decided on the host (Leechbell orbs): NetGate.grant_heal(target, amount, reason) -> the owner's machine
##     heals its own player (NetPlayers.host_heal), like damage.
##   * the real grenades (Skillz 32dc31c): a "grenade" projectile carries a Grenade body (p.body) whose `effect`
##     signal (blast / stick / zap / split / pull_start / leech / bell_bounce / toll / frost / fire_patch ...) is
##     forwarded from the host copy as an event of that kind, so Skillz's code needs no event calls. Copies get
##     net_event on the projectile, else on its body. Rookery bomblets (grenade_bomblet) and Leechbell orbs
##     (heal_orb) are host spawn() calls of their own, so they replicate like any projectile ("j:<net id>" refs).
## Nothing here knows a type id or variant: anything registered in data/projectiles.json syncs.
## owner_id is an instance id, so it never goes over the wire as is: it becomes owner_z (zombie name) or owner_peer
## (net peer) and is mapped back to the local puppet / player / avatar on arrival.

signal projectile_rx(spec: Dictionary) ## client: a host projectile's visual copy was spawned here
signal event_rx(net_id: int, kind: String, data: Dictionary) ## client: a host projectile event reached its copy
signal throw_refused(peer_id: int, reason: String) ## host: a client throw was rejected (logged, never a kick)
signal throw_dropped(req: int, reason: String) ## client: the host refused our throw; its local copy was removed

var script_path := "res://scripts/projectiles/thrown_projectile.gd" ## tests swap in a fake
var net: Node
var stats := {"tx": 0, "rx": 0, "throw_req": 0, "throw_ok": 0, "throw_refused": 0, "ev_tx": 0, "ev_rx": 0, "ev_lost": 0, "fx_fwd": 0, "dropped": 0}
var _thrower := 0 ## host: the peer whose request is being spawned right now (its P1 broadcast skips it)
var _thrower_req := 0 ## host: that request's token (bound to the new net id on the thrower)
var _throw_t: Dictionary = {} ## host: peer -> [msec of recent throws]
var _grenade_t: Dictionary = {} ## host: peer -> msec of the last throw whose type has a cooldown
var _next_id := 0 ## host: projectile net ids
var _by_id: Dictionary = {} ## every peer: net id -> projectile (weak: freed ones are skipped)
var _req_seq := 0 ## client: throw request tokens
var _pending_req: Dictionary = {} ## client: token -> its local visual copy, until the host binds a net id
var _script: Script = null


func _ready() -> void:
	net = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS
	if net.has_signal("returned_to_lobby"):
		net.returned_to_lobby.connect(clear)


func clear() -> void:
	_by_id.clear()
	_pending_req.clear()
	_throw_t.clear()
	_grenade_t.clear()
	_next_id = 0


func proj_script() -> Script:
	if _script == null and ResourceLoader.exists(script_path):
		_script = load(script_path)
	return _script


func available() -> bool:
	return proj_script() != null


func _cfg(key: String, fallback: float) -> float:
	return float(NetConfig.get_value("projectiles." + key, fallback))


func _main() -> Node:
	var m = net.get("_match")
	return m if m and is_instance_valid(m) else null


func projectile(net_id: int) -> Node:
	var p = _by_id.get(net_id)
	return p if p != null and is_instance_valid(p) else null


func _register(net_id: int, p: Node) -> void:
	if p == null or net_id <= 0:
		return
	p.set_meta("net_id", net_id)
	_by_id[net_id] = p
	if _by_id.size() > 256: # drop freed ones now and then
		for k in _by_id.keys():
			if not is_instance_valid(_by_id[k]):
				_by_id.erase(k)


# ------------------------------------------------------------------ node <-> wire mapping
## A node -> "z:<zombie name>" / "p:<peer>" / "j:<projectile net id>" / "" (not mappable).
func node_tx(n: Object) -> String:
	if not (n is Node) or not is_instance_valid(n):
		return ""
	var node := n as Node
	if node.has_meta("net_id") and int(node.get_meta("net_id")) > 0:
		return "j:%d" % int(node.get_meta("net_id"))
	var m := _main()
	var zroot: Node = m.get("zombies_root") if m else null
	if zroot and node.get_parent() == zroot:
		return "z:" + str(node.name)
	if node.is_in_group("player"):
		return "p:%d" % net.local_peer_id()
	if node.get("peer_id") != null and node.is_in_group("net_avatar"):
		return "p:%d" % int(node.get("peer_id"))
	return ""


func node_rx(ref: String) -> Node:
	var m := _main()
	if m == null or ref.length() < 3:
		return null
	if ref.begins_with("z:"):
		var zroot: Node = m.get("zombies_root")
		var zn := ref.substr(2)
		return zroot.get_node_or_null(NodePath(zn)) if zroot and zn.is_valid_filename() else null
	if ref.begins_with("j:"):
		return projectile(int(ref.substr(2)))
	if ref.begins_with("p:"):
		var pid := int(ref.substr(2))
		return m.get("player") if pid == net.local_peer_id() else net.match_players.avatar(pid)
	return null


## Event / spec data -> plain Variants: Node values become {"@n": ref}, arrays of nodes likewise.
func data_tx(v: Variant) -> Variant:
	if v is Object:
		return {"@n": node_tx(v)}
	if v is Array:
		return (v as Array).map(func(e): return data_tx(e))
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = data_tx(v[k])
		return out
	return v


func data_rx(v: Variant) -> Variant:
	if v is Dictionary:
		if v.size() == 1 and v.has("@n"):
			return node_rx(str(v["@n"]))
		var out := {}
		for k in v:
			out[k] = data_rx(v[k])
		return out
	if v is Array:
		return (v as Array).map(func(e): return data_rx(e))
	return v


## Spec -> wire form: plain Variants, owner as a zombie name or a peer id.
func spec_tx(spec: Dictionary) -> Dictionary:
	var tx := {}
	for k in ["type_id", "variant", "rarity", "pos", "vel", "seed"]:
		if spec.has(k):
			tx[k] = spec[k]
	if spec.get("fuse") is float or spec.get("fuse") is int: # a per-spawn fuse (Rookery bomblet_delay from the grenade data)
		tx["fuse"] = float(spec.fuse)
	var oid := int(spec.get("owner_id", 0))
	var ref := node_tx(instance_from_id(oid) if oid != 0 else null)
	if ref.begins_with("z:"):
		tx["owner_z"] = ref.substr(2)
	elif ref.begins_with("p:"):
		tx["owner_peer"] = int(ref.substr(2))
	return tx


## Wire form -> spec for spawn(): types checked, owner mapped to this machine's node (0 if unknown here).
func spec_rx(tx: Dictionary) -> Dictionary:
	var spec := {
		"type_id": StringName(str(tx.get("type_id", ""))),
		"variant": StringName(str(tx.get("variant", ""))),
		"rarity": int(tx.get("rarity", 0)),
		"pos": tx.get("pos") if tx.get("pos") is Vector3 else Vector3.ZERO,
		"vel": tx.get("vel") if tx.get("vel") is Vector3 else Vector3.ZERO,
		"seed": int(tx.get("seed", 0)),
		"owner_id": 0,
	}
	if tx.get("fuse") is float:
		spec["fuse"] = clampf(float(tx.fuse), 0.0, 30.0)
	var owner: Node = null
	if tx.has("owner_z"):
		owner = node_rx("z:" + str(tx.owner_z))
	elif tx.has("owner_peer"):
		owner = node_rx("p:%d" % int(tx.owner_peer))
	if owner:
		spec.owner_id = owner.get_instance_id()
	return spec


# ------------------------------------------------------------------ host spawns (hook P1)
## P1 (host): the authoritative projectile `p` exists; every client gets a visual copy under a new net id. Solo /
## client / visual copies: nothing. Returns the net id (0 = not broadcast).
func host_spawned(spec: Dictionary, p: Node = null) -> int:
	if not net.is_networked() or not net.is_host() or bool(spec.get("visual_only", false)):
		return 0
	_next_id += 1
	var nid := _next_id
	_register(nid, p)
	_watch_body(p)
	if p and p.get("body") == null:
		_watch_body.call_deferred(p) # P1 ahead of the Grenade body (the first P1 line): hook it once spawn() returned
	var tx := spec_tx(spec)
	tx["net_id"] = nid
	stats.tx += 1
	if _thrower == 0:
		_rpc_projectile.rpc(tx)
	else:
		for pid in multiplayer.get_peers():
			if pid != _thrower:
				_rpc_projectile.rpc_id(pid, tx)
		_rpc_bind.rpc_id(_thrower, _thrower_req, nid)
	return nid


@rpc("authority", "call_remote", "reliable")
func _rpc_projectile(tx: Dictionary) -> void:
	receive_projectile(tx)


## Client: spawn the host's projectile as a visual-only copy (same spec, same seed, same flight).
func receive_projectile(tx: Dictionary) -> Node:
	var S := proj_script()
	if S == null or not (tx is Dictionary) or _main() == null: # still loading (late join): nothing to show yet
		return null
	var spec := spec_rx(tx)
	spec["visual_only"] = true
	var p: Node = S.spawn(spec)
	if p:
		_register(int(tx.get("net_id", 0)), p)
		stats.rx += 1
		projectile_rx.emit(spec)
	return p


## Thrower: the host spawned our request as `net_id`; our local copy answers to it from now on.
@rpc("authority", "call_remote", "reliable")
func _rpc_bind(req: int, net_id: int) -> void:
	bind_request(req, net_id)


func bind_request(req: int, net_id: int) -> void:
	var p = _pending_req.get(req)
	_pending_req.erase(req)
	if p != null and is_instance_valid(p):
		_register(net_id, p)


## Host: a projectile with a gameplay body (grenades: p.body, a Grenade) -> its `effect` signal goes to the copies.
func _watch_body(p: Node) -> void:
	var b = p.get("body") if p != null and is_instance_valid(p) else null
	if b is Node and is_instance_valid(b) and b.has_signal("effect") and not b.has_meta("net_fx"):
		b.set_meta("net_fx", true)
		b.connect("effect", func(what, info): _body_effect(p, str(what), info))


func _body_effect(p: Node, what: String, info: Variant) -> void:
	if p != null and is_instance_valid(p) and host_event(p, what, info if info is Dictionary else {}):
		stats.fx_fwd += 1


# ------------------------------------------------------------------ host projectile events
## Host gameplay moment on projectile `p` (Skillz's code, the authoritative copy only) -> every client copy runs
## p.net_event(kind, data). Solo / client / a projectile the host never broadcast: false (nothing to do).
func host_event(p: Node, kind: String, data: Dictionary = {}) -> bool:
	if p == null or not net.is_networked() or not net.is_host() or not p.has_meta("net_id"):
		return false
	stats.ev_tx += 1
	_rpc_event.rpc(int(p.get_meta("net_id")), kind, data_tx(data))
	return true


@rpc("authority", "call_remote", "reliable")
func _rpc_event(net_id: int, kind: String, data: Dictionary) -> void:
	receive_event(net_id, kind, data)


func receive_event(net_id: int, kind: String, data: Dictionary) -> bool:
	var p := projectile(net_id)
	if p == null or kind.length() > 32:
		stats.ev_lost += 1 # landed / freed here already, or never shown (late join): nothing to update
		return false
	stats.ev_rx += 1
	var d: Dictionary = data_rx(data)
	var b = p.get("body")
	if p.has_method("net_event"):
		p.net_event(kind, d)
	elif b is Node and is_instance_valid(b) and b.has_method("net_event"):
		b.net_event(kind, d)
	event_rx.emit(net_id, kind, d)
	return true


# ------------------------------------------------------------------ client throws (grenades)
## A variant's data rarity: the Rarity int, or its id ("rare", as in data/grenades.json).
func _rarity_int(v: Variant) -> int:
	return Rarity.IDS.find(str(v).to_lower()) if v is String or v is StringName else int(v)


## data/net.json projectiles.cooldown_types: player-thrown types on a cooldown (grenades) -> grenade_min_interval_s.
func _cooldown_type(type_id: StringName) -> bool:
	var lst = NetConfig.get_value("projectiles.cooldown_types", ["grenade"])
	return lst is Array and (lst as Array).has(str(type_id))


## Any peer's own throw. Solo / host: spawn() straight away (the host's P1 broadcasts it). Client: a visual copy now
## + a request to the host, which spawns the real one. Returns the local projectile (or null).
func request_throw(spec: Dictionary) -> Node:
	var S := proj_script()
	if S == null:
		return null
	if not net.is_networked() or net.is_host():
		return S.spawn(spec)
	var mine := spec.duplicate()
	mine["visual_only"] = true
	var p: Node = S.spawn(mine)
	_req_seq += 1
	if p:
		_pending_req[_req_seq] = p
	stats.throw_req += 1
	var tx := spec_tx(spec)
	tx["req"] = _req_seq
	_rpc_throw.rpc_id(1, tx)
	return p


@rpc("any_peer", "call_remote", "reliable")
func _rpc_throw(tx: Dictionary) -> void:
	if net.is_host():
		host_throw(multiplayer.get_remote_sender_id(), tx)


## Host: check a client's throw, then spawn the real projectile owned by that player's avatar. Reject + log (never
## kick): unknown type / variant, rarity not the variant's, too far from the thrower, too fast, too many per second,
## or a cooldown type (grenades) thrown again within grenade_min_interval_s.
func host_throw(peer_id: int, tx: Dictionary) -> String:
	var S := proj_script()
	var why := ""
	var spec := spec_rx(tx) if tx is Dictionary else {}
	var av: Node3D = net.match_players.avatar(peer_id)
	var def: Dictionary = S.type_def(spec.type_id, spec.variant) if S and not spec.is_empty() else {}
	var now := Time.get_ticks_msec()
	if S == null:
		why = "no_projectiles"
	elif def.is_empty():
		why = "unknown_type"
	elif spec.variant != &"" and def.get("variants") is Dictionary and not (def.variants as Dictionary).is_empty() and not (def.variants as Dictionary).has(str(spec.variant)):
		why = "unknown_variant"
	elif def.has("rarity") and _rarity_int(def.rarity) != int(spec.rarity):
		why = "wrong_rarity"
	elif int(spec.rarity) < 0 or int(spec.rarity) >= Rarity.IDS.size():
		why = "wrong_rarity"
	elif av == null:
		why = "no_avatar"
	elif (spec.pos as Vector3).distance_to(av.global_position) > _cfg("max_throw_dist", 4.0):
		why = "too_far"
	elif (spec.vel as Vector3).length() > _cfg("max_throw_speed", 45.0):
		why = "too_fast"
	elif _cooldown_type(spec.type_id) and now - int(_grenade_t.get(peer_id, -999999)) < int(_cfg("grenade_min_interval_s", 2.0) * 1000.0):
		why = "grenade_interval"
	else:
		var recent: Array = (_throw_t.get(peer_id, []) as Array).filter(func(t): return now - int(t) < 1000)
		if recent.size() >= int(_cfg("max_throws_per_s", 4.0)):
			why = "rate"
		else:
			recent.append(now)
		_throw_t[peer_id] = recent
	if why != "":
		stats.throw_refused += 1
		push_warning("NetProjectiles: refused a throw from peer %d (%s)" % [peer_id, why])
		throw_refused.emit(peer_id, why)
		if peer_id != net.local_peer_id() and multiplayer.has_multiplayer_peer() and int(tx.get("req", 0)) > 0:
			_rpc_throw_refused.rpc_id(peer_id, int(tx.get("req", 0)), why)
		return why
	if _cooldown_type(spec.type_id):
		_grenade_t[peer_id] = now
	spec.owner_id = av.get_instance_id()
	stats.throw_ok += 1
	_thrower = peer_id
	_thrower_req = int(tx.get("req", 0))
	S.spawn(spec) # P1 -> host_spawned (skips the thrower, binds its copy)
	_thrower = 0
	_thrower_req = 0
	return ""


## Thrower: the host refused our throw -> the local copy goes (it would have shown a grenade that never happened).
@rpc("authority", "call_remote", "reliable")
func _rpc_throw_refused(req: int, why: String) -> void:
	drop_request(req, why)


func drop_request(req: int, why: String) -> void:
	var p = _pending_req.get(req)
	_pending_req.erase(req)
	if p != null and is_instance_valid(p):
		p.queue_free()
	stats.dropped += 1
	throw_dropped.emit(req, why)
