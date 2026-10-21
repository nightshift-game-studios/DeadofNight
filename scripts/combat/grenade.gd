class_name Grenade
extends RigidBody3D
## Thrown physics grenade. Data (fuse, radius, damage, type, variant...) comes from data/grenades.json.
## Art4 (Skillz): visual = Desi's grenade GLB (Body / Spoon / Pin / Band / Fuse / Light, clip Arm). The emissive Band is
## recoloured with the type's effect tint (data color "#hex") and pulses with the fuse light; Arm plays on throw.
## Missing GLB -> the old dark sphere with an emissive tint. Collision stays SphereShape3D r 0.09 (GLB origin = body centre).
##
## Playtest #25 (Skillz, GRENADES_SPEC.md): grenades by rarity. data "type" picks the effect, "variant" is the stable id
## (never rename: SFX keys grenade_<variant>_*, Desi's model, Netz sync). Every throw goes through
## ThrownProjectile.spawn(spec) with type_id &"grenade" and variant = the id; the projectile (data/projectiles.json type
## "grenade", body "grenade") makes this RigidBody and owns the spec / is_visual_only. Co-op (Netz rules): only the
## authoritative copy (solo / host) deals damage, applies statuses, heals, refunds and spawns child projectiles; a visual
## copy flies, bounces, sticks and plays every FX / SFX. RNG = the spec seed (rng), so both copies scatter alike.
##   frag          one blast after the fuse
##   pulse         Tremor Charge: repeated pulses
##   cinderjar     shatters on first contact: small blast + a fire patch (patch_radius, patch_duration, burn_dps)
##   shiverglass   cryo burst: slow (slow, slow_time) + "frost" status (+frozen_damage_mult-1 damage taken; enemy.gd §24)
##   tallyhook     sticks at the hook tips to the first zombie it touches (parented to it); stick_delay later it blasts
##                 and shock chains to chain_count more zombies, each hop <= chain_range
##   rookery       blast, then `bomblets` child projectiles (type "grenade_bomblet") that each pop bomblet_delay later
##   gravewell     stops, pulls non-boss zombies within pull_radius for pull_time (bosses only get a stagger), big blast
##   leechbell     blast; heal_frac of the damage dealt flies back as "heal_orb" child projectiles that heal the thrower
##   requiem_bell  `bounces` bounces with a small blast each; the last one tolls: every zombie within toll_radius gets
##                 "mark" (+mark_damage_mult-1 damage taken) for mark_time; a marked kill refunds mark_refund cooldown

const MODEL_PATH := "res://assets/models/pickups/grenade.glb"
## Desi #25: per-variant models res://assets/models/grenades/<variant>.glb (frag, cinderjar, shiverglass, tallyhook, rookery,
## gravewell, leechbell, requiem_bell). data "model" (else "variant") picks one; missing -> MODEL_PATH. FX helpers: GrenadeFX.
const VARIANT_DIR := "res://assets/models/grenades/"
const MARK_VOICES := 4 ## requiem mark SFX cap per toll (Audi-0: 3-4, ~40 ms apart)
static var model_path: String = MODEL_PATH ## tests point this at a missing file to exercise the sphere fallback
static var requiem_refunds: int = 0 ## marked kills that refunded cooldown (tests / stats)
static var orbs_healed: float = 0.0 ## HP healed by Leechbell orbs (tests / stats)

signal effect(what: StringName, info: Dictionary) ## stick / zap / split / pull_start / blast / toll ... (tests, Netz)

var data: Dictionary = {}
var thrower: Node
var proj: ThrownProjectile ## the spec carrier (null when made without one)
var variant: String = ""
var rarity: int = 0
var authoritative: bool = true ## false = visual-only copy (co-op puppet): no damage / status / heal / refund / children
var rng := RandomNumberGenerator.new()
var done: bool = false
var last: Dictionary = {} ## what the last effect did (tests): chain, staggered, pulled, orbs, healed_total, marked ...
var _fuse: float = 1.5
var _pulses_left: int = 0
var _pulse_timer: float = 0.0
var _armed_zone: MeshInstance3D
var _light: OmniLight3D
var _t: float = 0.0
var _bounce_cd: float = 0.0
var _loop: AudioStreamPlayer3D ## Tremor Charge pulse loop / Gravewell vortex loop
var visual: Node3D ## grenade GLB instance (or the fallback sphere)
var band_material: StandardMaterial3D ## Band override (null on the fallback sphere)
var _trail: Node3D ## GrenadeFX flight trail (effect tint)
var _contacts: Dictionary = {} ## collider instance id -> last contact point (hook-tip stick point)
var stuck_to: Node3D ## Tallyhook: the zombie it is stuck to
var _stick_t: float = -1.0
var bounces_done: int = 0 ## Requiem Bell
var _rest_t: float = 0.0
var _vortex_t: float = -1.0 ## Gravewell: pull time left (>= 0 while pulling)
var _vortex_lead: bool = false
var _staggered: Dictionary = {}
var _net_held: bool = false ## NET G1: co-op visual copy: waits for the host's moments (net_event), own fuse + NET_GRACE as fallback
var _net_fired: bool = false ## NET G1: the host's detonation already played on this copy
const NET_GRACE := 1.0
const NET_DETONATE_KINDS := ["blast", "fire_patch", "frost", "zap", "split", "pull_start", "leech"]


