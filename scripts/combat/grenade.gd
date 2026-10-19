class_name Grenade
extends RigidBody3D
## Thrown physics grenade. Data (fuse, radius, damage, type...) comes from data/grenades.json.

var data: Dictionary = {}
var thrower: Node
var _fuse: float = 1.5
var _pulses_left: int = 0
var _pulse_timer: float = 0.0
var _armed_zone: MeshInstance3D
var _light: OmniLight3D
var _t: float = 0.0
var _bounce_cd: float = 0.0
var _loop: AudioStreamPlayer3D ## Tremor Charge pulse loop


static func throw_from(player: Node, grenade_data: Dictionary, origin: Vector3, dir: Vector3, inherit: Vector3) -> Grenade:
	var g := Grenade.new()
	g.data = grenade_data
	g.thrower = player
	player.get_tree().current_scene.add_child(g)
	g.global_position = origin
	g.linear_velocity = dir * float(grenade_data.get("throw_speed", 15.0)) + Vector3.UP * 3.0 + inherit * 0.5
	g.angular_velocity = Vector3(randf_range(-8, 8), randf_range(-8, 8), randf_range(-8, 8))
	return g


func _ready() -> void:
	collision_layer = 8 # layer 4: projectiles
	collision_mask = 1 | 4
	continuous_cd = true
	mass = 0.4
	var pm := PhysicsMaterial.new()
	pm.bounce = float(data.get("bounce", 0.4))
	pm.friction = 0.8
	physics_material_override = pm
	linear_damp = 0.3
	angular_damp = 1.5
	var shape := CollisionShape3D.new()
	var s := SphereShape3D.new()
	s.radius = 0.09
	shape.shape = s
	add_child(shape)
	var c := _color()
	var mesh := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.09
	sm.height = 0.18
	mesh.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.15, 0.17, 0.15)
	m.metallic = 0.6
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 0.8
	mesh.material_override = m
	add_child(mesh)
	_light = OmniLight3D.new()
	_light.light_color = c
	_light.light_energy = 1.0
	_light.omni_range = 1.5
	add_child(_light)
	_fuse = float(data.get("fuse", 1.5))
	contact_monitor = true
	max_contacts_reported = 2
	body_entered.connect(_on_bounce)


func _sfx() -> Node:
	return get_node_or_null("/root/Sfx")


func _on_bounce(_body: Node) -> void:
	if _bounce_cd > 0.0 or linear_velocity.length() < 1.5 or freeze:
		return
	_bounce_cd = 0.12
	var a := _sfx()
	if a:
		a.play_at("frag_bounce", global_position, clampf(linear_velocity.length() - 8.0, -8.0, 0.0))


func _color() -> Color:
	var a: Array = data.get("color", [1, 0.5, 0.2])
	return Color(a[0], a[1], a[2])


func _physics_process(delta: float) -> void:
	_t += delta
	_bounce_cd = max(_bounce_cd - delta, 0.0)
	_light.light_energy = 0.5 + 1.5 * absf(sin(_t * 18.0))
	if _pulses_left > 0:
		_pulse_timer -= delta
		if _pulse_timer <= 0.0:
			_pulse()
		return
	_fuse -= delta
	if _fuse <= 0.0:
		_detonate()


func _detonate() -> void:
	var bus := get_node_or_null("/root/GameEvents")
	if bus and thrower:
		bus.emit_event(&"grenade_detonated", {"player": thrower, "pos": global_position, "data": data})
	if data.get("type", "frag") == "pulse":
		freeze = true
		_pulses_left = int(data.get("pulses", 4))
		_pulse_timer = 0.0
		_armed_zone = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		var r := float(data.get("radius", 4.0))
		cm.top_radius = r
		cm.bottom_radius = r
		cm.height = 0.05
		_armed_zone.mesh = cm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var c := _color()
		m.albedo_color = Color(c.r, c.g, c.b, 0.25)
		_armed_zone.material_override = m
		add_child(_armed_zone)
		_armed_zone.global_rotation = Vector3.ZERO
		var a := _sfx()
		if a:
			_loop = a.attach_loop("tremor_charge_pulse_loop", self) # stops when the grenade is freed
		return
	var a2 := _sfx()
	if a2:
		a2.play_at("frag_explode", global_position)
	Explosion.explode(get_tree().current_scene, global_position, float(data.get("radius", 5.0)),
		float(data.get("damage", 200)), float(data.get("knockback", 8.0)), _color(), thrower, null, 1.0, {"source": "grenade"})
	queue_free()


func _pulse() -> void:
	_pulses_left -= 1
	_pulse_timer = float(data.get("interval", 0.5))
	Explosion.explode(get_tree().current_scene, global_position, float(data.get("radius", 4.0)),
		float(data.get("damage", 60)), float(data.get("knockback", 2.0)), _color(), thrower, null, 0.45, {"source": "grenade"})
	if _pulses_left <= 0:
		queue_free()
