extends SkillEffect
## Applies an enemy status to ctx.target. params: status ("mark", "rot", "burn", "slow"), dur, amp, dps.


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var t = ctx.get("target")
	if t == null or not is_instance_valid(t) or not t.has_method("apply_status"):
		return
	var st := {"dur": float(p("dur", 4.0)), "amp": float(p("amp", 0.0)), "dps": float(p("dps", 0.0)), "source": player}
	t.apply_status(str(params.get("status", "mark")), st)
