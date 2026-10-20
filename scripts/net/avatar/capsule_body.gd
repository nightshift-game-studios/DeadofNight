class_name NetCapsuleBody
extends NetAvatarBody
## Placeholder remote-player body: a tinted capsule with a "visor" so facing reads, a box for the gun.

var mesh: MeshInstance3D
var head_anchor: Node3D
var gun_socket: Node3D
var _mat: StandardMaterial3D
var last_event := ""


func _ready() -> void:
	mesh = MeshInstance3D.new()
	var cap := CapsuleMesh.new()
	cap.radius = 0.35
	cap.height = 1.8
	mesh.mesh = cap
	mesh.position.y = 0.9
	_mat = StandardMaterial3D.new()
	mesh.material_override = _mat
	add_child(mesh)
	var visor := MeshInstance3D.new()
	var vb := BoxMesh.new()
	vb.size = Vector3(0.4, 0.12, 0.1)
	visor.mesh = vb
	visor.position = Vector3(0, 1.6, -0.32)
	add_child(visor)
	head_anchor = Node3D.new()
	head_anchor.position.y = 2.1
	add_child(head_anchor)
	gun_socket = Node3D.new()
	gun_socket.position = Vector3(0.3, 1.25, -0.35)
	gun_socket.rotation_degrees.y = 90.0 # weapons/*.glb: +X forward -> -Z
	add_child(gun_socket)
	set_slot(slot)


func name_tag_anchor() -> Node3D:
	return head_anchor if head_anchor else self


func _apply_tint(c: Color) -> void:
	if _mat:
		_mat.albedo_color = c


func _apply_weapon(arch_id: String) -> void:
	if gun_socket == null:
		return
	for c in gun_socket.get_children():
		c.queue_free()
	var m := weapon_model(arch_id)
	if m:
		gun_socket.add_child(m)


func _apply_life(_prev: String, state: String) -> void:
	if mesh == null:
		return
	match state: # lie down for downed / dead, kneel for reviving
		LIFE_DOWNED, LIFE_DEAD:
			mesh.rotation_degrees.x = 90.0
			mesh.position.y = 0.35
		LIFE_REVIVING:
			mesh.rotation_degrees.x = 0.0
			mesh.position.y = 0.6
		_:
			mesh.rotation_degrees.x = 0.0
			mesh.position.y = 0.9


func _trigger(event_id: String, _data: Dictionary) -> void:
	last_event = event_id
