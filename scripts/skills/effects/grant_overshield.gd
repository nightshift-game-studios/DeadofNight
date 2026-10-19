extends SkillEffect
## Overshield on an event. params: amount, cap (lower cap for this grant), every_n_kills.

var _kills: int = 0


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	var n := int(p("every_n_kills", 0))
	if n > 0:
		_kills += 1
		if _kills % n != 0:
			return
	player.grant_overshield(float(p("amount", 0.0)), float(p("cap", -1.0)))
