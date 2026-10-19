extends SkillEffect
## Prevents lethal damage `uses` times per match: 1 HP, invulnerability and overshield.
## params: uses, invuln, overshield.

var uses_left: int = -1


func attach() -> void:
	uses_left = int(p("uses", 1))


func default_hooks() -> Array:
	return ["lethal_damage"]


func on_event(_name: StringName, ctx: Dictionary) -> void:
	if uses_left <= 0 or ctx.get("prevent", false):
		return
	uses_left -= 1
	ctx["prevent"] = true
	player.invulnerable_t = maxf(player.invulnerable_t, float(p("invuln", 3.0)))
	var os := float(p("overshield", 0.0))
	player.grant_overshield(os, maxf(os, player.overshield_cap))
