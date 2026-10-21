class_name ThrownProjectile
extends Node3D
## Thrown projectile base (Skillz, DESIGN §22 / MAIN_HOOKS §22): a slow, visible, ballistic throw (the Gallspitter's
## bile glob today, grenades later). Types live in data/projectiles.json by type_id.
## Only ever created through ThrownProjectile.spawn(spec), the co-op contract agreed with Netz:
##   spec = {type_id: StringName, variant: StringName (&"" default), rarity: int (Rarity, 0 for enemy shots),
##           pos: Vector3, vel: Vector3, owner_id: int (enemy / player instance id, or net id), seed: int}
## is_visual_only: a client copy. It flies, splashes and leaves the puddle visual, but never damages, slows or
## collides with anyone (the host's copy does).
## Grenades (Skillz, playtest #25): type "grenade" has body "grenade": spawn() makes a Grenade RigidBody (child, top_level)
## that does the physics and the effect; this node carries the spec and follows it. Child specs the grenades spawn:
## "grenade_bomblet" (Rookery: fuse s, then pops; settles where it lands) and "heal_orb" (Leechbell: homes on the owner,
## no world collision; impacted(direct_hit = owner) on arrival, the host's handler heals). Same contract, so Netz syncs them.
## Motion: own gravity (types[].gravity), stepped in _physics_process. Each step sweeps prev -> next against the world
## (layer 1) and against every player's capsule (collision_radius), so a fast frame can't tunnel through.

const DATA_PATH := "res://data/projectiles.json"
const WORLD_MASK := 1
const HazardScr := preload("res://scripts/projectiles/gall_puddle.gd")

signal impacted(p: ThrownProjectile, where: Vector3, direct_hit: Node) ## direct_hit = the player hit, or null

static var _data: Dictionary = {}
static var spawned_total: int = 0 ## tests / stats
static var live: Array = [] ## projectiles in flight (tests, debug draw)

var type_id: StringName = &""
var variant: StringName = &""
var rarity: int = 0
var owner_id: int = 0
var seed_value: int = 0
var spec: Dictionary = {}
var def: Dictionary = {}
var is_visual_only: bool = false
var velocity: Vector3 = Vector3.ZERO
var gravity: float = 6.0
var collision_radius: float = 0.25
var visual_radius: float = 0.18
var age: float = 0.0
var lifetime: float = 6.0
var done: bool = false
var direct_hit: Node = null ## who it hit (tests)
var impact_pos: Vector3 = Vector3.INF
var hazard: Node3D = null
var start_pos: Vector3
var _visual: Node3D
var _loop: Node
var body: Node3D = null ## type body "grenade": the Grenade RigidBody this projectile carries
var fuse: float = 0.0 ## > 0: pops `fuse` s after spawn (bomblets); a world hit before that just settles it
var _settled: bool = false
var homing: bool = false ## heal orbs: steer at the owner, no world collision


# ------------------------------------------------------------------ data

static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_data = d if d is Dictionary else {}
	return _data


static func reload_data(forced: Dictionary = {}) -> void:
	_data = forced


## A type's settings with the variant's overrides merged on top. {} for an unknown type.
static func type_def(id: StringName, var_id: StringName = &"") -> Dictionary:
	var t: Dictionary = data().get("types", {}).get(str(id), {})
	if t.is_empty():
		return {}
	var out := t.duplicate(true)
	if var_id != &"":
		out.merge(t.get("variants", {}).get(str(var_id), {}), true)
	return out


## Launch velocity for a lob from `from` that lands on `to` with the type's horizontal launch_speed and gravity.
## Flight time = flat distance / launch_speed.
static func lob_velocity(from: Vector3, to: Vector3, id: StringName = &"bile_glob") -> Vector3:
	var d := type_def(id)
	var hs := float(d.get("launch_speed", 9.0))
	var g := float(d.get("gravity", 6.0))
	var flat := Vector3(to.x - from.x, 0.0, to.z - from.z)
	var dist := flat.length()
	var t := maxf(dist / hs, 0.2)
	var vy := ((to.y - from.y) + 0.5 * g * t * t) / t
	return (flat.normalized() * hs if dist > 0.01 else Vector3.ZERO) + Vector3(0.0, vy, 0.0)


## Points along that lob (for clearance checks / debug draw), `n` segments.
static func lob_points(from: Vector3, vel: Vector3, flight_t: float, id: StringName = &"bile_glob", n: int = 10) -> PackedVector3Array:
	var g := float(type_def(id).get("gravity", 6.0))
	var pts := PackedVector3Array()
	for i in n + 1:
		var t := flight_t * float(i) / float(n)
		pts.append(from + vel * t + Vector3(0.0, -0.5 * g * t * t, 0.0))
	return pts


