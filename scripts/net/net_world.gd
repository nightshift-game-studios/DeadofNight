class_name NetWorld
extends Node
## Co-op world replication (Netz, milestone B). Lives at /root/Net/World on every peer.
##   * zombies: the host spawns from a spec -> every client builds the same zombie (main.make_zombie, same name +
##     seed) as a puppet; host snapshots at tick.zombie_sync_hz (pos / yaw / hp / dead / attack); despawn on free
##   * shared drops: host drop -> NetPickup on every peer (Item.to_dict / from_dict); first grab wins
##   * spending: request to the host's wallet ledger (Net._points); the result comes back to the requester
##   * client round state: HUD round / enemies, GameEvents round_started / round_cleared, own Gravemark
##     milestones and own Field Card offer

signal spend_result(ok: bool, amount: int, reason: String)
signal drop_spawned(drop_id: String)
signal drop_removed(drop_id: String, taker_peer: int)
signal door_opened(key: String, opener_peer: int) ## M13, every peer, after the door's own open() ran here
signal door_refused(door_id: String, reason: String) ## M13, requester only: "points" / "already_open" / "unknown_door" / "wrong_map" / "no_id"

const ItemScr := preload("res://scripts/items/item.gd")
const PICKUP_SCENE := "res://scenes/pickup.tscn"
const NetPickupScr := preload("res://scripts/net/net_pickup.gd")

var net: Node
var drops: Dictionary = {} ## every peer: drop_id -> NetPickup (or null in node-less tests)
var _host_drops: Dictionary = {} ## host: drop_id -> {item: dict, taker: 0}
var _drop_counter := 0
var _snap_t := 0.0
var stats := {"snaps_tx": 0, "snaps_rx": 0, "spawns_rx": 0, "gone_rx": 0, "doors_rx": 0, "refunds": 0}
## M13 doors, every peer: "<map_id>/<door_id>" -> opener peer. Applied to the map on attach (late joiners) and kept
## for the match; never keyed on node paths.
var doors_open: Dictionary = {}
var _door_req_t: Dictionary = {} ## client: door key -> msec of the last request (anti-spam)
## M13 token spends (rerolls). Client: token -> {cb, deadline_ms, amount, reason}; late answers are refunded.
var _pending_spends: Dictionary = {}
var _spend_token := 0
## Host: peer -> {token: amount} charged and still refundable (last 32 per peer).
var _charged: Dictionary = {}


func _ready() -> void:
	net = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS
	net.returned_to_lobby.connect(clear)
	net.disconnected.connect(func(_r): clear())


func clear() -> void:
	drops.clear()
	_host_drops.clear()
	_drop_counter = 0
	doors_open.clear()
	_door_req_t.clear()
	_pending_spends.clear()
	_charged.clear()


func _process(_delta: float) -> void:
	if _pending_spends.is_empty():
		return
	var now := Time.get_ticks_msec()
	for tok in _pending_spends.keys():
		var p: Dictionary = _pending_spends[tok]
		if now >= int(p.deadline_ms) and not p.get("timed_out", false):
			p.timed_out = true # keep the entry so a late "yes" can be refunded
			p.timed_out_at = now
			(p.cb as Callable).call(false, "timeout")
		elif p.get("timed_out", false) and now - int(p.timed_out_at) > 60000:
			_pending_spends.erase(tok)


func _main() -> Node:
	var m = net.get("_match")
	return m if m and is_instance_valid(m) else null


func _zroot() -> Node:
	var m := _main()
	return m.get("zombies_root") if m else null


# ------------------------------------------------------------------ zombies
## Host, from Net.spawn_zombie after the zombie is in the tree.
func host_spawned(z: Node3D, spec: Dictionary) -> void:
	if not net.is_networked() or not net.is_host():
		return
	_rpc_spawn_zombie.rpc(spec, z.global_position, z.rotation.y)
	var zn := str(z.name)
	z.tree_exiting.connect(func(): if net.is_networked() and net.is_host(): _rpc_zombie_gone.rpc(zn))


