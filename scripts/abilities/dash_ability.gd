class_name DashAbility
extends Ability
## Quick burst of speed in the direction you're moving (or looking, if standing still).

@export var dash_speed: float = 22.0


func activate(player: Node) -> bool:
	var dir: Vector3 = player.get_move_direction()
	if dir == Vector3.ZERO:
		dir = -player.global_basis.z
	dir.y = 0.0
	dir = dir.normalized()
	player.velocity.x = dir.x * dash_speed
	player.velocity.z = dir.z * dash_speed
	player.movement_locked_time = duration # skip normal acceleration while dashing
	return true
