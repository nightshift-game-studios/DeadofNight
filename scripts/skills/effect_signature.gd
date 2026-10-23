class_name EffectSignature
## Machine-checkable "what does this do" signature for skill nodes, weapon perks / attributes, armor stats and Field
## Cards (Jason playtest #12 line 15: field cards must not duplicate skills). A signature is
##     family | trigger | cond
## family  what changes: "stat:<stat>", "heal", "overshield", "blast", "status:<id>", "refill_mag", ...
## trigger when: "always" (a permanent bump), an event name (or "a+b"), "tick", ...
## cond    sorted "&"-joined gates: the JSON "if" keys, a stat_mod "while", a conditional_damage "cond", plus card
##         wrapper tokens (timed, growing, armed, fleeting, wager, chain) that make a card temporary or situational.
## audit() fails a card when
##   A. one of its signatures equals a skill / perk / attribute / armor-stat signature (same effect, same trigger,
##      same condition),
##   B. it is BROADER than one: same family + trigger and its condition set is a subset of the skill's,
##   C. two cards share a signature, or a card name equals a skill / perk / stat / other card name,
##   D. an effect is a plain permanent bump: trigger "always" with no condition (every card effect needs a trigger,
##      a condition, a duration, a growth rule or a cost).

const NO_SIG := ["unlock_cards", "offer_mod", "offer_weight", "card_fleeting", "card_echo"]
const DEFAULT_TRIGGER := {
	"cheat_death": "lethal_damage", "card_instant": "card_picked", "round_interest": "round_cleared",
	"kill_counter": "enemy_killed", "shot_counter": "shot_fired", "round_growth": "round_cleared",
	"free_shots": "round_started", "aura_zap": "tick", "flawless_round": "round_cleared", "execute": "hit",
	"stacking_damage": "hit", "reflect_damage": "damage_taken",
}
## perk "effect" id (data/perks.json) -> signatures (family|trigger|cond)
const PERK_SIGS := {
	"damage_stack": ["stat:damage_out|enemy_killed|stack"],
	"reload_buff": ["stat:reload_speed|enemy_killed|"],
	"explode": ["blast|hit|chance"],
	"reload_after_kill": ["stat:damage_out|reload_finished|kill_before"],
	"grenade_refund": ["refund_grenade|enemy_killed|"],
	"heal_on_kill": ["heal|enemy_killed|"],
	"crouch_stability": ["stat:spread_mult|always|crouch"],
	"mag_tail_damage": ["stat:damage_out|always|mag_tail"],
	"mag_head_damage": ["stat:damage_out|always|mag_head"],
	"still_damage": ["stat:damage_out|always|still"],
	"moving_damage": ["stat:damage_out|always|moving", "stat:spread_mult|always|moving"],
	"low_health_damage": ["stat:damage_out|always|health_below"],
	"chain_hit": ["arc|hit|chance"],
	"ignite_hit": ["status:burn|hit|chance"],
	"slow_hit": ["status:slow|hit|"],
	"mark_hit": ["status:mark|hit|chance"],
	"kill_refill": ["refill_mag|enemy_killed|"],
	"empty_reload": ["stat:reload_time_mult|always|empty"],
	"ads_stability": ["stat:spread_mult|always|ads"],
}
## armor stat effect key (data/stats.json) -> stat_mod stat it feeds
const ARMOR_STATS := {
	"move_speed": "move_speed", "damage_reduction": "damage_in", "regen_delay_cut": "regen_delay_add",
	"regen_rate_add": "regen_rate_add", "grenade_cooldown_cut": "grenade_cd_mult",
	"ability_cooldown_cut": "ability_cd_mult", "melee_damage": "melee_damage_mult", "melee_cooldown_cut": "melee_cd",
}
const REACTION_ACTIONS := {
	"heal": "heal", "heal_missing": "heal", "points": "points", "overshield": "overshield",
	"grenade_reset": "refund_grenade", "melee_reset": "cooldown:melee", "ability_reset": "cooldown:ability",
	"invuln": "invuln", "blast_damage": "blast",
}
const CHAIN_PAYOUTS := {
	"refill_mag": "refill_mag", "overshield": "overshield", "heal": "heal", "heal_full": "heal",
	"melee_reset": "cooldown:melee", "grenade_reset": "refund_grenade", "drop": "drop_pickup",
}


