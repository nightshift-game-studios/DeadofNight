extends SkillEffect
## Refunds a fraction of the grenade cooldown (player.refund_grenade applies the global
## 60%-per-rolling-5s cap). params: fraction, per_airtime (max refunds until you touch the ground).

var _count: int = 0


func has_tick() -> bool:
	return params.has("per_airtime")


func tick(_delta: float) -> void:
	if player and player.is_on_floor():
		_count = 0


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	if params.has("per_airtime"):
		if _count >= int(p("per_airtime", 3)):
			return
		_count += 1
	player.refund_grenade(float(p("fraction", 0.1)))