static func throw_from(player: Node, grenade_data: Dictionary, origin: Vector3, dir: Vector3, inherit: Vector3) -> Grenade:
	var vel := dir * float(grenade_data.get("throw_speed", 15.0)) + Vector3.UP * 3.0 + inherit * 0.5
	var spec := make_spec(player, grenade_data, origin, vel, randi())
	var p := NetGate.request_throw(spec) as ThrownProjectile # NET G5: co-op client -> visual copy now + the host validates and spawns the real one
	if p == null:
		p = ThrownProjectile.spawn(spec)
	if p != null and p.body is Grenade:
		return p.body as Grenade
	if p != null:
		p.queue_free()
	return _make(player, grenade_data, origin, vel, int(spec.seed), false, null) # no "grenade" projectile type (old data)


## The ThrownProjectile spec of a throw (Netz contract) + "data" (the thrower's grenade dict; puppets rebuild it from the
## variant). type_id &"grenade", variant = the stable id.
static func make_spec(player: Node, grenade_data: Dictionary, origin: Vector3, vel: Vector3, seed_v: int) -> Dictionary:
	return {"type_id": &"grenade", "variant": StringName(variant_of(grenade_data)),
		"rarity": Rarity.from_id(str(grenade_data.get("rarity", "common"))), "pos": origin, "vel": vel,
		"owner_id": player.get_instance_id() if player else 0, "seed": seed_v, "data": grenade_data}


## ThrownProjectile type "grenade" calls this from spawn(): the body for that spec (child of the projectile, top_level).
static func from_projectile(p: ThrownProjectile) -> Grenade:
	var d: Dictionary = p.spec.get("data", {})
	if d.is_empty():
		d = data_for_variant(str(p.variant))
	var owner_node: Node = null
	if p.owner_id != 0:
		var o = instance_from_id(p.owner_id)
		if o is Node and is_instance_valid(o):
			owner_node = o
	return _make(owner_node, d, p.global_position, p.velocity, p.seed_value, p.is_visual_only, p)


static func _make(player: Node, d: Dictionary, pos: Vector3, vel: Vector3, seed_v: int, visual_only: bool, carrier: ThrownProjectile) -> Grenade:
	var g := Grenade.new()
	g.data = d
	g.thrower = player
	g.proj = carrier
	g.authoritative = not visual_only
	g.variant = variant_of(d)
	g.rarity = Rarity.from_id(str(d.get("rarity", "common")))
	g.rng.seed = seed_v
	var tree := Engine.get_main_loop() as SceneTree
	var parent: Node = carrier if carrier else (tree.current_scene if tree.current_scene else tree.root)
	if carrier:
		g.top_level = true # the carrier only follows it
	parent.add_child(g)
	g.global_position = pos
	g.linear_velocity = vel
	g.angular_velocity = Vector3(g.rng.randf_range(-8, 8), g.rng.randf_range(-8, 8), g.rng.randf_range(-8, 8))
	return g


## grenades.json entry by variant id (GearDB), {} if unknown.
static func data_for_variant(v: String) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var gdb: Node = tree.root.get_node_or_null("GearDB") if tree else null
	if gdb == null or v == "":
		return {}
	var all: Dictionary = gdb.get("grenades")
	if all.has(v):
		return all[v]
	for k in all:
		if str(all[k].get("variant", "")) == v:
			return all[k]
	return {}


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
	visual = make_visual(c, model_of(data))
	add_child(visual)
	_trail = GrenadeFX.attach_trail(self, c)
	band_material = visual.get_meta("band_material") if visual.has_meta("band_material") else null
	_light = OmniLight3D.new()
	_light.light_color = c
	_light.light_energy = 1.0
	_light.omni_range = 1.5
	var lp := visual.find_child("Light", true, false) as Node3D
	if lp:
		_light.position = lp.position
	add_child(_light)
	var ap := visual.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap and ap.has_animation("Arm"):
		ap.play("Arm") # spoon flies / pin out as it leaves the hand
	_fuse = float(data.get("fuse", 1.5))
	if _fuse <= 0.0: # impact grenades (Cinderjar): a fallback fuse in case it never touches anything
		_fuse = float(data.get("max_fuse", 4.0))
	var n := NetGate.net()
	_net_held = not authoritative and n != null and n.is_networked() # NET G1
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_bounce)
	_play_at("grenade_throw", global_position)
	if rarity >= Rarity.LEGENDARY:
		_play_at("grenade_rarity_" + Rarity.IDS[rarity], global_position)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(proj) and not proj.is_queued_for_deletion():
		proj.queue_free()