@rpc("authority", "call_remote", "reliable")
func _rpc_spawn_zombie(spec: Dictionary, pos: Vector3, yaw: float) -> void:
	var m := _main()
	var root := _zroot()
	if m == null or root == null or root.has_node(NodePath(str(spec.get("name", "")))):
		return
	stats.spawns_rx += 1
	var z: Node3D = m.make_zombie(spec)
	z.set_meta("net_puppet", true)
	z.set_meta("net_pos", pos)
	z.set_meta("net_yaw", yaw)
	var patched := z.has_method("play_death_visual") # enemy.gd E2-E5 applied
	root.add_child(z)
	z.global_position = pos
	z.rotation.y = yaw
	if not patched:
		z.set_physics_process(false) # unpatched enemy.gd: no local AI; we drive the puppet (see _physics_process)


@rpc("authority", "call_remote", "reliable")
func _rpc_zombie_gone(zombie_name: String) -> void:
	var root := _zroot()
	var z := root.get_node_or_null(NodePath(zombie_name)) if root else null
	if z:
		stats.gone_rx += 1
		z.queue_free()


## [[name, pos, yaw, hp, flags (1 dead, 2 attacking)], ...] + enemies left for the HUD.
func host_snapshot() -> Array:
	var out: Array = []
	var root := _zroot()
	if root == null:
		return out
	for z in root.get_children():
		if not (z is Node3D):
			continue
		var f := 0
		if bool(z.get("_dead")):
			f |= 1
		if float(z.get("_attack_anim_t") if "_attack_anim_t" in z else 0.0) > 0.0:
			f |= 2
		out.append([str(z.name), z.global_position, z.rotation.y, float(z.get("health")), f])
	return out


func _physics_process(delta: float) -> void:
	if not net.is_networked() or _main() == null:
		return
	if net.is_host():
		_snap_t -= delta
		if _snap_t <= 0.0:
			_snap_t = 1.0 / maxf(float(NetConfig.get_value("tick.zombie_sync_hz", 20)), 1.0)
			var m := _main()
			var left := int(m.get("_to_spawn")) + int(m.get("_alive")) if "_alive" in m else 0
			stats.snaps_tx += 1
			_rpc_zombie_snap.rpc(host_snapshot(), left)
		return
	var root := _zroot()
	if root == null:
		return
	var k := 1.0 - exp(-15.0 * delta)
	for z in root.get_children():
		if not z.has_meta("net_puppet") or not (z is Node3D):
			continue
		var target: Vector3 = z.get_meta("net_pos", z.global_position)
		z.global_position = z.global_position.lerp(target, k) if z.global_position.distance_to(target) < 4.0 else target
		z.rotation.y = lerp_angle(z.rotation.y, float(z.get_meta("net_yaw", z.rotation.y)), k)
		if not z.is_physics_processing(): # unpatched enemy.gd: animate it here (patched ones call this from E2)
			net.zombie_puppet_tick(z, delta)


@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_zombie_snap(snap: Array, enemies_left: int) -> void:
	apply_snapshot(snap, enemies_left)


func apply_snapshot(snap: Array, enemies_left: int) -> void:
	stats.snaps_rx += 1
	var root := _zroot()
	if root == null:
		return
	for s in snap:
		if not (s is Array) or s.size() < 5:
			continue
		var z := root.get_node_or_null(NodePath(str(s[0])))
		if z == null:
			continue
		z.set_meta("net_pos", s[1])
		z.set_meta("net_yaw", float(s[2]))
		z.set("health", float(s[3]))
		if int(s[4]) & 2:
			z.set_meta("net_anim", "attack")
		elif z.has_meta("net_anim"):
			z.remove_meta("net_anim")
		if int(s[4]) & 1 and not bool(z.get("_dead")):
			z.set("_dead", true) # puppet tick plays the death visual once
			if z.get("health_bar"):
				z.health_bar.hide_now()
	var m := _main()
	if m and m.get("hud"):
		m.hud.set_enemies(enemies_left)


# ------------------------------------------------------------------ shared drops
## Host (Net.spawn_pickup, M6): one shared drop for everyone. Returns true = main must not spawn its own.
func host_drop(item: Item, pos: Vector3, chime: bool) -> bool:
	if not net.is_networked() or not net.is_host() or item == null or not NetConfig.get_bool("drops.shared_world_drops"):
		return false
	_drop_counter += 1
	var id := "D%d" % _drop_counter
	var d: Dictionary = item.to_dict()
	_host_drops[id] = {"item": d, "taker": 0}
	_rpc_drop.rpc(id, d, pos, chime)
	return true


