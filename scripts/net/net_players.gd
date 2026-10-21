class_name NetPlayers
extends Node
## Co-op players during a match (Netz, milestone B). Lives at /root/Net/Players (same path on every peer, so its
## RPCs line up). Owns:
##   * remote avatars (NetRemoteAvatar + NetAvatarBody adapter) for every other party member
##   * the local player's state stream (player_state_hz, unreliable_ordered) and one-shot events from GameEvents
##     (shot_fired / reload_started / grenade_thrown / jumped) - only state + triggers go over the wire
##   * zombie hits on avatars (host) -> the owner's own Player.take_damage; owner damage -> host callout driver
##   * downed / revive / bleed-out / game over (host-authoritative, data/net.json downed.*)
##   * late join (phase 3a): the joiner spectates (life "dead", party state "spectating") until the next round break
##   * spectate camera (NetSpectate) while the local player is downed / dead; game_event ids for Gooey's HUD:
##     player_downed, player_revived, revive_progress, player_bled_out, player_respawned, player_joined_late

signal life_changed(peer_id: int, state: String) ## alive | downed | dead
signal revive_changed(target_peer: int, reviver_peer: int, active: bool) ## UI: progress bar over revive_time_s
signal all_down() ## every player is downed or dead -> game over on every machine
signal spectate_changed(target_peer: int, target_name: String) ## local: the spectate camera now follows target_peer (0 / "" = off)

const LIFE_ALIVE := "alive"
const LIFE_DOWNED := "downed"
const LIFE_DEAD := "dead"
const EVENT_KINDS := ["fire", "reload", "throw", "jump", "hit"]
## Net.game_event ids (host-broadcast, every peer; peer_id = the player it's about). Gooey: LobbyAPI.EV_*.
const EV_DOWNED := &"player_downed" ## {bleed_out_s}
const EV_REVIVED := &"player_revived" ## {reviver}
const EV_REVIVE_PROGRESS := &"revive_progress" ## {reviver, active, progress 0..1, time_s}: at start / stop and every 0.5 s
const EV_BLED_OUT := &"player_bled_out" ## {} (downed.enabled false: straight to dead, {instant: true})
const EV_RESPAWNED := &"player_respawned" ## {late_join}
const EV_JOINED_LATE := &"player_joined_late" ## {spectating, round}
const NetSpectateScr := preload("res://scripts/net/net_spectate.gd")

var net: Node
var avatars: Dictionary = {} ## peer_id -> NetRemoteAvatar
var life: Dictionary = {} ## peer_id -> alive | downed | dead (every peer's view, from the host)
var downed: Dictionary = {} ## host: peer_id -> {bleed, reviver, progress}
var body_kind := "" ## "" = data/net.json avatar.body; tests force "capsule" / "desi"
var stats := {"state_rx": 0, "state_clamped": 0, "events_rx": 0, "damage_fwd": 0, "damage_rx": 0, "heal_tx": 0, "heal_rx": 0, "heal_clipped": 0}
var _heal_window: Dictionary = {} ## host: peer -> [window start msec, HP relayed in it]
var _player: Node3D
var _root: Node
var _send_t := 0.0
var _seq := 0
var _last_weapon := "?"
var _hold_target := 0 ## local: the downed peer we're holding interact on
var late_spectators: Dictionary = {} ## host: late joiners spectating until the next round break (peer -> true)
var spectate: Node ## NetSpectate under the match (local camera while downed / dead)
var _progress_t := 0.0


func _ready() -> void:
	net = get_parent()
	process_mode = Node.PROCESS_MODE_ALWAYS
	var ge := get_node_or_null("/root/GameEvents")
	if ge:
		ge.event.connect(_on_game_event)
	net.peer_left.connect(func(id, _n, _r): _drop_peer(id))
	net.returned_to_lobby.connect(clear)
	net.disconnected.connect(func(_r): clear())


## Net.attach_match: the local player + one avatar per other party member (at their spawn slot).
func begin_match(main: Node) -> void:
	clear()
	_player = main.get("player") as Node3D
	_root = Node3D.new()
	_root.name = "NetAvatars"
	main.add_child(_root)
	var base: Transform3D = main.get("_player_spawn") if "_player_spawn" in main else Transform3D()
	spectate = NetSpectateScr.new()
	spectate.name = "NetSpectate"
	spectate.players = self
	main.add_child(spectate)
	for e in net.get_party():
		life[int(e.peer_id)] = LIFE_ALIVE
		net._set_life_entry(int(e.peer_id), LIFE_ALIVE, false)
		if int(e.peer_id) != net.local_peer_id():
			spawn_avatar(int(e.peer_id), int(e.slot), str(e.name), net.spawn_slot_transform(base, int(e.peer_id)).origin)


