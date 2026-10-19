extends SkillEffect
## Volt arcs. All element_arc effects add up: the first one in the runner handles the hit using
## targets = sum(targets), frac/range/decay/chain_range = max, chain = max, primary_frac = max.
## Fan: up to `targets` zombies within `range` of the struck zombie take frac x the hit.
## Chain: then hops up to `chain` times (nearest unhit within chain_range), x decay per hop.
## Volt hits only; with primary_frac > 0 Ballistic hits also arc at that strength. Arcs never re-arc.


func default_hooks() -> Array:
	return ["hit"]


func wants(_ctx: Dictionary) -> bool:
	return true


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var mine: Array = runner.effects_of("element_arc")
	if mine.is_empty() or mine[0] != self:
		return
	if int(ctx.get("depth", 0)) > 0 or str(ctx.get("source", "")) in ["arc", "dot", "hazard", "reflect"]:
		return
	var targets := 0
	var chain := 0
	var frac := 0.0
	var rng_r := 0.0
	var decay := 0.0
	var chain_r := 0.0
	var primary := 0.0
	for e in mine:
		targets += int(e.p("targets", 0))
		chain = maxi(chain, int(e.p("chain", 0)))
		frac = maxf(frac, float(e.p("frac", 0.35)))
		rng_r = maxf(rng_r, float(e.p("range", 4.0)))
		decay = maxf(decay, float(e.p("decay", 0.8)))
		chain_r = maxf(chain_r, float(e.p("chain_range", 3.0)))
		primary = maxf(primary, float(e.p("primary_frac", 0.0)))
	var el := str(ctx.get("element", ""))
	var strength := 1.0
	if el == "ballistic" and primary > 0.0:
		strength = primary
	elif el != "volt":
		return
	var t = ctx.get("target")
	if t == null or not is_instance_valid(t):
		return
	var base := float(ctx.get("damage", 0.0)) * frac * strength
	var hit_list: Array = [t]
	var origin := SkillRunner.center_of(t)
	var col := GearDB.element_color("volt")
	var scene: Node = player.get_tree().current_scene
	for i in targets:
		var n: Node = runner.nearest_enemy(origin, rng_r, hit_list)
		if n == null:
			break
		hit_list.append(n)
		Effects.spawn_tracer(scene, origin, SkillRunner.center_of(n), col)
		runner.deal(n, base, "arc", ctx, {"element": "volt"})
	var cur: Node = t
	var dmg := base
	for i in chain:
		var n2: Node = runner.nearest_enemy(SkillRunner.center_of(cur), chain_r, hit_list)
		if n2 == null:
			break
		hit_list.append(n2)
		Effects.spawn_tracer(scene, SkillRunner.center_of(cur), SkillRunner.center_of(n2), col)
		runner.deal(n2, dmg, "arc", ctx, {"element": "volt"})
		cur = n2
		dmg *= decay