@rpc("authority", "call_local", "reliable")
func _rpc_drop(id: String, d: Dictionary, pos: Vector3, chime: bool) -> void:
	var item: Item = ItemScr.from_dict(d)
	var m := _main()
	if item == null:
		return
	var p: Node = null
	if m and m.get("pickups_root"):
		if chime and m.has_method("_sfx") and m._sfx():
			var g := item as GearItem
			m._sfx().loot_chime(Rarity.IDS[g.rarity] if g else "common")
		p = (load(PICKUP_SCENE) as PackedScene).instantiate()
		p.set_script(NetPickupScr)
		p.item = item
		p.drop_id = id
		p.name = id
		m.pickups_root.add_child(p)
		p.global_position = pos
	drops[id] = p
	drop_spawned.emit(id)


func request_grab(id: String) -> void:
	if net.is_host():
		host_grab(net.local_peer_id(), id)
	else:
		_rpc_grab.rpc_id(1, id)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_grab(id: String) -> void:
	if net.is_host():
		host_grab(multiplayer.get_remote_sender_id(), id)


## Host: first request wins; the drop is reserved for that peer until it confirms (inventory may be full).
func host_grab(peer_id: int, id: String) -> bool:
	var hd: Dictionary = _host_drops.get(id, {})
	if hd.is_empty() or int(hd.taker) != 0:
		if peer_id == net.local_peer_id():
			_release(id)
		else:
			_rpc_grab_refused.rpc_id(peer_id, id)
		return false
	hd.taker = peer_id
	if peer_id == net.local_peer_id():
		_grant(id, hd.item)
	else:
		_rpc_grant.rpc_id(peer_id, id, hd.item)
	return true


@rpc("authority", "call_remote", "reliable")
func _rpc_grant(id: String, d: Dictionary) -> void:
	_grant(id, d)


@rpc("authority", "call_remote", "reliable")
func _rpc_grab_refused(id: String) -> void:
	_release(id)


func _release(id: String) -> void:
	var p = drops.get(id)
	if p and is_instance_valid(p) and p.has_method("release"):
		p.release()


## Grabber: rebuild the item and give it to the local player; tell the host whether it fit.
func _grant(id: String, d: Dictionary) -> void:
	var m := _main()
	var pl = m.get("player") if m else null
	var item: Item = ItemScr.from_dict(d)
	var ok: bool = item != null and pl != null and pl.receive_item(item)
	if not ok:
		_release(id)
	if net.is_host():
		host_grab_result(net.local_peer_id(), id, ok)
	else:
		_rpc_grab_result.rpc_id(1, id, ok)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_grab_result(id: String, ok: bool) -> void:
	if net.is_host():
		host_grab_result(multiplayer.get_remote_sender_id(), id, ok)


func host_grab_result(peer_id: int, id: String, ok: bool) -> void:
	var hd: Dictionary = _host_drops.get(id, {})
	if hd.is_empty() or int(hd.taker) != peer_id:
		return
	if not ok:
		hd.taker = 0
		return
	_host_drops.erase(id)
	_rpc_drop_gone.rpc(id, peer_id)


@rpc("authority", "call_local", "reliable")
func _rpc_drop_gone(id: String, taker: int) -> void:
	var p = drops.get(id)
	drops.erase(id)
	if p and is_instance_valid(p):
		p.queue_free()
	drop_removed.emit(id, taker)


# ------------------------------------------------------------------ spending (host wallet)
## Any peer: ask the host to spend `amount` of this player's points. spend_result fires on the requester.
func request_spend(amount: int, reason: String) -> void:
	if not net.is_networked():
		var m := _main()
		var pl = m.get("player") if m else null
		spend_result.emit(pl != null and pl.spend_points(amount), amount, reason)
		return
	if net.is_host():
		host_spend(net.local_peer_id(), amount, reason)
	else:
		_rpc_spend.rpc_id(1, amount, reason)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_spend(amount: int, reason: String) -> void:
	if net.is_host():
		host_spend(multiplayer.get_remote_sender_id(), amount, reason)


func host_spend(peer_id: int, amount: int, reason: String) -> bool:
	var ok: bool = amount > 0 and net.get_points(peer_id) >= amount
	if ok:
		net.award_points(peer_id, -amount, "spend:" + reason) # replicated total; the owner's wallet follows
	if peer_id == net.local_peer_id():
		spend_result.emit(ok, amount, reason)
	else:
		_rpc_spend_result.rpc_id(peer_id, ok, amount, reason)
	return ok


