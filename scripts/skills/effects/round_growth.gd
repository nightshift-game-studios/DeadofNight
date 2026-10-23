extends SkillEffect
## Growing Field Card (card type "growing", playtest #13): a stat multiplier that grows with every round cleared
## after the card was taken. params: stat (default damage_out), per_round, cap, sources (damage_out only: ctx.source
## filter, default ["gun"]), reset_below (optional: growth resets when health drops under this fraction).

var rounds: int = 0


func default_hooks() -> Array:
	return ["round_cleared"]


func hooks() -> Array:
	var h: Array = super.hooks().duplicate()
	if params.has("reset_below") and not h.has("damage_taken"):
		h.append("damage_taken")
	return h


func wants(ctx: Dictionary) -> bool:
	if str(ctx.get("event", "")) == "damage_taken":
		return params.has("reset_below")
	return passes(ctx)


func on_event(name: StringName, ctx: Dictionary) -> void:
	if name == &"damage_taken":
		# risk: dropping under `reset_below` of max health wipes the accumulated growth
		if rounds > 0 and float(ctx.get("health_frac", 1.0)) < float(p("reset_below", 0.3)):
			rounds = 0
			if str(params.get("stat", "damage_out")) != "damage_out" and player and player.has_method("recalc_stats"):
				player.recalc_stats()
		return
	rounds += 1
	if str(params.get("stat", "damage_out")) != "damage_out" and player and player.has_method("recalc_stats"):
		player.recalc_stats()


func bonus() -> float:
	return minf(float(p("per_round", 0.02)) * rounds, float(p("cap", 0.3)))


func stats() -> Array:
	return [str(params.get("stat", "damage_out"))]


func priority() -> int:
	return 10


func modify(stat: String, value: float, ctx: Dictionary) -> float:
	if stat == "damage_out" and not (str(ctx.get("source", "gun")) in params.get("sources", ["gun"])):
		return value
	return value * (1.0 + bonus())
