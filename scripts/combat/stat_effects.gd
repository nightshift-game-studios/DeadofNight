class_name StatEffects
extends RefCounted
## Armor stat -> gameplay numbers (Skillz, Economy v2 / DESIGN §21; data/stats.json; Gooey: /workspace/skillz/STATS_API.md).
##   StatEffects.effects(stats)      -> raw multipliers / adds from armor stats alone (what player.gd applies, MAIN_HOOKS §21b)
##   StatEffects.for_player(player)  -> what is ACTUALLY applied on that player right now (armor + skills + Field Cards),
##                                      measured from the player's live fields; player.get_stat_effects() returns this
##   StatEffects.rows(player, preview := {}) -> display rows [{stat, name, value, value_next, effects: [{key, label,
##                                      value, unit, text, next, text_next}]}]; *_next only when a preview is given
##   StatEffects.preview_stats(stats, preview) -> hypothetical totals. preview = {stat: delta} (e.g. {"agility": 5}),
##                                      or {"totals": {stat: value}} for full hypothetical totals; each clamped 0..100
##   StatEffects.for_player(player, preview := {}) adds "next" (same keys, with the preview applied) + "stats_next"
##   StatEffects.curve(x)            -> 0..1 share of an effect's max at stat x (0..100)

const DATA_PATH := "res://data/stats.json"
const STAT_ORDER := ["agility", "toughness", "vitality", "ordnance", "focus", "brawn"]
## Base numbers player.gd works from (same as its defaults): regen 4 s delay / 6 HP/s, melee 70 dmg / 1.6 s.
const BASE := {"regen_delay": 4.0, "regen_delay_floor": 1.5, "regen_rate": 6.0, "melee_damage": 70.0, "melee_cooldown": 1.6}

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var v = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH)) if FileAccess.file_exists(DATA_PATH) else null
		_data = v if typeof(v) == TYPE_DICTIONARY else {}
	return _data


static func reload(d: Dictionary = {}) -> void:
	_data = d


static func curve(x: float) -> float:
	var f := clampf(x / 100.0, 0.0, 1.0)
	if str(data().get("curve", "ease_out")) == "linear":
		return f
	return 1.0 - pow(1.0 - f, maxf(float(data().get("power", 2.0)), 0.01))


## Effect `key` of `stat` at value v: max x curve(v). 0 if the stat has no such effect.
static func value(stat: String, key: String, v: float) -> float:
	var m := float(data().get("stats", {}).get(stat, {}).get("effects", {}).get(key, 0.0))
	return m * curve(v)


## From armor stat totals alone: {move_mult, damage_reduction, regen_delay_cut, regen_rate_add, grenade_cd_mult,
## ability_cd_mult, melee_damage_mult, melee_cd_mult}. Missing stats count as 0.
static func effects(stats: Dictionary) -> Dictionary:
	var g := func(s): return float(stats.get(s, 0))
	return {
		"move_mult": 1.0 + value("agility", "move_speed", g.call("agility")),
		"damage_reduction": clampf(value("toughness", "damage_reduction", g.call("toughness")), 0.0, 0.9),
		"regen_delay_cut": value("vitality", "regen_delay_cut", g.call("vitality")),
		"regen_rate_add": value("vitality", "regen_rate_add", g.call("vitality")),
		"grenade_cd_mult": maxf(1.0 - value("ordnance", "grenade_cooldown_cut", g.call("ordnance")), 0.1),
		"ability_cd_mult": maxf(1.0 - value("focus", "ability_cooldown_cut", g.call("focus")), 0.1),
		"melee_damage_mult": 1.0 + value("brawn", "melee_damage", g.call("brawn")),
		"melee_cd_mult": maxf(1.0 - value("brawn", "melee_cooldown_cut", g.call("brawn")), 0.1),
	}


static func _f(p: Object, k: String, fb: float) -> float:
	var v = p.get(k) if p and k in p else null
	return float(v) if v != null else fb


