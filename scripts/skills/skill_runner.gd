class_name SkillRunner
extends Node
## Lives on the Player (created in player._ready as "SkillRunner"). Holds one flat effect list =
## owned meta-tree nodes (Progress.skill_ranks, class-gated, and ability-gated: a node with "ability": "<id>" only runs
## while that Q ability is equipped) + this match's Field Cards (RunState.cards) + Armory parts + the equipped class
## item's effect (+ its synergy effects when the paired keystone is owned; DESIGN §23.3).
##  - events: GameEvents.event(name, ctx) -> every effect hooked to `name` whose wants(ctx) is true.
##  - stats:  modify(stat, base, ctx) folds base through every effect answering `stat`
##            (additive priority 0 first, then multiplicative priority 10).
## Re-entrancy guard: ctx.depth (chain explosions, arcs, rays, reflected damage add 1) stops at MAX_DEPTH,
## and a dispatch counter stops runaway synchronous recursion.

const MAX_DEPTH := 4
const MAX_DISPATCH := 24

var player ## the Player (untyped: effects call player-only methods)
var effects: Array = [] ## Array[SkillEffect]
var rng := RandomNumberGenerator.new()
var time: float = 0.0 ## seconds of (scaled, unpaused) game time since the runner started
var _by_event: Dictionary = {} ## StringName -> Array[SkillEffect]
var _by_stat: Dictionary = {} ## String -> Array[SkillEffect] (sorted by priority)
var _tickers: Array = []
var _dispatching: int = 0


func setup(p: Node) -> void:
	player = p
	rng.randomize()
	var bus := get_node_or_null("/root/GameEvents")
	if bus and not bus.event.is_connected(_on_event):
		bus.event.connect(_on_event)
	# §23.3: swapping the class item mid-match swaps its effect (only those effects; the rest keep their state).
	var inv = p.get("inventory") if p else null
	if inv and inv.has_signal("armor_changed") and not inv.armor_changed.is_connected(refresh_class_item):
		inv.armor_changed.connect(refresh_class_item)


func now() -> float:
	return time


func _physics_process(delta: float) -> void:
	time += delta
	for e in _tickers.duplicate():
		e.tick(delta)


## Rebuild from Progress + RunState. Effect state (cooldowns, stacks, once-per-match uses) resets,
## so this runs only from player.apply_stats() (round 0 / new match), never mid-match.
func rebuild() -> void:
	for e in effects:
		e.detach()
	effects.clear()
	var prog := get_node_or_null("/root/Progress")
	if prog:
		for id in prog.all_node_ids():
			var r: int = prog.rank(id)
			if r > 0 and prog.class_active(id) and ability_active_for(prog.get_skill(id)):
				_add_def(prog.get_skill(id), r, id, "meta")
	var rs := get_node_or_null("/root/RunState")
	if rs:
		for id in rs.cards:
			if rs.card_class_ok(id):
				_add_def(rs.card_def(id), int(rs.cards[id]), id, "card")
	_add_armory()
	_add_class_item()
	_index()


## Id of the Q ability the player holds ("" without one / legacy resources).
func ability_id() -> String:
	var a = player.get("ability") if player else null
	return str(a.id) if a is Ability else ""


## Skill node gate: no "ability" field, or it names the equipped Q ability.
func ability_active_for(def: Dictionary) -> bool:
	var need := str(def.get("ability", ""))
	return need == "" or need == ability_id()


## The equipped class item (inventory slot class_item) -> its class effect, rank = rarity + 1, active only when the
## item's class is the class being played; its synergy effects join when the paired keystone is owned.
func _add_class_item() -> void:
	var inv = player.get("inventory") if player else null
	if inv == null:
		return
	var item = inv.equipped.get("class_item") if "equipped" in inv else null
	for d in ClassItems.active_defs(item):
		_add_def(d.def, int(d.rank), str(d.source), "class_item")


## Re-read the equipped class item without touching other effects (Inventory.armor_changed).
func refresh_class_item() -> void:
	var keep: Array = []
	for e in effects:
		if e.source_kind == "class_item":
			e.detach()
		else:
			keep.append(e)
	effects = keep
	_add_class_item()
	_index()


## Armory attachments (data/attachments.json -> effects): one effect per equipped part per archetype, gated by
## weapon_arch (the effect only runs / modifies while that archetype is the weapon in ctx or in hand).
func _add_armory() -> void:
	var A = load("res://scripts/armory/armory.gd")
	if A == null or get_node_or_null("/root/Progress") == null:
		return
	for e in A.effect_defs():
		var eff: SkillEffect = EffectRegistry.make(e.def, 1, "armory:%s@%s" % [e.id, e.arch], "armory")
		if eff == null:
			continue
		eff.weapon_arch = str(e.arch)
		eff.runner = self
		effects.append(eff)
		eff.attach()


## Armory gate: the ctx weapon (or the weapon in hand) must be of the effect's archetype.
func arch_ok(e: SkillEffect, ctx: Dictionary) -> bool:
	if e.weapon_arch == "":
		return true
	var w = ctx.get("weapon")
	if not (w is WeaponItem) and player and player.has_method("current_weapon"):
		w = player.current_weapon()
	return w is WeaponItem and w.archetype == e.weapon_arch


