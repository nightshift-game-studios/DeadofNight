extends Node3D
## Lightweight telegraph stubs for boss attacks (Skillz). Circle = slam AoE; line = charge / lantern beam.
## Instantiate via preload("res://scripts/enemies/boss_telegraph.gd").new() then setup_circle / setup_line.
## No class_name (avoids self-referential .new() compile issues).

enum Kind { CIRCLE, LINE }

var kind: Kind = Kind.CIRCLE
var radius: float = 3.5
var length: float = 10.0
var width: float = 0.6
var color: Color = Color(1.0, 0.25, 0.15, 0.45)
var _mesh: MeshInstance3D
var _mat: StandardMaterial3D
var _t: float = 0.0
var _dur: float = 1.0


func setup_circle(at: Vector3, rad: float, duration: float, col: Color = Color(1.0, 0.35, 0.1, 0.5)) -> void:
	kind = Kind.CIRCLE
	radius = rad
	color = col
	_dur = maxf(duration, 0.05)
	global_position = Vector3(at.x, at.y + 0.05, at.z)
	_rebuild()


func setup_line(from: Vector3, dir: Vector3, len: float, duration: float, col: Color = Color(1.0, 0.15, 0.1, 0.55), wid: float = 0.55) -> void:
	kind = Kind.LINE
	length = len
	width = wid
	color = col
	_dur = maxf(duration, 0.05)
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() < 0.001:
		flat = Vector3.FORWARD
	flat = flat.normalized()
	global_position = Vector3(from.x, from.y + 0.05, from.z) + flat * (len * 0.5)
	rotation.y = atan2(-flat.x, -flat.z)
	_rebuild()


## Convenience: create + add_child + setup_circle.
static func spawn_circle(parent: Node3D, at: Vector3, rad: float, duration: float, col: Color = Color(1.0, 0.35, 0.1, 0.5)) -> Node3D:
	var scr: GDScript = load("res://scripts/enemies/boss_telegraph.gd") as GDScript
	var t: Node3D = scr.new()
	parent.add_child(t)
	t.call("setup_circle", at, rad, duration, col)
	return t


static func spawn_line(parent: Node3D, from: Vector3, dir: Vector3, len: float, duration: float, col: Color = Color(1.0, 0.15, 0.1, 0.55), wid: float = 0.55) -> Node3D:
	var scr: GDScript = load("res://scripts/enemies/boss_telegraph.gd") as GDScript
	var t: Node3D = scr.new()
	parent.add_child(t)
	t.call("setup_line", from, dir, len, duration, col, wid)
	return t


func _ready() -> void:
	if _mesh == null:
		_rebuild()


func _rebuild() -> void:
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mat = StandardMaterial3D.new()
		_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.albedo_color = color
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mesh.material_override = _mat
		add_child(_mesh)
	_mat.albedo_color = color
	if kind == Kind.CIRCLE:
		var cyl := CylinderMesh.new()
		cyl.top_radius = radius
		cyl.bottom_radius = radius
		cyl.height = 0.04
		cyl.radial_segments = 24
		_mesh.mesh = cyl
	else:
		var box := BoxMesh.new()
		box.size = Vector3(width, 0.04, length)
		_mesh.mesh = box


func _process(delta: float) -> void:
	_t += delta
	var a := clampf(1.0 - _t / _dur, 0.0, 1.0)
	if _mat:
		var c := color
		c.a = color.a * (0.35 + 0.65 * a)
		_mat.albedo_color = c
	if _t >= _dur:
		queue_free()