## What the player actually has right now, as percentages vs a bare character of the same class (no armor, no skills):
## {move_speed_pct, sprint_speed_pct, crouch_speed_pct, damage_taken_pct (negative = takes less), damage_reduction_pct,
##  regen_delay_s, regen_rate_hps, grenade_cooldown_s, grenade_cooldown_pct, ability_cooldown_s, ability_cooldown_pct,
##  melee_damage, melee_damage_pct, melee_cooldown_s, melee_cooldown_pct, max_health, stats {agility..brawn},
##  from_armor (effects(stats))}. Works on any object with player.gd's fields; missing fields read as the base.
static func preview_stats(stats: Dictionary, preview: Dictionary) -> Dictionary:
	var out := stats.duplicate()
	if preview.has("totals") and typeof(preview.totals) == TYPE_DICTIONARY:
		for k in preview.totals:
			out[str(k)] = clampi(int(preview.totals[k]), 0, 100)
		return out
	for k in preview:
		out[str(k)] = clampi(int(out.get(str(k), 0)) + int(preview[k]), 0, 100)
	return out


## Live numbers re-scaled from the current armor effects to the preview's: skills / Field Cards stay as they are.
static func _next(fx: Dictionary, p: Object, nxt_stats: Dictionary) -> Dictionary:
	var a: Dictionary = fx.from_armor
	var b := effects(nxt_stats)
	var ratio := func(k: String): return float(b[k]) / float(a[k]) if float(a[k]) != 0.0 else 1.0
	var out := fx.duplicate()
	out.erase("from_armor")
	out.erase("stats")
	var mv: float = ratio.call("move_mult")
	for k in ["move_speed_pct", "sprint_speed_pct", "crouch_speed_pct"]:
		out[k] = (1.0 + float(fx[k]) / 100.0) * mv * 100.0 - 100.0 if not (k == "crouch_speed_pct" and _f(p, "_base_crouch", -1.0) <= 0.0) else float(fx[k])
	var dr := clampf(float(fx.damage_reduction_pct) / 100.0 - float(a.damage_reduction) + float(b.damage_reduction), 0.0, 0.9)
	out.damage_reduction_pct = dr * 100.0
	out.damage_taken_pct = -dr * 100.0
	out.regen_delay_s = maxf(float(fx.regen_delay_s) + float(a.regen_delay_cut) - float(b.regen_delay_cut), BASE.regen_delay_floor)
	out.regen_rate_hps = float(fx.regen_rate_hps) - float(a.regen_rate_add) + float(b.regen_rate_add)
	for pair in [["grenade_cooldown", "grenade_cd_mult"], ["ability_cooldown", "ability_cd_mult"], ["melee_cooldown", "melee_cd_mult"]]:
		var r: float = ratio.call(pair[1])
		out[pair[0] + "_s"] = float(fx[pair[0] + "_s"]) * r
		out[pair[0] + "_pct"] = (1.0 + float(fx[pair[0] + "_pct"]) / 100.0) * r * 100.0 - 100.0
	var md: float = ratio.call("melee_damage_mult")
	out.melee_damage = float(fx.melee_damage) * md
	out.melee_damage_pct = (1.0 + float(fx.melee_damage_pct) / 100.0) * md * 100.0 - 100.0
	return out


static func for_player(p: Object, preview: Dictionary = {}) -> Dictionary:
	var fx := _live(p)
	if not preview.is_empty():
		var ns := preview_stats(fx.stats, preview)
		fx["stats_next"] = ns
		fx["next"] = _next(fx, p, ns)
	return fx


