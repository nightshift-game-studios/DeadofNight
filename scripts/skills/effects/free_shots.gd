extends SkillEffect
## Free-ammo window Field Card (card type "reactive"): for the first `dur` seconds of every round, each shot puts its
## round straight back (the shot still fires). Round 1 counts from round_started like every other round.

var left: float = 0.0
var refunded: int = 0


func hooks() -> Array:
	return ["round_started", "shot_fired"]


func has_tick() -> bool:
	return true


func wants(_ctx: Dictionary) -> bool:
	return true


func tick(delta: float) -> void:
	if left > 0.0:
		left = maxf(left - delta, 0.0)


func on_event(name: StringName, ctx: Dictionary) -> void:
	if name == &"round_started":
		left = float(p("dur", 6.0))
		return
	if left <= 0.0:
		return
	var w = ctx.get("weapon")
	if w is WeaponItem and w.ammo < w.mag_size():
		w.ammo += 1
		refunded += 1
		if player and is_instance_valid(player):
			player.emit_ammo()
