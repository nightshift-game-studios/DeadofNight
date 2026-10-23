extends SkillEffect
## Clean-sheet Field Card (card type "wager"): clear a round without losing any health (overshield absorbs count as
## clean) and you are paid: overshield, heal and points. params: overshield, heal, points_per_round (x the round).

var _hurt: bool = false
var paid: int = 0 ## flawless rounds paid (tests / HUD)


func hooks() -> Array:
	return ["round_started", "damage_taken", "round_cleared"]


func wants(_ctx: Dictionary) -> bool:
	return true


func on_event(name: StringName, ctx: Dictionary) -> void:
	match name:
		&"round_started":
			_hurt = false
		&"damage_taken":
			if int(ctx.get("dealt", 0)) > 0:
				_hurt = true
		&"round_cleared":
			if _hurt:
				return
			var pl = player
			if pl == null or not is_instance_valid(pl):
				return
			paid += 1
			if params.has("overshield"):
				pl.grant_overshield(float(p("overshield", 0.0)), float(p("cap", -1.0)))
			if params.has("heal"):
				pl.heal(int(p("heal", 0)))
			var pts := int(p("points_per_round", 0)) * maxi(int(ctx.get("round", 1)), 1)
			if pts > 0:
				pl.add_points(pts, "card")
