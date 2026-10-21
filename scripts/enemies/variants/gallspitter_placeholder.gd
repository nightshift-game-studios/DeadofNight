extends RefCounted
## Gallspitter placeholder model (Skillz, DESIGN §22) until Desi's res://assets/models/zombies/gallspitter.glb lands.
## Same node names, socket positions and clip names as DESI_RANGED.md, so the behaviour script can't tell the difference:
##   Gallspitter (root, feet at origin, faces -Z)
##     Body / ArmL / ArmR (meshes)   Chest (socket)   GallSac (glowing throat sac, the telegraph)
##     Head (pivot + head hitbox) / Head/HeadPoint (socket)    Head/ProjectileSpawn (mouth socket, -Z = spit direction)
##     AnimationPlayer: Idle (loop), Walk (loop), Spit (1.1 s, marker "release" at 0.7), Hit (0.35 s), Death (1.2 s)
## Built at 1.70 m (zombies.json gallspitter.model_height), so the auto-scale is 1.0.

const HEIGHT := 1.7
const SKIN := Color(0.36, 0.40, 0.30)
const SAC := Color(0.62, 0.78, 0.16)

## Positions (m, model space at 1.70 m) - DESI_RANGED.md quotes the same numbers.
const CHEST := Vector3(0.0, 1.10, -0.06)
const SAC_POS := Vector3(0.0, 1.20, -0.20)
const HEAD := Vector3(0.0, 1.50, -0.16)
const MOUTH_LOCAL := Vector3(0.0, -0.06, -0.17) ## ProjectileSpawn under Head -> model (0, 1.44, -0.33)