## The one way to make a projectile. Returns null for an unknown type or no scene tree.
static func spawn(spec_in: Dictionary) -> ThrownProjectile:
	var id := StringName(str(spec_in.get("type_id", "")))
	var var_id := StringName(str(spec_in.get("variant", "")))
	var d := type_def(id, var_id)
	var tree := Engine.get_main_loop() as SceneTree
	if d.is_empty() or tree == null:
		return null
	var p := ThrownProjectile.new()
	p.type_id = id
	p.variant = var_id
	p.rarity = int(spec_in.get("rarity", 0))
	p.owner_id = int(spec_in.get("owner_id", 0))
	p.seed_value = int(spec_in.get("seed", 0))
	p.spec = spec_in.duplicate()
	p.def = d
	p.velocity = spec_in.get("vel", Vector3.ZERO)
	p.is_visual_only = bool(spec_in.get("visual_only", false))
	# NETZ phase-3 hook P1 (MAIN_HOOKS §22): the host-only branch point. Solo and the co-op host make the authoritative
	# copy here (damage, puddle effects); Netz adds the replication of `spec_in` to every peer at this line, and peers
	# call spawn() with visual_only = true. A non-host peer can never make an authoritative projectile: in co-op its
	# copy is visual-only even if a caller forgot the flag.
	var n := NetGate.net()
	if n != null and n.is_networked() and not n.is_host():
		p.is_visual_only = true
	var parent: Node = tree.current_scene if tree.current_scene else tree.root
	parent.add_child(p)
	p.global_position = spec_in.get("pos", Vector3.ZERO)
	p.start_pos = p.global_position
	spawned_total += 1
	if str(d.get("body", "")) == "grenade": # playtest #25: the RigidBody grenade does the flight
		p.body = Grenade.from_projectile(p)
	return p


# ------------------------------------------------------------------ node

func _ready() -> void:
	name = "Proj_%s_%d" % [type_id, spawned_total]
	add_to_group("thrown_projectiles")
	live.append(self)
	gravity = float(def.get("gravity", 6.0))
	collision_radius = float(def.get("collision_radius", 0.25))
	visual_radius = float(def.get("visual_radius", 0.18))
	lifetime = float(def.get("lifetime", 6.0))
	fuse = float(spec.get("fuse", def.get("fuse", 0.0)))
	homing = bool(def.get("homing", false))
	if str(def.get("body", "")) == "grenade":
		return # the Grenade body brings its own visual, light and audio
	_build_visual()
	var a: Dictionary = def.get("audio", {})
	var sfx := get_node_or_null("/root/Sfx")
	if sfx and str(a.get("flight_loop", "")) != "" and _loop_room():
		_loop = sfx.attach_loop(str(a.flight_loop), self)


## loop_cap (data): at most that many live projectiles of this type play their flight loop (Leechbell orbs: ~4 voices).
func _loop_room() -> bool:
	var cap := int(def.get("loop_cap", 0))
	if cap <= 0:
		return true
	var n := 0
	for q in live:
		if q != self and is_instance_valid(q) and q.type_id == type_id and q._loop != null and is_instance_valid(q._loop):
			n += 1
	return n < cap


func _exit_tree() -> void:
	live.erase(self)


func _build_visual() -> void:
	var v: Dictionary = def.get("visual", {})
	var path := str(v.get("model", ""))
	if path != "" and ResourceLoader.exists(path):
		var sc := load(path) as PackedScene
		if sc:
			_visual = sc.instantiate() as Node3D
	if _visual == null: # placeholder until Desi's bile_glob.glb lands
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = visual_radius
		sm.height = visual_radius * 2.0
		sm.radial_segments = 16
		sm.rings = 8
		mi.mesh = sm
		var mat := StandardMaterial3D.new()
		var c: Array = v.get("color", [0.62, 0.78, 0.16, 0.95])
		mat.albedo_color = Color(c[0], c[1], c[2], c[3] if c.size() > 3 else 1.0)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA if mat.albedo_color.a < 1.0 else BaseMaterial3D.TRANSPARENCY_DISABLED
		var e: Array = v.get("emission", [0.42, 0.62, 0.06])
		mat.emission_enabled = true
		mat.emission = Color(e[0], e[1], e[2])
		mat.emission_energy_multiplier = float(v.get("emission_energy", 1.6))
		mat.roughness = 0.2
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_visual = mi
	_visual.name = "Visual"
	add_child(_visual)
	var tint_c := _tint()
	if tint_c.a > 0.0 and not (_visual is MeshInstance3D): # visual.tint_parts {node: "additive" | "emissive"} (heal orb)
		var parts: Dictionary = v.get("tint_parts", {})
		for part in parts:
			var n := _visual.find_child(str(part), true, false)
			if n:
				for m in GrenadeFX.tint(n, tint_c, str(parts[part]) == "additive", float(v.get("tint_energy", 1.5))):
					if str(parts[part]) != "additive":
						m.emission_energy_multiplier = float(v.get("emission_energy", 4.0))
	var light := OmniLight3D.new() # keeps it readable at night / at range
	light.name = "Glow"
	light.light_color = tint_c if tint_c.a > 0.0 else Color(0.55, 0.85, 0.2)
	light.light_energy = 0.6
	light.omni_range = 2.2
	light.shadow_enabled = false
	add_child(light)