## Grenade visual tinted with `c`: the GLB with its Band recoloured (meta "band_material"), else the old sphere.
## Static so a held / viewmodel grenade can reuse it.
static func make_visual(c: Color, variant_id: String = "") -> Node3D:
	var path := model_path
	if variant_id != "" and model_path == MODEL_PATH and ResourceLoader.exists(VARIANT_DIR + variant_id + ".glb"):
		path = VARIANT_DIR + variant_id + ".glb"
	if path != "" and ResourceLoader.exists(path):
		var vis := (load(path) as PackedScene).instantiate() as Node3D
		var band := vis.find_child("Band", true, false) as MeshInstance3D
		if band:
			var bm := StandardMaterial3D.new()
			bm.albedo_color = c
			bm.emission_enabled = true
			bm.emission = c
			bm.emission_energy_multiplier = 2.0
			band.material_override = bm
			vis.set_meta("band_material", bm)
		for mi in vis.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return vis
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
	return mesh


## Stable variant id of a grenade data dict (ThrownProjectile spec variant, SFX keys, Netz sync); "" if none.
static func variant_of(d: Dictionary) -> String:
	return str(d.get("variant", ""))


## Model id: "model" (a mesh override, e.g. pulse -> frag), else the variant. Picks grenades/<id>.glb.
static func model_of(d: Dictionary) -> String:
	return str(d.get("model", d.get("variant", "")))


## Effect tint of a grenade data dict: "#RRGGBB" (playtest #25) or the old [r, g, b] array.
static func color_of(d: Dictionary, key: String = "color") -> Color:
	var v = d.get(key, [1, 0.5, 0.2])
	if v is String:
		return Color.html(v) if Color.html_is_valid(v) else Color(1, 0.5, 0.2)
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return Color(1, 0.5, 0.2)


func _color() -> Color:
	return color_of(data)


func _type() -> String:
	return str(data.get("type", "frag"))


func _num(key: String, fallback: float) -> float:
	return float(data.get(key, fallback))


# ------------------------------------------------------------------ audio / scene helpers

func _sfx() -> Node:
	return get_node_or_null("/root/Sfx")


func _play_at(key: String, pos: Vector3) -> void:
	var a := _sfx()
	if a and is_inside_tree():
		a.play_at(key, pos)


## "grenade_<variant>_detonate" (Audi-0 HOOKUP); frag (and anything without its own file) -> the old frag_explode.
func detonate_key() -> String:
	var k := "grenade_%s_detonate" % variant
	var a := _sfx()
	if variant == "" or variant == "frag" or variant == "pulse" or (a and not a.has(k)):
		return "frag_explode"
	return k


func _scene() -> Node:
	var tree := get_tree()
	return tree.current_scene if tree.current_scene else tree.root


func _owner() -> Node:
	return thrower if thrower != null and is_instance_valid(thrower) else null


static func center_of(e: Node3D) -> Vector3:
	return e.global_position + Vector3(0, 0.9, 0)


static func is_boss(e: Node) -> bool:
	return e.has_meta("is_boss") and bool(e.get_meta("is_boss"))


## Live zombies whose centre (feet + 0.9 m) is within `r` of `pos`, nearest first.
func enemies_near(pos: Vector3, r: float) -> Array:
	var out := []
	for e in get_tree().get_nodes_in_group("enemies"):
		if e is Node3D and is_instance_valid(e) and not e.get("_dead") and center_of(e).distance_to(pos) <= r:
			out.append(e)
	out.sort_custom(func(a, b): return center_of(a).distance_to(pos) < center_of(b).distance_to(pos))
	return out


## Area blast (authoritative: Explosion.explode with kill credit; visual copy: the VFX only). Returns kills.
func blast(pos: Vector3, radius: float, damage: float, knock: float, vfx_scale: float = 1.0) -> int:
	effect.emit(&"blast", {"pos": pos, "radius": radius, "damage": damage})
	if not authoritative:
		Explosion.spawn_vfx(_scene(), pos, radius * vfx_scale, _color())
		return 0
	return Explosion.explode(_scene(), pos, radius, damage, knock, _color(), _owner(), null, vfx_scale,
		{"source": "grenade", "grenade": variant})


