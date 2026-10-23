extends Node3D
## Gall puddle (Skillz, DESIGN §22): the hazard a bile glob leaves where it lands. A disc of `radius` m for `duration` s.
## Every player inside (co-op: every avatar, NetGate E6) takes `dps` as damage ticks every `tick` s and is slowed by
## `slow` (PlayerStatus.slow, MAIN_HOOKS §15b; the strongest slow wins, so it never stacks with Bloater bile).
## Overlapping gall puddles don't stack damage: one tick per player per `tick` s across all of them (_last_tick).
## Zombies are not affected. is_visual_only (client copy, MAIN_HOOKS §22 P1): the disc and the sizzle, no effects.

const PlayerStatusScr := preload("res://scripts/combat/player_status.gd")

const REACH_H := 0.5 ## ray height above the puddle floor / the player's feet for the wall check

static var _last_tick: Dictionary = {} ## player instance id -> game clock (s) of their last gall tick
static var _clock: float = 0.0 ## game seconds (physics deltas, so time_scale and tick rate don't matter)
static var _clock_frame: int = -1

var radius: float = 2.5
var duration: float = 4.0
var dps: float = 4.0
var tick: float = 0.5
var slow_amp: float = 0.25
var age: float = 0.0
var is_visual_only: bool = false
var attacker: Node = null
var players_inside: Array = []
var damage_dealt: float = 0.0 ## tests
var _mesh: MeshInstance3D
var _loop: Node
var _vis: Dictionary = {}
var _audio: Dictionary = {}


static func spawn(parent: Node, pos: Vector3, imp: Dictionary, proj_def: Dictionary, owner_node: Node, visual_only: bool) -> Node3D:
	var p: Node3D = (load("res://scripts/projectiles/gall_puddle.gd") as GDScript).new()
	p.name = "GallPuddle"
	p.radius = float(imp.get("radius", 2.5))
	p.duration = float(imp.get("duration", 4.0))
	p.dps = float(imp.get("dps", 4.0))
	p.tick = maxf(float(imp.get("tick", 0.5)), 0.05)
	p.slow_amp = float(imp.get("slow", 0.25))
	p.is_visual_only = visual_only
	p.attacker = owner_node
	p._vis = proj_def.get("visual", {})
	p._audio = proj_def.get("audio", {})
	p.add_to_group("gall_puddles")
	parent.add_child(p)
	p.global_position = pos
	return p


static func now() -> float:
	return _clock


func _ready() -> void:
	var path := str(_vis.get("puddle_model", ""))
	var model: Node3D = null
	if path != "" and ResourceLoader.exists(path):
		var sc := load(path) as PackedScene
		if sc:
			model = sc.instantiate() as Node3D
			model.scale = Vector3.ONE * radius / maxf(float(_vis.get("puddle_model_radius", 2.5)), 0.01) # Desi's gall_puddle.glb: 2.5 m
			add_child(model)
			_fade_model(model)
	if model == null:
		_mesh = MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = radius
		cyl.bottom_radius = radius
		cyl.height = 0.02
		cyl.radial_segments = 28
		_mesh.mesh = cyl
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.5, 0.66, 0.1, 0.72)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.1
		mat.emission_enabled = true
		mat.emission = Color(0.35, 0.5, 0.05)
		mat.emission_energy_multiplier = 0.7
		_mesh.material_override = mat
		_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mesh.position.y = 0.035
		add_child(_mesh)
	# Audi-0 (gallspitter_HOOKUP.md): the one-shot sizzle is cut to 4.0 s with its fade; any other duration loops and
	# fades out over the last 0.6 s. Missing files: Sfx returns null, silent.
	var sfx := get_node_or_null("/root/Sfx")
	if sfx:
		if is_equal_approx(duration, 4.0) and str(_audio.get("puddle", "")) != "":
			sfx.play_at(str(_audio.puddle), global_position)
		elif str(_audio.get("puddle_loop", "")) != "":
			_loop = sfx.attach_loop(str(_audio.puddle_loop), self)


## Desi's fade: own copy of each material, albedo alpha 1 -> 0 and emission -> 0 over the puddle's life.
func _fade_model(model: Node) -> void:
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m3 := mi as MeshInstance3D
		if m3.mesh == null:
			continue
		for i in m3.mesh.get_surface_count():
			var am := m3.get_active_material(i) as StandardMaterial3D
			if am == null:
				continue
			var m := am.duplicate() as StandardMaterial3D
			m3.set_surface_override_material(i, m)
			var tw := create_tween().set_parallel(true)
			tw.tween_property(m, "albedo_color:a", 0.0, duration)
			if m.emission_enabled:
				tw.tween_property(m, "emission_energy_multiplier", 0.0, duration)


func _targets() -> Array:
	var lst = NetGate.players_or_null()
	return lst if lst is Array else get_tree().get_nodes_in_group("player")


func contains(p: Vector3) -> bool:
	return Vector2(p.x - global_position.x, p.z - global_position.z).length() <= radius and absf(p.y - global_position.y) < 1.5


## Playtest 2026-10-22 #11: the disc doesn't reach through geometry. False when a wall / prop (layer 1) stands between the puddle
## and a point `REACH_H` m above where the player stands, so a puddle beside a wall never hurts or slows someone on the far side.
func reaches(p: Vector3) -> bool:
	if not is_inside_tree():
		return true
	var q := PhysicsRayQueryParameters3D.create(global_position + Vector3(0, REACH_H, 0), p + Vector3(0, REACH_H, 0), 1)
	q.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _physics_process(delta: float) -> void:
	if Engine.get_physics_frames() != _clock_frame:
		_clock_frame = Engine.get_physics_frames()
		_clock += delta
	age += delta
	if age >= duration:
		queue_free()
		return
	if _loop and is_instance_valid(_loop) and age > duration - 0.6 and not _loop.has_meta("fading"):
		_loop.set_meta("fading", true)
		create_tween().tween_property(_loop, "volume_db", -60.0, 0.6)
	if _mesh and age > duration - 0.6: # fade out the last 0.6 s
		var m := _mesh.material_override as StandardMaterial3D
		m.albedo_color.a = 0.72 * clampf((duration - age) / 0.6, 0.0, 1.0)
	players_inside.clear()
	for pl in _targets():
		if not (pl is Node3D) or not is_instance_valid(pl) or pl.get("dead"):
			continue
		if not contains((pl as Node3D).global_position) or not reaches((pl as Node3D).global_position):
			continue
		players_inside.append(pl)
		if is_visual_only:
			continue
		PlayerStatusScr.slow(pl, slow_amp, 0.25, self)
		var id: int = pl.get_instance_id()
		var t := now()
		if t - float(_last_tick.get(id, -INF)) >= tick - 0.001:
			_last_tick[id] = t
			var dmg := dps * tick
			damage_dealt += dmg
			if pl.has_method("take_damage"):
				pl.call("take_damage", dmg, attacker if is_instance_valid(attacker) else null)