## Tests / attach: an avatar for `peer_id` (parent: the match's NetAvatars node, else this node).
func spawn_avatar(peer_id: int, slot: int, display_name: String, at: Vector3 = Vector3.ZERO) -> NetRemoteAvatar:
	if avatars.has(peer_id):
		return avatars[peer_id]
	var a := NetRemoteAvatar.create(peer_id, slot, display_name, body_kind)
	(_root if _root and is_instance_valid(_root) else self).add_child(a)
	a.global_position = at
	avatars[peer_id] = a
	resend_weapon() # the new peer's machine hasn't seen my weapon / slot yet (late join)
	return a


func set_local_player(p: Node3D) -> void:
	_player = p


## Zombies chasing a body that's about to be freed drop it now (the next E1 retarget picks a live player) instead of
## holding a freed reference until then.
func _untarget(body: Node) -> void:
	var t := get_tree()
	if t == null:
		return
	for z in t.get_nodes_in_group("enemies"):
		if z.get("target") == body:
			z.set("target", null)


func clear() -> void:
	for a in avatars.values():
		if is_instance_valid(a):
			a.queue_free()
	avatars.clear()
	life.clear()
	downed.clear()
	late_spectators.clear()
	_hold_target = 0
	if spectate and is_instance_valid(spectate):
		spectate.queue_free()
	spectate = null
	_seq = 0
	_last_weapon = "?"
	if _root and is_instance_valid(_root):
		_root.queue_free()
	_root = null
	_player = null


func _drop_peer(id: int) -> void:
	if avatars.has(id):
		if is_instance_valid(avatars[id]):
			_untarget(avatars[id])
			avatars[id].queue_free()
		avatars.erase(id)
	life.erase(id)
	late_spectators.erase(id)
	if downed.has(id):
		downed.erase(id)
	for t in downed: # a reviver who left stops reviving
		if int(downed[t].reviver) == id:
			_stop_revive(t, downed[t])
	if net.is_host() and net.is_match_running():
		_check_all_down()


func avatar(peer_id: int) -> NetRemoteAvatar:
	return avatars.get(peer_id)


func life_of(peer_id: int) -> String:
	return str(life.get(peer_id, LIFE_ALIVE))


# ------------------------------------------------------------------ state stream
func _physics_process(delta: float) -> void:
	if not net.is_networked() or _player == null or not is_instance_valid(_player):
		return
	_send_t -= delta
	if _send_t <= 0.0:
		_send_t = 1.0 / maxf(float(NetConfig.get_value("tick.player_state_hz", 30)), 1.0)
		send_state()
	_local_revive_input()
	if net.is_host():
		host_tick(delta)


## [seq, pos, yaw, pitch, horizontal speed, crouch 0/1, flags (air | ads | dead)]
func sample_state(p: Node3D) -> Array:
	var head := p.get("head") as Node3D
	var v: Vector3 = p.get("velocity") if "velocity" in p else Vector3.ZERO
	var flags := 0
	if p.has_method("is_on_floor") and not p.is_on_floor():
		flags |= NetRemoteAvatar.F_AIR
	if bool(p.get("ads_active")):
		flags |= NetRemoteAvatar.F_ADS
	if life_of(net.local_peer_id()) == LIFE_DEAD:
		flags |= NetRemoteAvatar.F_DEAD
	var crouched: bool = p.has_method("is_crouched") and p.is_crouched()
	_seq += 1
	return [_seq, p.global_position, p.rotation.y, head.rotation.x if head else 0.0, Vector2(v.x, v.z).length(),
		1.0 if crouched else 0.0, flags]


func send_state() -> void:
	_rpc_state.rpc(sample_state(_player))
	var w = _player.call("current_weapon") if _player.has_method("current_weapon") else null
	var wid: String = str(w.archetype) if w and "archetype" in w else ""
	var inv = _player.get("inventory")
	var slot: String = str(inv.get("active_weapon_slot")) if inv and inv.get("active_weapon_slot") != null else ""
	if wid + "|" + slot != _last_weapon:
		_last_weapon = wid + "|" + slot
		_rpc_weapon_slot.rpc(wid, slot)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_state(st: Array) -> void:
	receive_state(multiplayer.get_remote_sender_id(), st)


