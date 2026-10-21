class_name ChalkMarkAbility
extends Ability
## Scout, mark (DESIGN §23.2): chalks every zombie in a cone ahead of you (up to `max_targets`, nearest first):
## Marked zombies take +`amp` damage from every source for `mark_time` seconds (the enemy "mark" status, so Spotter /
## "target_marked" skills read it). Tuning: ab_mark_count, ab_mark_amp, ab_mark_time, ab_mark_range.
@export var range_m: float = 30.0
@export var cone_deg: float = 40.0
@export var max_targets: int = 8
@export var amp: float = 0.25
@export var mark_time: float = 8.0
var last_marked: Array = [] ## tests


func activate(player: Node) -> bool:
	last_marked = targets_in_cone(player, tuned(player, "mark_range", range_m), cone_deg, int(tuned(player, "mark_count", max_targets)))
	var a := tuned(player, "mark_amp", amp)
	var t := tuned(player, "mark_time", mark_time)
	for e in last_marked:
		AbilityField.status(e, "mark", t, a)
		Effects.spawn_tracer(player.get_tree().current_scene, (player as Node3D).global_position + Vector3(0, 1.4, 0),
			(e as Node3D).global_position + Vector3(0, 1.2, 0), Color(0.95, 0.95, 0.85, 0.6))
	return true


## Zombies within `range_m` and `cone` degrees (half-angle) of the player's facing, nearest first, at most `n`.
static func targets_in_cone(player: Node, range_m: float, cone: float, n: int) -> Array:
	var p3 := player as Node3D
	var fwd: Vector3 = -p3.global_basis.z
	var cam = player.get("camera")
	if cam is Camera3D:
		fwd = -(cam as Camera3D).global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	var cos_lim := cos(deg_to_rad(cone))
	var out: Array = []
	for e in AbilityField.enemies_around(player, p3.global_position + Vector3(0, 0.9, 0), range_m):
		var d: Vector3 = (e as Node3D).global_position - p3.global_position
		d.y = 0.0
		if d.length() < 0.5 or d.normalized().dot(fwd) >= cos_lim:
			out.append(e)
	out.sort_custom(func(a, b): return p3.global_position.distance_to(a.global_position) < p3.global_position.distance_to(b.global_position))
	return out.slice(0, maxi(n, 0))
