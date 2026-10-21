class_name NetProjectiles
extends Node
## Thrown projectile + grenade sync (Netz phase 3b). Lives at /root/Net/Projectiles on every peer.
## Contract (Skillz, locked): ThrownProjectile (scripts/projectiles/thrown_projectile.gd), created only through
## ThrownProjectile.spawn(spec), spec = {type_id: StringName, variant: StringName, rarity: int, pos: Vector3,
## vel: Vector3, owner_id: int, seed: int}; types by type_id in data/projectiles.json; a client copy is
## visual-only (spec "visual_only" = true -> ThrownProjectile.is_visual_only).
##   * host: hook P1 in spawn() (MAIN_HOOKS §22) calls NetGate.projectile_spawned(spec) after the authoritative copy
##     exists -> host_spawned() broadcasts the spec; every client runs spawn(spec + visual_only) for the same flight.
##   * a client's own throw (grenades, later): request_throw(spec) shows a visual copy at once and asks the host;
##     the host checks it (known type, near the thrower, sane speed, rate) and spawns the real one, whose P1
##     broadcast skips the thrower (it already has its copy).
## Nothing here knows a type id: anything registered in data/projectiles.json syncs. Until ThrownProjectile is on
## main (script missing) every entry point is a safe no-op.
## owner_id is an instance id, so it never goes over the wire as is: it becomes owner_z (zombie name) or owner_peer
## (net peer) and is mapped back to the local puppet / player / avatar on arrival.

signal projectile_rx(spec: Dictionary) ## client: a host projectile's visual copy was spawned here
signal throw_refused(peer_id: int, reason: String) ## host: a client throw was rejected (logged, never a kick)

var script_path := "res://scripts/projectiles/thrown_projectile.gd" ## tests swap in a fake
var net: Node
var stats := {"tx": 0, "rx": 0, "throw_req": 0, "throw_ok": 0, "throw_refused": 0}
var _thrower := 0 ## host: the peer whose request is being spawned right now (its P1 broadcast skips it)
var _throw_t: Dictionary = {} ## host: peer -> [msec of recent throws]
var _script: Script = null


func _ready() -> void:
	net = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS


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


# ------------------------------------------------------------------ owner mapping
## Spec -> wire form: plain Variants, owner as a zombie name or a peer id.
func spec_tx(spec: Dictionary) -> Dictionary:
	var tx := {}
	for k in ["type_id", "variant", "rarity", "pos", "vel", "seed"]:
		if spec.has(k):
			tx[k] = spec[k]
	var oid := int(spec.get("owner_id", 0))
	var o: Object = instance_from_id(oid) if oid != 0 else null
	if o is Node and is_instance_valid(o):
		var n := o as Node
		var m := _main()
		var zroot: Node = m.get("zombies_root") if m else null
		if zroot and n.get_parent() == zroot:
			tx["owner_z"] = str(n.name)
		elif n.is_in_group("player"):
			tx["owner_peer"] = net.local_peer_id()
		elif n.get("peer_id") != null:
			tx["owner_peer"] = int(n.get("peer_id"))
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
	var owner: Node = null
	if tx.has("owner_z"):
		var m := _main()
		var zroot: Node = m.get("zombies_root") if m else null
		var zn := str(tx.owner_z)
		owner = zroot.get_node_or_null(NodePath(zn)) if zroot and zn.is_valid_filename() else null
	elif tx.has("owner_peer"):
		var pid := int(tx.owner_peer)
		if pid == net.local_peer_id():
			var m := _main()
			owner = m.get("player") if m else null
		else:
			owner = net.match_players.avatar(pid)
	if owner:
		spec.owner_id = owner.get_instance_id()
	return spec


# ------------------------------------------------------------------ host spawns (hook P1)
## P1 (host): the authoritative projectile exists; every client gets a visual copy. Solo / client / visual copies:
## nothing. Returns true if it was broadcast.
func host_spawned(spec: Dictionary) -> bool:
	if not net.is_networked() or not net.is_host() or bool(spec.get("visual_only", false)):
		return false
	var tx := spec_tx(spec)
	stats.tx += 1
	if _thrower == 0:
		_rpc_projectile.rpc(tx)
	else:
		for pid in multiplayer.get_peers():
			if pid != _thrower:
				_rpc_projectile.rpc_id(pid, tx)
	return true


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
		stats.rx += 1
		projectile_rx.emit(spec)
	return p


# ------------------------------------------------------------------ client throws (grenades, later)
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
	stats.throw_req += 1
	_rpc_throw.rpc_id(1, spec_tx(spec))
	return p


@rpc("any_peer", "call_remote", "reliable")
func _rpc_throw(tx: Dictionary) -> void:
	if net.is_host():
		host_throw(multiplayer.get_remote_sender_id(), tx)


## Host: check a client's throw, then spawn the real projectile owned by that player's avatar. Reject + log (never
## kick): unknown type/variant, too far from the thrower, too fast, too many per second.
func host_throw(peer_id: int, tx: Dictionary) -> String:
	var S := proj_script()
	var why := ""
	var spec := spec_rx(tx) if tx is Dictionary else {}
	var av: Node3D = net.match_players.avatar(peer_id)
	if S == null:
		why = "no_projectiles"
	elif spec.is_empty() or S.type_def(spec.type_id, spec.variant).is_empty():
		why = "unknown_type"
	elif av == null:
		why = "no_avatar"
	elif (spec.pos as Vector3).distance_to(av.global_position) > _cfg("max_throw_dist", 4.0):
		why = "too_far"
	elif (spec.vel as Vector3).length() > _cfg("max_throw_speed", 45.0):
		why = "too_fast"
	else:
		var now := Time.get_ticks_msec()
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
		return why
	spec.owner_id = av.get_instance_id()
	stats.throw_ok += 1
	_thrower = peer_id
	S.spawn(spec) # P1 -> host_spawned (skips the thrower)
	_thrower = 0
	return ""