func receive_state(sender: int, st: Array) -> void:
	if st.size() < 7 or not (st[1] is Vector3):
		return
	stats.state_rx += 1
	var mx := float(NetConfig.get_value("validation.max_player_speed", 20.0))
	if float(st[4]) > mx or is_nan(float(st[4])):
		st[4] = mx
		stats.state_clamped += 1
	var a := avatar(sender)
	if a:
		a.push_state(st)


## Old archetype-only form, still accepted (slot unknown).
@rpc("any_peer", "call_remote", "reliable")
func _rpc_weapon(arch_id: String) -> void:
	receive_weapon(multiplayer.get_remote_sender_id(), arch_id, "")


## The owner's held weapon: archetype + Inventory.active_weapon_slot ("primary" / "secondary" / "heavy" / future slots).
## Net never applies slot rules; the avatar just keeps the slot for its pose.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_weapon_slot(arch_id: String, slot: String) -> void:
	receive_weapon(multiplayer.get_remote_sender_id(), arch_id, slot)


func receive_weapon(sender: int, arch_id: String, slot: String) -> void:
	var a := avatar(sender)
	if a and arch_id.length() < 48 and slot.length() < 24:
		a.set_weapon(arch_id, slot)


## Re-announce the held weapon (a late joiner's new avatars need it).
func resend_weapon() -> void:
	_last_weapon = "?"


# ------------------------------------------------------------------ one-shot events (from the owner's GameEvents)
func _on_game_event(ev_name: StringName, ctx: Dictionary) -> void:
	if not net.is_networked() or _player == null or ctx.get("player") != _player:
		return
	match ev_name:
		&"shot_fired":
			_rpc_event.rpc("fire", {})
		&"reload_started":
			_rpc_event.rpc("reload", {"time": float(ctx.get("time", 2.167))})
		&"grenade_thrown":
			_rpc_event.rpc("throw", {})
		&"jumped", &"wall_jumped":
			_rpc_event.rpc("jump", {})
		&"damage_taken":
			if float(ctx.get("dealt", 0)) > 0.0:
				_rpc_event.rpc("hit", {})
				if net.is_host():
					net.report_damage(net.local_peer_id())
				else:
					_rpc_damaged.rpc_id(1)


@rpc("any_peer", "call_remote", "unreliable")
func _rpc_event(kind: String, data: Dictionary) -> void:
	receive_event(multiplayer.get_remote_sender_id(), kind, data)


func receive_event(sender: int, kind: String, data: Dictionary) -> void:
	if kind not in EVENT_KINDS:
		return
	stats.events_rx += 1
	var a := avatar(sender)
	if a:
		var clean := {}
		if data.has("time"):
			clean["time"] = clampf(float(data.time), 0.1, 10.0)
		a.trigger(kind, clean)


## Owner -> host: "I took real damage" (after dodge / armor / overshield) -> callout driver streak reset.
@rpc("any_peer", "call_remote", "reliable")
func _rpc_damaged() -> void:
	if net.is_host():
		net.report_damage(multiplayer.get_remote_sender_id())


# ------------------------------------------------------------------ zombie hits on avatars (host)
func avatar_damaged(a: NetRemoteAvatar, amount: float, attacker: Node) -> void:
	if not net.is_networked() or not net.is_host() or a == null or life_of(a.peer_id) != LIFE_ALIVE or is_nan(amount) or amount <= 0.0:
		return
	stats.damage_fwd += 1
	_rpc_take_damage.rpc_id(a.peer_id, minf(amount, 1000.0), str(attacker.name) if attacker else "")


@rpc("authority", "call_remote", "reliable")
func _rpc_take_damage(amount: float, zombie_name: String) -> void:
	stats.damage_rx += 1
	if _player and is_instance_valid(_player) and life_of(net.local_peer_id()) == LIFE_ALIVE and _player.has_method("take_damage"):
		_player.take_damage(amount, net._find_zombie(zombie_name) if zombie_name != "" else null)


# ------------------------------------------------------------------ downed / revive / bleed-out
## M9 via Net.report_local_down: the local player hit 0 HP.
func report_local_down() -> void:
	if net.is_host():
		host_down(net.local_peer_id())
	else:
		_rpc_report_down.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_report_down() -> void:
	if net.is_host():
		host_down(multiplayer.get_remote_sender_id())


