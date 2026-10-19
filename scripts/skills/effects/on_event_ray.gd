extends SkillEffect
## Fires a bonus ray from the event's target to the nearest other zombie. params: frac (of
## ctx.damage), range.


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var t = ctx.get("target")
	if t == null or not is_instance_valid(t):
		return
	var from := SkillRunner.center_of(t)
	var other: Node = runner.nearest_enemy(from, float(p("range", 8.0)), [t])
	if other == null:
		return
	Effects.spawn_tracer(player.get_tree().current_scene, from, SkillRunner.center_of(other), Color(1.0, 0.85, 0.5))
	runner.deal(other, float(ctx.get("damage", 0.0)) * float(p("frac", 0.5)), "ray", ctx)