## Attach (or re-rank) one Field Card without touching anything else.
func add_card(id: String) -> void:
	remove_source(id, false)
	var rs := get_node_or_null("/root/RunState")
	if rs and rs.cards.has(id) and rs.card_class_ok(id):
		_add_def(rs.card_def(id), int(rs.cards[id]), id, "card")
	_index()


func remove_source(id: String, reindex: bool = true) -> void:
	for e in effects.filter(func(x): return x.source_id == id):
		e.detach()
		effects.erase(e)
	if reindex:
		_index()


func _add_def(def: Dictionary, r: int, src: String, kind: String) -> void:
	for ed in def.get("effects", []):
		var e: SkillEffect = EffectRegistry.make(ed, r, src, kind)
		if e == null:
			continue
		e.runner = self
		effects.append(e)
		e.attach()


func _index() -> void:
	_by_event.clear()
	_by_stat.clear()
	_tickers.clear()
	for e in effects:
		for h in e.hooks():
			var key := StringName(h)
			if not _by_event.has(key):
				_by_event[key] = []
			_by_event[key].append(e)
		for s in e.stats():
			if not _by_stat.has(s):
				_by_stat[s] = []
			_by_stat[s].append(e)
		if e.has_tick():
			_tickers.append(e)
	for s in _by_stat:
		_by_stat[s].sort_custom(func(a, b): return a.priority() < b.priority())


func modify(stat: String, base: float, ctx: Dictionary = {}) -> float:
	var v := base
	for e in _by_stat.get(stat, []):
		if e.weapon_arch != "" and not arch_ok(e, ctx):
			continue
		v = e.modify(stat, v, ctx)
	return v


func has_stat(stat: String) -> bool:
	return _by_stat.has(stat)


func effects_of(script_id: String) -> Array:
	return effects.filter(func(e): return e.script_id == script_id)


func effects_from(source_id: String) -> Array:
	return effects.filter(func(e): return e.source_id == source_id)


func _on_event(name: StringName, ctx: Dictionary) -> void:
	if not _by_event.has(name):
		return
	if ctx.has("player") and ctx.player != player:
		return
	if int(ctx.get("depth", 0)) > MAX_DEPTH or _dispatching >= MAX_DISPATCH:
		return
	_dispatching += 1
	for e in _by_event[name].duplicate():
		if e.runner == self and (e.weapon_arch == "" or arch_ok(e, ctx)) and e.wants(ctx):
			e.on_event(name, ctx)
	_dispatching -= 1


# ---------------------------------------------------------------- shared conditions

