class_name NetSpectate
extends Node3D
## Spectate camera (Netz, phase 3a). Lives under the match (NetPlayers.begin_match adds it); local only, nothing is
## sent. While the local player is dead (bled out / late joiner waiting for the break) or downed
## (data/net.json spectate.when_downed), it takes over the viewport and follows an alive teammate's avatar from behind
## the shoulder. spectate.next_action / prev_action (default shoot / ads) cycle through the alive teammates (peer-id
## order); when the watched one goes down, dies or leaves, it moves on by itself. With nobody alive to watch it holds
## the last view. NetPlayers.spectate_changed(peer, name) fires on every change (0 / "" = off) for Gooey's banner.

var players: Node ## NetPlayers
var camera: Camera3D
var active := false
var target_peer := 0
var _prev_cam: Camera3D
var _hidden_gun: Node3D
var _snap := true


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "SpectateCam"
	camera.top_level = true
	camera.current = false
	add_child(camera)
	if players:
		players.life_changed.connect(func(_p, _s): refresh())


## Switch on / off right away (life changes), not only on the next physics tick (slow right after a big map load).
func refresh() -> void:
	if not is_inside_tree():
		return
	var want := wants_active()
	if want != active:
		_set_active(want)
	elif active and not candidates().has(target_peer):
		var c := candidates()
		_set_target(c[0] if not c.is_empty() else 0)


func _cfg(key: String, fallback):
	return NetConfig.get_value("spectate." + key, fallback)


## True while the local player should be watching someone else.
func wants_active() -> bool:
	if players == null or not bool(_cfg("enabled", true)):
		return false
	var net: Node = players.net
	if net == null or not net.is_networked():
		return false
	var l: String = players.life_of(net.local_peer_id())
	return l == NetPlayers.LIFE_DEAD or (l == NetPlayers.LIFE_DOWNED and bool(_cfg("when_downed", true)))


## Alive teammates with an avatar here, in peer-id order.
func candidates() -> Array:
	var out: Array = []
	if players == null:
		return out
	for id in players.avatars:
		var a = players.avatars[id]
		if is_instance_valid(a) and players.life_of(int(id)) == NetPlayers.LIFE_ALIVE:
			out.append(int(id))
	out.sort()
	return out


## Next (dir 1) / previous (dir -1) alive teammate; returns the new target (0 = nobody).
func cycle(dir: int = 1) -> int:
	var c := candidates()
	if c.is_empty():
		_set_target(0)
		return 0
	var i := c.find(target_peer)
	_set_target(c[0] if i < 0 else c[posmod(i + (1 if dir >= 0 else -1), c.size())])
	return target_peer


func _physics_process(delta: float) -> void:
	var want := wants_active()
	if want != active:
		_set_active(want)
	if not active:
		return
	var c := candidates()
	if not c.has(target_peer):
		_set_target(c[0] if not c.is_empty() else 0)
	_cycle_input()
	_follow(delta)


func _cycle_input() -> void:
	var nxt := str(_cfg("next_action", "shoot"))
	var prv := str(_cfg("prev_action", "ads"))
	if InputMap.has_action(nxt) and Input.is_action_just_pressed(nxt):
		cycle(1)
	elif InputMap.has_action(prv) and Input.is_action_just_pressed(prv):
		cycle(-1)


func _set_active(on: bool) -> void:
	active = on
	var pl = players._player if players else null
	if on:
		var vp := get_viewport()
		_prev_cam = vp.get_camera_3d() if vp else null
		if _prev_cam and _prev_cam != camera:
			camera.global_transform = _prev_cam.global_transform
			camera.fov = _prev_cam.fov
		camera.current = true
		_snap = true
		var g = pl.get("gun") if pl and is_instance_valid(pl) else null
		if g is Node3D and (g as Node3D).visible: # the first-person viewmodel would float where the player lies
			_hidden_gun = g
			_hidden_gun.visible = false
		cycle(1)
	else:
		camera.current = false
		if _prev_cam and is_instance_valid(_prev_cam):
			_prev_cam.current = true
		_prev_cam = null
		if _hidden_gun and is_instance_valid(_hidden_gun):
			_hidden_gun.visible = true
		_hidden_gun = null
		_set_target(0)


func _set_target(peer: int) -> void:
	if peer == target_peer:
		return
	target_peer = peer
	_snap = true
	if players:
		players.spectate_changed.emit(peer, players.net.get_player_name(peer) if peer != 0 else "")


## Behind-the-shoulder pose for the watched avatar; pulled in when a wall is in the way.
func pose_for(a: Node3D) -> Transform3D:
	var yaw := a.global_rotation.y
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var eye := a.global_position + Vector3(0, 1.6, 0)
	var want := eye - fwd * float(_cfg("distance_m", 2.6)) + Vector3(0, float(_cfg("height_m", 0.45)), 0)
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space:
		var q := PhysicsRayQueryParameters3D.create(eye, want, 1)
		var hit := space.intersect_ray(q)
		if hit:
			want = (hit.position as Vector3) + (eye - want).normalized() * 0.2
	return Transform3D(Basis.IDENTITY, want).looking_at(eye + fwd * 4.0, Vector3.UP)


func _follow(delta: float) -> void:
	var a = players.avatar(target_peer) if target_peer != 0 else null
	if a == null or not is_instance_valid(a):
		return
	var t := pose_for(a)
	if _snap:
		camera.global_transform = t
		_snap = false
		return
	var k := 1.0 - exp(-10.0 * delta)
	camera.global_transform = camera.global_transform.interpolate_with(t, k)
