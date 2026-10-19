extends SkillEffect
## Field Card offer economy (stats "offer_<key>", read by RunState). params (additive):
## free_rerolls, size, lucky_slot_chance, banishes, milestone_all_legendary.


func stats() -> Array:
	return params.keys().map(func(k): return "offer_" + str(k))


func modify(stat: String, value: float, _ctx: Dictionary) -> float:
	return value + float(p(stat.trim_prefix("offer_"), 0.0))