@rpc("authority", "call_remote", "reliable")
func _rpc_spend_result(ok: bool, amount: int, reason: String) -> void:
	spend_result.emit(ok, amount, reason)


# ------------------------------------------------------------------ client round state (from Net._rpc_round_state)
func client_round_state(n: int, phase: String, enemies: int) -> void:
	var m := _main()
	if m == null or net.is_host():
		return
	m.set("current_round", n)
	if m.get("hud"):
		m.hud.set_round(n)
		m.hud.set_enemies(enemies)
	var ge := get_node_or_null("/root/GameEvents")
	var pl = m.get("player")
	if phase == "combat":
		if ge:
			ge.emit_event(&"round_started", {"player": pl, "round": n})
	elif phase == "break":
		if ge:
			ge.emit_event(&"round_cleared", {"player": pl, "round": n})
		net.ArmoryScr.on_round_cleared(n) # this player's own milestone Gravemarks (own save)
		var rs := get_node_or_null("/root/RunState")
		if rs and bool(m.get("field_cards_enabled")) and n >= 1:
			rs.open_offer(n) # own Field Card offer; main reports the pick through M8


# ------------------------------------------------------------------ M13 doors (maps/common/map_door.gd interact hook)
static func door_key(map_id: String, door_id: String) -> String:
	return "%s/%s" % [map_id, door_id]


func _map_id() -> String:
	var m := _main()
	return str(m.get("map_id")) if m and m.get("map_id") != null else ""


func _find_door(door_id: String) -> Node:
	var t := get_tree()
	if t == null or door_id == "":
		return null
	for d in t.get_nodes_in_group("map_doors"):
		if is_instance_valid(d) and str(d.get("door_id")) == door_id:
			return d
	return null


func _local_body() -> Node:
	var m := _main()
	return m.get("player") if m else null


## Hook M13 from MapDoor.interact(player). Solo: false (the door charges + opens itself exactly as before).
## Co-op: true = handled here; the host charges the opener and opens the door on every peer; clients only ask.
func door_interact(door: Node, _player: Node) -> bool:
	if not net.is_networked():
		return false
	if door.get("is_open"):
		return true
	var id := str(door.get("door_id"))
	if id == "":
		push_warning("Net M13: door %s has no door_id; co-op can't replicate it, refusing the buy" % door.get_path())
		door_refused.emit("", "no_id")
		return true
	var mid := _map_id()
	if net.is_host():
		host_door(net.local_peer_id(), mid, id)
		return true
	var key := door_key(mid, id)
	var now := Time.get_ticks_msec()
	if now - int(_door_req_t.get(key, -100000)) < int(1000.0 * float(NetConfig.get_value("spend.door_retry_s", 1.0))):
		return true
	_door_req_t[key] = now
	_rpc_door_request.rpc_id(1, mid, id)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _rpc_door_request(map_id: String, door_id: String) -> void:
	if net.is_host():
		host_door(multiplayer.get_remote_sender_id(), map_id, door_id)


## Host: validate, charge the opener's ledger (host_spend), open here and on every client. Returns "" or the refusal.
func host_door(peer_id: int, map_id: String, door_id: String) -> String:
	var reason := ""
	var door := _find_door(door_id)
	if map_id != _map_id():
		reason = "wrong_map"
	elif door == null:
		reason = "unknown_door"
	elif door.get("is_open") or doors_open.has(door_key(map_id, door_id)):
		reason = "already_open"
	else:
		var cost := int(door.get("cost"))
		if cost > 0 and not host_spend(peer_id, cost, "door:" + door_id):
			reason = "points"
	if reason != "":
		if peer_id == net.local_peer_id():
			door_refused.emit(door_id, reason)
		else:
			_rpc_door_refused.rpc_id(peer_id, door_id, reason)
		return reason
	_apply_door(map_id, door_id, peer_id)
	_rpc_door_opened.rpc(map_id, door_id, peer_id)
	net.broadcast_event(&"door_opened", peer_id, {"door": door_id, "map": map_id})
	return ""


@rpc("authority", "call_remote", "reliable")
func _rpc_door_refused(door_id: String, reason: String) -> void:
	door_refused.emit(door_id, reason)


@rpc("authority", "call_remote", "reliable")
func _rpc_door_opened(map_id: String, door_id: String, opener: int) -> void:
	stats.doors_rx += 1
	_apply_door(map_id, door_id, opener)


