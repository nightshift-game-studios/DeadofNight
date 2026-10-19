@tool
extends EditorScenePostImport
## Hide Desi *-col magenta collision meshes after glTF import (Godot keeps them visible by default).
func _post_import(scene: Node) -> Object:
	for mi in scene.find_children("*", "MeshInstance3D", true, false):
		var hide := false
		if String(mi.name).contains("-col"):
			hide = true
		elif mi.mesh and String(mi.mesh.resource_name).contains("-col"):
			hide = true
		else:
			var mat: Material = mi.get_active_material(0)
			if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
				mat = mi.mesh.surface_get_material(0)
			if mat and String(mat.resource_name).contains("-col"):
				hide = true
			elif mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_color.is_equal_approx(Color(1, 0, 1)):
				hide = true
		if hide:
			mi.visible = false
	return scene
