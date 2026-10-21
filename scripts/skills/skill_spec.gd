class_name SkillSpec
extends Node
## Home-menu skill tree API (DESIGN §23.4 / §23.6, docs: /workspace/skillz/SKILLTREE_API.md). Lives at
## /root/Characters/SkillSpec (Characters.spec). Reads and writes Progress (the active character); adds the
## "why not", preview, undo and paid-respec layer on top of Progress.state / buy_rank / respec.
##
## Respec rule:
##  - Undo: any rank picked during this home visit (begin_session .. end_session) can be refunded free, newest
##    first per node, as long as nothing you still own needs it.
##  - Full respec: allowed when Progress.respec_allowed (home, round 0, game over). The character's first full respec
##    is free; after that it costs Scrap = clamp(per_point x points spent, min, max) from skill_tree.json "respec".
##    Until Batch A's Scrap API exists in Progress (scrap_balance / spend_scrap) the cost is waived and
##    respec_cost().currency_available is false.

signal node_changed(id: String, rank: int)
signal tree_changed ## any change: pick, refund, respec, character / class switch, load
signal points_changed(available: int)
signal respec_done(cost: int)
signal pick_refused(id: String, code: String, reason: String)

const STAT_LABELS := {"max_health": "Max health", "max_health_mult": "Max health", "move_speed": "Move speed",
	"reload_time_mult": "Reload time", "fire_rate_mult": "Fire rate", "headshot_mult_add": "Precision multiplier",
	"explosion_damage_mult": "Explosion damage", "grenade_cd_mult": "Grenade cooldown", "ability_cd_mult": "Ability cooldown",
	"overshield_cap": "Overshield cap", "regen_rate_add": "Health regen /s", "melee_damage_mult": "Melee damage",
	"points_kill_mult": "Kill points", "drop_chance_add": "Gear drop chance", "max_wall_jumps_add": "Wall jumps",
	"mag_size_mult": "Magazine size", "jump_mult": "Jump height", "spread_mult": "Spread",
	"ab_banner_radius": "Banner radius (m)", "ab_banner_time": "Banner time (s)", "ab_banner_slow": "Banner slow",
	"ab_banner_cap": "Banner overshield cap", "ab_mark_count": "Chalk Mark targets", "ab_mark_range": "Chalk Mark range (m)",
	"ab_mark_amp": "Chalk Mark damage taken", "ab_bell_tolls": "Bell tolls", "ab_bell_damage": "Toll damage",
	"ab_bell_radius": "Toll radius (m)", "ab_bell_heal": "Heal per zombie tolled", "ab_stone_time": "Headstone time (s)",
	"ab_stone_radius": "Headstone radius (m)", "ab_stone_amp": "Headstone damage taken", "ab_candle_time": "Candle time (s)",
	"ab_candle_count": "Candles at once", "ab_candle_dps": "Candle burn (dps)", "ab_candle_radius": "Candle radius (m)",
	"ab_brand_count": "Ember Brand targets", "ab_brand_dps": "Brand burn (dps)", "ab_brand_burst": "Brand burst damage",
	"ab_brand_time": "Brand time (s)"}

var session_picks: Array = [] ## [id, ...] ranks bought this home visit, in order (undo stack)
var session_open := false


func _prog() -> Node:
	return get_node_or_null("/root/Progress")


func _chars() -> Node:
	return get_node_or_null("/root/Characters")


## Home menu opened (or the skill tree page): picks from now on can be refunded free.
func begin_session() -> void:
	session_picks.clear()
	session_open = true


## Leaving the home menu / switching character or class: picks become permanent.
func end_session() -> void:
	session_picks.clear()
	session_open = false
	tree_changed.emit()


# ---------------------------------------------------------------- reading

func points_available() -> int:
	return _prog().skill_points_available()


func points_spent() -> int:
	return int(_prog().skill_points_spent)


## Every node as a UI row (file order). filter: {"branch": id, "class": id ("" = general only), "ability": id,
## "state": "available"...}. Missing keys don't filter.
func list_nodes(filter: Dictionary = {}) -> Array:
	var out: Array = []
	for id in _prog().all_node_ids():
		var row := node_info(id)
		var ok := true
		for k in filter:
			if str(row.get(k, "")) != str(filter[k]):
				ok = false
		if ok:
			out.append(row)
	return out


