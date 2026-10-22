class_name AbilityVFX
extends RefCounted
## Desi's §24 Q-ability visuals (playtest 2026-10-22 #3). Scenes live in res://assets/vfx/abilities/ (script-free GPUParticles3D;
## see each root's editor_description). Visual only: gameplay stays in the ability scripts. Missing scene -> no-op.

const RUSH := "res://assets/vfx/abilities/vfx_breach_rush.tscn"
const HARE := "res://assets/vfx/abilities/vfx_hares_break.tscn"
static var _cache: Dictionary = {}


static func _inst(path: String, parent: Node) -> Node3D:
	if parent == null or not parent.is_inside_tree():
		return null
	if not _cache.has(path):
		_cache[path] = load(path) if ResourceLoader.exists(path) else null
	var ps: PackedScene = _cache[path]
	if ps == null:
		return null
	var n := ps.instantiate() as Node3D
	parent.add_child(n)
	return n


static func _free_after(n: Node, t: float) -> void:
	if n != null and n.is_inside_tree():
		n.get_tree().create_timer(t).timeout.connect(func(): if is_instance_valid(n): n.queue_free())


## Breach Rush cast: dust + leading-shoulder streak on the player (follows them for the rush); frees itself.
static func rush_start(player: Node, rush_time: float = 0.3) -> Node3D:
	var n := _inst(RUSH, player)
	if n == null:
		return null
	var st := n.get_node_or_null("Streak") as Node3D
	if st != null:
		st.create_tween().tween_property(st, "scale", Vector3(1, 1, 0.05), rush_time + 0.1)
	_free_after(n, rush_time + 0.9)
	return n


## A zombie ploughed by the rush: one dust/impact puff at its chest (in the world, not on the player).
static func rush_hit(vfx: Node3D, pos: Vector3) -> void:
	if vfx == null or not is_instance_valid(vfx) or not vfx.is_inside_tree():
		return
	var tmpl := vfx.get_node_or_null("HitPuff") as GPUParticles3D
	if tmpl == null:
		return
	var p := tmpl.duplicate() as GPUParticles3D
	var world: Node = vfx.get_tree().current_scene
	if world == null:
		world = vfx.get_tree().root
	world.add_child(p)
	p.global_position = pos + Vector3(0, 1.0, 0)
	p.emitting = true
	p.restart()
	p.finished.connect(p.queue_free)


static func _stop(n: Node) -> void:
	if is_instance_valid(n):
		for c in n.get_children():
			if c is GPUParticles3D:
				(c as GPUParticles3D).emitting = false


## Hare's Break cast: green speed wisps on the player for `duration` s, then they trail off and the node frees.
static func hare_start(player: Node, duration: float = 4.0) -> Node3D:
	var n := _inst(HARE, player)
	if n == null:
		return null
	n.get_tree().create_timer(duration).timeout.connect(_stop.bind(n))
	_free_after(n, duration + 0.9)
	return n
