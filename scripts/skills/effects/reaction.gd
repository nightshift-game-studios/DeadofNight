extends SkillEffect
## Trigger Field Card (card type "trigger", playtest #12 dedupe): an event (JSON "on" + "if", any SkillRunner
## "@cond") fires one small, situational payoff, limited by `per_round` and/or `icd` seconds.
## Actions (any mix, rank arrays ok):
##   heal (HP), points (flat), heal_missing (fraction of missing HP), overshield (+ cap), grenade_reset, melee_reset,
##   ability_reset, invuln (s),
##   blast_damage + blast_radius + blast_knockback + blast_at ("player" | "pos" | "target")  area blast (source "skill"),
##   status ("slow" | "burn" | "mark" ...) + status_dur / status_amp / status_dps / status_radius / status_at
##   (every zombie in the radius around the player, ctx.pos or ctx.target).
## Healing never undoes a lethal hit: nothing fires while health is 0.

var _ready_at: float = -INF
var _round_uses: int = 0
var fired: int = 0 ## tests / HUD
var last_blast: Dictionary = {}


func hooks() -> Array:
	var h: Array = super.hooks().duplicate()
	if int(params.get("per_round", 0)) > 0 and not h.has("round_started"):
		h.append("round_started") ## resets the per-round allowance
	return h


func wants(ctx: Dictionary) -> bool:
	if str(ctx.get("event", "")) == "round_started" and int(params.get("per_round", 0)) > 0:
		return true
	return passes(ctx)


func round_uses() -> int:
	return _round_uses


func on_event(name: StringName, ctx: Dictionary) -> void:
	if name == &"round_started":
		_round_uses = 0
		if not on.has("round_started"):
			return
		if not passes(ctx):
			return
	var pl = player
	if pl == null or not is_instance_valid(pl) or pl.health <= 0 or pl.dead:
		return
	if now() < _ready_at:
		return
	var cap := int(params.get("per_round", 0))
	if cap > 0 and _round_uses >= int(p("per_round", 1)):
		return
	_ready_at = now() + float(p("icd", 0.0))
	_round_uses += 1
	fired += 1
	_act(pl, ctx)


func _origin(pl, ctx: Dictionary, at: String) -> Vector3:
	var t = ctx.get("target")
	if at == "target" and t is Node3D and is_instance_valid(t):
		return SkillRunner.center_of(t)
	if at == "pos" and ctx.get("pos") is Vector3:
		return ctx.pos
	return pl.global_position + Vector3(0, 0.6, 0)


func _act(pl, ctx: Dictionary) -> void:
	if params.has("heal"):
		pl.heal(int(p("heal", 0)))
	if params.has("points"):
		pl.add_points(int(p("points", 0)), "card")
	if params.has("heal_missing"):
		var missing: int = int(pl.max_health) - int(pl.health)
		pl.heal(int(ceil(float(missing) * float(p("heal_missing", 0.5)))))
	if params.has("overshield"):
		pl.grant_overshield(float(p("overshield", 0.0)), float(p("cap", -1.0)))
	if params.get("grenade_reset", false):
		pl.reset_cooldown("grenade")
	if params.get("melee_reset", false):
		pl.reset_cooldown("melee")
	if params.get("ability_reset", false):
		pl.reset_cooldown("ability")
	if params.has("invuln"):
		pl.invulnerable_t = maxf(pl.invulnerable_t, float(p("invuln", 1.0)))
	if params.has("blast_damage"):
		var pos := _origin(pl, ctx, str(params.get("blast_at", "player")))
		var dmg := float(p("blast_damage", 50.0))
		last_blast = {"damage": dmg, "pos": pos}
		pl.skill_explosion(pos, float(p("blast_radius", 4.0)), dmg, float(p("blast_knockback", 5.0)),
			{"source": "skill", "depth": int(ctx.get("depth", 0)) + 1, "skill": source_id}, 0.8)
	if params.has("status"):
		var spos := _origin(pl, ctx, str(params.get("status_at", "player")))
		var st := {"dur": float(p("status_dur", 3.0)), "amp": float(p("status_amp", 0.0)),
			"dps": float(p("status_dps", 0.0)), "source": pl}
		for e in runner.enemies_near(spos, float(p("status_radius", 5.0))):
			if e.has_method("apply_status"):
				e.apply_status(str(params.get("status")), st.duplicate())