func host_down(peer_id: int) -> void:
	if not net.is_host() or life_of(peer_id) != LIFE_ALIVE:
		return
	if not NetConfig.get_bool("downed.enabled"):
		_rpc_life.rpc(peer_id, LIFE_DEAD)
		net.broadcast_event(EV_BLED_OUT, peer_id, {"instant": true})
	else:
		downed[peer_id] = {"bleed": NetConfig.get_float("downed.bleed_out_s"), "reviver": 0, "progress": 0.0, "active": false}
		_rpc_life.rpc(peer_id, LIFE_DOWNED)
		net.broadcast_event(EV_DOWNED, peer_id, {"bleed_out_s": NetConfig.get_float("downed.bleed_out_s")})
	_check_all_down()


@rpc("authority", "call_local", "reliable")
func _rpc_life(peer_id: int, state: String) -> void:
	var prev := life_of(peer_id)
	life[peer_id] = state
	var a := avatar(peer_id)
	if a:
		a.dead = state == LIFE_DEAD
		a.set_downed(state == LIFE_DOWNED)
	if peer_id == net.local_peer_id() and _player and is_instance_valid(_player):
		if state == LIFE_ALIVE and prev != LIFE_ALIVE:
			_restore_local(prev == LIFE_DEAD)
		elif state == LIFE_DEAD and not bool(_player.get("dead")):
			_park_local() # late joiner: spectating, never hit 0 HP itself
	net._set_life_entry(peer_id, state, true)
	life_changed.emit(peer_id, state)


## Late join while a round is on: the local player waits out of play (no input, zombies ignore dead players).
func _park_local() -> void:
	_player.set("dead", true)
	_player.set("input_enabled", false)
	if "velocity" in _player:
		_player.set("velocity", Vector3.ZERO)


## Revived (prev downed): revive_health_frac of max HP where you lie. Respawn (prev dead): full HP at your spawn slot.
func _restore_local(respawn: bool) -> void:
	var mx := int(_player.get("max_health"))
	_player.set("dead", false)
	_player.set("input_enabled", true)
	_player.set("health", mx if respawn else maxi(int(round(mx * NetConfig.get_float("downed.revive_health_frac"))), 1))
	if _player.has_signal("health_changed"):
		_player.health_changed.emit(int(_player.get("health")), mx)
	var m = net.get("_match")
	if respawn and m and "_player_spawn" in m:
		_player.global_transform = m.get("_player_spawn")


## Local / UI: hold (true) or release (false) revive on a downed teammate. The host checks range and time.
func set_revive_hold(target_peer: int, holding: bool) -> void:
	if net.is_host():
		host_revive_hold(net.local_peer_id(), target_peer, holding)
	else:
		_rpc_revive_hold.rpc_id(1, target_peer, holding)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_revive_hold(target_peer: int, holding: bool) -> void:
	if net.is_host():
		host_revive_hold(multiplayer.get_remote_sender_id(), target_peer, holding)


func host_revive_hold(reviver: int, target_peer: int, holding: bool) -> bool:
	if not downed.has(target_peer) or reviver == target_peer or life_of(reviver) != LIFE_ALIVE:
		return false
	var d: Dictionary = downed[target_peer]
	if holding:
		if int(d.reviver) != 0 and int(d.reviver) != reviver:
			return false # someone else is already on it
		d.reviver = reviver # range is checked every host tick (the reviver may still be walking in)
		return true
	if int(d.reviver) == reviver:
		_stop_revive(target_peer, d)
	return true


func _stop_revive(target_peer: int, d: Dictionary) -> void:
	var r := int(d.reviver)
	if bool(d.get("active", false)):
		_rpc_reviving.rpc(target_peer, r, false)
		_revive_event(target_peer, r, false, 0.0)
	d.reviver = 0
	d.progress = 0.0
	d.active = false


@rpc("authority", "call_local", "reliable")
func _rpc_reviving(target_peer: int, reviver: int, active: bool) -> void:
	var a := avatar(reviver)
	if a:
		a.set_reviving(active)
	revive_changed.emit(target_peer, reviver, active)


func _pos_of(peer_id: int) -> Vector3:
	if peer_id == net.local_peer_id():
		return _player.global_position if _player and is_instance_valid(_player) else Vector3.INF
	var a := avatar(peer_id)
	return a.global_position if a else Vector3.INF


func _in_revive_range(a_peer: int, b_peer: int) -> bool:
	var pa := _pos_of(a_peer)
	var pb := _pos_of(b_peer)
	return pa != Vector3.INF and pb != Vector3.INF and pa.distance_to(pb) <= NetConfig.get_float("downed.revive_range_m") * float(NetConfig.get_value("validation.range_slack", 1.1))