## Named conditions used by conditional_damage, damage_in_mod, force_precision, stat_mod "while".
## ctx keys win (so tests and emitters can state facts); otherwise the live player is asked.
func cond(name: String, ctx: Dictionary, p: Dictionary = {}) -> bool:
	if name == "":
		return true
	var pl = player
	match name:
		"headshot":
			return SkillEffect.truthy(ctx.get("is_headshot"))
		"bodyshot":
			return not SkillEffect.truthy(ctx.get("is_headshot")) and str(ctx.get("source", "gun")) == "gun"
		"last_round":
			return SkillEffect.truthy(ctx.get("last_round"))
		"airborne":
			return SkillEffect.truthy(ctx.get("airborne")) if ctx.has("airborne") else (pl != null and pl.is_airborne())
		"sliding":
			return SkillEffect.truthy(ctx.get("sliding")) if ctx.has("sliding") else (pl != null and pl.is_sliding_recent(0.5))
		"still":
			return SkillEffect.truthy(ctx.get("still")) if ctx.has("still") else (pl != null and pl.is_still(0.5))
		"beyond_falloff":
			return float(ctx.get("distance", 0.0)) > float(ctx.get("falloff_start", INF))
		"has_overshield":
			return pl != null and pl.overshield > 0.0
		"target_marked":
			var t = ctx.get("target")
			return t != null and is_instance_valid(t) and t.has_method("has_status") and t.has_status("mark")
		"target_health_below":
			var t2 = ctx.get("target")
			if t2 == null or not is_instance_valid(t2) or not ("health" in t2):
				return false
			return float(t2.health) / maxf(float(t2.max_health), 1.0) < float(p.get("threshold", 0.25))
		"ads": # aiming down sights (player.ads_active)
			return SkillEffect.truthy(ctx.get("ads")) if ctx.has("ads") else (pl != null and "ads_active" in pl and pl.ads_active)
		"target_unhurt": # Armory suppressors: zombie still at full health
			var t3 = ctx.get("target")
			return t3 != null and is_instance_valid(t3) and "health" in t3 and float(t3.health) >= float(t3.max_health)
		"target_boss": # Gravesight: bosses and elites
			var t4 = ctx.get("target")
			return t4 != null and is_instance_valid(t4) and ((t4.has_meta("is_boss") and t4.get_meta("is_boss")) \
				or (t4.has_meta("elite") and t4.get_meta("elite")))
		"close": # within params.range metres (ctx.distance)
			return ctx.has("distance") and float(ctx.distance) <= float(p.get("range", 6.0))
		"crowded": # at least params.count zombies within params.radius of the player (Heartbeat Counter)
			if ctx.has("crowded"):
				return SkillEffect.truthy(ctx.crowded)
			return pl != null and enemies_near(pl.global_position + Vector3(0, 0.9, 0), float(p.get("radius", 10.0))).size() \
				>= int(p.get("count", 5))
		"ability_active":
			return pl != null and pl.is_ability_active()
		"health_below":
			return pl != null and float(pl.health) / maxf(float(pl.max_health), 1.0) < float(p.get("threshold", 0.5))
		"health_above": # §23: at or above params.threshold of max health
			return pl != null and float(pl.health) / maxf(float(pl.max_health), 1.0) >= float(p.get("threshold", 0.8))
		"target_burning", "target_slowed", "target_branded":
			var ts = ctx.get("target")
			var sid: String = {"target_burning": "burn", "target_slowed": "slow", "target_branded": "brand"}[name]
			return ts != null and is_instance_valid(ts) and ts.has_method("has_status") and ts.has_status(sid)
		"target_close": # §23: target within params.range metres of the player (measured, not ctx.distance)
			var tc = ctx.get("target")
			return pl != null and tc is Node3D and is_instance_valid(tc) and \
				(tc as Node3D).global_position.distance_to(pl.global_position) <= float(p.get("range", 6.0))
		"target_far": # §23: target farther than params.range metres from the player
			var tfar = ctx.get("target")
			return pl != null and tfar is Node3D and is_instance_valid(tfar) and \
				(tfar as Node3D).global_position.distance_to(pl.global_position) > float(p.get("range", 15.0))
		"in_field": # §23: the player stands inside one of their own placed ability objects (banner, stone, candle)
			return pl != null and _in_own_field(pl.global_position)
		"target_in_field":
			var tf = ctx.get("target")
			return pl != null and tf is Node3D and is_instance_valid(tf) and _in_own_field((tf as Node3D).global_position)
		"recent_damage": # the player lost health within params.within seconds (Kill Plating)
			return pl != null and float(pl._since_damage) <= float(p.get("within", 2.0))
		"shield_broke": # damage_taken that emptied the overshield
			return pl != null and float(ctx.get("absorbed", 0.0)) > 0.0 and pl.overshield <= 0.0
		"near_event": # ctx.pos within params.radius metres of the player (Powder Burn)
			return pl != null and ctx.get("pos") is Vector3 and (ctx.pos as Vector3).distance_to(pl.global_position) <= float(p.get("radius", 8.0))
		"ability_source": # §23: the hit / kill came from a class ability
			return str(ctx.get("source", "")) == "ability"
	push_warning("SkillRunner: unknown condition '%s'" % name)
	return false


func _in_own_field(pos: Vector3) -> bool:
	if player == null or not player.is_inside_tree():
		return false
	for f in player.get_tree().get_nodes_in_group("ability_fields"):
		if is_instance_valid(f) and f.get("player") == player and float(f.get("radius")) > 0.0 \
				and Vector2(pos.x - f.global_position.x, pos.z - f.global_position.z).length() <= float(f.radius):
			return true
	return false


# ---------------------------------------------------------------- shared helpers for effects

func enemies_near(pos: Vector3, radius: float, exclude: Array = []) -> Array:
	var out := []
	if player == null or not player.is_inside_tree():
		return out
	for e in player.get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e) or e in exclude:
			continue
		if (e.global_position + Vector3(0, 0.9, 0)).distance_to(pos) <= radius:
			out.append(e)
	return out


func nearest_enemy(pos: Vector3, radius: float, exclude: Array = []) -> Node:
	var best: Node = null
	var best_d := radius
	for e in enemies_near(pos, radius, exclude):
		var d: float = (e.global_position + Vector3(0, 0.9, 0)).distance_to(pos)
		if d <= best_d:
			best = e
			best_d = d
	return best


static func center_of(n: Node) -> Vector3:
	return (n as Node3D).global_position + Vector3(0, 0.9, 0) if n is Node3D else Vector3.ZERO


## Skill-caused damage to one zombie: take_damage + register_hit (so it raises hit / enemy_killed
## events with source `source` and depth parent.depth + 1). Returns true on a kill.
func deal(target: Node, dmg: float, source: String, parent: Dictionary = {}, extra: Dictionary = {}) -> bool:
	if target == null or not is_instance_valid(target) or not target.has_method("take_damage") or dmg <= 0.0:
		return false
	if "_dead" in target and target._dead:
		return false
	var pos := center_of(target)
	var killed: bool = target.take_damage(dmg, pos, false, player)
	var c := {"source": source, "depth": int(parent.get("depth", 0)) + 1, "pos": pos}
	c.merge(extra, true)
	if player and player.has_method("register_hit"):
		player.register_hit(target, dmg, false, killed, c)
	return killed
