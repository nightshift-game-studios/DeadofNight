class_name StatPreview
extends RefCounted
## Gooey (playtest #34): what the six armor stats actually do, as numbers, for the character screen.
## v070: the numbers come from Skillz's StatEffects.for_player(p, preview) (= player.get_stat_effects(preview),
## STATS_API.md); this file no longer carries its own copy of the formulas. derived() only turns that result into the
## absolute values the tiles show (m/s, seconds, HP/s, dmg), and rows() lays them out per stat with "+1 point" or
## "now -> previewed" deltas.

const StatEffectsScr := preload("res://scripts/combat/stat_effects.gd")


static func _num(p: Object, prop: String, fallback: float) -> float:
	if p == null or not (prop in p):
		return fallback
	var v = p.get(prop)
	return float(v) if v != null else fallback


## Gameplay values for armor-stat totals `st` (agility ... brawn) on player `p` (skills / Field Cards kept), from
## StatEffects.for_player(p, {"totals": st}). p may be null (a bare character).
static func derived(p: Object, st: Dictionary) -> Dictionary:
	var fx: Dictionary = StatEffectsScr.for_player(p, {"totals": st})
	var nx: Dictionary = fx.get("next", fx)
	var live_mv := 1.0 + float(fx.move_speed_pct) / 100.0
	var live_sp := 1.0 + float(fx.sprint_speed_pct) / 100.0
	var out := {}
	out["walk_speed"] = _num(p, "walk_speed", 5.0) / live_mv * (1.0 + float(nx.move_speed_pct) / 100.0)
	out["sprint_speed"] = _num(p, "sprint_speed", 8.0) / live_sp * (1.0 + float(nx.sprint_speed_pct) / 100.0)
	out["move_pct"] = float(nx.move_speed_pct)
	out["damage_reduction"] = float(nx.damage_reduction_pct) / 100.0
	out["damage_taken_pct"] = 100.0 + float(nx.damage_taken_pct)
	out["regen_delay"] = float(nx.regen_delay_s)
	out["regen_rate"] = float(nx.regen_rate_hps)
	out["grenade_cooldown"] = float(nx.grenade_cooldown_s)
	var has_ab: bool = p != null and "ability" in p and p.get("ability") != null
	out["ability_cooldown"] = float(nx.ability_cooldown_s) if has_ab else -1.0
	out["melee_damage"] = float(nx.melee_damage)
	out["melee_cooldown"] = float(nx.melee_cooldown_s)
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