## Host: bleed-out timers (paused while someone revives), revive progress, game over.
func host_tick(delta: float) -> void:
	for t in downed.keys():
		var d: Dictionary = downed[t]
		var r := int(d.reviver)
		if r != 0 and life_of(r) != LIFE_ALIVE:
			_stop_revive(t, d)
			r = 0
		if r != 0 and _in_revive_range(r, t):
			var rt := NetConfig.get_float("downed.revive_time_s")
			if not bool(d.get("active", false)):
				d.active = true
				d.progress = 0.0
				d.ev_t = 0.0
				_rpc_reviving.rpc(t, r, true)
				_revive_event(t, r, true, 0.0)
			d.progress = float(d.progress) + delta # bleed-out pauses while a teammate is actually reviving
			d.ev_t = float(d.get("ev_t", 0.0)) + delta
			if float(d.progress) >= rt:
				downed.erase(t)
				_rpc_reviving.rpc(t, r, false)
				_revive_event(t, r, false, 1.0)
				_rpc_life.rpc(t, LIFE_ALIVE)
				net.broadcast_event(EV_REVIVED, t, {"reviver": r})
				net.award_points(r, int(NetConfig.points("revive")), "revive")
			elif float(d.ev_t) >= 0.5:
				d.ev_t = 0.0
				_revive_event(t, r, true, float(d.progress) / maxf(rt, 0.01))
			continue
		if bool(d.get("active", false)): # walked out of range: progress lost, still holding
			d.active = false
			d.progress = 0.0
			_rpc_reviving.rpc(t, r, false)
			_revive_event(t, r, false, 0.0)
		d.bleed = float(d.bleed) - delta
		if float(d.bleed) <= 0.0:
			downed.erase(t)
			if r != 0:
				_rpc_reviving.rpc(t, r, false)
			_rpc_life.rpc(t, LIFE_DEAD)
			net.broadcast_event(EV_BLED_OUT, t, {})
			_check_all_down()


func _revive_event(target: int, reviver: int, active: bool, progress: float) -> void:
	net.broadcast_event(EV_REVIVE_PROGRESS, target, {"reviver": reviver, "active": active, "progress": clampf(progress, 0.0, 1.0),
		"time_s": NetConfig.get_float("downed.revive_time_s")})


func _check_all_down() -> void:
	if not NetConfig.get_bool("downed.game_over_when_all_down"):
		return
	var ids: Array = []
	for e in net.get_party():
		ids.append(int(e.peer_id))
	if ids.is_empty():
		return
	for id in ids:
		if life_of(id) == LIFE_ALIVE:
			return
	_rpc_all_down.rpc()


@rpc("authority", "call_local", "reliable")
func _rpc_all_down() -> void:
	downed.clear()
	all_down.emit()
	net.on_all_down()


## Host, M7 round start: dead players respawn (data/net.json downed.respawn_next_round); downed ones stay down.
func on_round_started() -> void:
	if not net.is_host() or not NetConfig.get_bool("downed.respawn_next_round"):
		return
	for id in life.keys():
		if life_of(id) == LIFE_DEAD:
			late_spectators.erase(id)
			_rpc_life.rpc(id, LIFE_ALIVE)
			net.broadcast_event(EV_RESPAWNED, id, {"late_join": false})


## Host, M7 round cleared (break): late joiners who were spectating come in now.
func on_round_cleared() -> void:
	if not net.is_host():
		return
	for id in late_spectators.keys():
		late_spectators.erase(id)
		if life_of(id) == LIFE_DEAD and net._party.has(id):
			_rpc_life.rpc(id, LIFE_ALIVE)
			net.broadcast_event(EV_RESPAWNED, id, {"late_join": true})


# ------------------------------------------------------------------ late join (phase 3a)
## Host, once the joiner's match scene is ready: its avatar on every other peer, every player's life (+ downed bleed)
## on the joiner, then the joiner's own life: spectating (dead) during a round, alive in a break / before round 1.
func host_late_join(peer_id: int, display_name: String, slot: int, spectating: bool) -> void:
	if not net.is_host():
		return
	var at := _player.global_position if _player and is_instance_valid(_player) else Vector3.ZERO
	spawn_avatar(peer_id, slot, display_name, at)
	life[peer_id] = LIFE_ALIVE
	_rpc_add_avatar.rpc(peer_id, slot, display_name, at)
	var bleed := {}
	for t in downed:
		bleed[t] = float(downed[t].bleed)
	_rpc_life_sync.rpc_id(peer_id, life.duplicate(), bleed)
	if spectating:
		late_spectators[peer_id] = true
		_rpc_life.rpc(peer_id, LIFE_DEAD)
	else:
		_rpc_life.rpc(peer_id, LIFE_ALIVE)


