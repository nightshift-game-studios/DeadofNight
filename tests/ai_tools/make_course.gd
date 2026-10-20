extends SceneTree
## Generates res://tests/ai_nav_course.tscn: a synthetic map-contract course for ai_nav_test.gd (Skillz).
## godot --headless --path . -s res://tests/ai_tools/make_course.gd
var croot: Node3D
var geo: Node3D

func _initialize() -> void:
	croot = Node3D.new()
	croot.name = "AiNavCourse"
	croot.set_script(load("res://maps/common/map_root.gd"))
	croot.set("map_id", &"ai_course")
	croot.set("display_name", "AI Nav Course")
	croot.set_meta("map_id", "ai_course")
	var env := WorldEnvironment.new(); env.name = "WorldEnvironment"; env.environment = Environment.new(); _add(croot, env)
	var sun := DirectionalLight3D.new(); sun.name = "Sun"; sun.rotation_degrees = Vector3(-50, 30, 0); _add(croot, sun)
	var nr := NavigationRegion3D.new(); nr.name = "NavigationRegion3D"
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.geometry_collision_mask = 1
	nm.agent_height = 2.0; nm.agent_radius = 0.5; nm.agent_max_climb = 0.5; nm.agent_max_slope = 40.0
	nm.cell_size = 0.25; nm.cell_height = 0.25
	nr.navigation_mesh = nm
	_add(croot, nr)
	geo = Node3D.new(); geo.name = "Geometry"; _add(nr, geo)
	var doors := Node3D.new(); doors.name = "Doors"; _add(nr, doors)
	# floor + perimeter
	_box("Floor", Vector3(0, -0.5, 0), Vector3(70, 1, 70))
	_box("WallN", Vector3(0, 2, -35.5), Vector3(72, 4, 1)); _box("WallS", Vector3(0, 2, 35.5), Vector3(72, 4, 1))
	_box("WallE", Vector3(35.5, 2, 0), Vector3(1, 4, 72)); _box("WallW", Vector3(-35.5, 2, 0), Vector3(1, 4, 72))
	# u_trap: cup open to +Z, player behind the back wall (-Z)
	_box("CupBack", Vector3(0, 1.5, -6), Vector3(6.6, 3, 0.6)); _box("CupL", Vector3(-3, 1.5, -3.5), Vector3(0.6, 3, 5)); _box("CupR", Vector3(3, 1.5, -3.5), Vector3(0.6, 3, 5))
	# wedge_ramp: 2 m platform reached by a 7 m wedge (16 deg), crate beside the foot
	_box("RampPlatform", Vector3(20, 1.0, -16.5), Vector3(6, 2, 7))
	_wedge("WedgeRamp", 18.0, 22.0, -6.0, -13.0, 2.0)
	_box("RampFootCrate", Vector3(17.0, 0.45, -5.0), Vector3(1.2, 0.9, 1.2))
	# step_ledges: two 0.3 m steps (box ledges, no wedge) up to a 0.6 m deck
	_box("Ledge1", Vector3(-20, 0.15, -9), Vector3(8, 0.3, 2))
	_box("LedgeDeck", Vector3(-20, 0.3, -14), Vector3(8, 0.6, 8))
	# box_stairs: six 0.25 m box risers (0.6 m treads) to a 1.5 m deck
	for k in 6:
		var top := 0.25 * (k + 1)
		_box("Stair%d" % k, Vector3(-10.3 - 0.6 * k, top * 0.5, 18), Vector3(0.6, top, 4))
	_box("StairDeck", Vector3(-18.8, 0.75, 18), Vector3(10.4, 1.5, 6))
	# doorway_pillars: pillar field, then a wall with a 1.6 m doorway
	for ix in 5:
		for iz in 3:
			_box("Pillar_%d_%d" % [ix, iz], Vector3(6 + ix * 2.2 + (iz % 2) * 1.1, 1.5, 8 + iz * 2.0), Vector3(0.6, 3, 0.6))
	_box("DoorWallW", Vector3(9.6, 1.5, 14), Vector3(15.2, 3, 0.6))
	_box("DoorWallE", Vector3(27.1, 1.5, 14), Vector3(16.2, 3, 0.6))
	# steep_slope: 32 deg wedge to a 2.5 m deck
	_wedge("SteepSlope", -2.0, 2.0, 16.0, 20.0, 2.5)
	_box("SlopeDeck", Vector3(0, 1.25, 23), Vector3(4, 2.5, 6))
	# markers
	var ps := Marker3D.new(); ps.name = "PlayerSpawn"; ps.position = Vector3(0, 0.1, 0); _add(croot, ps)
	var sp := Node3D.new(); sp.name = "SpawnPoints"; _add(croot, sp)
	var spots := [Vector3(-30, 0.1, -30), Vector3(30, 0.1, -30), Vector3(-30, 0.1, 30), Vector3(30, 0.1, 30), Vector3(0, 0.1, 30), Vector3(-30, 0.1, 0)]
	for i in spots.size():
		var m := Marker3D.new(); m.name = "Spawn%d" % (i + 1); m.position = spots[i]; m.set_meta("area", &"start"); _add(sp, m)
	var ps2 := PackedScene.new()
	var err := ps2.pack(croot)
	print("pack ", err, " save ", ResourceSaver.save(ps2, "res://tests/ai_nav_course.tscn"))
	quit()

func _add(parent: Node, n: Node) -> void:
	parent.add_child(n)
	n.owner = croot

func _body(name: String, pos: Vector3) -> StaticBody3D:
	var b := StaticBody3D.new(); b.name = name; b.position = pos; b.collision_layer = 1; b.collision_mask = 0
	b.set_meta("surface", "concrete")
	_add(geo, b)
	return b

func _box(name: String, pos: Vector3, size: Vector3) -> void:
	var b := _body(name, pos)
	var cs := CollisionShape3D.new(); cs.name = "Collision"; var sh := BoxShape3D.new(); sh.size = size; cs.shape = sh; _add(b, cs)
	var mi := MeshInstance3D.new(); mi.name = "Mesh"; var bm := BoxMesh.new(); bm.size = size; mi.mesh = bm; _add(b, mi)

## Wedge from z0 (ground) to z1 (height h), x0..x1 wide.
func _wedge(name: String, x0: float, x1: float, z0: float, z1: float, h: float) -> void:
	var b := _body(name, Vector3.ZERO)
	var pts := PackedVector3Array([Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x0, 0, z1), Vector3(x1, 0, z1), Vector3(x0, h, z1), Vector3(x1, h, z1)])
	var cs := CollisionShape3D.new(); cs.name = "Collision"; var sh := ConvexPolygonShape3D.new(); sh.points = pts; cs.shape = sh; _add(b, cs)
	var mi := MeshInstance3D.new(); mi.name = "Mesh"
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for tri in [[0, 2, 4], [0, 4, 1], [1, 4, 5], [1, 5, 3], [2, 3, 5], [2, 5, 4], [0, 1, 3], [0, 3, 2]]:
		for idx in tri: st.add_vertex(pts[idx])
	st.generate_normals(); mi.mesh = st.commit(); _add(b, mi)
