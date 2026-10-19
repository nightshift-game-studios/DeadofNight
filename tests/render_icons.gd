extends SceneTree
## Run with a display:  godot --path . -s res://tests/render_icons.gd
## Renders weapon tile icons into res://assets/icons/<archetype>.png (dev tool).
func _initialize(): _go.call_deferred()
func _go():
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/weapons.json"))
	var vp := SubViewport.new()
	vp.size = Vector2i(256, 160)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.position = Vector3(0, 0, 5)
	vp.add_child(cam)
	var l := DirectionalLight3D.new()
	l.rotation_degrees = Vector3(-35, 25, 0)
	l.light_energy = 1.4
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
	env.ambient_light_energy = 0.7
	we.environment = env
	vp.add_child(we)
	for a in data.archetypes:
		var model: Node3D = (load(a.model) as PackedScene).instantiate()
		var holder := Node3D.new()
		vp.add_child(holder)
		holder.add_child(model)
		holder.rotation_degrees = Vector3(0, 0, 8) # barrel along +X, slight tilt
		await process_frame
		var aabb := ModelUtil.get_aabb(model)
		model.position = -aabb.get_center()
		cam.size = max(aabb.size.x * 0.62 * 1.1, aabb.size.y * 1.1)
		for i in 3: await process_frame
		var img := vp.get_texture().get_image()
		img.save_png("res://assets/icons/%s.png" % a.id)
		print("icon ", a.id)
		holder.queue_free()
		await process_frame
	quit()
