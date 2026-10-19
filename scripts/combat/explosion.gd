class_name Explosion
## Area damage with falloff + knockback + VFX. Used by grenades, rockets and perks.


## Damages every zombie within `radius` of `pos`. Damage falls off to 30% at the edge.
## `player` (optional) gets kill credit; `weapon` (optional) gets perk on-kill procs.
## `extra` is merged into each hit's skill ctx: source ("grenade", "skill", ...; default "explosion"),
## depth (chain guard) and any chain bookkeeping. The player's "explosion_damage_mult" and per-target
## "damage_out" skill modifiers apply.
static func explode(scene: Node, pos: Vector3, radius: float, damage: float, knockback: float,
		color: Color, player: Node = null, weapon: WeaponItem = null, vfx_scale: float = 1.0, extra: Dictionary = {}) -> int:
	if scene == null:
		return 0
	var kills := 0
	var skilled: bool = player != null and player.has_method("mod_stat")
	var ctx_base := {"source": "explosion", "weapon": weapon, "element": weapon.element if weapon else "", "pos": pos, "depth": 0}
	ctx_base.merge(extra, true)
	if skilled:
		damage = player.mod_stat("explosion_damage_mult", 1.0, ctx_base) * damage
	for e in scene.get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		var center: Vector3 = e.global_position + Vector3(0, 0.9, 0)
		var d := center.distance_to(pos)
		if d > radius:
			continue
		var f := 1.0 - 0.7 * (d / radius)
		var push := (center - pos)
		push.y = 0.0
		push = push.normalized() if push.length() > 0.01 else Vector3.FORWARD
		e.apply_knockback(push * knockback * f + Vector3.UP * knockback * 0.4 * f)
		var dmg := damage * f
		var ctx := ctx_base.duplicate()
		if skilled:
			ctx = player.hit_ctx(ctx)
			ctx["target"] = e
			dmg = player.mod_stat("damage_out", dmg, ctx)
		var killed: bool = e.take_damage(dmg, center, false, player)
		if skilled:
			player.register_hit(e, dmg, false, killed, ctx)
		elif player and player.has_method("register_hit"):
			player.register_hit(e, dmg, false, killed)
		if killed:
			kills += 1
			if player and weapon:
				player.on_enemy_killed(e, weapon)
	if player and player.has_method("add_shake"):
		var pd: float = player.global_position.distance_to(pos)
		if pd < radius * 3.0:
			player.add_shake(0.25 * vfx_scale * (1.0 - pd / (radius * 3.0)))
	spawn_vfx(scene, pos, radius * vfx_scale, color)
	return kills


static func _mat(color: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func spawn_vfx(scene: Node, pos: Vector3, radius: float, color: Color) -> void:
	var root := Node3D.new()
	scene.add_child(root)
	root.global_position = pos

	# Fireball
	var ball := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.5
	sm.height = 1.0
	ball.mesh = sm
	var bm := _mat(Color(color.r, color.g * 0.9, color.b * 0.6, 0.9), 4.0)
	ball.material_override = bm
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	ball.scale = Vector3.ONE * 0.2
	root.add_child(ball)
	# White-hot core
	var core := MeshInstance3D.new()
	core.mesh = sm
	var cm := _mat(Color(1.0, 0.95, 0.8, 1.0), 6.0)
	cm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	core.material_override = cm
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.scale = Vector3.ONE * 0.1
	root.add_child(core)

	# Shockwave ring
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.42
	tm.outer_radius = 0.5
	ring.mesh = tm
	var rm := _mat(Color(1, 0.9, 0.7, 0.7), 2.0)
	ring.material_override = rm
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ring)

	# Flash
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 8.0
	light.omni_range = radius * 2.5
	root.add_child(light)

	# Sparks / debris
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 40
	p.lifetime = 0.9
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = radius * 1.5
	p.initial_velocity_max = radius * 3.5
	p.gravity = Vector3(0, -14, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.5
	var pm := BoxMesh.new()
	pm.size = Vector3(0.06, 0.06, 0.06)
	pm.material = _mat(Color(1.0, 0.75, 0.35, 1.0), 5.0)
	p.mesh = pm
	root.add_child(p)
	p.emitting = true

	# Smoke
	for i in 6:
		var s := MeshInstance3D.new()
		var ssm := SphereMesh.new()
		ssm.radius = 0.5
		ssm.height = 1.0
		ssm.radial_segments = 12
		ssm.rings = 6
		s.mesh = ssm
		var smat := StandardMaterial3D.new()
		smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		smat.albedo_color = Color(0.15, 0.14, 0.13, 0.55)
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		s.material_override = smat
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		s.position = Vector3(randf_range(-0.5, 0.5), randf_range(0.0, 0.6), randf_range(-0.5, 0.5)) * radius * 0.4
		s.scale = Vector3.ONE * 0.3
		root.add_child(s)
		var st := s.create_tween().set_parallel(true)
		st.tween_property(s, "scale", Vector3.ONE * radius * randf_range(0.35, 0.6), 1.2).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		st.tween_property(s, "position:y", s.position.y + radius * 0.4, 1.4)
		st.tween_property(smat, "albedo_color:a", 0.0, 1.4)

	var t := root.create_tween().set_parallel(true)
	t.tween_property(core, "scale", Vector3.ONE * radius * 0.55, 0.12).set_ease(Tween.EASE_OUT)
	t.tween_property(cm, "albedo_color:a", 0.0, 0.25).set_delay(0.05)
	t.tween_property(ball, "scale", Vector3.ONE * radius * 0.9, 0.18).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	t.tween_property(bm, "albedo_color:a", 0.0, 0.45).set_delay(0.15)
	t.tween_property(ring, "scale", Vector3.ONE * radius * 2.2, 0.35).set_ease(Tween.EASE_OUT)
	t.tween_property(rm, "albedo_color:a", 0.0, 0.35)
	t.tween_property(light, "light_energy", 0.0, 0.35)
	t.chain().tween_interval(1.2)
	t.chain().tween_callback(root.queue_free)
