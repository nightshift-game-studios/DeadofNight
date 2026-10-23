extends SceneTree
## Field Card dedupe audit (Skillz, Jason playtest #12 line 15): no Field Card may duplicate a skill-tree node,
## weapon perk / attribute or armor stat, and every card effect must be temporary, conditional or paid for.
## Pure data test (no scenes):
##   XDG_DATA_HOME=/tmp/fca_xdg godot --headless --path . -s res://tests/field_card_audit_test.gd   (exit code = failures)
## Signatures: scripts/skills/effect_signature.gd (family | trigger | cond). The negative controls at the bottom seed
## duplicates in memory and require the audit to catch every one of them.

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var rp: Dictionary = _json("res://data/run_picks.json")
	var tree: Dictionary = _json("res://data/skill_tree.json")
	var perks: Dictionary = _json("res://data/perks.json")
	var stats: Dictionary = _json("res://data/stats.json")
	var cards: Array = rp.cards
	var refs := {}
	for m in [EffectSignature.of_skill_nodes(tree.nodes), EffectSignature.of_perks(perks.perks), EffectSignature.of_armor_stats(stats.stats)]:
		for s in m:
			refs[s] = refs.get(s, []) + m[s]
	var names := {}
	for n in tree.nodes:
		names[str(n.name).to_lower()] = "skill node " + str(n.id)
	for pk in perks.perks:
		names[str(pk.name).to_lower()] = "perk " + str(pk.id)
	for sid in stats.stats:
		names[str(stats.stats[sid].name).to_lower()] = "armor stat " + sid
	check(tree.nodes.size() >= 100 and perks.perks.size() >= 22 and refs.size() > 80,
		"reference set: %d skill nodes, %d perks / attributes, %d armor stats -> %d signatures" % [tree.nodes.size(), perks.perks.size(), stats.stats.size(), refs.size()])
	check(cards.size() == 52, "52 field cards audited (%d)" % cards.size())

	# ---- the real pool
	var problems := EffectSignature.audit(cards, refs, names)
	for pr in problems:
		print("      ", pr)
	check(problems.is_empty(), "no field card duplicates a skill / perk / attribute / armor stat, a name, or another card; none is a permanent bump (%d problems)" % problems.size())
	# every effect script resolves and every card has a signature (an echo card ranks up another card)
	var registry: Dictionary = load("res://scripts/skills/effect_registry.gd").SCRIPTS ## loaded at runtime: it needs the GearDB autoload
	var bad := 0
	for c in cards:
		for e in c.effects:
			if not registry.has(str(e.script)):
				bad += 1
		if EffectSignature.of_card(c).is_empty() and str(c.type) != "echo":
			bad += 1
	check(bad == 0, "every card effect script is registered and signed (%d bad)" % bad)
	# the reworked cards really are event / condition driven
	var triggered := 0
	for c in cards:
		for s in EffectSignature.of_card(c):
			if EffectSignature._parts(s.sig)[1] != "always":
				triggered += 1
				break
	check(triggered >= 40, "most cards fire on a trigger, not an always-on bump (%d / %d)" % [triggered, cards.size()])

	# ---- negative controls: each seeded card must be caught
	var tree_stat := _first_effect(tree.nodes, "stat_mod")
	var seeds := {
		"skill stat_mod copied verbatim": _seed("x_dup_skill", "Seed One", [tree_stat.duplicate(true)]),
		"skill conditional_damage copied": _seed("x_dup_cond", "Seed Two", [_first_effect(tree.nodes, "conditional_damage").duplicate(true)]),
		"perk twin (heal on kill)": _seed("x_dup_perk", "Seed Three", [{"script": "heal", "params": {"amount": 3}, "on": ["enemy_killed"]}]),
		"armor-stat twin (permanent move speed)": _seed("x_dup_armor", "Seed Four", [{"script": "stat_mod", "params": {"stat": "move_speed", "add": 0.1}}]),
		"permanent stat bump": _seed("x_perm", "Seed Five", [{"script": "stat_mod", "params": {"stat": "reload_time_mult", "mult": 0.8}}]),
		"name collision with a skill node": _seed("x_name", str(tree.nodes[3].name), [{"script": "reaction", "params": {"heal": 1}, "on": ["round_cleared"]}]),
		"same effect as another card": _seed("x_twin", "Seed Six", cards[0].effects.duplicate(true)),
		"broader than a skill (heal on any kill)": _seed("x_broad", "Seed Seven", [{"script": "heal", "params": {"amount": 4}, "on": ["enemy_killed"], "if": {"source": "melee"}}]),
	}
	for label in seeds:
		var pool: Array = cards.duplicate()
		pool.append(seeds[label])
		var found := EffectSignature.audit(pool, refs, names)
		var mine := found.filter(func(p): return str(p).begins_with(seeds[label].id + ":"))
		check(not mine.is_empty(), "audit catches a seeded duplicate: %s" % label)
	# a clean, distinct, conditional card is NOT flagged (no false positives)
	var clean := _seed("x_clean", "Seed Clean", [{"script": "reaction", "params": {"heal": 5, "icd": 5.0}, "on": ["door_opened"]}])
	var pool2: Array = cards.duplicate()
	pool2.append(clean)
	var found2 := EffectSignature.audit(pool2, refs, names)
	check(found2.filter(func(p): return str(p).begins_with("x_clean:")).is_empty(), "audit accepts a distinct, triggered card")

	print("field_card_audit: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)


func _first_effect(nodes: Array, script: String) -> Dictionary:
	for n in nodes:
		for e in n.get("effects", []):
			if str(e.script) == script and not e.get("params", {}).has("while") and e.get("params", {}).get("stat", "x") != "":
				return e
	return {}


func _seed(id: String, nm: String, effects: Array) -> Dictionary:
	return {"id": id, "name": nm, "type": "passive", "drawback": "", "effects": effects}
