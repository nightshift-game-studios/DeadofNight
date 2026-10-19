extends SkillEffect
## Heals on an event. params: amount (number or "full").


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	var a = p("amount", 0)
	if str(a) == "full":
		player.heal(player.max_health)
	else:
		player.heal(int(a))
