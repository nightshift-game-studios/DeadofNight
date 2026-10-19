class_name ModelUtil
## Helpers for imported models.


## Combined AABB of every mesh under `root`, in root's local space.
static func get_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var inv := root.global_transform.affine_inverse() if root.is_inside_tree() else Transform3D.IDENTITY
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var t: Transform3D
		if root.is_inside_tree():
			t = inv * mi.global_transform
		else:
			t = _local_to(root, mi)
		var a: AABB = t * mi.mesh.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


static func _local_to(root: Node3D, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


static func set_shadows(root: Node, on: bool) -> void:
	for mi in root.find_children("*", "GeometryInstance3D", true, false):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
