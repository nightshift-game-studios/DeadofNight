extends SkillEffect
## Field Card draw weight for one branch (stat "offer_weight:<branch>"). params: branch, mult.


func stats() -> Array:
	return ["offer_weight:" + str(params.get("branch", ""))]


func priority() -> int:
	return 10


func modify(_stat: String, value: float, _ctx: Dictionary) -> float:
	return value * float(p("mult", 1.5))
