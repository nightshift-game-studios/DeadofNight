class_name GrenadeFX
extends RefCounted
## Desi's grenade FX pieces (playtest #25, GRENADES_SPEC.md). Meshes live in res://assets/models/grenades/fx/*.glb; each helper
## spawns one, tints it with the type's effect tint, animates it with tweens and frees itself. Light: a handful of meshes,
## 512 px textures, no lights, no shadows. Gameplay (damage, slow, pull, heal, marks) stays in Skillz's code; these are visuals only.

const DIR := "res://assets/models/grenades/fx/"


## Instance fx/<id>.glb (null if missing). Shadows off on every mesh.
static func load_fx(id: String) -> Node3D:
	var p := DIR + id + ".glb"
	if not ResourceLoader.exists(p):
		return null
	var n := (load(p) as PackedScene).instantiate() as Node3D
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return n


## Per-instance copies of every surface material, tinted with `c`. additive = unshaded glow (trails, arcs, sparks, rings);
## otherwise the shaded decal look (fire patch, frost ring) with its emission tinted. Returns the materials (to fade them).
static func tint(n: Node, c: Color, additive: bool = true, energy: float = 1.0) -> Array[BaseMaterial3D]:
	var out: Array[BaseMaterial3D] = []
	if n == null:
		return out
	var meshes := n.find_children("*", "MeshInstance3D", true, false)
	if n is MeshInstance3D:
		meshes.push_front(n)
	for node in meshes:
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s) as BaseMaterial3D
			if src == null:
				continue
			var m := src.duplicate() as BaseMaterial3D
			if additive:
				m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				m.albedo_color = Color(c.r * energy, c.g * energy, c.b * energy, src.albedo_color.a)
			else:
				m.emission_enabled = true
				m.emission = c
				if m.emission_texture:
					m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
			m.cull_mode = BaseMaterial3D.CULL_DISABLED if additive else m.cull_mode
			mi.set_surface_override_material(s, m)
			out.append(m)
	return out


## Named part of an FX instance (the GLB root wraps the glTF root node, so search recursively).
static func _n(n: Node, part: String) -> Node3D:
	return n.find_child(part, true, false) as Node3D


static func _spawn(scene: Node, id: String, pos: Vector3) -> Node3D:
	if scene == null:
		return null
	var n := load_fx(id)
	if n == null:
		return null
	scene.add_child(n)
	n.global_position = pos
	return n


static func _fade(n: Node3D, mats: Array[BaseMaterial3D], delay: float, time: float) -> void:
	var t := n.create_tween().set_parallel(true)
	for m in mats:
		t.tween_property(m, "albedo_color:a", 0.0, time).set_delay(delay)
		if m.emission_enabled:
			t.tween_property(m, "emission_energy_multiplier", 0.0, time).set_delay(delay)
	t.chain().tween_callback(n.queue_free)


# ------------------------------------------------------------------ all types: flight trail

## Trail ribbon (1 m, head at the grenade). top_level so the grenade's spin doesn't twist it; call update_trail each physics frame.
static func attach_trail(grenade: Node3D, c: Color) -> Node3D:
	var n := load_fx("fx_trail")
	if n == null:
		return null
	grenade.add_child(n)
	n.top_level = true
	tint(n, c, true, 1.5)
	n.global_position = grenade.global_position
	return n


static func update_trail(trail: Node3D, pos: Vector3, vel: Vector3) -> void:
	if trail == null:
		return
	trail.global_position = pos
	var sp := vel.length()
	trail.visible = sp > 2.0
	if sp > 0.01:
		var up := Vector3.UP if absf(vel.normalized().dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
		trail.look_at(pos + vel, up) # -Z toward travel, ribbon streams along +Z behind
		trail.scale = Vector3(1, 1, clampf(sp / 15.0, 0.2, 1.2))


# ------------------------------------------------------------------ Cinderjar

## Glass shatter: 12 shards, one shot.
static func shatter(scene: Node, pos: Vector3) -> void:
	var src := load_fx("fx_glass_shards")
	if src == null or scene == null:
		return
	var shard := src.find_child("Shard", true, false) as MeshInstance3D
	var p := CPUParticles3D.new()
	p.mesh = shard.mesh
	src.free()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 12
	p.lifetime = 0.8
	p.direction = Vector3.UP
	p.spread = 70.0
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 5.0
	p.angular_velocity_min = -720.0
	p.angular_velocity_max = 720.0
	p.gravity = Vector3(0, -14, 0)
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	scene.add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)


