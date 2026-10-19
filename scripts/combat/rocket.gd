class_name Rocket
extends Node3D
## Rocket projectile: flies straight, explodes on impact (or after its lifetime).

var velocity: Vector3
var damage: float = 250.0
var radius: float = 5.0
var knockback: float = 12.0
var shooter: Node
var weapon: WeaponItem
var _life: float = 4.0
var _trail_t: float = 0.0
var _color := Color(1.0, 0.5, 0.2)


static func fire(player: Node, w: WeaponItem, origin: Vector3, dir: Vector3, dmg: float) -> Rocket:
	var r := Rocket.new()
	var p: Dictionary = w.arch.get("projectile", {})
	r.velocity = dir * float(p.get("speed", 30.0))
	r.radius = float(p.get("radius", 5.0))
	r.knockback = float(p.get("knockback", 12.0))
	r.damage = dmg
	r.shooter = player
	r.weapon = w
	r._color = GearDB.element_color(w.element) if w.element != "ballistic" else Color(1.0, 0.5, 0.2)
	player.get_tree().current_scene.add_child(r)
	r.global_position = origin
	r.look_at(origin + dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
	return r


func _ready() -> void:
	var body := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.05
	cm.height = 0.35
	body.mesh = cm
	body.rotation_degrees.x = -90
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.3, 0.32, 0.3)
	body.material_override = m
	add_child(body)
	var glow := OmniLight3D.new()
	glow.light_color = _color
	glow.light_energy = 2.0
	glow.omni_range = 3.0
	glow.position.z = 0.25
	add_child(glow)


func _physics_process(delta: float) -> void:
	_life -= delta
	var from := global_position
	var to := from + velocity * delta
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1 | 4 | 32 # world, zombies, zombie head hitboxes
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty() or _life <= 0.0:
		var p: Vector3 = hit.position + hit.normal * 0.2 if not hit.is_empty() else from
		var a := get_node_or_null("/root/Sfx")
		if a:
			a.play_at("rocket_explosion", p)
		Explosion.explode(get_tree().current_scene, p, radius, damage, knockback, _color, shooter, weapon, 1.2)
		queue_free()
		return
	global_position = to
	_trail_t -= delta
	if _trail_t <= 0.0:
		_trail_t = 0.03
		_puff(from)


func _puff(at: Vector3) -> void:
	var s := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.08
	sm.height = 0.16
	sm.radial_segments = 8
	sm.rings = 4
	s.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.8, 0.8, 0.8, 0.5)
	s.material_override = m
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_parent().add_child(s)
	s.global_position = at
	var t := s.create_tween().set_parallel(true)
	t.tween_property(s, "scale", Vector3.ONE * 4.0, 0.6)
	t.tween_property(m, "albedo_color:a", 0.0, 0.6)
	t.chain().tween_callback(s.queue_free)
