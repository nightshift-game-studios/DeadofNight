extends SkillEffect
## Flat stat modifier. params: stat, add | mult (rank arrays ok), optional "while" condition
## (any SkillRunner.cond name, e.g. "ability_active", "still").


func stats() -> Array:
	return [str(params.get("stat", ""))]


func priority() -> int:
	return 10 if params.has("mult") else 0


func modify(_stat: String, value: float, ctx: Dictionary) -> float:
	var w := str(params.get("while", ""))
	if w != "" and not runner.cond(w, ctx, params):
		return value
	if params.has("add"):
		value += float(p("add", 0.0))
	if params.has("mult"):
		value *= float(p("mult", 1.0))
	return value