## Fire patch: charred decal + 16 flame cards, flickers, fades over the last 0.8 s. radius in metres (mesh = 3 m).
static func fire_patch(scene: Node, pos: Vector3, c: Color, radius: float = 3.0, duration: float = 5.0) -> Node3D:
	var n := _spawn(scene, "fx_cinder_patch", pos)
	if n == null:
		return null
	n.scale = Vector3.ONE * (radius / 3.0)
	var mats := tint(_n(n, "Patch"), c, false)
	mats.append_array(tint(_n(n, "Flames"), c, true, 2.0))
	var fl := _n(n, "Flames") as Node3D
	fl.scale = Vector3(1, 0.1, 1)
	var t := fl.create_tween()
	t.tween_property(fl, "scale:y", 1.0, 0.25)
	var f := fl.create_tween().set_loops(int(duration / 0.3) + 1)
	f.tween_property(fl, "scale:y", 0.8, 0.15)
	f.tween_property(fl, "scale:y", 1.05, 0.15)
	_fade(n, mats, maxf(duration - 0.8, 0.0), 0.8)
	return n


# ------------------------------------------------------------------ Shiverglass

## Crystal burst (spikes pop out then melt) + frost ring decal that lingers for slow_time.
static func frost_burst(scene: Node, pos: Vector3, c: Color, radius: float = 4.0, slow_time: float = 3.0) -> Node3D:
	var n := _spawn(scene, "fx_frost_burst", pos)
	if n == null:
		return null
	var cr := _n(n, "Crystals") as Node3D
	var ring := _n(n, "FrostRing") as Node3D
	ring.scale = Vector3.ONE * (radius / 4.0)
	var cm := tint(cr, c, false)
	var rm := tint(ring, c, false)
	cr.scale = Vector3.ONE * 0.05
	var t := cr.create_tween()
	t.tween_property(cr, "scale", Vector3.ONE * (radius / 4.0) * 1.1, 0.12).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	t.tween_interval(0.35)
	t.tween_property(cr, "scale", Vector3(1, 0.05, 1) * (radius / 4.0), 0.5).set_ease(Tween.EASE_IN)
	cm.append_array(rm)
	_fade(n, cm, maxf(slow_time - 0.6, 0.3), 0.6)
	return n


# ------------------------------------------------------------------ Tallyhook / sparks

