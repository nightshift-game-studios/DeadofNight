class_name Effects
## Small, throwaway visual effects built from primitive meshes (no assets needed).


static func _unshaded(color: Color, energy: float = 2.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat


## Bullet tracer: a thin stretched box from the muzzle to the hit point that fades out.
static func spawn_tracer(parent: Node, from: Vector3, to: Vector3, color: Color = Color(1.0, 0.85, 0.4, 0.8)) -> void:
	var length := from.distance_to(to)
	if length < 0.05 or parent == null:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.015, 0.015, length)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := _unshaded(Color(color.r, color.g, color.b, 0.8), 3.0)
	mi.material_override = mat
	parent.add_child(mi)
	var mid := (from + to) * 0.5
	var up := Vector3.UP
	if abs((to - from).normalized().dot(up)) > 0.99:
		up = Vector3.FORWARD
	mi.look_at_from_position(mid, to, up)
	var tween := mi.create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.08)
	tween.tween_callback(mi.queue_free)


## Impact puff at the hit point. Red for enemies, light grey sparks for walls.
static func spawn_impact(parent: Node, pos: Vector3, normal: Vector3, hit_enemy: bool) -> void:
	if parent == null:
		return
	var color := Color(1.0, 0.15, 0.1, 1.0) if hit_enemy else Color(1.0, 0.9, 0.6, 1.0)
	var mesh := SphereMesh.new()
	mesh.radius = 0.08
	mesh.height = 0.16
	mesh.radial_segments = 8
	mesh.rings = 4
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := _unshaded(color, 4.0)
	mi.material_override = mat
	parent.add_child(mi)
	mi.global_position = pos + normal * 0.03
	var tween := mi.create_tween().set_parallel(true)
	tween.tween_property(mi, "scale", Vector3.ONE * 2.5, 0.15)
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.15)
	tween.chain().tween_callback(mi.queue_free)
