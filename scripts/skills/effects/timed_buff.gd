extends SkillEffect
## Reactive Field Card (card type "reactive", playtest #13): an event (JSON "on", e.g. reload_finished) grants
## `stat` add / mult for `duration` seconds (re-triggering refreshes; `sources` limits a damage_out buff to those ctx.source values). Stats folded in recalc_stats (move_speed,
## reload_speed, ...) are re-applied when the buff starts and ends.

var left: float = 0.0


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	var was := left > 0.0
	left = float(p("duration", 3.0))
	if not was:
		_recalc()


func has_tick() -> bool:
	return true


func tick(delta: float) -> void:
	if left <= 0.0:
		return
	left -= delta
	if left <= 0.0:
		left = 0.0
		_recalc()


func active() -> bool:
	return left > 0.0


func _recalc() -> void:
	if player and is_instance_valid(player) and player.has_method("recalc_stats"):
		player.recalc_stats()


func stats() -> Array:
	return [str(params.get("stat", ""))]


func priority() -> int:
	return 10 if params.has("mult") else 0


func modify(stat: String, value: float, ctx: Dictionary) -> float:
	if left <= 0.0:
		return value
	if stat == "damage_out" and params.has("sources") and not (str(ctx.get("source", "gun")) in params.sources):
		return value ## e.g. Knuckle Wraps: sources ["melee"]
	if params.has("add"):
		value += float(p("add", 0.0))
	if params.has("mult"):
		value *= float(p("mult", 1.0))
	return value
