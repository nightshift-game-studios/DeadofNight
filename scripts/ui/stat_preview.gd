class_name StatPreview
extends RefCounted
## Gooey (playtest #34): what the six armor stats actually do, as numbers, for the character screen.
## derived() mirrors player.gd recalc_stats() (armor part: StatEffects.effects, Skillz §21b) (same constants, same skill mod_stat folds), so the UI
## can show "current -> with these points" without touching the player. tests/stat_preview_test.gd re-runs the real
## recalc_stats() and fails if these drift apart, so a formula change in player.gd shows up as a red test.
## Formula owner: player.gd (Skillz / G4M3N). If Skillz moves stats to spendable points, only the input totals change.

const StatEffectsScr := preload("res://scripts/combat/stat_effects.gd")


static func _mod(p: Object, stat: String, base: float) -> float:
	return float(p.call("mod_stat", stat, base)) if p and p.has_method("mod_stat") else base


static func _num(p: Object, prop: String, fallback: float) -> float:
	if p == null:
		return fallback
	var v = p.get(prop)
	return float(v) if v != null else fallback


## Derived gameplay values for armor-stat totals `st` (agility ... brawn), using `p`'s class bases and skills.
static func derived(p: Object, st: Dictionary) -> Dictionary:
	# Skillz Economy v2 (MAIN_HOOKS §21b): the armor-stat part comes from StatEffects (data/stats.json, ease-out curve),
	# the same call player.gd recalc_stats() makes; the skill mod_stat folds stay here as before.
	var fx: Dictionary = StatEffectsScr.effects(st)
	var move := 1.0 + _mod(p, "move_speed", 0.0)
	var base_walk := _num(p, "_base_walk", 5.0)
	var base_sprint := _num(p, "_base_sprint", 8.0)
	var out := {}
	out["walk_speed"] = base_walk * move * float(fx.move_mult)
	out["sprint_speed"] = base_sprint * move * float(fx.move_mult)
	out["move_pct"] = (float(fx.move_mult) - 1.0) * 100.0 # vs the class base (skills apply on top)
	out["damage_reduction"] = float(fx.damage_reduction)
	out["damage_taken_pct"] = (1.0 - float(fx.damage_reduction)) * 100.0
	out["regen_delay"] = maxf(4.0 - float(fx.regen_delay_cut) + _mod(p, "regen_delay_add", 0.0), 1.5)
	out["regen_rate"] = 6.0 + float(fx.regen_rate_add) + _mod(p, "regen_rate_add", 0.0)
	var gd = p.get("grenade_data") if p else null
	var g_cd := float(gd.get("cooldown", 20.0)) if gd is Dictionary else 20.0
	out["grenade_cooldown"] = g_cd * float(fx.grenade_cd_mult) * _mod(p, "grenade_cd_mult", 1.0)
	var ab = p.get("ability") if p else null
	if ab != null:
		var base_cd := _num(p, "_ability_base_cd", 5.0)
		var cd := (base_cd + _mod(p, "ability_cooldown_add", 0.0)) * maxf(1.0 - _mod(p, "ability_cooldown", 0.0), 0.2)
		out["ability_cooldown"] = maxf(cd * float(fx.ability_cd_mult) * _mod(p, "ability_cd_mult", 1.0), 1.0)
	else:
		out["ability_cooldown"] = -1.0
	out["melee_damage"] = 70.0 * float(fx.melee_damage_mult) * _mod(p, "melee_damage_mult", 1.0)
	out["melee_cooldown"] = 1.6 * float(fx.melee_cd_mult)
	return out


## Display lines per stat: [{label, key, fmt, better_low}] (key into derived()).
const LINES := {
	"agility": [["Move speed", "walk_speed", "%.2f m/s", false], ["Sprint", "sprint_speed", "%.2f m/s", false]],
	"toughness": [["Damage taken", "damage_taken_pct", "%.1f%%", true]],
	"vitality": [["Regen after", "regen_delay", "%.2fs", true], ["Regen", "regen_rate", "%.1f HP/s", false]],
	"ordnance": [["Grenade", "grenade_cooldown", "%.1fs", true]],
	"focus": [["Ability", "ability_cooldown", "%.1fs", true]],
	"brawn": [["Melee", "melee_damage", "%.0f dmg", false], ["Melee cd", "melee_cooldown", "%.2fs", true]],
}


## Rows for the character screen: for each stat, its value now, the value with `preview` totals (or +1 point when
## preview is empty), and each derived line as {label, now, next, delta, better}.
## better: 1 = the change helps, -1 = hurts, 0 = no change.
static func rows(p: Object, st: Dictionary, preview: Dictionary = {}) -> Array:
	var now := derived(p, st)
	var out: Array = []
	for s in ["agility", "toughness", "vitality", "ordnance", "focus", "brawn"]:
		var cur := int(st.get(s, 0))
		var nxt_st := st.duplicate()
		var previewing := not preview.is_empty()
		nxt_st[s] = int(preview.get(s, cur)) if previewing else cur + 1
		var nxt := derived(p, nxt_st if not previewing else _merge(st, preview))
		var lines: Array = []
		for ln in LINES[s]:
			var a := float(now.get(ln[1], 0.0))
			var b := float(nxt.get(ln[1], 0.0))
			if a < 0.0: # no ability
				lines.append({"label": ln[0], "now": "-", "next": "-", "delta": 0.0, "better": 0, "key": ln[1]})
				continue
			var d := b - a
			var better := 0
			if absf(d) > 0.0001:
				better = (1 if d < 0.0 else -1) if ln[3] else (1 if d > 0.0 else -1)
			lines.append({"label": ln[0], "key": ln[1], "now": ln[2] % a, "next": ln[2] % b, "delta": d, "better": better,
				"delta_text": _delta_text(ln[2], d)})
		out.append({"stat": s, "value": cur, "next_value": int(nxt_st[s]) if not previewing else int(preview.get(s, cur)),
			"previewing": previewing, "lines": lines})
	return out


static func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var o := a.duplicate()
	for k in b:
		o[k] = b[k]
	return o


static func _delta_text(fmt: String, d: float) -> String:
	if absf(d) < 0.0001:
		return "±0"
	# number only ("+0.01/pt"; units sit on the value next to it), with enough decimals that small per-point
	# gains never print as "+0" (Focus ≈ -0.015 s, Brawn ≈ +0.4 dmg per point)
	var n := absf(d)
	var num := "%.0f" % n if n >= 10.0 else ("%.1f" % n if n >= 1.0 else ("%.2f" % n if n >= 0.1 else "%.3f" % n))
	if num.contains("."):
		num = num.rstrip("0").rstrip(".")
	var unit := ""
	if fmt.contains("%%"):
		unit = "%"
	elif fmt.split(" ")[0].ends_with("s"):
		unit = "s"
	return ("+" if d > 0.0 else "-") + num + unit
