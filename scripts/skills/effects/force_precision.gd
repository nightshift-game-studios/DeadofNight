extends SkillEffect
## Makes gun hits count as precision while `cond` holds (stat "force_precision" > 0).
## params: cond, threshold.


func stats() -> Array:
	return ["force_precision"]


func modify(_stat: String, value: float, ctx: Dictionary) -> float:
	return maxf(value, 1.0) if runner.cond(str(params.get("cond", "")), ctx, params) else value