## One zombie hit with the thrower's explosion / damage_out modifiers and kill credit (Tallyhook chain). Host only.
static func deal(e: Node, dmg: float, player: Node, pos: Vector3, extra: Dictionary = {}) -> bool:
	if e == null or not is_instance_valid(e) or e.get("_dead"):
		return false
	var skilled: bool = player != null and is_instance_valid(player) and player.has_method("mod_stat")
	var ctx := {"source": "grenade", "weapon": null, "element": "", "pos": pos, "depth": 0}
	ctx.merge(extra, true)
	if skilled:
		dmg = player.mod_stat("explosion_damage_mult", 1.0, ctx) * dmg
		ctx = player.hit_ctx(ctx)
		ctx["target"] = e
		dmg = player.mod_stat("damage_out", dmg, ctx)
	var prev := Explosion.current
	Explosion.current = ctx
	var killed: bool = e.take_damage(dmg, center_of(e), false, player)
	Explosion.current = prev
	if skilled:
		player.register_hit(e, dmg, false, killed, ctx)
	elif player != null and is_instance_valid(player) and player.has_method("register_hit"):
		player.register_hit(e, dmg, false, killed)
	return killed


# ------------------------------------------------------------------ flight

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	for i in state.get_contact_count():
		var o := state.get_contact_collider_object(i)
		if o:
			_contacts[o.get_instance_id()] = state.get_contact_collider_position(i)


## Where this grenade touched `body`: the physics contact if one was reported, else the point of its capsule nearest us.
func contact_point(body: Node3D) -> Vector3:
	if _contacts.has(body.get_instance_id()):
		return _contacts[body.get_instance_id()]
	var c := center_of(body)
	var axis_p := Vector3(c.x, clampf(global_position.y, body.global_position.y + 0.3, body.global_position.y + 1.6), c.z)
	var d := global_position - axis_p
	return axis_p + (d.normalized() * 0.35 if d.length() > 0.01 else Vector3.ZERO)


func _on_bounce(body: Node) -> void:
	if done:
		return
	var t := _type()
	if _net_held and t in ["tallyhook", "cinderjar", "requiem_bell"]: # NET G1: the host's stick / impact / bounce arrive as events
		return
	if t == "tallyhook" and stuck_to == null and body.is_in_group("enemies") and not body.get("_dead"):
		stick_to(body as Node3D, contact_point(body as Node3D))
		return
	if _bounce_cd > 0.0 or freeze:
		return
	if t == "cinderjar":
		detonate()
		return
	if linear_velocity.length() < 1.5 and t != "requiem_bell":
		return
	_bounce_cd = 0.12
	if t == "requiem_bell":
		_bell_bounce()
		return
	GrenadeFX.toll(visual) # bells: clapper swing on every bounce (no-op on the others)
	var a := _sfx()
	if a:
		a.play_at("frag_bounce", global_position, clampf(linear_velocity.length() - 8.0, -8.0, 0.0))


func _physics_process(delta: float) -> void:
	if done:
		return
	_t += delta
	_bounce_cd = max(_bounce_cd - delta, 0.0)
	GrenadeFX.update_trail(_trail, global_position, linear_velocity if not freeze else Vector3.ZERO)
	_light.light_energy = 0.5 + 1.5 * absf(sin(_t * 18.0))
	if band_material:
		band_material.emission_energy_multiplier = 1.0 + 3.0 * absf(sin(_t * 18.0))
	if _pulses_left > 0:
		_pulse_timer -= delta
		if _pulse_timer <= 0.0:
			_pulse()
		return
	if _vortex_t >= 0.0:
		_vortex_step(delta)
		return
	if _stick_t >= 0.0:
		_stick_t -= delta
		if _stick_t <= (-NET_GRACE if _net_held else 0.0):
			_stick_t = -1.0
			_zap()
		return
	if _type() == "requiem_bell" and not freeze and not _net_held: # came to rest early (wedged): toll anyway
		_rest_t = _rest_t + delta if linear_velocity.length() < 0.4 else 0.0
		if _rest_t >= 0.5:
			_toll()
			return
	_fuse -= delta
	if _fuse <= (-NET_GRACE if _net_held else 0.0):
		detonate()


## NET G2: the host copy's `effect` (Net forwards it, node refs mapped to this machine) -> this visual copy plays the
## same moment where the host had it. The first detonation kind detonates (visual paths only: not authoritative).
func net_event(kind: String, d: Dictionary) -> void:
	if authoritative or done:
		return
	var at = d.get("pos")
	match kind:
		"stick":
			var z = d.get("target")
			if z is Node3D and is_instance_valid(z):
				stick_to(z, d.get("contact") if d.get("contact") is Vector3 else global_position)
		"bell_bounce":
			_net_snap(at)
			_bell_bounce()
		"toll":
			_net_snap(at)
			_toll()
		_:
			if _type() == "requiem_bell": # its blasts are the bounces (bell_bounce / toll above)
				return
			if kind in NET_DETONATE_KINDS and not _net_fired:
				_net_fired = true
				_net_held = false
				_net_snap(at)
				detonate()


func _net_snap(at: Variant) -> void:
	if at is Vector3 and stuck_to == null:
		global_position = at
		linear_velocity = Vector3.ZERO


