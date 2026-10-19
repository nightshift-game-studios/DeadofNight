extends SkillEffect
## Area blast on an event (via Explosion.explode, source "skill").
## Damage: damage (flat) | damage_frac x ctx.damage | damage_per_fall_speed x ctx.fall_speed (needs
## min_fall) | grenade_frac x your grenade's damage (and its radius).
## params: radius, knockback, chance, icd, at ("target" | "player"), chain/decay/max_depth (blast kills
## from this effect chain again for decay x the previous blast, up to max_depth links).

var _ready_at: float = -INF


func wants(ctx: Dictionary) -> bool:
	return passes(ctx) or int(ctx.get("chain_owner", 0)) == get_instance_id()


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var dmg := 0.0
	var radius := float(p("radius", 3.0))
	var link := 1
	if int(ctx.get("chain_owner", 0)) == get_instance_id():
		if not params.get("chain", false):
			return
		link = int(ctx.get("chain_depth", 1)) + 1
		if link > int(p("max_depth", 4)):
			return
		dmg = float(ctx.get("chain_damage", 0.0)) * float(p("decay", 0.7))
	else:
		if now() < _ready_at:
			return
		if params.has("chance") and runner.rng.randf() >= float(p("chance", 1.0)):
			return
		if params.has("damage_frac"):
			dmg = float(ctx.get("damage", 0.0)) * float(p("damage_frac", 0.5))
		elif params.has("damage_per_fall_speed"):
			var fs := float(ctx.get("fall_speed", 0.0))
			if fs < float(p("min_fall", 3.5)):
				return
			dmg = fs * float(p("damage_per_fall_speed", 10.0))
		elif params.has("grenade_frac"):
			var gd: Dictionary = player.grenade_data
			dmg = float(gd.get("damage", 200.0)) * float(p("grenade_frac", 0.5))
			radius = float(gd.get("radius", radius))
		else:
			dmg = float(p("damage", 50.0))
		_ready_at = now() + float(p("icd", 0.0))
	if dmg <= 0.0:
		return
	var pos: Vector3
	var t = ctx.get("target")
	if str(params.get("at", "target")) == "target" and t != null and is_instance_valid(t):
		pos = SkillRunner.center_of(t)
	else:
		pos = player.global_position + Vector3(0, 0.6, 0)
	var extra := {"source": "skill", "depth": int(ctx.get("depth", 0)) + 1, "skill": source_id,
		"chain_owner": get_instance_id(), "chain_depth": link, "chain_damage": dmg}
	last_blast = {"damage": dmg, "link": link, "depth": extra.depth}
	blasts += 1
	player.skill_explosion(pos, radius, dmg, float(p("knockback", 4.0)), extra)


var last_blast: Dictionary = {} ## tests / debugging
var blasts: int = 0
