extends Area3D
## Lantern Stalker blight spit (Skillz). Dodgeable projectile; damages the player on body enter.

var velocity: Vector3 = Vector3.ZERO
var damage: int = 20
var lifetime: float = 3.5
var _owner: Node = null
var on_land: Callable = Callable() ## host: called with the landing position when it hits a player or a wall (boss rework: gloam puddles)
var visual_only: bool = false ## NET B5: a co-op client's copy of the host's spit: flies and pops, never damages


static func fire(from_node: Node3D, origin: Vector3, dir: Vector3, dmg: int, speed: float = 14.0, visual: bool = false, land: Callable = Callable()) -> Area3D:
	var p := load("res://scripts/enemies/blight_spit.gd").new() as Area3D
	p.damage = dmg
	p.visual_only = visual
	p.on_land = land
	p.velocity = dir.normalized() * speed
	p._owner = from_node
	from_node.get_tree().current_scene.add_child(p)
	p.global_position = origin
	return p


func _ready() -> void:
	monitoring = true
	monitorable = false
	collision_layer = 0
	collision_mask = 1 # world + player default layer
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 0.22
	cs.shape = sph
	add_child(cs)
	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.18
	sm.height = 0.36
	mesh.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.45, 0.9, 0.25, 0.9)
	mat.emission_enabled = true
	mat.emission = Color(0.3, 0.7, 0.1)
	mesh.material_override = mat
	add_child(mesh)
	body_entered.connect(_on_body)


func _physics_process(delta: float) -> void:
	global_position += velocity * delta
	lifetime -= delta
	if lifetime <= 0.0:
		queue_free()


func _on_body(body: Node) -> void:
	if body == _owner:
		return
	# NET B5: co-op host also hits remote avatars (they forward the damage to their owner); visual copies never damage.
	if (body.is_in_group("player") or body.is_in_group("net_avatar")) and body.has_method("take_damage"):
		if not visual_only:
			body.call("take_damage", damage, _owner)
		_landed()
		queue_free()
	elif body is StaticBody3D or body is CSGShape3D:
		_landed()
		queue_free()


func _landed() -> void:
	if not visual_only and on_land.is_valid():
		on_land.call(global_position)
