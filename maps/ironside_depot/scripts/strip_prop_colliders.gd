extends Node3D
## Ironside: put on a dressing group whose Desi glbs are VISUAL ONLY (debris piles, rubble on top of existing
## collision blocks). Frees every imported "-col" collider and hides the magenta "-col" preview meshes, so the
## dressing can never block a zombie route that the navmesh (baked without it) says is open.
func _ready() -> void:
	for c in find_children("*", "CollisionObject3D", true, false):
		c.get_parent().remove_child(c)
		c.queue_free()
	for mi in find_children("*", "MeshInstance3D", true, false):
		var n := String(mi.name) + String(mi.get_parent().name)
		var mat: Material = mi.get_active_material(0)
		if n.contains("-col") or (mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_color.is_equal_approx(Color(1, 0, 1))):
			mi.visible = false
