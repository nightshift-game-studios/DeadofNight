extends Node3D
## Attached to DesiCars / DesiDebris / Dressing: hide magenta *-col mesh visuals; keep StaticBody colliders.
func _ready() -> void:
	for mi in find_children("*", "MeshInstance3D", true, false):
		if _is_col_visual(mi):
			mi.visible = false

func _is_col_visual(mi: MeshInstance3D) -> bool:
	var n := String(mi.name)
	var pn := String(mi.get_parent().name) if mi.get_parent() else ""
	if n.contains("-col") or pn.contains("-col"):
		return true
	if mi.mesh and String(mi.mesh.resource_name).contains("-col"):
		return true
	var mat: Material = mi.get_active_material(0)
	if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
		mat = mi.mesh.surface_get_material(0)
	if mat and String(mat.resource_name).contains("-col"):
		return true
	if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_color.is_equal_approx(Color(1, 0, 1)):
		return true
	return false
