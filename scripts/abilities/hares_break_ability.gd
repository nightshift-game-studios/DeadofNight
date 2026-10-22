class_name HaresBreakAbility
extends SpeedBoostAbility
## Scout, movement (DESIGN §24.4, replaces the generic Adrenaline): break away like a startled hare. Run
## `speed_multiplier` faster for `duration` seconds, the held gun reloads at once from reserve, and any slow on you is
## shaken off. Self-only: no damage, no RNG, nothing to sync beyond the player's own movement.
## Tuning: ab_hare_speed (multiplier), ab_hare_reload (1 = full magazine, 0.5 = half).
const PlayerStatus := preload("res://scripts/combat/player_status.gd")

@export var reload_fraction: float = 1.0
var reloaded: int = 0 ## rounds moved into the magazine on the last cast (tests)


func activate(player: Node) -> bool:
	var base := speed_multiplier
	speed_multiplier = tuned(player, "hare_speed", base)
	var ok := super.activate(player)
	speed_multiplier = base
	if not ok:
		return false
	reloaded = 0
	var w = player.current_weapon() if player.has_method("current_weapon") else null
	if w != null and w.has_method("mag_size"):
		var mag: int = w.mag_size()
		var want: int = int(ceil(mag * clampf(tuned(player, "hare_reload", reload_fraction), 0.0, 1.0)))
		var take: int = mini(mini(want, mag - w.ammo), w.reserve)
		if take > 0:
			if player.has_method("cancel_reload_for_skill"):
				player.cancel_reload_for_skill()
			w.ammo += take
			w.reserve -= take
			reloaded = take
	PlayerStatus.clear_slows(player)
	return true
