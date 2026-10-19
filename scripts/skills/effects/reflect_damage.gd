extends SkillEffect
## Zombies that hit you take mult x the raw hit back. params: mult.


func default_hooks() -> Array:
	return ["damage_taken"]


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var a = ctx.get("attacker")
	if a == null or not is_instance_valid(a) or not a.has_method("take_damage"):
		return
	runner.deal(a, float(ctx.get("raw", 0.0)) * float(p("mult", 3.0)), "reflect", ctx)