## Fuse end (or impact): the type's effect. Public so tests and the cinderjar contact can call it.
func detonate() -> void:
	if done:
		return
	var bus := get_node_or_null("/root/GameEvents")
	if bus and _owner() and authoritative:
		bus.emit_event(&"grenade_detonated", {"player": _owner(), "pos": global_position, "data": data})
	match _type():
		"pulse":
			_start_pulse()
		"cinderjar":
			_cinderjar()
		"shiverglass":
			_shiverglass()
		"tallyhook":
			_zap()
		"rookery":
			_rookery()
		"gravewell":
			_gravewell()
		"leechbell":
			_leechbell()
		"requiem_bell":
			_toll()
		_:
			_frag()


func _finish() -> void:
	done = true
	queue_free()


func _frag() -> void:
	_play_at(detonate_key(), global_position)
	blast(global_position, _num("radius", 5.0), _num("damage", 200), _num("knockback", 8.0))
	_finish()


# ------------------------------------------------------------------ pulse (Tremor Charge)

func _start_pulse() -> void:
	freeze = true
	_pulses_left = int(data.get("pulses", 4))
	_pulse_timer = 0.0
	_armed_zone = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	var r := _num("radius", 4.0)
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


func _pulse() -> void:
	_pulses_left -= 1
	_pulse_timer = _num("interval", 0.5)
	blast(global_position, _num("radius", 4.0), _num("damage", 60), _num("knockback", 2.0), 0.45)
	if _pulses_left <= 0:
		_finish()


# ------------------------------------------------------------------ Cinderjar

## Ground point under `pos` (world layer), or `pos` if nothing within `drop` m.
func _ground(pos: Vector3, drop: float = 4.0) -> Vector3:
	if not is_inside_tree():
		return pos
	var q := PhysicsRayQueryParameters3D.create(pos + Vector3(0, 0.3, 0), pos - Vector3(0, drop, 0), 1)
	var r := get_world_3d().direct_space_state.intersect_ray(q)
	return r.position if not r.is_empty() else pos


func _cinderjar() -> void:
	var pos := global_position
	var ground := _ground(pos)
	_play_at(detonate_key(), pos)
	GrenadeFX.shatter(_scene(), pos)
	blast(pos, _num("radius", 3.0), _num("damage", 90), _num("knockback", 4.0), 0.5)
	var r := _num("patch_radius", 3.0)
	var dur := _num("patch_duration", 5.0)
	GrenadeFX.fire_patch(_scene(), ground, _color(), r, dur)
	var zone: GrenadeZone = null
	if authoritative:
		zone = GrenadeZone.make(_scene(), ground, r, dur, _num("burn_tick", 0.5))
		zone.name = "CinderPatch"
		var dps := _num("burn_dps", 40.0)
		var src := _owner()
		var tick := zone.tick
		zone.on_tick = func(z: GrenadeZone) -> void:
			for e in z.enemies_inside():
				e.apply_status("burn", {"dur": tick * 2.0, "dps": dps, "source": src})
	var a := _sfx()
	if a:
		if is_equal_approx(dur, 5.0): # Audi-0: the one-shot is exactly 5.0 s
			a.play_at("grenade_cinderjar_fire", ground)
		elif zone:
			a.attach_loop("grenade_cinderjar_fire_loop", zone) # child of the zone: stops when it expires
	last = {"patch": zone, "ground": ground}
	effect.emit(&"fire_patch", {"pos": ground, "radius": r, "duration": dur, "zone": zone})
	_finish()


# ------------------------------------------------------------------ Shiverglass

func _shiverglass() -> void:
	var pos := global_position
	_play_at(detonate_key(), pos)
	_play_at("grenade_shiverglass_frost", pos)
	var r := _num("radius", 4.0)
	var st := _num("slow_time", 3.0)
	var caught := enemies_near(pos, r)
	blast(pos, r, _num("damage", 120), _num("knockback", 2.0))
	GrenadeFX.frost_burst(_scene(), _ground(pos), _color(), r, st)
	var frozen := []
	if authoritative:
		for e in caught:
			if not is_instance_valid(e) or e.get("_dead"):
				continue
			e.apply_status("slow", {"dur": st, "amp": _num("slow", 0.5), "source": _owner()})
			e.apply_status("frost", {"dur": st, "amp": _num("frozen_damage_mult", 1.15) - 1.0, "source": _owner()})
			frozen.append(e)
	last = {"frozen": frozen}
	effect.emit(&"frost", {"pos": pos, "frozen": frozen})
	_finish()


# ------------------------------------------------------------------ Tallyhook

