extends SkillEffect
## Blight Rot: Blight hits apply "rot" (+amp damage taken, dur). A rotting zombie that dies bursts
## for `burst` damage to every zombie within `radius` (source "rot", depth + 1) and spreads Rot to them.


func default_hooks() -> Array:
	return ["hit", "enemy_killed"]


func wants(_ctx: Dictionary) -> bool:
	return true


func on_event(name: StringName, ctx: Dictionary) -> void:
	var t = ctx.get("target")
	if t == null or not is_instance_valid(t) or not t.has_method("apply_status"):
		return
	var st := {"amp": float(p("amp", 0.1)), "dur": float(p("dur", 4.0))}
	if name == &"hit":
		if str(ctx.get("element", "")) == "blight" and str(ctx.get("source", "")) != "rot":
			t.apply_status("rot", st)
		return
	if not t.has_status("rot"):
		return
	var pos := SkillRunner.center_of(t)
	Explosion.spawn_vfx(player.get_tree().current_scene, pos, float(p("radius", 3.0)) * 0.5, GearDB.element_color("blight"))
	for e in runner.enemies_near(pos, float(p("radius", 3.0)), [t]):
		e.apply_status("rot", st)
		runner.deal(e, float(p("burst", 40.0)), "rot", ctx, {"element": "blight"})