## {id, name, branch, class, ability, type, keystone, x, y, rank, max_rank, next_cost, state, active, inactive_reason,
##  excluded_by, excluded_by_name, choice_group, exclusive_with, description, next_description, drawback, requires,
##  requires_any, can_pick, pick_code, pick_reason, refundable}
func node_info(id: String) -> Dictionary:
	var prog := _prog()
	var n: Dictionary = prog.get_skill(id)
	if n.is_empty():
		return {}
	var r: int = prog.rank(id)
	var cp := can_pick(id)
	var ex: String = prog.excluded_by(id)
	return {"id": id, "name": str(n.name), "branch": str(n.branch), "class": str(n.get("class", "")),
		"ability": str(n.get("ability", "")), "type": str(n.type), "keystone": bool(n.keystone), "x": float(n.x), "y": float(n.y),
		"rank": r, "max_rank": int(n.ranks), "next_cost": prog.next_cost(id), "state": prog.state(id),
		"active": inactive_reason(id) == "", "inactive_reason": inactive_reason(id),
		"excluded_by": ex, "excluded_by_name": str(prog.get_skill(ex).get("name", "")) if ex != "" else "",
		"choice_group": str(n.get("choice_group", "")), "exclusive_with": exclusive_with(id),
		"description": prog.format_description(n, maxi(r, 1)), "next_description": prog.format_description(n, mini(r + 1, int(n.ranks))),
		"drawback": prog.format_drawback(n, maxi(r, 1)), "requires": n.get("requires", []).duplicate(),
		"requires_any": n.get("requires_any", []).duplicate(),
		"can_pick": cp.ok, "pick_code": cp.code, "pick_reason": cp.reason, "refundable": can_refund(id).ok}


## Other members of this node's choice group (picking this one locks them until a respec / undo).
func exclusive_with(id: String) -> Array:
	var prog := _prog()
	var g := str(prog.get_skill(id).get("choice_group", ""))
	if g == "":
		return []
	return prog.all_node_ids().filter(func(o): return o != id and str(prog.get_skill(o).get("choice_group", "")) == g)


## Why an owned node does nothing right now ("" = it runs): other class, or a Q-ability path you haven't equipped.
func inactive_reason(id: String) -> String:
	var prog := _prog()
	var n: Dictionary = prog.get_skill(id)
	var c := str(n.get("class", ""))
	if c != "" and c != str(prog.selected_class):
		return "%s only: play %s to use it." % [ClassRoster.template(c).display_name, ClassRoster.template(c).display_name]
	var need := str(n.get("ability", ""))
	if need != "":
		var ch := _chars()
		var have: String = ch.ability_for(c) if ch else ClassRoster.default_ability(c)
		if need != have:
			var a := ClassRoster.find_ability(c, need)
			return "Needs %s as your Q ability." % (a.display_name if a else need)
	return ""


## {ok, code, reason}. Codes: unknown, maxed, locked, excluded, no_points. (Nodes of another class or ability path can
## still be picked; node_info().inactive_reason tells the player they won't run yet.)
func can_pick(id: String) -> Dictionary:
	var prog := _prog()
	var n: Dictionary = prog.get_skill(id)
	if n.is_empty():
		return {"ok": false, "code": "unknown", "reason": "No such skill."}
	var st: String = prog.state(id)
	if st == "maxed":
		return {"ok": false, "code": "maxed", "reason": "Already at max rank."}
	if st == "excluded":
		var ex: String = prog.excluded_by(id)
		var how := " Undo or respec to switch." if not session_picks.has(ex) else " Refund it to switch."
		return {"ok": false, "code": "excluded", "reason": "Locked by %s (pick one).%s" % [prog.get_skill(ex).get("name", ex), how]}
	if st == "locked":
		return {"ok": false, "code": "locked", "reason": _missing_text(id, n)}
	var cost: int = prog.next_cost(id)
	var have: int = prog.skill_points_available()
	if cost > have:
		return {"ok": false, "code": "no_points", "reason": "Needs %d skill point%s (you have %d)." % [cost, "" if cost == 1 else "s", have]}
	return {"ok": true, "code": "", "reason": ""}


func _missing_text(id: String, n: Dictionary) -> String:
	var prog := _prog()
	var miss: Array = []
	for req in n.get("requires", []):
		if not prog._req_ok(req, n):
			var need := int(n.get("requires_rank", {}).get(req, 1))
			miss.append(str(prog.get_skill(req).get("name", req)) + (" rank %d" % need if need > 1 else ""))
	var any_of: Array = n.get("requires_any", [])
	if not any_of.is_empty() and not any_of.any(func(r): return prog._req_ok(r, n)):
		miss.append(" or ".join(any_of.map(func(r): return str(prog.get_skill(r).get("name", r)))))
	return "Needs " + ", ".join(miss) + "." if not miss.is_empty() else "Locked."


# ---------------------------------------------------------------- writing