## Shock arc from `a` to `b` (3 jagged variants flicker). Use one per chained zombie.
static func shock_arc(scene: Node, a: Vector3, b: Vector3, c: Color, duration: float = 0.3) -> Node3D:
	var n := _spawn(scene, "fx_arc", a)
	if n == null:
		return null
	var d := a.distance_to(b)
	if d > 0.01:
		var up := Vector3.UP if absf((b - a).normalized().dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
		n.look_at(b, up)
		n.scale = Vector3(1, 1, d)
	tint(n, c, true, 2.0)
	var arcs := [_n(n, "Arc1"), _n(n, "Arc2"), _n(n, "Arc3")]
	var flick := func(i: int) -> void:
		for j in 3:
			arcs[j].visible = j == i
	flick.call(0)
	var t := n.create_tween().set_loops(maxi(int(duration / 0.06), 1))
	for i in 3:
		t.tween_callback(flick.bind(i)).set_delay(0.02)
	n.create_tween().tween_callback(n.queue_free).set_delay(duration)
	return n


## Star-shaped spark flash (Tallyhook stick/zap, Rookery split pop, bell bounce). size in metres (mesh = 0.3 m).
static func spark(scene: Node, pos: Vector3, c: Color, size: float = 0.3) -> Node3D:
	var n := _spawn(scene, "fx_spark", pos)
	if n == null:
		return null
	var mats := tint(n, c, true, 2.5)
	n.scale = Vector3.ONE * size / 0.3 * 0.4
	n.rotation.y = randf() * TAU
	var t := n.create_tween()
	t.tween_property(n, "scale", Vector3.ONE * size / 0.3, 0.08)
	_fade(n, mats, 0.05, 0.15)
	return n


# ------------------------------------------------------------------ Rookery

## Global transforms of the 5 bomblets in a rookery visual (hides them). Spawn fx/rookery_bomblet.glb (or a Grenade) at each.
static func rookery_split(visual: Node3D) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for i in 5:
		var b := visual.find_child("Bomblet%d" % (i + 1), true, false) as Node3D
		if b:
			out.append(b.global_transform)
			b.visible = false
	return out


# ------------------------------------------------------------------ Gravewell

## Vortex: spinning swirl disc + funnel + void core for `duration`, then the core collapses (call the big blast then).
static func vortex(scene: Node, pos: Vector3, c: Color, radius: float = 4.0, duration: float = 2.5) -> Node3D:
	var n := _spawn(scene, "fx_vortex", pos)
	if n == null:
		return null
	n.scale = Vector3.ONE * (radius / 4.0)
	var mats := tint(_n(n, "Swirl"), c, true, 1.6)
	mats.append_array(tint(_n(n, "Funnel"), c, true, 1.2))
	var sw := _n(n, "Swirl") as Node3D
	var fu := _n(n, "Funnel") as Node3D
	var co := _n(n, "Core") as Node3D
	co.scale = Vector3.ONE * 0.1
	var t := n.create_tween().set_parallel(true)
	t.tween_property(sw, "rotation:y", -TAU * 2.5 * duration / 2.5, duration)
	t.tween_property(fu, "rotation:y", -TAU * 4.0 * duration / 2.5, duration)
	t.tween_property(co, "scale", Vector3.ONE, 0.3).set_ease(Tween.EASE_OUT)
	t.tween_property(co, "scale", Vector3.ONE * 0.05, 0.15).set_delay(duration - 0.15).set_ease(Tween.EASE_IN)
	t.tween_property(sw, "scale", Vector3.ONE * 0.2, 0.2).set_delay(duration - 0.2)
	_fade(n, mats, duration - 0.2, 0.2)
	return n


# ------------------------------------------------------------------ Leechbell

## Heal orb that drifts from `from` to `target` (follows it), then calls on_arrive (heal + chime there).
static func heal_orb(scene: Node, from: Vector3, target: Node3D, c: Color, speed: float = 6.0, on_arrive: Callable = Callable()) -> Node3D:
	var n := _spawn(scene, "fx_heal_orb", from)
	if n == null:
		return null
	tint(_n(n, "Glow"), c, true, 1.5)
	var om := tint(_n(n, "Orb"), c, false)
	for m in om:
		m.emission_energy_multiplier = 4.0
	var dist := from.distance_to(target.global_position + Vector3.UP)
	var wob := Vector3(randf_range(-1, 1), randf_range(0.3, 1.0), randf_range(-1, 1)) * 0.8
	var step := func(k: float) -> void:
		if is_instance_valid(target) and is_instance_valid(n):
			n.global_position = from.lerp(target.global_position + Vector3.UP, k * k) + wob * sin(k * PI)
	var arrive := func() -> void:
		if on_arrive.is_valid():
			on_arrive.call()
		n.queue_free()
	var t := n.create_tween()
	t.tween_method(step, 0.0, 1.0, clampf(dist / speed, 0.25, 2.0))
	t.tween_callback(arrive)
	return n


# ------------------------------------------------------------------ Requiem Bell

## Expanding toll shockwave ring (ground), radius metres (mesh = 1 m): small per bounce, 10 m for the final toll.
static func toll_ring(scene: Node, pos: Vector3, c: Color, radius: float = 10.0, time: float = 0.5) -> Node3D:
	var n := _spawn(scene, "fx_toll_ring", pos)
	if n == null:
		return null
	var mats := tint(n, c, true, 2.0)
	n.scale = Vector3.ONE * 0.1
	var t := n.create_tween()
	t.tween_property(n, "scale", Vector3.ONE * radius, time).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUART)
	_fade(n, mats, time * 0.4, time * 0.6)
	return n


## Mark on a zombie: ground sigil + halo above the head (local y 1.95), slow spin, gone after duration.
## Parented to the zombie, so it follows it and dies with it. Returns the node (free it early if the mark ends).
static func mark(target: Node3D, c: Color, duration: float = 6.0, height: float = 1.95) -> Node3D:
	var n := load_fx("fx_mark")
	if n == null or target == null:
		return null
	target.add_child(n)
	var halo := _n(n, "Halo") as Node3D
	halo.position.y = height
	var mats := tint(n, c, true, 1.6)
	var t := n.create_tween().set_loops(int(duration / 2.0) + 1)
	t.tween_property(n, "rotation:y", TAU, 2.0).from(0.0)
	_fade(n, mats, maxf(duration - 0.4, 0.0), 0.4)
	return n


## Plays the bell's "Toll" clip (Clapper swing) on a Leechbell / Requiem Bell visual, e.g. on every bounce.
static func toll(visual: Node) -> void:
	var ap := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap and ap.has_animation("Toll"):
		ap.stop()
		ap.play("Toll")