@rpc("authority", "call_remote", "reliable")
func _rpc_add_avatar(peer_id: int, slot: int, display_name: String, at: Vector3) -> void:
	if peer_id != net.local_peer_id() and _root and is_instance_valid(_root):
		spawn_avatar(peer_id, slot, display_name, at)
		life[peer_id] = LIFE_ALIVE


## Joiner: everyone's life as the host has it (downed avatars lie down; dead ones are hidden by their state stream).
@rpc("authority", "call_remote", "reliable")
func _rpc_life_sync(lives: Dictionary, bleed: Dictionary) -> void:
	for k in lives:
		var id := int(k)
		var st := str(lives[k])
		if id == net.local_peer_id() or st not in [LIFE_ALIVE, LIFE_DOWNED, LIFE_DEAD]:
			continue
		life[id] = st
		var a := avatar(id)
		if a:
			a.dead = st == LIFE_DEAD
			a.set_downed(st == LIFE_DOWNED)
		net._set_life_entry(id, st, false)
		if st != LIFE_ALIVE:
			life_changed.emit(id, st)
	sync_bleed = bleed.duplicate()
	net.party_changed.emit(net.get_party())


var sync_bleed: Dictionary = {} ## joiner: downed peers' bleed-out seconds left at the moment it joined (UI countdown)


## Local input: holding interact near a downed teammate (prompt / bar are Gooey's; this is the minimal hook).
func _local_revive_input() -> void:
	if downed.is_empty() and not life.values().has(LIFE_DOWNED):
		if _hold_target != 0:
			_hold_target = 0
		return
	var want := 0
	if life_of(net.local_peer_id()) == LIFE_ALIVE and InputMap.has_action("interact") and Input.is_action_pressed("interact"):
		var best := INF
		for id in avatars:
			if life_of(id) == LIFE_DOWNED:
				var dd: float = avatars[id].global_position.distance_to(_player.global_position)
				if dd <= NetConfig.get_float("downed.revive_range_m") and dd < best:
					best = dd
					want = id
	if want != _hold_target:
		if _hold_target != 0:
			set_revive_hold(_hold_target, false)
		_hold_target = want
		if want != 0:
			set_revive_hold(want, true)


# ------------------------------------------------------------------ host-decided heals (Leechbell orbs, ...)
## Host: heal `target` (local player or a remote avatar) by `amount`. The owner's machine applies it to its own
## player (Player.heal), like damage. Capped per player per second (projectiles.heal_max_per_s; the rest is
## clipped and logged). Returns the HP sent (0 = nothing: downed / dead / not a player / cap used up).
func host_heal(target: Node, amount: int, reason: String = "") -> int:
	var net := get_parent()
	if target == null or amount <= 0 or not net.is_host():
		return 0
	var pid := 0
	if target == _player:
		pid = net.local_peer_id()
	elif target is NetRemoteAvatar:
		pid = (target as NetRemoteAvatar).peer_id
	if pid == 0 or life_of(pid) != LIFE_ALIVE:
		return 0
	var now := Time.get_ticks_msec()
	var w: Array = _heal_window.get(pid, [now, 0])
	if now - int(w[0]) >= 1000:
		w = [now, 0]
	var cap := int(NetConfig.get_value("projectiles.heal_max_per_s", 120))
	var give := mini(amount, maxi(cap - int(w[1]), 0))
	if give < amount:
		stats.heal_clipped += 1
		push_warning("NetPlayers: heal for peer %d clipped %d -> %d (%s)" % [pid, amount, give, reason])
	w[1] = int(w[1]) + give
	_heal_window[pid] = w
	if give <= 0:
		return 0
	stats.heal_tx += 1
	if pid == net.local_peer_id():
		_apply_heal(give)
	else:
		_rpc_heal.rpc_id(pid, give, reason)
	return give


@rpc("authority", "call_remote", "reliable")
func _rpc_heal(amount: int, _reason: String) -> void:
	_apply_heal(amount)


func _apply_heal(amount: int) -> void:
	stats.heal_rx += 1
	if _player and is_instance_valid(_player) and _player.has_method("heal") and amount > 0:
		_player.heal(mini(amount, 1000))