## Every peer: remember it and run the door's own open() (no charge) -> opened(door) -> area unlock + nav rebake.
func _apply_door(map_id: String, door_id: String, opener: int) -> void:
	doors_open[door_key(map_id, door_id)] = opener
	if map_id != _map_id():
		return # map not loaded yet here; apply_doors() on attach
	var door := _find_door(door_id)
	if door and not door.get("is_open"):
		door.open(_local_body())
		door_opened.emit(door_key(map_id, door_id), opener)


## Every peer, after the map is loaded (attach_match) and for late joiners: open every door the host says is open.
func apply_doors() -> void:
	var mid := _map_id()
	for key in doors_open:
		var k := str(key)
		if k.begins_with(mid + "/"):
			_apply_door(mid, k.substr(mid.length() + 1), int(doors_open[key]))


## Host -> one peer (scene ready / late join): the full open-door list.
func send_doors_to(peer_id: int) -> void:
	if net.is_host() and peer_id != net.local_peer_id() and not doors_open.is_empty():
		_rpc_doors_state.rpc_id(peer_id, doors_open.duplicate())


@rpc("authority", "call_remote", "reliable")
func _rpc_doors_state(state: Dictionary) -> void:
	for k in state:
		doors_open[str(k)] = int(state[k])
	apply_doors()


# ------------------------------------------------------------------ M13 token spends (run_state.gd paid reroll)
## Any peer: charge `amount` through the host and call cb.call(ok: bool, reason: String) -> bool once.
## Solo: the local player's spend_points, synchronously. cb returns false if the caller no longer wants it (offer
## closed meanwhile); a host "yes" the caller didn't take, or one that arrives after timeout_s, is refunded.
func spend_with_callback(amount: int, reason: String, cb: Callable) -> void:
	if not net.is_networked():
		var pl = _local_body()
		var ok: bool = pl != null and pl.spend_points(amount)
		cb.call(ok, "" if ok else "points")
		return
	_spend_token += 1
	var tok := _spend_token
	_pending_spends[tok] = {"cb": cb, "amount": amount, "reason": reason,
		"deadline_ms": Time.get_ticks_msec() + int(1000.0 * float(NetConfig.get_value("spend.timeout_s", 3.0)))}
	if net.is_host():
		_spend_answer(tok, host_spend_token(net.local_peer_id(), tok, amount, reason))
	else:
		_rpc_spend_token.rpc_id(1, tok, amount, reason)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_spend_token(tok: int, amount: int, reason: String) -> void:
	if net.is_host():
		var pid := multiplayer.get_remote_sender_id()
		_rpc_spend_token_result.rpc_id(pid, tok, host_spend_token(pid, tok, amount, reason))


func host_spend_token(peer_id: int, tok: int, amount: int, reason: String) -> bool:
	var ok: bool = amount > 0 and net.get_points(peer_id) >= amount
	if ok:
		net.award_points(peer_id, -amount, "spend:" + reason)
		var c: Dictionary = _charged.get_or_add(peer_id, {})
		c[tok] = amount
		while c.size() > 32:
			c.erase(c.keys()[0])
	return ok


@rpc("authority", "call_remote", "reliable")
func _rpc_spend_token_result(tok: int, ok: bool) -> void:
	_spend_answer(tok, ok)


func _spend_answer(tok: int, ok: bool) -> void:
	var p = _pending_spends.get(tok)
	if p == null:
		return
	_pending_spends.erase(tok)
	if p.get("timed_out", false):
		if ok:
			_refund(tok) # the caller already treated it as refused
		return
	var taken = (p.cb as Callable).call(ok, "" if ok else "points")
	if ok and taken is bool and not taken:
		_refund(tok)


func _refund(tok: int) -> void:
	stats.refunds += 1
	if net.is_host():
		host_refund(net.local_peer_id(), tok)
	else:
		_rpc_refund.rpc_id(1, tok)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_refund(tok: int) -> void:
	if net.is_host():
		host_refund(multiplayer.get_remote_sender_id(), tok)


## Host: give back a charge this peer made with `tok` (once; unknown tokens are ignored, so it can't mint points).
func host_refund(peer_id: int, tok: int) -> bool:
	var c: Dictionary = _charged.get(peer_id, {})
	if not c.has(tok):
		return false
	var amount := int(c[tok])
	c.erase(tok)
	net.award_points(peer_id, amount, "refund")
	return true
