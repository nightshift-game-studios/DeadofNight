extends SkillEffect
## Resets a cooldown on an event. params: what ("melee" | "grenade" | "ability").


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	player.reset_cooldown(str(params.get("what", "melee")))