## Stick to zombie `z` with the hook tips (Desi's StickPoint, y -0.072) at `contact`, parented to the zombie.
func stick_to(z: Node3D, contact: Vector3) -> void:
	if stuck_to != null or done or z == null:
		return
	stuck_to = z
	_stick_t = _num("stick_delay", 1.0)
	freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	freeze = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	var sp_local := Vector3(0, -0.072, 0)
	var sp := visual.find_child("StickPoint", true, false) as Node3D if visual else null
	if sp:
		sp_local = global_transform.affine_inverse() * sp.global_position
	var inward := center_of(z) - contact
	inward.y *= 0.25
	inward = inward.normalized() if inward.length() > 0.01 else -z.global_transform.basis.z
	var up := -inward # model -Y (the hook tips) points into the zombie
	var side := Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := up.cross(side).normalized()
	var b := Basis(x, up, x.cross(up).normalized())
	top_level = false
	reparent(z, true)
	global_transform = Transform3D(b, contact - b * sp_local)
	if z.has_signal("died") and not z.died.is_connected(_on_host_died):
		z.died.connect(_on_host_died, CONNECT_ONE_SHOT)
	_play_at("grenade_tallyhook_stick", contact)
	_play_at("grenade_tallyhook_charge", contact) # exactly 1.0 s, ends at the zap
	GrenadeFX.spark(_scene(), contact, _color(), 0.25)
	last = {"stuck_to": z, "contact": contact}
	effect.emit(&"stick", {"target": z, "contact": contact})


## The zombie we're stuck to died: drop back into the scene where we are and keep counting down.
func _on_host_died(_e: Node) -> void:
	if done or not is_inside_tree():
		return
	var gt := global_transform
	reparent(_scene(), false)
	global_transform = gt


func hook_point() -> Vector3:
	var sp := visual.find_child("StickPoint", true, false) as Node3D if visual else null
	return sp.global_position if sp else global_position


func _zap() -> void:
	if done:
		return
	var pos := global_position
	var arc_from := global_position
	var ap := visual.find_child("ArcPoint", true, false) as Node3D if visual else null
	if ap:
		arc_from = ap.global_position
	_play_at(detonate_key(), pos)
	var primary: Node = stuck_to if stuck_to != null and is_instance_valid(stuck_to) and not stuck_to.get("_dead") else null
	blast(pos, _num("radius", 2.5), _num("damage", 200), _num("knockback", 4.0), 0.6)
	GrenadeFX.spark(_scene(), pos, _color(), 0.5)
	var chain := []
	var hit := {}
	if primary:
		hit[primary.get_instance_id()] = true
	var from_pt := center_of(primary) if primary else pos
	var rng_r := _num("chain_range", 6.0)
	var prev_vis := arc_from
	for i in int(data.get("chain_count", 4)):
		var best: Node3D = null
		var bd := INF
		for e in get_tree().get_nodes_in_group("enemies"):
			if not (e is Node3D) or not is_instance_valid(e) or e.get("_dead") or hit.has(e.get_instance_id()):
				continue
			var d := center_of(e).distance_to(from_pt)
			if d <= rng_r and d < bd:
				bd = d
				best = e
		if best == null:
			break
		hit[best.get_instance_id()] = true
		var to := center_of(best)
		GrenadeFX.shock_arc(_scene(), prev_vis, to, _color(), 0.3)
		_play_at("grenade_tallyhook_arc", to)
		chain.append(best)
		if authoritative:
			deal(best, _num("chain_damage", 120), _owner(), to, {"grenade": variant, "chain": i + 1})
		from_pt = to
		prev_vis = to
	last = {"stuck_to": primary, "chain": chain}
	effect.emit(&"zap", {"pos": pos, "primary": primary, "chain": chain})
	_finish()


# ------------------------------------------------------------------ Rookery

func _rookery() -> void:
	var pos := global_position
	_play_at(detonate_key(), pos)
	blast(pos, _num("radius", 3.5), _num("damage", 140), _num("knockback", 6.0))
	GrenadeFX.spark(_scene(), pos, _color(), 0.6)
	var xf: Array[Transform3D] = GrenadeFX.rookery_split(visual) if visual else ([] as Array[Transform3D])
	var n := int(data.get("bomblets", 5))
	var kids := []
	if authoritative: # puppets get the bomblets from the host's specs (Netz P1), never their own
		for i in n:
			var from := xf[i].origin if i < xf.size() else pos + Vector3(cos(TAU * i / n), 0.1, sin(TAU * i / n)) * 0.12
			var out := from - pos
			out.y = 0.0
			if out.length() < 0.01:
				out = Vector3(cos(TAU * i / n), 0, sin(TAU * i / n))
			var a := rng.randf_range(-0.35, 0.35)
			out = out.normalized().rotated(Vector3.UP, a)
			var sp := _num("bomblet_speed", 5.0) * rng.randf_range(0.6, 1.0) * clampf(_num("bomblet_spread", 3.0) / 3.0, 0.2, 3.0)
			var vel := out * sp + Vector3.UP * rng.randf_range(2.5, 4.0)
			var spec := {"type_id": &"grenade_bomblet", "variant": StringName(variant), "rarity": rarity, "pos": from,
				"vel": vel, "owner_id": _owner().get_instance_id() if _owner() else 0, "seed": rng.randi(),
				"fuse": _num("bomblet_delay", 0.4)}
			var p := ThrownProjectile.spawn(spec)
			if p:
				p.impacted.connect(Grenade.bomblet_pop.bind(data.duplicate(), spec.owner_id))
				kids.append(p)
	last = {"bomblets": kids}
	effect.emit(&"split", {"pos": pos, "bomblets": kids})
	_finish()


