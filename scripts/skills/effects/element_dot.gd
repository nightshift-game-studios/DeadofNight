extends SkillEffect
## Blaze burns (enemy status "burn": dps for dur, refreshing keeps the higher dps).
## Ignite: the first element_dot with frac_per_s handles Blaze hits; frac_per_s adds up over all
## element_dot effects (Kindling + Cinder Shells). params: frac_per_s, dur.
## spread_on_death: a burning zombie that dies ignites everything within spread_radius (spread_dps min).


func default_hooks() -> Array:
	return ["enemy_killed"] if params.get("spread_on_death", false) else ["hit"]


func wants(ctx: Dictionary) -> bool:
	return true if params.get("spread_on_death", false) else passes(ctx)


func on_event(name: StringName, ctx: Dictionary) -> void:
	var t = ctx.get("target")
	if t == null or not is_instance_valid(t) or not t.has_method("apply_status"):
		return
	if name == &"enemy_killed":
		if not t.has_status("burn"):
			return
		var dps := maxf(float(t.status("burn").get("dps", 0.0)), float(p("spread_dps", 10.0)))
		for e in runner.enemies_near(SkillRunner.center_of(t), float(p("spread_radius", 3.0)), [t]):
			e.apply_status("burn", {"dps": dps, "dur": float(p("dur", 3.0)), "source": player})
		return
	if str(ctx.get("source", "")) in ["dot", "hazard"]:
		return
	var ign: Array = runner.effects_of("element_dot").filter(func(e): return float(e.p("frac_per_s", 0.0)) > 0.0)
	if ign.is_empty() or ign[0] != self:
		return
	var frac := 0.0
	var dur := 0.0
	for e in ign:
		frac += float(e.p("frac_per_s", 0.0))
		dur = maxf(dur, float(e.p("dur", 3.0)))
	t.apply_status("burn", {"dps": float(ctx.get("damage", 0.0)) * frac, "dur": dur, "source": player})
