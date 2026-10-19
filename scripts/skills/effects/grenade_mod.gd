extends SkillEffect
## Grenade tweaks: charges (+N, stat "grenade_charges_add"), cd_mult (stat "grenade_cd_mult"),
## cluster (on grenade_detonated: N bomblets around the blast, cluster_frac x damage, cluster_radius).

var bomblets: int = 0


func stats() -> Array:
	var s := []
	if params.has("charges"):
		s.append("grenade_charges_add")
	if params.has("cd_mult"):
		s.append("grenade_cd_mult")
	return s


func priority() -> int:
	return 10


func modify(stat: String, value: float, _ctx: Dictionary) -> float:
	if stat == "grenade_charges_add":
		return value + float(p("charges", 0))
	if stat == "grenade_cd_mult":
		return value * float(p("cd_mult", 1.0))
	return value


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var n := int(p("cluster", 0))
	if n <= 0:
		return
	var data: Dictionary = ctx.get("data", player.grenade_data)
	var pos: Vector3 = ctx.get("pos", player.global_position)
	for i in n:
		var a: float = TAU * (float(i) / n) + runner.rng.randf_range(-0.4, 0.4)
		var off: Vector3 = Vector3(cos(a), 0, sin(a)) * runner.rng.randf_range(1.5, 2.5)
		bomblets += 1
		player.skill_explosion(pos + off, float(p("cluster_radius", 2.5)), float(data.get("damage", 200.0)) * float(p("cluster_frac", 0.4)),
			3.0, {"source": "grenade", "depth": int(ctx.get("depth", 0)) + 1, "skill": source_id, "bomblet": true}, 0.5)
