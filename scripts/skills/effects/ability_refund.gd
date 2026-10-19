extends SkillEffect
## A kill within `window` seconds after using the ability refunds one charge (once per use).

var _used_at: float = -INF


func default_hooks() -> Array:
	return ["ability_used", "enemy_killed"]


func wants(_ctx: Dictionary) -> bool:
	return true


func on_event(name: StringName, _ctx: Dictionary) -> void:
	if name == &"ability_used":
		_used_at = now()
	elif now() - _used_at <= float(p("window", 1.0)):
		_used_at = -INF
		player.refund_ability_charge()
