extends SkillEffect
## Tally-style stacks: each precision gun hit adds a stack (max `max`), a shot that hits nothing resets.
## Gun damage x (1 + per * stacks). params: per, max.

var stacks: int = 0


func default_hooks() -> Array:
	return ["hit", "shot_missed"]


func wants(_ctx: Dictionary) -> bool:
	return true


func stats() -> Array:
	return ["damage_out"]


func priority() -> int:
	return 10


func on_event(name: StringName, ctx: Dictionary) -> void:
	if name == &"shot_missed":
		stacks = 0
	elif name == &"hit" and str(ctx.get("source", "")) == "gun" and SkillEffect.truthy(ctx.get("is_headshot")):
		stacks = mini(stacks + 1, int(p("max", 10)))


func modify(_stat: String, value: float, ctx: Dictionary) -> float:
	if str(ctx.get("source", "gun")) != "gun":
		return value
	return value * (1.0 + float(p("per", 0.03)) * stacks)
