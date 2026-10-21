class_name GrenadeZone
extends Node3D
## A timed ground zone left by a grenade (Skillz, playtest #25): Cinderjar fire patch, Gravewell vortex.
## Host-only: the grenade creates one only on its authoritative copy (puppets get Desi's GrenadeFX visual alone).
## Callbacks must not capture the grenade (it is freed right after it spawns the zone): pass values, not `self`.
##   on_tick(zone)        every `tick` s, first one at t = 0
##   on_frame(zone, dt)   every physics frame
##   on_end(zone)         once, when `duration` runs out (then the zone frees itself)

var radius: float = 3.0
var duration: float = 5.0
var tick: float = 0.5
var height: float = 2.0 ## |dy| from the zone centre that still counts as inside
var t: float = 0.0
var on_tick: Callable
var on_frame: Callable
var on_end: Callable
var _acc: float = 0.0
var _ended: bool = false


static func make(scene: Node, pos: Vector3, r: float, dur: float, tick_s: float = 0.5) -> GrenadeZone:
	var z := GrenadeZone.new()
	z.radius = r
	z.duration = dur
	z.tick = maxf(tick_s, 0.05)
	z._acc = z.tick # first tick on the first frame
	scene.add_child(z)
	z.global_position = pos
	z.add_to_group("grenade_zones")
	return z


## Live zombies whose feet are within `radius` (flat) of the zone centre and within `height` vertically.
func enemies_inside() -> Array:
	var out := []
	for e in get_tree().get_nodes_in_group("enemies"):
		if not (e is Node3D) or not is_instance_valid(e) or e.get("_dead"):
			continue
		var d: Vector3 = (e as Node3D).global_position - global_position
		if absf(d.y) <= height and Vector2(d.x, d.z).length() <= radius:
			out.append(e)
	return out


func _physics_process(delta: float) -> void:
	if _ended:
		return
	step(delta)


## One frame of zone time (tests call it directly).
func step(delta: float) -> void:
	t += delta
	if on_frame.is_valid():
		on_frame.call(self, delta)
	_acc += delta
	while _acc >= tick - 0.0001 and t <= duration + 0.0001:
		_acc -= tick
		if on_tick.is_valid():
			on_tick.call(self)
	if t >= duration and not _ended:
		_ended = true
		if on_end.is_valid():
			on_end.call(self)
		queue_free()
