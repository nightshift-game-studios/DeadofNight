extends SkillEffect
## Slides hold at least sprint speed for floor_time seconds (stat "slide_floor_time").


func stats() -> Array:
	return ["slide_floor_time"]


func modify(_stat: String, value: float, _ctx: Dictionary) -> float:
	return maxf(value, float(p("floor_time", 1.5)))