static func _cond_tokens(iff: Dictionary) -> Array:
	var out: Array = []
	for k in iff:
		var key := str(k).trim_prefix("@")
		var v = iff[k]
		out.append(key if typeof(v) == TYPE_BOOL and v else "%s=%s" % [key, str(v)])
	return out


static func _join(tokens: Array) -> String:
	var t: Array = []
	for x in tokens:
		if str(x) != "" and not t.has(str(x)):
			t.append(str(x))
	t.sort()
	return "&".join(t)


static func _sig(family: String, trigger: String, tokens: Array) -> String:
	return "%s|%s|%s" % [family, trigger, _join(tokens)]


## Signatures of one effect entry {"script","params","on","if"}. `wrap` = card wrapper tokens (fleeting / wager).
static func of_effect(e: Dictionary, wrap: Array = []) -> Array:
	var script := str(e.get("script", ""))
	if script in NO_SIG:
		return []
	var pr: Dictionary = e.get("params", {})
	var on_list: Array = e.get("on", [])
	var on_s := "+".join(on_list.map(func(x): return str(x)))
	var ifs: Array = _cond_tokens(e.get("if", {}))
	var out: Array = []
	match script:
		"stat_mod":
			out.append(_sig("stat:%s" % pr.get("stat", ""), "always", [str(pr.get("while", ""))] + wrap))
		"conditional_damage":
			out.append(_sig("stat:%s" % pr.get("stat", "damage_out"), "always", [str(pr.get("cond", ""))] + ifs + wrap))
		"damage_in_mod":
			out.append(_sig("stat:damage_in", "always", [str(pr.get("cond", ""))] + wrap))
		"force_precision":
			out.append(_sig("stat:force_precision", "always", [str(pr.get("cond", ""))] + wrap))
		"ability_mod", "grenade_mod":
			var fam := "ability" if script == "ability_mod" else "grenade"
			for k in pr:
				if str(k) != "cond":
					out.append(_sig("%s:%s" % [fam, k], on_s if on_s != "" else "always", ifs + wrap))
		"timed_buff":
			out.append(_sig("stat:%s" % pr.get("stat", ""), on_s, ifs + ["timed"]))
		"round_growth":
			out.append(_sig("stat:%s" % pr.get("stat", "damage_out"), "round_cleared", ["growing"] + (["reset"] if pr.has("reset_below") else [])))
		"armed_shot":
			out.append(_sig("stat:damage_out", on_s if on_s != "" else "ads_hold", ifs + ["armed"]))
		"free_shots":
			out.append(_sig("ammo_free", "round_started", ["window"]))
		"aura_zap":
			out.append(_sig("zap_aura", "tick", [str(pr.get("cond", "still"))]))
		"flawless_round":
			out.append(_sig("flawless_round", "round_cleared", ["no_damage"]))
		"execute":
			out.append(_sig("execute", "hit", ifs))
		"reaction":
			for k in REACTION_ACTIONS:
				if pr.has(k):
					var fam: String = REACTION_ACTIONS[k]
					if not out.has(_sig(fam, on_s, ifs)):
						out.append(_sig(fam, on_s, ifs))
			if pr.has("status"):
				out.append(_sig("status:%s" % pr.status, on_s, ifs))
		"kill_chain":
			for k in CHAIN_PAYOUTS:
				if pr.has(k):
					var sg := _sig(CHAIN_PAYOUTS[k], on_s if on_s != "" else "enemy_killed", ifs + ["chain"])
					if not out.has(sg):
						out.append(sg)
		"apply_status":
			out.append(_sig("status:%s" % pr.get("status", ""), on_s, ifs))
		"cooldown_reset":
			out.append(_sig("cooldown:%s" % pr.get("what", ""), on_s, ifs))
		"heal":
			out.append(_sig("heal", on_s if on_s != "" else "always", ifs))
		"grant_overshield":
			out.append(_sig("overshield", on_s, ifs + (["every_n"] if pr.has("every_n_kills") else [])))
		"refund_grenade", "refill_mag", "drop_pickup":
			out.append(_sig(script, on_s, ifs))
		"on_event_explode":
			out.append(_sig("blast", on_s, ifs))
		"on_event_ray":
			out.append(_sig("ray", on_s, ifs))
		"element_arc":
			out.append(_sig("arc", on_s, ifs))
		"element_debuff": ## hard-wired: Blight hits apply Rot, rotters burst on death
			out.append(_sig("status:rot", "hit", ifs + ["element:blight"]))
		"slowmo_trigger":
			out.append(_sig("slowmo", on_s if on_s != "" else str(pr.get("mode", "")), ifs + [str(pr.get("mode", ""))]))
		_:
			var trig: String = on_s if on_s != "" else str(DEFAULT_TRIGGER.get(script, "always"))
			out.append(_sig(script, trig, ifs + wrap))
	return out