static func _mat(c: Color, emit: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.75
	if emit > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = emit
	return m


static func _mesh(name: String, mesh: Mesh, mat: Material, pos: Vector3, parent: Node3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


static func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	return c


static func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	return s


static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "Gallspitter"
	var skin := _mat(SKIN)
	var body := _mesh("Body", _capsule(0.27, 1.22), skin, Vector3(0, 0.78, 0.02), root)
	body.rotation_degrees.x = -14.0 # hunched forward
	_mesh("LegL", _capsule(0.09, 0.62), skin, Vector3(-0.13, 0.31, 0.0), root)
	_mesh("LegR", _capsule(0.09, 0.62), skin, Vector3(0.13, 0.31, 0.0), root)
	var arm_l := _mesh("ArmL", _capsule(0.06, 0.78), skin, Vector3(-0.32, 0.95, -0.08), root)
	arm_l.rotation_degrees = Vector3(-20, 0, -8)
	var arm_r := _mesh("ArmR", _capsule(0.06, 0.78), skin, Vector3(0.32, 0.95, -0.08), root)
	arm_r.rotation_degrees = Vector3(-20, 0, 8)
	var chest := Marker3D.new()
	chest.name = "Chest"
	chest.position = CHEST
	root.add_child(chest)
	var sac := _mesh("GallSac", _sphere(0.16), _mat(SAC, 0.6), SAC_POS, root)
	sac.scale = Vector3(1.0, 0.85, 1.0)
	var head := Node3D.new()
	head.name = "Head"
	head.position = HEAD
	root.add_child(head)
	_mesh("HeadMesh", _sphere(0.15), skin, Vector3.ZERO, head)
	var hp := Marker3D.new()
	hp.name = "HeadPoint" # Desi's socket name (HeadPoint, not Head: a Head node renames the GLB's Head bone)
	head.add_child(hp)
	var jaw := _mesh("Jaw", _capsule(0.07, 0.2), _mat(Color(0.22, 0.2, 0.16)), Vector3(0, -0.07, -0.1), head)
	jaw.rotation_degrees.x = 90.0
	var mouth := Marker3D.new()
	mouth.name = "ProjectileSpawn"
	mouth.position = MOUTH_LOCAL
	head.add_child(mouth)
	var eyes := _mat(Color(0.85, 0.95, 0.3), 2.0)
	_mesh("EyeL", _sphere(0.025), eyes, Vector3(-0.055, 0.03, -0.13), head)
	_mesh("EyeR", _sphere(0.025), eyes, Vector3(0.055, 0.03, -0.13), head)
	var ap := AnimationPlayer.new()
	ap.name = "AnimationPlayer"
	root.add_child(ap)
	var lib := AnimationLibrary.new()
	lib.add_animation("Idle", _idle())
	lib.add_animation("Walk", _walk())
	lib.add_animation("Spit", _spit())
	lib.add_animation("Hit", _hit())
	lib.add_animation("Death", _death())
	ap.add_animation_library("", lib)
	return root


static func _track(a: Animation, path: String, keys: Array) -> void:
	var t := a.add_track(Animation.TYPE_VALUE)
	a.track_set_path(t, NodePath(path))
	a.value_track_set_update_mode(t, Animation.UPDATE_CONTINUOUS)
	for k in keys:
		a.track_insert_key(t, float(k[0]), k[1])


static func _idle() -> Animation:
	var a := Animation.new()
	a.length = 2.0
	a.loop_mode = Animation.LOOP_LINEAR
	_track(a, "Body:position", [[0.0, Vector3(0, 0.78, 0.02)], [1.0, Vector3(0, 0.76, 0.02)], [2.0, Vector3(0, 0.78, 0.02)]])
	_track(a, "GallSac:scale", [[0.0, Vector3(1, 0.85, 1)], [1.0, Vector3(1.08, 0.92, 1.08)], [2.0, Vector3(1, 0.85, 1)]])
	return a


static func _walk() -> Animation:
	var a := Animation.new()
	a.length = 1.0
	a.loop_mode = Animation.LOOP_LINEAR
	_track(a, "LegL:rotation", [[0.0, Vector3(0.5, 0, 0)], [0.5, Vector3(-0.5, 0, 0)], [1.0, Vector3(0.5, 0, 0)]])
	_track(a, "LegR:rotation", [[0.0, Vector3(-0.5, 0, 0)], [0.5, Vector3(0.5, 0, 0)], [1.0, Vector3(-0.5, 0, 0)]])
	_track(a, "Body:position", [[0.0, Vector3(0, 0.78, 0.02)], [0.25, Vector3(0, 0.74, 0.02)], [0.5, Vector3(0, 0.78, 0.02)],
		[0.75, Vector3(0, 0.74, 0.02)], [1.0, Vector3(0, 0.78, 0.02)]])
	return a


## 0.0-0.7 wind-up (head rears back, sac swells: the telegraph), "release" marker at 0.7 (lunge), 0.7-1.1 recovery.
static func _spit() -> Animation:
	var a := Animation.new()
	a.length = 1.1
	_track(a, "Head:rotation", [[0.0, Vector3.ZERO], [0.6, Vector3(0.55, 0, 0)], [0.7, Vector3(-0.35, 0, 0)], [1.1, Vector3.ZERO]])
	_track(a, "Head:position", [[0.0, HEAD], [0.6, HEAD + Vector3(0, 0.04, 0.1)], [0.7, HEAD + Vector3(0, -0.02, -0.12)], [1.1, HEAD]])
	_track(a, "GallSac:scale", [[0.0, Vector3(1, 0.85, 1)], [0.65, Vector3(1.6, 1.45, 1.6)], [0.72, Vector3(0.8, 0.7, 0.8)], [1.1, Vector3(1, 0.85, 1)]])
	_track(a, "Body:rotation", [[0.0, Vector3(-0.24, 0, 0)], [0.6, Vector3(0.05, 0, 0)], [0.75, Vector3(-0.42, 0, 0)], [1.1, Vector3(-0.24, 0, 0)]])
	a.add_marker("release", 0.7)
	return a


static func _hit() -> Animation:
	var a := Animation.new()
	a.length = 0.35
	_track(a, "Body:rotation", [[0.0, Vector3(-0.24, 0, 0)], [0.1, Vector3(0.15, 0, 0.1)], [0.35, Vector3(-0.24, 0, 0)]])
	return a


static func _death() -> Animation:
	var a := Animation.new()
	a.length = 1.2
	_track(a, "Body:rotation", [[0.0, Vector3(-0.24, 0, 0)], [1.0, Vector3(1.35, 0, 0.2)], [1.2, Vector3(1.4, 0, 0.2)]])
	_track(a, "Body:position", [[0.0, Vector3(0, 0.78, 0.02)], [1.0, Vector3(0, 0.3, 0.45)], [1.2, Vector3(0, 0.28, 0.48)]])
	_track(a, "Head:position", [[0.0, HEAD], [1.0, Vector3(0, 0.35, 0.95)], [1.2, Vector3(0, 0.3, 1.0)]])
	_track(a, "GallSac:scale", [[0.0, Vector3(1, 0.85, 1)], [0.5, Vector3(1.3, 1.2, 1.3)], [0.6, Vector3(0.2, 0.2, 0.2)], [1.2, Vector3(0.2, 0.2, 0.2)]])
	return a
