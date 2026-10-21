extends SkillEffect
## Hoard Field Card (card type "hoard", playtest #13): at every round start you gain `pct` of your unspent points,
## at most `cap` per round. Rewards banking points instead of spending them.

var paid: int = 0


func default_hooks() -> Array:
	return ["round_started"]


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	var pl = player
	if pl == null or not is_instance_valid(pl) or not ("points" in pl):
		return
	var n := mini(int(floor(float(pl.points) * float(p("pct", 0.05)))), int(p("cap", 300)))
	if n > 0:
		pl.add_points(n, "interest")
		paid += n