static func _live(p: Object) -> Dictionary:
	var stats: Dictionary = p.get("armor_stats") if p and "armor_stats" in p and p.get("armor_stats") != null else {}
	var bw := _f(p, "_base_walk", _f(p, "walk_speed", 5.0))
	var bs := _f(p, "_base_sprint", _f(p, "sprint_speed", 8.5))
	var bc := _f(p, "_base_crouch", -1.0)
	var pct := func(now: float, base: float): return (now / base - 1.0) * 100.0 if base > 0.0 else 0.0
	var gd = p.get("grenade_data") if p and "grenade_data" in p else {}
	var g_base := float(gd.get("cooldown", 20.0)) if typeof(gd) == TYPE_DICTIONARY else 20.0
	var ab = p.get("ability") if p and "ability" in p else null
	var a_base := _f(p, "_ability_base_cd", 0.0)
	var a_now := float(ab.cooldown) if ab != null and "cooldown" in ab else 0.0
	var dr := _f(p, "damage_reduction", 0.0)
	return {
		"move_speed_pct": pct.call(_f(p, "walk_speed", bw), bw),
		"sprint_speed_pct": pct.call(_f(p, "sprint_speed", bs), bs),
		"crouch_speed_pct": pct.call(_f(p, "crouch_speed", bc), bc) if bc > 0.0 else 0.0,
		"damage_reduction_pct": dr * 100.0,
		"damage_taken_pct": -dr * 100.0,
		"regen_delay_s": _f(p, "regen_delay", BASE.regen_delay),
		"regen_rate_hps": _f(p, "regen_rate", BASE.regen_rate),
		"grenade_cooldown_s": _f(p, "grenade_cooldown", g_base),
		"grenade_cooldown_pct": pct.call(_f(p, "grenade_cooldown", g_base), g_base),
		"ability_cooldown_s": a_now,
		"ability_cooldown_pct": pct.call(a_now, a_base) if a_base > 0.0 and a_now > 0.0 else 0.0,
		"melee_damage": _f(p, "melee_damage", BASE.melee_damage),
		"melee_damage_pct": pct.call(_f(p, "melee_damage", BASE.melee_damage), BASE.melee_damage),
		"melee_cooldown_s": _f(p, "melee_cooldown", BASE.melee_cooldown),
		"melee_cooldown_pct": pct.call(_f(p, "melee_cooldown", BASE.melee_cooldown), BASE.melee_cooldown),
		"max_health": int(_f(p, "max_health", 100.0)),
		"stats": stats.duplicate(),
		"from_armor": effects(stats),
	}


## Display rows for Gooey's character screen: one per stat in STAT_ORDER with its live effects.
static func rows(p: Object, preview: Dictionary = {}) -> Array:
	var fx := for_player(p, preview)
	var st: Dictionary = fx.stats
	var nx: Dictionary = fx.get("next", {})
	var defs: Dictionary = data().get("stats", {})
	var e := func(key: String, label: String, v: float, unit: String, fmt: String):
		var row := {"key": key, "label": label, "value": v, "unit": unit, "text": fmt % v}
		if not nx.is_empty():
			row["next"] = float(nx[key])
			row["text_next"] = fmt % float(nx[key])
		return row
	var out := []
	for s in STAT_ORDER:
		var list := []
		match s:
			"agility":
				list.append(e.call("move_speed_pct", "Move speed", fx.move_speed_pct, "%", "%+.0f%%"))
			"toughness":
				list.append(e.call("damage_taken_pct", "Damage taken", fx.damage_taken_pct, "%", "%+.0f%%"))
			"vitality":
				list.append(e.call("regen_delay_s", "Regen starts after", fx.regen_delay_s, "s", "%.1f s"))
				list.append(e.call("regen_rate_hps", "Regen", fx.regen_rate_hps, "HP/s", "%.0f HP/s"))
			"ordnance":
				list.append(e.call("grenade_cooldown_pct", "Grenade cooldown", fx.grenade_cooldown_pct, "%", "%+.0f%%"))
			"focus":
				list.append(e.call("ability_cooldown_pct", "Ability cooldown", fx.ability_cooldown_pct, "%", "%+.0f%%"))
			"brawn":
				list.append(e.call("melee_damage_pct", "Melee damage", fx.melee_damage_pct, "%", "%+.0f%%"))
				list.append(e.call("melee_cooldown_pct", "Melee cooldown", fx.melee_cooldown_pct, "%", "%+.0f%%"))
		var r := {"stat": s, "name": str(defs.get(s, {}).get("name", s.capitalize())), "value": int(st.get(s, 0)), "effects": list}
		if not nx.is_empty():
			r["value_next"] = int(fx.stats_next.get(s, 0))
		out.append(r)
	return out