## Buys the next rank. Returns can_pick()'s dict (+ rank). Emits node_changed / points_changed / tree_changed, or
## pick_refused(id, code, reason).
func pick(id: String) -> Dictionary:
	var cp := can_pick(id)
	if not cp.ok:
		pick_refused.emit(id, cp.code, cp.reason)
		return cp
	var prog := _prog()
	if not prog.buy_rank(id):
		cp = {"ok": false, "code": "refused", "reason": "Couldn't buy that rank."}
		pick_refused.emit(id, cp.code, cp.reason)
		return cp
	session_picks.append(id)
	_after_change(id)
	cp["rank"] = prog.rank(id)
	return cp


## {ok, code, reason}. Codes: not_this_session, needed_by, not_owned.
func can_refund(id: String) -> Dictionary:
	var prog := _prog()
	if prog.rank(id) <= 0:
		return {"ok": false, "code": "not_owned", "reason": "Not owned."}
	if not session_picks.has(id):
		return {"ok": false, "code": "not_this_session", "reason": "Picked on an earlier visit: use Respec."}
	var r: int = prog.rank(id) - 1
	for other in prog.skill_ranks:
		if other == id:
			continue
		var n: Dictionary = prog.get_skill(other)
		var need := int(n.get("requires_rank", {}).get(id, 1))
		var blocks := false
		if id in n.get("requires", []) and r < need:
			blocks = true
		var any_of: Array = n.get("requires_any", [])
		if id in any_of and r < need:
			blocks = not any_of.any(func(o): return o != id and prog._req_ok(o, n))
		if blocks:
			return {"ok": false, "code": "needed_by", "reason": "%s needs it. Refund that first." % n.get("name", other)}
	return {"ok": true, "code": "", "reason": ""}


## Free undo of one rank picked this home visit.
func refund(id: String) -> Dictionary:
	var c := can_refund(id)
	if not c.ok:
		return c
	var prog := _prog()
	var r: int = prog.rank(id) - 1
	if r <= 0:
		prog.skill_ranks.erase(id)
	else:
		prog.skill_ranks[id] = r
	session_picks.remove_at(session_picks.rfind(id))
	prog._recompute_spent()
	prog.save_data()
	_after_change(id)
	return c


## {allowed, reason, amount, currency, free, currency_available, balance, can_afford, points}
func respec_cost() -> Dictionary:
	var prog := _prog()
	var rule: Dictionary = prog.tree.get("respec", {})
	var spent: int = int(prog.skill_points_spent)
	var used: int = int(_chars().respecs_used) if _chars() else 0
	var free: bool = used < int(rule.get("free_full_respecs", 1))
	var amount := 0 if free else clampi(int(rule.get("per_point", 2)) * spent, int(rule.get("min", 10)), int(rule.get("max", 200)))
	var cur_ok := scrap_api_available()
	var bal := scrap_balance() if cur_ok else 0
	var out := {"allowed": true, "reason": "", "amount": amount, "currency": str(rule.get("currency", "scrap")), "free": free,
		"currency_available": cur_ok, "balance": bal, "can_afford": free or not cur_ok or bal >= amount, "points": spent,
		"respecs_used": used}
	if not prog.respec_allowed:
		out.allowed = false
		out.reason = "Respec only at home, before round 1 or after game over."
	elif spent <= 0:
		out.allowed = false
		out.reason = "Nothing to refund."
	elif not out.can_afford:
		out.allowed = false
		out.reason = "Needs %d Scrap (you have %d)." % [amount, bal]
	return out


## Full refund of every point (Progress.respec) after paying respec_cost(). Returns {ok, reason, cost}.
func respec() -> Dictionary:
	var c := respec_cost()
	if not c.allowed:
		return {"ok": false, "reason": c.reason, "cost": 0}
	var paid := 0
	if not c.free and c.currency_available and int(c.amount) > 0:
		if not _prog().spend_scrap(int(c.amount)):
			return {"ok": false, "reason": "Couldn't pay the Scrap.", "cost": 0}
		paid = int(c.amount)
	var ch := _chars()
	if ch:
		ch.respecs_used += 1
	if not _prog().respec():
		return {"ok": false, "reason": "Respec refused.", "cost": 0}
	session_picks.clear()
	respec_done.emit(paid)
	_after_change("")
	return {"ok": true, "reason": "", "cost": paid}


# ---------------------------------------------------------------- Scrap adapter (Batch A)

func scrap_api_available() -> bool:
	var prog := _prog()
	return prog != null and prog.has_method("spend_scrap") and prog.has_method("scrap_balance")


func scrap_balance() -> int:
	return int(_prog().scrap_balance()) if scrap_api_available() else 0


