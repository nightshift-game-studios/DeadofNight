class_name SpeedBoostAbility
extends Ability
## Temporarily multiplies the player's move speed (an "adrenaline" style ability).

@export var speed_multiplier: float = 1.6


var _prev_multiplier: float = 1.0


func activate(player: Node) -> bool:
	_prev_multiplier = player.speed_multiplier
	player.speed_multiplier = speed_multiplier
	return true


## Re-activating mid-boost would stack the multiplier and break the restore, so a second charge waits.
func allow_recast_while_active() -> bool:
	return false


func end(player: Node) -> void:
	player.speed_multiplier = _prev_multiplier # restore whatever was there before, not a hard 1.0
