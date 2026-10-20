class_name NetRemoteAvatar
extends CharacterBody3D
## Another player's body on this machine (Netz, milestone B). Group "net_avatar" (Net.players(), zombie targeting,
## spawn distance). Moved only by replicated state (interpolated, interp_delay_ms behind); its body is a
## NetAvatarBody adapter (Desi's rig or the capsule), so swapping the model is one scene / config change.
## The local player never has one: it keeps first-person arms only.

var peer_id := 0
var slot := 0
var display_name := ""
var dead := false ## zombies skip dead / downed targets
var downed := false
var reviving := false
var body: NetAvatarBody
var name_tag: Label3D
var _buf: Array = [] ## [[recv_ms, pos, yaw, pitch, speed, crouch, flags], ...] oldest first
var _last_seq := -1
const F_AIR := 1
const F_ADS := 2
const F_DEAD := 4


static func create(p_peer: int, p_slot: int, p_name: String, body_kind: String = "") -> NetRemoteAvatar:
	var a := NetRemoteAvatar.new()
	a.peer_id = p_peer
	a.slot = p_slot
	a.display_name = p_name
	a.name = "Avatar%d" % p_peer
	var kind := body_kind if body_kind != "" else str(NetConfig.get_value("avatar.body", "desi"))
	var ok_desi := kind == "desi" and ResourceLoader.exists(str(NetConfig.get_value("avatar.scene", "")))
	a.body = NetDesiBody.new() if ok_desi else NetCapsuleBody.new()
	a.body.name = "Body"
	a.body.slot = p_slot
	return a


func _ready() -> void:
	add_to_group("net_avatar")
	collision_layer = 2 # "player": zombie projectiles / blight spit see it; local rays (world + enemy) don't
	collision_mask = 0
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.8
	shape.shape = cap
	shape.position.y = 0.9
	add_child(shape)
	if body:
		add_child(body)
		body.set_slot(slot)
	name_tag = Label3D.new()
	name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	name_tag.no_depth_test = true
	name_tag.fixed_size = true
	name_tag.pixel_size = 0.0012
	name_tag.font_size = 28
	name_tag.outline_size = 8
	name_tag.text = display_name
	name_tag.modulate = NetAvatarBody.tint_for(slot).lightened(0.35)
	var anchor := body.name_tag_anchor() if body else self
	anchor.add_child(name_tag)
	name_tag.position.y = float(NetConfig.get_value("avatar.name_tag_offset_m", 0.0)) if anchor != self else 2.1


func set_display_name(n: String) -> void:
	display_name = n
	if name_tag:
		name_tag.text = n


## A state packet from the owner: [seq, pos, yaw, pitch, speed, crouch, flags].
func push_state(st: Array) -> void:
	if st.size() < 7:
		return
	var seq := int(st[0])
	if seq <= _last_seq and _last_seq - seq < 1000: # stale / duplicate (wraps after a long time)
		return
	_last_seq = seq
	var pos: Vector3 = st[1]
	if _buf.is_empty() or pos.distance_to(_buf.back()[1]) > float(NetConfig.get_value("avatar.snap_teleport_m", 6.0)):
		_buf.clear() # first packet / respawn / teleport: snap
		global_position = pos
		rotation.y = float(st[2])
	_buf.append([Time.get_ticks_msec(), pos, float(st[2]), float(st[3]), float(st[4]), float(st[5]), int(st[6])])
	while _buf.size() > 32:
		_buf.pop_front()


func _physics_process(_delta: float) -> void:
	if _buf.is_empty():
		return
	var t := Time.get_ticks_msec() - int(NetConfig.get_value("tick.interp_delay_ms", 100))
	var a: Array = _buf[0]
	var b: Array = a
	for i in range(1, _buf.size()):
		if _buf[i][0] >= t:
			b = _buf[i]
			break
		a = _buf[i]
		b = a
	var f := 0.0 if b[0] == a[0] else clampf(float(t - a[0]) / float(b[0] - a[0]), 0.0, 1.0)
	global_position = (a[1] as Vector3).lerp(b[1], f)
	rotation.y = lerp_angle(a[2], b[2], f)
	while _buf.size() > 2 and _buf[1][0] < t: # keep one sample behind the render time
		_buf.pop_front()
	var flags := int(b[6])
	dead = flags & F_DEAD != 0
	if body:
		body.apply_state({"speed": lerpf(a[4], b[4], f), "crouch": lerpf(a[5], b[5], f), "airborne": flags & F_AIR != 0,
			"ads": flags & F_ADS != 0, "pitch": lerpf(a[3], b[3], f)})
		body.set_life(_life())


func _life() -> String:
	if dead:
		return NetAvatarBody.LIFE_DEAD
	if downed:
		return NetAvatarBody.LIFE_DOWNED
	if reviving:
		return NetAvatarBody.LIFE_REVIVING
	return NetAvatarBody.LIFE_ALIVE


func set_downed(v: bool) -> void:
	downed = v
	if body:
		body.set_life(_life())


func set_reviving(v: bool) -> void:
	reviving = v
	if body:
		body.set_life(_life())


func trigger(event_id: String, data: Dictionary = {}) -> void:
	if body:
		body.trigger(event_id, data)


func set_weapon(arch_id: String) -> void:
	if body:
		body.set_weapon(arch_id)


## Zombies hit this body on the host: the damage belongs to the owning player's own machine.
func take_damage(amount: float, attacker: Node = null) -> void:
	var net := get_node_or_null("/root/Net")
	if net and not dead and not downed:
		net.avatar_damaged(self, amount, attacker)


func is_crouched() -> bool:
	return body != null and body.crouch > 0.5


func head_center() -> Vector3:
	return global_position + Vector3(0, 1.62 if not is_crouched() else 1.0, 0)
