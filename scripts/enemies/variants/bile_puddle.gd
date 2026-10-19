extends Node3D
## Bloater bile puddle (art pass 3): a flat disc left by the death burst. While the player stands in it they are
## slowed (PlayerStatus.slow; needs MAIN_HOOKS §15b to actually change movement). Zombies walking through it are
## not slowed. Frees itself after `duration` seconds.

const PlayerStatusScr := preload("res://scripts/combat/player_status.gd")

var radius: float = 2.2
var duration: float = 4.0
var slow_amp: float = 0.45
var age: float = 0.0
var _mesh: MeshInstance3D
var player_inside: bool = false


static func spawn(parent: Node, pos: Vector3, r: float, dur: float, amp: float) -> Node3D:
	var p: Node3D = (load("res://scripts/enemies/variants/bile_puddle.gd") as GDScript).new()
	p.name = "BilePuddle"
	p.radius = r
	p.duration = dur
	p.slow_amp = amp
	p.add_to_group("bile_puddles")
	parent.add_child(p)
	p.global_position = pos
	return p


func _ready() -> void:
	_mesh = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.02
	cyl.radial_segments = 24
	_mesh.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.55, 0.12, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.15
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.35, 0.05)
	mat.emission_energy_multiplier = 0.4
	_mesh.material_override = mat
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.position.y = 0.03
	add_child(_mesh)


func _physics_process(delta: float) -> void:
	age += delta
	if age >= duration:
		queue_free()
		return
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	player_inside = false
	if pl and not pl.get("dead"):
		var d := Vector2(pl.global_position.x - global_position.x, pl.global_position.z - global_position.z).length()
		if d <= radius and absf(pl.global_position.y - global_position.y) < 1.5:
			player_inside = true
			PlayerStatusScr.slow(pl, slow_amp, 0.2, self)
	var fade := clampf((duration - age) / 0.6, 0.0, 1.0)
	if _mesh and _mesh.material_override:
		(_mesh.material_override as StandardMaterial3D).albedo_color.a = 0.7 * fade