## A rookery bomblet popped (host copy): its blast with the thrower's kill credit.
static func bomblet_pop(p: ThrownProjectile, where: Vector3, _hit: Node, d: Dictionary, owner_iid: int) -> void:
	if p.is_visual_only:
		return
	var o = instance_from_id(owner_iid) if owner_iid != 0 else null
	var owner_node: Node = o if o is Node and is_instance_valid(o) else null
	var scene: Node = p.get_parent() if p.get_parent() else p.get_tree().root
	Explosion.explode(scene, where, float(d.get("bomblet_radius", 2.5)), float(d.get("bomblet_damage", 80)), 3.0,
		color_of(d), owner_node, null, 0.5, {"source": "grenade", "grenade": str(d.get("variant", "rookery")), "bomblet": true})


# ------------------------------------------------------------------ Gravewell

func _gravewell() -> void:
	freeze = true
	linear_velocity = Vector3.ZERO
	_vortex_t = _num("pull_time", 2.5)
	_vortex_lead = false
	_staggered = {}
	var r := _num("pull_radius", 4.0)
	GrenadeFX.vortex(_scene(), global_position, _color(), r, _vortex_t)
	var a := _sfx()
	if a:
		_loop = a.attach_loop("grenade_gravewell_vortex_loop", self)
	last = {"pulled": {}, "staggered": []}
	effect.emit(&"pull_start", {"pos": global_position, "radius": r})
	_vortex_step(0.0)


func _vortex_step(delta: float) -> void:
	_vortex_t -= delta
	var c := global_position
	if authoritative:
		var r := _num("pull_radius", 4.0)
		for e in enemies_near(c, r):
			if is_boss(e):
				if not _staggered.has(e.get_instance_id()):
					_staggered[e.get_instance_id()] = true
					stagger(e, _num("boss_stagger", 0.6))
					last.staggered.append(e)
				continue
			var to: Vector3 = c - (e as Node3D).global_position
			to.y = 0.0
			var d := to.length()
			if d > 0.35:
				var kb: Vector3 = e.get("knockback")
				var pull := to / d * _num("pull_speed", 5.0) * clampf(d / 1.0, 0.3, 1.0)
				e.set("knockback", Vector3(pull.x, kb.y, pull.z))
			last.pulled[e.get_instance_id()] = e
	if not _vortex_lead and _vortex_t <= 0.35: # Audi-0: the file starts with a 0.35 s implode
		_vortex_lead = true
		_play_at(detonate_key(), c)
	if _vortex_t <= 0.0:
		_vortex_t = -1.0
		if _loop and is_instance_valid(_loop):
			_loop.stop()
			_loop.queue_free()
		for e in last.pulled.values():
			if is_instance_valid(e):
				e.set("knockback", Vector3.ZERO)
		blast(c, _num("radius", 4.0), _num("damage", 420), _num("knockback", 10.0), 1.2)
		_finish()


## Boss stagger: the boss's own stagger(t) if it has one, else a near-stop slow for t seconds.
static func stagger(e: Node, t: float) -> void:
	if e.has_method("stagger"):
		e.call("stagger", t)
	else:
		e.apply_status("slow", {"dur": t, "amp": 0.9})


# ------------------------------------------------------------------ Leechbell

func _leechbell() -> void:
	var pos := global_position
	_play_at(detonate_key(), pos)
	GrenadeFX.toll(visual)
	var r := _num("radius", 5.0)
	var caught := enemies_near(pos, r)
	var before := {}
	for e in caught:
		before[e.get_instance_id()] = float(e.health)
	blast(pos, r, _num("damage", 300), _num("knockback", 8.0))
	var dealt := 0.0
	var spots: Array[Vector3] = []
	for e in caught:
		if not is_instance_valid(e):
			continue
		var h0: float = before[e.get_instance_id()]
		var lost := clampf(h0 - float(e.health), 0.0, h0)
		if lost > 0.0:
			dealt += lost
			spots.append(center_of(e))
	var total := dealt * _num("heal_frac", 0.3)
	var orbs := []
	var o := _owner()
	if authoritative and total > 0.0 and o is Node3D:
		var n := clampi(ceili(total / maxf(_num("orb_heal", 5.0), 0.01)), 1, int(data.get("orbs_max", 8)))
		var each := total / n
		for i in n:
			var from: Vector3 = spots[i % spots.size()] if spots.size() else pos
			var vel := Vector3(rng.randf_range(-1.5, 1.5), rng.randf_range(2.0, 3.5), rng.randf_range(-1.5, 1.5))
			var spec := {"type_id": &"heal_orb", "variant": StringName(variant), "rarity": rarity, "pos": from + Vector3(0, 0.3, 0),
				"vel": vel, "owner_id": o.get_instance_id(), "seed": rng.randi(), "heal": each}
			var p := ThrownProjectile.spawn(spec)
			if p:
				p.impacted.connect(Grenade.orb_arrived.bind(each))
				orbs.append(p)
	last = {"dealt": dealt, "heal_total": total, "orbs": orbs}
	effect.emit(&"leech", {"pos": pos, "dealt": dealt, "orbs": orbs})
	_finish()