## visual.tint "grenade": the variant's grenades.json effect colour; "#hex": that; else transparent (no tint).
func _tint() -> Color:
	var t := str(def.get("visual", {}).get("tint", ""))
	if t == "grenade":
		return Grenade.color_of(Grenade.data_for_variant(str(variant)))
	if t != "" and Color.html_is_valid(t):
		return Color.html(t)
	return Color(0, 0, 0, 0)


func _physics_process(delta: float) -> void:
	if done:
		return
	if body != null or str(def.get("body", "")) == "grenade":
		if is_instance_valid(body):
			global_position = body.global_position
		else:
			queue_free()
		return
	step(delta)


## One motion step (tests call it directly).
func step(delta: float) -> void:
	if done:
		return
	age += delta
	if fuse > 0.0 and age >= fuse:
		_impact(global_position, null, Vector3.UP)
		return
	if _settled:
		return
	if homing:
		_home(delta)
		return
	var from := global_position
	var vel0 := velocity
	velocity.y -= gravity * delta
	var to := from + (vel0 + velocity) * 0.5 * delta
	# players first (a glob that clips a player's head and then a wall hits the player)
	if bool(def.get("hits_players", true)):
		var pl := _player_on_segment(from, to)
		if pl:
			_impact(_closest_on_segment(from, to, (pl as Node3D).global_position + Vector3(0, 0.9, 0)), pl, Vector3.UP)
			return
	var hit := _world_hit(from, to) if bool(def.get("hits_world", true)) else {}
	if not hit.is_empty():
		if fuse > 0.0: # bomblet: lands and waits for its fuse
			global_position = hit.position
			velocity = Vector3.ZERO
			_settled = true
			return
		_impact(hit.position, null, hit.normal)
		return
	global_position = to
	if _visual and velocity.length() > 0.1:
		_visual.look_at(global_position + velocity, Vector3.UP if absf(velocity.normalized().y) < 0.99 else Vector3.FORWARD)
	if age >= lifetime or global_position.y < -60.0:
		_impact(global_position, null, Vector3.UP)


## Heal orb: drift up a little, then steer at the owner's chest; arrival -> impacted(direct_hit = owner). No damage here.
func _home(delta: float) -> void:
	var o = instance_from_id(owner_id) if owner_id != 0 else null
	if not (o is Node3D) or not is_instance_valid(o):
		if age >= lifetime:
			_impact(global_position, null, Vector3.UP)
		else:
			global_position += velocity * delta
			velocity = velocity.lerp(Vector3.ZERO, clampf(2.0 * delta, 0.0, 1.0))
		return
	var goal: Vector3 = (o as Node3D).global_position + Vector3(0, float(def.get("home_height", 1.0)), 0)
	var to := goal - global_position
	var d := to.length()
	if d <= float(def.get("arrive_radius", 0.6)) or age >= lifetime:
		_arrive(o)
		return
	var sp := float(def.get("home_speed", 6.0)) * clampf(age / maxf(float(def.get("home_ramp", 0.35)), 0.01), 0.2, 1.0)
	velocity = velocity.lerp(to / d * sp, clampf(float(def.get("home_turn", 6.0)) * delta, 0.0, 1.0))
	global_position += velocity * delta


func _arrive(target: Node) -> void:
	done = true
	impact_pos = global_position
	direct_hit = target
	var a: Dictionary = def.get("audio", {})
	var sfx := get_node_or_null("/root/Sfx")
	if sfx and str(a.get("arrive", "")) != "" and target is Node and (target as Node).is_in_group("player") \
			and not (target as Node).get("is_remote"): # the chime is 2D, for the healed (local) player only
		sfx.play(str(a.arrive))
	impacted.emit(self, global_position, target)
	if _loop and is_instance_valid(_loop):
		_loop.queue_free()
	queue_free()