## Cards: wrapper tokens come from the card (card_fleeting effect, drawback text).
static func of_card(card: Dictionary) -> Array:
	var wrap: Array = []
	for e in card.get("effects", []):
		if str(e.get("script", "")) == "card_fleeting":
			wrap.append("fleeting")
	if str(card.get("drawback", "")) != "":
		wrap.append("wager")
	var out: Array = []
	for e in card.get("effects", []):
		for s in of_effect(e, wrap):
			out.append({"sig": s, "script": str(e.get("script", ""))})
	return out


static func of_skill_nodes(nodes: Array) -> Dictionary:
	var m := {}
	for n in nodes:
		for e in n.get("effects", []):
			for s in of_effect(e):
				_add(m, s, "skill:%s" % n.get("id", "?"))
	return m


static func of_perks(perks: Array) -> Dictionary:
	var m := {}
	for pk in perks:
		for s in PERK_SIGS.get(str(pk.get("effect", "")), []):
			_add(m, s, "perk:%s" % pk.get("id", "?"))
	return m


static func of_armor_stats(stats: Dictionary) -> Dictionary:
	var m := {}
	for sid in stats:
		for k in stats[sid].get("effects", {}):
			if ARMOR_STATS.has(k):
				_add(m, _sig("stat:%s" % ARMOR_STATS[k], "always", []), "armor:%s" % sid)
	return m


static func _add(m: Dictionary, sig: String, src: String) -> void:
	if not m.has(sig):
		m[sig] = []
	m[sig].append(src)


static func _parts(sig: String) -> PackedStringArray:
	return sig.split("|")


static func _cond_set(c: String) -> Array:
	return [] if c == "" else Array(c.split("&"))


## `refs` = merged skill / perk / armor signature map {sig: [sources]}; `names` = {lowercase name: source}.
## Returns a list of problem strings (empty = every card is distinct and temporary / conditional).
static func audit(cards: Array, refs: Dictionary, names: Dictionary) -> Array:
	var problems: Array = []
	var seen := {} ## card sig -> card id
	var card_names := {}
	for c in cards:
		var id := str(c.get("id", "?"))
		var nm := str(c.get("name", "")).to_lower()
		if names.has(nm):
			problems.append("%s: name '%s' is already %s" % [id, c.get("name", ""), names[nm]])
		if card_names.has(nm):
			problems.append("%s: name '%s' is already card %s" % [id, c.get("name", ""), card_names[nm]])
		card_names[nm] = id
		var sigs: Array = of_card(c)
		if sigs.is_empty() and not (str(c.get("type", "")) in ["echo"]):
			problems.append("%s: no effect signature (no effect?)" % id)
		for s in sigs:
			var sig: String = s.sig
			var pp := _parts(sig)
			if refs.has(sig):
				problems.append("%s: duplicates %s (%s)" % [id, ", ".join(refs[sig]), sig])
			for rs in refs:
				if rs == sig:
					continue
				var rp := _parts(rs)
				if rp[0] == pp[0] and rp[1] == pp[1]:
					var cc := _cond_set(pp[2])
					var rc := _cond_set(rp[2])
					var subset := true
					for t in cc:
						if not rc.has(t):
							subset = false
					if subset:
						problems.append("%s: broader than %s (%s vs %s)" % [id, ", ".join(refs[rs]), sig, rs])
			if seen.has(sig) and seen[sig] != id:
				problems.append("%s: same effect as card %s (%s)" % [id, seen[sig], sig])
			seen[sig] = id
			if pp[1] == "always" and pp[2] == "":
				problems.append("%s: permanent bump, needs a trigger / condition / duration / cost (%s)" % [id, sig])
	return problems