# ---------------------------------------------------------------- preview

## What the next rank of `id` changes: {id, rank_from, rank_to, text_now, text_next, drawback_next, lines:
## [{stat, label, before, after, unit}], other: [non-stat effect descriptions]}. before / after fold every owned,
## class-active, unconditional meta stat_mod for that stat over the class base, so "Max health 100 -> 115".
func preview(id: String) -> Dictionary:
	var prog := _prog()
	var n: Dictionary = prog.get_skill(id)
	if n.is_empty():
		return {}
	var r: int = prog.rank(id)
	var r2: int = mini(r + 1, int(n.ranks))
	var stats: Array = []
	var other := false
	for e in n.get("effects", []):
		if str(e.get("script", "")) == "stat_mod" and str(e.get("params", {}).get("while", "")) == "":
			var s := str(e.params.get("stat", ""))
			if not stats.has(s):
				stats.append(s)
		elif str(e.get("script", "")) != "unlock_cards":
			other = true
	var lines: Array = []
	for s in stats:
		var before := _fold(s, {})
		var after := _fold(s, {id: r2})
		lines.append({"stat": s, "label": STAT_LABELS.get(s, s.capitalize()), "before": before, "after": after,
			"unit": "%" if s.ends_with("_mult") or s in ["move_speed", "drop_chance_add", "ab_mark_amp", "ab_stone_amp", "ab_banner_slow"] else ""})
	return {"id": id, "rank_from": r, "rank_to": r2, "text_now": prog.format_description(n, r) if r > 0 else "",
		"text_next": prog.format_description(n, r2), "drawback_next": prog.format_drawback(n, r2), "lines": lines,
		"other": [prog.format_description(n, r2)] if other else []}


func _base(stat: String) -> float:
	var prog := _prog()
	var cls := ClassRoster.template(str(prog.selected_class))
	match stat:
		"max_health":
			return float(cls.max_health)
	if stat.ends_with("_mult"):
		return 1.0
	if stat.begins_with("ab_"):
		var ch := _chars()
		var a := ClassRoster.find_ability(str(prog.selected_class), ch.ability_for(str(prog.selected_class)) if ch else "")
		if a:
			return float(_ability_base(a, stat.trim_prefix("ab_")))
	return 0.0


## Default value behind an ability tuning key, read from the ability resource's matching property.
static func _ability_base(a: Ability, key: String) -> float:
	var map := {"banner_time": "banner_time", "banner_radius": "radius", "banner_os": "overshield_per_pulse",
		"banner_cap": "overshield_cap", "banner_slow": "slow", "mark_count": "max_targets", "mark_amp": "amp",
		"mark_time": "mark_time", "mark_range": "range_m", "bell_tolls": "tolls", "bell_radius": "radius",
		"bell_damage": "damage", "bell_heal": "heal_per_zombie", "bell_slow": "slow", "stone_time": "stone_time",
		"stone_radius": "radius", "stone_slow": "slow", "stone_amp": "amp", "candle_time": "candle_time",
		"candle_radius": "radius", "candle_dps": "dps", "candle_count": "max_candles", "brand_count": "max_targets",
		"brand_time": "brand_time", "brand_dps": "dps", "brand_burst": "burst"}
	var prop: String = map.get(key, key)
	return float(a.get(prop)) if prop in a else 0.0


## stat folded over the base with owned + overridden ranks (additive first, then multiplicative, like SkillRunner).
func _fold(stat: String, override: Dictionary) -> float:
	var prog := _prog()
	var ranks: Dictionary = prog.skill_ranks.duplicate()
	ranks.merge(override, true)
	var v := _base(stat)
	var mults: Array = []
	for id in ranks:
		var n: Dictionary = prog.get_skill(id)
		if n.is_empty() or inactive_reason_for(n) != "":
			continue
		for e in n.get("effects", []):
			if str(e.get("script", "")) != "stat_mod" or str(e.get("params", {}).get("stat", "")) != stat:
				continue
			if str(e.params.get("while", "")) != "":
				continue
			if e.params.has("add"):
				v += float(prog.rank_value(e.params.add, int(ranks[id])))
			if e.params.has("mult"):
				mults.append(float(prog.rank_value(e.params.mult, int(ranks[id]))))
	for m in mults:
		v *= m
	return snappedf(v, 0.001)


func inactive_reason_for(n: Dictionary) -> String:
	return inactive_reason(str(n.get("id", ""))) if n.has("id") else ""


func _after_change(id: String) -> void:
	var prog := _prog()
	if id != "":
		node_changed.emit(id, prog.rank(id))
	points_changed.emit(prog.skill_points_available())
	tree_changed.emit()