## Sphere sweep from `a` to `b` against the world (layer 1), as a ray offset by the collision radius along the motion.
func _world_hit(a: Vector3, b: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var dir := (b - a)
	var len := dir.length()
	if len < 0.0001:
		return {}
	var q := PhysicsRayQueryParameters3D.create(a, b + dir / len * collision_radius, WORLD_MASK)
	q.collide_with_areas = false
	var r := space.intersect_ray(q)
	if r.is_empty():
		return {}
	var owner_node := instance_from_id(owner_id) if owner_id != 0 else null
	if owner_node != null and r.collider == owner_node:
		return {}
	r.position = (r.position as Vector3) - dir / len * collision_radius
	return r


static func _closest_on_segment(a: Vector3, b: Vector3, p: Vector3) -> Vector3:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-8), 0.0, 1.0)
	return a + ab * t


## Distance between two segments (a0-a1, b0-b1).
static func seg_seg_dist(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3) -> float:
	var best := INF
	for i in 9:
		var p := a0.lerp(a1, float(i) / 8.0)
		best = minf(best, p.distance_to(_closest_on_segment(b0, b1, p)))
	var q := _closest_on_segment(a0, a1, _closest_on_segment(b0, b1, a0.lerp(a1, 0.5)))
	best = minf(best, q.distance_to(_closest_on_segment(b0, b1, q)))
	return best


## Every player body this projectile can hit (co-op: local + remote avatars, NetGate E6 list).
func targets() -> Array:
	var lst = NetGate.players_or_null()
	if lst is Array:
		return lst
	return get_tree().get_nodes_in_group("player")


func _player_on_segment(a: Vector3, b: Vector3) -> Node:
	for pl in targets():
		if not (pl is Node3D) or not is_instance_valid(pl) or pl.get("dead"):
			continue
		var r := 0.4
		var h := 1.8
		var cs := (pl as Node).get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs and cs.shape is CapsuleShape3D:
			r = (cs.shape as CapsuleShape3D).radius
			h = (cs.shape as CapsuleShape3D).height
		var mid: Vector3 = (pl as Node3D).global_position + Vector3(0, h * 0.5, 0)
		if cs:
			mid = cs.global_position
		var half := maxf(h * 0.5 - r, 0.0)
		var c0 := mid - Vector3(0, half, 0)
		var c1 := mid + Vector3(0, half, 0)
		if seg_seg_dist(a, b, c0, c1) <= r + collision_radius:
			return pl
	return null


func _impact(where: Vector3, hit_player: Node, normal: Vector3) -> void:
	done = true
	impact_pos = where
	direct_hit = hit_player
	global_position = where
	var owner_node := instance_from_id(owner_id) if owner_id != 0 else null
	if owner_node != null and not is_instance_valid(owner_node):
		owner_node = null
	var a: Dictionary = def.get("audio", {})
	var sfx := get_node_or_null("/root/Sfx")
	if hit_player and not is_visual_only:
		var dmg := int(def.get("direct_damage", 10))
		if owner_node and owner_node.has_method("projectile_damage"):
			dmg = int(owner_node.projectile_damage(type_id))
		if hit_player.has_method("take_damage"):
			hit_player.call("take_damage", dmg, owner_node)
		if sfx and str(a.get("direct_hit", "")) != "":
			sfx.play_at(str(a.direct_hit), where)
	if sfx and str(a.get("impact", "")) != "":
		sfx.play_at(str(a.impact), where)
	var imp: Dictionary = def.get("impact", {})
	if bool(imp.get("vfx_blast", false)) and is_visual_only: # the host copy's handler blasts (with its own VFX)
		Explosion.spawn_vfx(get_parent(), where, float(imp.get("vfx_radius", 2.5)), _tint() if _tint().a > 0.0 else Color.ORANGE)
	if str(imp.get("hazard", "")) != "":
		var ground := _ground_below(where, normal, float(imp.get("max_drop", 8.0)))
		if ground != Vector3.INF:
			hazard = HazardScr.spawn(get_parent(), ground, imp, def, owner_node, is_visual_only)
	impacted.emit(self, where, hit_player)
	if _loop and is_instance_valid(_loop):
		_loop.queue_free()
	queue_free()


## Where the hazard lies: straight down from the impact (a wall / ceiling splash drips to the floor below).
func _ground_below(where: Vector3, normal: Vector3, max_drop: float) -> Vector3:
	var space := get_world_3d().direct_space_state
	var start := where + normal * 0.05 + Vector3(0, 0.3, 0)
	var q := PhysicsRayQueryParameters3D.create(start, start - Vector3(0, max_drop + 0.3, 0), WORLD_MASK)
	var r := space.intersect_ray(q)
	return r.position if not r.is_empty() else Vector3.INF
