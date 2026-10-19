extends SceneTree
## Run with a display:  godot --path . -s res://tests/render_armor_icons.gd
## Renders armor tile / item-card icons from the display GLBs in data/armor_models.json into
## res://assets/icons/armor_<piece>.png (dev tool, Gooey; same idea as render_icons.gd). Re-run when the models change.
func _initialize(): _go.call_deferred()
func _go():
	var vp := SubViewport.new()
	vp.size = Vector2i(160, 160)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.position = Vector3(0, 0, 5)
	vp.add_child(cam)
	var l := DirectionalLight3D.new()
	l.rotation_degrees = Vector3(-35, 25, 0)
	l.light_energy = 1.5
	vp.add_child(l)
	var l2 := DirectionalLight3D.new()
	l2.rotation_degrees = Vector3(20, 160, 0)
	l2.light_energy = 0.6
	vp.add_child(l2)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.8, 0.8, 0.85)
	env.ambient_light_energy = 0.8
	we.environment = env
	vp.add_child(we)
	for piece in ArmorModels.data().get("pieces", {}):
		var path: String = ArmorModels.piece(piece).get("display", "")
		if path == "" or not ResourceLoader.exists(path):
			continue
		var model: Node3D = (load(path) as PackedScene).instantiate()
		var holder := Node3D.new()
		vp.add_child(holder)
		holder.add_child(model)
		var meshes := model.find_children("*", "MeshInstance3D", true, false)
		if piece == "gauntlets" and meshes.size() >= 2: # side by side
			meshes[0].position = Vector3(0.13, 0, 0)
			meshes[1].position = Vector3(-0.13, 0, 0)
		holder.rotation_degrees = Vector3(8, 28, 0)
		await process_frame
		var box := AABB()
		var first := true
		for mi in meshes:
			var a: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			box = a if first else box.merge(a)
			first = false
		model.position -= box.get_center()
		cam.size = maxf(box.size.x, box.size.y) * 1.12
		for i in 4: await process_frame
		vp.get_texture().get_image().save_png("res://assets/icons/armor_%s.png" % piece)
		print("icon armor_", piece)
		holder.queue_free()
		await process_frame
	quit()
