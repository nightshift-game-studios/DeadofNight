extends SkillEffect
## Counter Field Card (card type "counter", playtest #13): every `every`th kill (any source) rings a shockwave
## around the player: damage (+ damage_per_round x current round), radius, knockback.

var kills: int = 0
var rung: int = 0


func default_hooks() -> Array:
	return ["enemy_killed"]


func wants(ctx: Dictionary) -> bool:
	return passes(ctx) and str(ctx.get("source", "")) != "skill_counter"


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	kills += 1
	if kills % maxi(int(p("every", 12)), 1) != 0:
		return
	var pl = player
	if pl == null or not is_instance_valid(pl) or not pl.has_method("skill_explosion"):
		return
	var rnd := 1
	var main: Node = pl.get_tree().current_scene if pl.is_inside_tree() else null
	if main and "current_round" in main:
		rnd = maxi(int(main.current_round), 1)
	rung += 1
	pl.skill_explosion(pl.global_position + Vector3(0, 0.5, 0), float(p("radius", 5.0)),
		float(p("damage", 150.0)) + float(p("damage_per_round", 0.0)) * rnd, float(p("knockback", 6.0)),
		{"source": "skill_counter", "depth": 1}, 0.9)
