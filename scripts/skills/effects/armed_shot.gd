extends SkillEffect
## Armed-shot Field Card (card type "trigger"): an event ("on", e.g. round_started, slide_ended, reload_finished) or
## holding aim for `hold_ads` seconds ARMS one shot. The next gun shot deals x(1 + bonus) damage and spends the charge.
## `window` (s, optional): the charge fades if unused for that long. params: bonus, hold_ads, window, sources.
## The charge is read on shot_fired (it fires before the per-pellet damage_out modifiers), so a shotgun's pellets all
## count as the one shot.

var armed: bool = false
var live: bool = false ## the shot in flight is the armed one
var charge: float = 0.0
var _armed_at: float = -INF
var empowered: int = 0 ## shots that carried the bonus (tests)


func hooks() -> Array:
	var h: Array = super.hooks().duplicate()
	if not h.has("shot_fired"):
		h.append("shot_fired")
	return h


func has_tick() -> bool:
	return params.has("hold_ads")


func stats() -> Array:
	return ["damage_out"]


func priority() -> int:
	return 10


func wants(ctx: Dictionary) -> bool:
	return str(ctx.get("event", "")) == "shot_fired" or passes(ctx)


func on_event(name: StringName, _ctx: Dictionary) -> void:
	if name == &"shot_fired":
		var fresh := not params.has("window") or now() - _armed_at <= float(p("window", 3.0))
		live = armed and fresh
		if armed:
			armed = false
			charge = 0.0
		if live:
			empowered += 1
		return
	armed = true
	_armed_at = now()


func tick(delta: float) -> void:
	if not params.has("hold_ads") or player == null or not is_instance_valid(player):
		return
	if "ads_active" in player and player.ads_active:
		charge += delta
		if charge >= float(p("hold_ads", 1.0)) and not armed:
			armed = true
			_armed_at = now()
	else:
		charge = 0.0
		if params.has("hold_ads"):
			armed = false


func modify(_stat: String, value: float, ctx: Dictionary) -> float:
	if not live or not (str(ctx.get("source", "gun")) in params.get("sources", ["gun"])):
		return value
	return value * (1.0 + float(p("bonus", 1.0)))
