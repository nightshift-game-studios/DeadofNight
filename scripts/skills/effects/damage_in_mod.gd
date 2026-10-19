extends SkillEffect
## Incoming damage. params: reduction (stat "damage_in" x (1 - reduction)), dodge (chance to
## cancel a hit on "damage_incoming"), cond (SkillRunner.cond name), threshold.


func default_hooks() -> Array:
	return ["damage_incoming"] if params.has("dodge") else []


func wants(_ctx: Dictionary) -> bool:
	return true


func stats() -> Array:
	return ["damage_in"] if params.has("reduction") else []


func priority() -> int:
	return 10


func _ok(ctx: Dictionary) -> bool:
	return runner.cond(str(params.get("cond", "")), ctx, params)


func modify(_stat: String, value: float, ctx: Dictionary) -> float:
	return value * (1.0 - float(p("reduction", 0.0))) if _ok(ctx) else value


func on_event(_name: StringName, ctx: Dictionary) -> void:
	if float(ctx.get("amount", 0.0)) > 0.0 and _ok(ctx) and runner.rng.randf() < float(p("dodge", 0.0)):
		ctx["amount"] = 0.0
		ctx["dodged"] = true