## A heal orb reached its owner (host copy): heal them.
static func orb_arrived(p: ThrownProjectile, _where: Vector3, target: Node, amount: float) -> void:
	if p.is_visual_only or target == null or not is_instance_valid(target):
		return
	if NetGate.grant_heal(target, maxi(int(round(amount)), 1), "leechbell"): # NET G4: co-op -> the owner's machine heals
		orbs_healed += amount
		return
	if not target.has_method("heal"):
		return
	target.call("heal", maxi(int(round(amount)), 1))
	orbs_healed += amount


# ------------------------------------------------------------------ Requiem Bell

func _bell_bounce() -> void:
	if bounces_done >= int(data.get("bounces", 3)):
		return
	bounces_done += 1
	var pos := global_position
	GrenadeFX.toll(visual)
	_play_at("grenade_requiem_bell_bounce", pos)
	_play_at("grenade_requiem_bell_detonate", pos)
	GrenadeFX.toll_ring(_scene(), pos, _color(), _num("bounce_radius", 2.5), 0.35)
	blast(pos, _num("bounce_radius", 2.5), _num("bounce_damage", 90), _num("knockback", 3.0), 0.4)
	effect.emit(&"bell_bounce", {"pos": pos, "n": bounces_done})
	if bounces_done >= int(data.get("bounces", 3)):
		_toll()
		return
	var v := linear_velocity # a lively hop so the 3 bounces always happen
	linear_velocity = Vector3(v.x * 0.7, maxf(absf(v.y) * 0.6, _num("hop_speed", 4.5)), v.z * 0.7)


func _toll() -> void:
	if done:
		return
	var pos := global_position
	var r := _num("toll_radius", 10.0)
	var mt := _num("mark_time", 6.0)
	_play_at("grenade_requiem_bell_toll", pos)
	GrenadeFX.toll(visual)
	GrenadeFX.toll_ring(_scene(), _ground(pos), _color(), r, 0.6)
	var marked := []
	var voices := 0
	for e in enemies_near(pos, r):
		marked.append(e)
		GrenadeFX.mark(e, _color(), mt)
		if voices < MARK_VOICES:
			var a := _sfx()
			if a:
				var at: Vector3 = center_of(e)
				get_tree().create_timer(0.04 * voices).timeout.connect(func(): a.play_at("grenade_requiem_bell_mark", at))
			voices += 1
		if authoritative:
			mark(e, mt, _num("mark_damage_mult", 1.25) - 1.0, _owner(), _num("mark_refund", 0.2))
	last = {"marked": marked}
	effect.emit(&"toll", {"pos": pos, "marked": marked})
	_finish()


## Requiem mark (host): the enemy "mark" status (+amp damage taken) for t s; a kill while it lasts refunds `refund`
## of `owner_node`'s grenade cooldown (Player.refund_grenade, shared refund cap).
static func mark(e: Node, t: float, amp: float, owner_node: Node, refund: float) -> void:
	e.apply_status("mark", {"dur": t, "amp": amp, "source": owner_node})
	e.set_meta("requiem_mark", {"until": Time.get_ticks_msec() + int(t * 1000.0),
		"owner": owner_node.get_instance_id() if owner_node else 0, "refund": refund})
	if e.has_signal("died") and not e.died.is_connected(Grenade._requiem_died):
		e.died.connect(Grenade._requiem_died)


static func _requiem_died(e: Node) -> void:
	var m: Dictionary = e.get_meta("requiem_mark", {})
	if m.is_empty() or Time.get_ticks_msec() > int(m.until):
		return
	var o = instance_from_id(int(m.owner)) if int(m.owner) != 0 else null
	if o is Node and is_instance_valid(o) and NetGate.grant_grenade_refund(o, float(m.refund), "requiem"): # NET G6
		requiem_refunds += 1
		return
	if o is Node and is_instance_valid(o) and o.has_method("refund_grenade"):
		o.call("refund_grenade", float(m.refund))
		requiem_refunds += 1
