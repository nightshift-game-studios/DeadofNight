extends SkillEffect
## Multiplies outgoing damage (stat "damage_out") by (1 + mult) when `cond` holds.
## params: cond (name or array, all must hold), mult, optional sources ["gun", "melee", ...], threshold.


func stats() -> Array:
	return [str(params.get("stat", "damage_out"))]


func priority() -> int:
	return 10


func modify(_stat: String, value: float, ctx: Dictionary) -> float:
	var srcs: Array = params.get("sources", [])
	if not srcs.is_empty() and not (str(ctx.get("source", "gun")) in srcs):
		return value
	var c = params.get("cond", "")
	var conds: Array = c if typeof(c) == TYPE_ARRAY else [c]
	for name in conds:
		if not runner.cond(str(name), ctx, params):
			return value
	return value * (1.0 + float(p("mult", 0.0)))
