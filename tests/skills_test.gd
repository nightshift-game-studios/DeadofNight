extends SceneTree
## Headless skills test:  godot --headless --path . -s res://tests/skills_test.gd
## Meta tree v2 (Progress), Field Cards (RunState), every effect script, every node and card,
## economy formulas, refund cap, time-scale flag on/off, v1 migration, exclusivity, respec, round flow.
## Exit code = number of failures. Uses its own save file, never the real one.

var _fails := 0
var _passes := 0
var main
var player
var runner
var prog
var rs
var bus
var _rank_signal: Array = []
var _closed: Array = []


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _truthy(v) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
	return str(v) != ""


func near(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


# ---------------------------------------------------------------- helpers

## Fresh state: meta ranks, no Field Cards, full health, no zombies, flag off.
## §23: pick the Q ability the next reset() loads for `cls` (memory only; "" clears every pick back to defaults).
func _equip_ability(cls: String, ability_id: String) -> void:
	var ch := root.get_node_or_null("Characters")
	if ch == null: # autoload line not in project.godot yet: an unbound instance still answers ability_for()
		ch = load("res://scripts/autoload/characters.gd").new()
		ch.name = "Characters"
		root.add_child(ch)
	if cls == "" or ability_id == "":
		ch.abilities.clear()
	else:
		ch.abilities[cls] = ability_id
	player.ability = null # apply_stats re-duplicates from the class


func reset(meta: Dictionary = {}, cards: Array = [], cls: String = "soldier") -> void:
	ProjectSettings.set_setting("skills/allow_time_scale", false)
	if rs.offer_open:
		rs.skip()
	for z in main.zombies_root.get_children():
		z.queue_free()
	await wait(2)
	rs.clear()
	# §23: the starter class item now carries a class effect; numbers here assume none (classes_test covers them)
	var ci = player.inventory.equipped.get("class_item")
	if ci and "class_effect" in ci:
		ci.class_effect = ""
	prog.respec_allowed = true
	prog.skill_ranks = meta.duplicate()
	prog._recompute_spent()
	if prog.selected_class != cls:
		prog.selected_class = cls
	player.player_class = prog.load_selected_class()
	player.apply_stats()
	rs.refresh_allowances()
	for c in cards:
		rs.add_card(c)
	player.health = player.max_health
	player.dead = false
	player.overshield = 0.0
	player.invulnerable_t = 0.0
	player.damage_reduction = 0.0
	player._grenade_cd = 0.0
	player._refund_log.clear()
	player._melee_cd = 0.0
	player.points = 0
	player.velocity = Vector3.ZERO
	Engine.time_scale = 1.0


func zombie(offset: Vector3, hp: int = 100000) -> Node:
	var z = main.ZOMBIE_SCENE.instantiate()
	z.setup(hp, 0.0, 0)
	main.zombies_root.add_child(z)
	z.global_position = player.global_position + offset
	return z


## A gun hit through the same pipeline player._fire_round uses (damage_out modifiers, register_hit).
func hit(z: Node, dmg: float, extra: Dictionary = {}) -> Dictionary:
	var w = player.current_weapon()
	var ctx: Dictionary = player.hit_ctx({"source": "gun", "weapon": w, "target": z, "element": "ballistic",
		"pos": runner.center_of(z), "is_headshot": false})
	ctx.merge(extra, true)
	var head := _truthy(ctx.get("is_headshot"))
	var d: float = player.mod_stat("damage_out", dmg, ctx)
	var killed: bool = z.take_damage(d, runner.center_of(z), head, player)
	player.register_hit(z, d, head, killed, ctx)
	return {"damage": d, "killed": killed}


func eff(script_id: String):
	var l: Array = runner.effects_of(script_id)
	return l[0] if not l.is_empty() else null


# ---------------------------------------------------------------- run

func _run() -> void:
	prog = root.get_node("Progress")
	rs = root.get_node("RunState")
	bus = root.get_node("GameEvents")
	prog.save_path = "user://progress_skills_test.cfg"
	prog.reset_skills()
	prog.xp = 0
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	main = current_scene
	main._break_timer = 99999.0
	player = main.get_node("Player")
	player.input_enabled = false
	runner = player.skill_runner
	await wait(30) # settle on the floor
	prog.rank_changed.connect(func(id, r): _rank_signal.append([id, r]))
	rs.offer_closed.connect(func(res, id): _closed.append([res, id]))

	_data_checks()
	await _progress_checks()
	await _runstate_checks()
	await _effect_checks()
	await _card_checks()
	await _card_type_checks()
	await _refund_cap_checks()
	await _time_scale_checks()
	await _flow_checks()

	await reset({})
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	print("SKILLS TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


# ---------------------------------------------------------------- data / schema

func _data_checks() -> void:
	var t: Dictionary = prog.tree
	check(int(t.get("version", 0)) == 2 and t.has("grid"), "skill_tree.json is v2 with a grid")
	check(prog.all_node_ids().size() == 110 and prog.branches().size() == 9, "110 nodes in 9 branches (%d / %d)" % [prog.all_node_ids().size(), prog.branches().size()])
	var schema_ok := true
	var text_ok := true
	var draw_ok := true
	for id in prog.all_node_ids():
		var n: Dictionary = prog.get_skill(id)
		for k in ["icon", "type", "description", "values", "x", "y", "requires", "requires_any", "choice_group", "class", "ranks", "cost"]:
			if not n.has(k):
				schema_ok = false
				print("  missing ", k, " on ", id)
		if float(n.x) < 0.0 or float(n.y) < 0.0 or n.cost.size() != int(n.ranks) or (n.type == "keystone") != bool(n.keystone):
			schema_ok = false
		for r in range(1, int(n.ranks) + 1):
			if "{" in prog.format_description(n, r) or "{" in prog.format_drawback(n, r):
				text_ok = false
				print("  unfilled placeholder in ", id)
		if n.type == "keystone" and str(n.get("drawback", "")) == "":
			draw_ok = false
	check(schema_ok, "every node has icon/type/template/values/grid fields, costs per rank, keystone bool matches type")
	check(text_ok, "every node description/drawback template fills at every rank")
	check(draw_ok, "every keystone has a drawback")
	var bschema := true
	for b in prog.branches():
		for k in ["id", "name", "accent", "color", "x"]:
			if not b.has(k):
				bschema = false
	check(bschema, "branches carry id/name/accent/color/x")
	# branches at least one grid column apart within each row
	var rows := {}
	for id in prog.all_node_ids():
		var n: Dictionary = prog.get_skill(id)
		var y := int(n.y)
		if not rows.has(y):
			rows[y] = {}
		var span: Array = rows[y].get(n.branch, [INF, -INF])
		rows[y][n.branch] = [minf(span[0], float(n.x)), maxf(span[1], float(n.x))]
	var spacing_ok := true
	for y in rows:
		var spans: Array = rows[y].values()
		spans.sort_custom(func(a, b): return a[0] < b[0])
		for i in range(1, spans.size()):
			if spans[i][0] - spans[i - 1][1] < 1.0:
				spacing_ok = false
				print("  row ", y, " branches closer than 1 column")
	check(spacing_ok, "branches >= 1 grid column apart in every row")
	var normal := 0
	var leg := 0
	for id in rs.card_ids():
		if id == rs.CACHE_ID:
			continue
		if rs.card_def(id).tier == "legendary":
			leg += 1
		else:
			normal += 1
	check(normal == 32 and leg == 20, "run_picks.json: 32 normal + 20 legendary cards (%d + %d)" % [normal, leg])
	var names := {}
	var dup := false
	for id in prog.all_node_ids():
		dup = dup or names.has(prog.get_skill(id).name)
		names[prog.get_skill(id).name] = true
	for id in rs.card_ids():
		dup = dup or names.has(rs.card_def(id).name)
		names[rs.card_def(id).name] = true
	check(not dup, "all node and card names unique")
	check(not ProjectSettings.get_setting("skills/allow_time_scale", true), "skills/allow_time_scale defaults to false")


# ---------------------------------------------------------------- Progress v2

func _progress_checks() -> void:
	await reset({})
	var api_ok := true
	for m in ["rank", "next_cost", "state", "excluded_by", "class_active", "can_afford", "buy_rank", "respec", "skill_points_available"]:
		api_ok = api_ok and prog.has_method(m)
	check(api_ok and prog.has_signal("rank_changed"), "Progress API names + rank_changed signal")
	var gone: bool = not ("skill_tree" in prog) and not ("unlocked_skills" in prog)
	for m in ["node_rank", "skill_rank", "skill_max", "skill_state", "unlock_skill", "get_skill_bonus", "is_unlocked", "choice_taken_by", "is_class_active", "_rebuild_view"]:
		gone = gone and not prog.has_method(m)
	check(gone, "v1 Progress shims removed (skill_tree view, unlock_skill, skill_state, ...)")
	check(not FileAccess.file_exists("res://scripts/skills/temp_run_pick_chooser.gd"), "TEMP Field Card chooser deleted (run_pick_menu.gd is the chooser)")
	prog.xp = 0
	check(prog.state("mk_root") == "available" and not prog.can_afford("mk_root"), "state is structural: available but unaffordable with 0 points")
	check(not prog.buy_rank("mk_root"), "buy_rank fails without points")
	prog.xp = prog.xp_for_level(41) # Economy v2: XP curve (data/skill_tree.json -> xp_curve)
	check(prog.get_level() == 41 and prog.skill_points_earned() == 40, "display level derived from skill points (%d)" % prog.get_level())
	check(prog.state("mk_aim") == "locked", "mk_aim locked before mk_root")
	_rank_signal.clear()
	check(prog.buy_rank("mk_root") and prog.rank("mk_root") == 1, "buy_rank mk_root")
	check(_rank_signal == [["mk_root", 1]], "rank_changed(id, new_rank) emitted")
	check(prog.state("mk_root") == "maxed" and not prog.can_afford("mk_root"), "1-rank node maxed, nothing left to afford")
	check(prog.state("mk_aim") == "available", "mk_aim available after mk_root")
	prog.buy_rank("mk_aim")
	check(prog.state("mk_aim") == "owned" and prog.next_cost("mk_aim") == 1, "multi-rank node 'owned' at 1/3")
	prog.buy_rank("mk_aim")
	prog.buy_rank("mk_aim")
	check(prog.state("mk_aim") == "maxed" and prog.next_cost("mk_aim") == 0 and not prog.buy_rank("mk_aim"), "mk_aim maxed at 3, next_cost 0")
	# choice exclusivity
	check(prog.buy_rank("mk_spotter"), "buy choice A (mk_spotter)")
	check(prog.state("mk_longcount") == "excluded" and prog.excluded_by("mk_longcount") == "mk_spotter" and not prog.buy_rank("mk_longcount"),
		"choice B excluded by choice A")
	# requires_any
	check(prog.state("mk_legend") == "available", "capstone opens via requires_any")
	prog.buy_rank("mk_legend")
	check(prog.buy_rank("mk_key"), "keystone Glass Sight bought")
	# §24: every main tree keeps its own keystone (no exclusivity across main trees any more)
	prog.skill_ranks.merge({"sp_root": 1, "sp_powder": 1, "sp_volt_coil": 1, "sp_legend": 1})
	prog._recompute_spent()
	check(prog.state("sp_key") == "available" and prog.excluded_by("sp_key") == "",
		"§24: sp_key stays open next to mk_key (one keystone per main tree)")
	# requires_rank
	prog.skill_ranks.merge({"lg_spare": 1, "lg_lucky": 1})
	prog._recompute_spent()
	check(prog.state("lg_gilded") == "locked", "lg_gilded locked with Lucky Find I (requires_rank 2)")
	check(prog.buy_rank("lg_lucky") and prog.state("lg_gilded") == "available", "lg_gilded available with Lucky Find II")
	# class gating
	check(prog.class_active("so_ram") and not prog.class_active("sc_fed"), "class gating: Soldier nodes active, Scout inactive")
	prog.skill_ranks["sc_ghost"] = 1
	runner.rebuild()
	check(runner.effects_from("sc_ghost").is_empty(), "inactive class node contributes no effects")
	prog.skill_ranks.erase("sc_ghost")
	check(prog.branches().size() == 9 and prog.all_node_ids().size() == 110, "v2 data: 9 branches, 110 nodes via branches()/all_node_ids()")
	# respec
	var earned: int = prog.skill_points_earned()
	prog.respec_allowed = false
	check(not prog.respec() and prog.rank("mk_root") == 1, "respec refused mid-match")
	prog.respec_allowed = true
	check(prog.respec() and prog.skill_ranks.is_empty() and prog.skill_points_available() == earned, "respec at round 0 / game over: free full refund")
	# v1 save migration
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "xp", 750)
	cfg.set_value("skills", "unlocked", ["mk_root", "tough_1", "speed_1", "sv_root"])
	cfg.save(prog.save_path)
	prog.load_data()
	check(prog.skill_ranks == {"mk_root": 1, "sv_root": 1}, "v1 save migrates: existing ids rank 1, removed ids dropped (%s)" % str(prog.skill_ranks))
	check(prog.skill_points_spent == 2 and prog.skill_points_available() == 1, "migrated save refunds dropped nodes (spent %d, free %d)" % [prog.skill_points_spent, prog.skill_points_available()])
	prog.save_data()
	var c2 := ConfigFile.new()
	c2.load(prog.save_path)
	check(int(c2.get_value("skills", "version", 0)) == 2 and c2.get_value("skills", "ranks", {}) == {"mk_root": 1, "sv_root": 1}, "migrated save written as v2")
	check(prog.migrate_ranks({"mk_aim": 9, "nope": 1}, []) == {"mk_aim": 3}, "v2 ranks clamp to max and drop unknown ids")
	prog.xp = 0
	prog.reset_skills()


# ---------------------------------------------------------------- RunState / offers

func _runstate_checks() -> void:
	await reset({})
	check(rs.reroll_cost_for(1, 0, false) == 50 and rs.reroll_cost_for(1, 1, false) == 100 and rs.reroll_cost_for(1, 2, false) == 200,
		"reroll cost r1: 50 -> 100 -> 200")
	check(rs.reroll_cost_for(10, 0, false) == 500 and rs.reroll_cost_for(10, 1, false) == 1000, "reroll cost r10: 500 -> 1000")
	check(rs.reroll_cost_for(5, 0, true) == 500 and rs.reroll_cost_for(5, 1, true) == 1000 and rs.reroll_cost_for(10, 0, true) == 1000,
		"milestone reroll cost: r5 500 -> 1000, r10 1000")
	# milestones
	var e5: Array = rs.open_offer(5)
	var leg5 := e5.filter(func(x): return x.tier == "legendary").size()
	check(rs.offer_is_milestone and leg5 == 2 and e5.size() == 3, "round 5 milestone: 2 legendaries in 3 (%d)" % leg5)
	rs.skip()
	var e10: Array = rs.open_offer(10)
	check(rs.offer_is_milestone and e10.filter(func(x): return x.tier == "legendary").size() == 2, "round 10 milestone: 2 legendaries")
	rs.skip()
	var e4: Array = rs.open_offer(4)
	check(not rs.offer_is_milestone and e4.filter(func(x): return x.tier == "legendary").is_empty(), "round 4: normal offer, no legendaries")
	rs.skip()
	# offer entry shape
	var ent: Dictionary = rs.open_offer(1)[0]
	var shape := true
	for k in ["id", "name", "tier", "branch", "type", "icon", "ranks", "rank_now", "rank_next", "summary", "description", "drawback", "synergy", "is_cache"]:
		shape = shape and ent.has(k)
	check(shape and not "{" in str(ent.description), "offer entry dict has the documented keys, formatted text")
	var sums_ok := true
	for cid in rs.card_ids():
		var sm := str(rs.card_def(cid).get("summary", ""))
		sums_ok = sums_ok and sm != "" and sm.length() <= 60 and not "{" in sm
	var rp: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/run_picks.json"))
	for c in rp.cards:
		sums_ok = sums_ok and str(c.get("summary", "")) != "" and str(c.summary).length() <= 60
	check(sums_ok and rp.cards.size() == 52 and str(rp.cache_card.get("summary", "")) != "", "every Field Card (52 + Supply Cache) has a short summary one-liner")
	check(int(rp.offer.skip_points_per_round) == 25 and int(rp.offer.cache_points_per_round) == 25 and rs.cache_points() == 25 * maxi(rs.offer_round, 1),
		"Economy v2 card economy: skip and Supply Cache pay 25 x round (was 50)")
	# reroll economy
	player.points = 1000
	check(rs.reroll_cost() == 50 and rs.reroll() and player.points == 950, "paid reroll r1 costs 50 points")
	check(rs.reroll_cost() == 100 and rs.reroll() and player.points == 850, "second reroll costs 100")
	player.points = 10
	check(not rs.can_reroll() and not rs.reroll(), "reroll refused without points")
	# skip
	_closed.clear()
	var pts: int = player.points
	check(rs.skip() == 25 and player.points == pts + 25 and _closed == [["skipped", ""]], "skip pays 25 x round (Economy v2) and closes")
	# choose
	rs.open_offer(2)
	var pick: String = rs.offer[0]
	bus.record = true
	bus.history.clear()
	_closed.clear()
	check(rs.choose(pick) and rs.card_rank(pick) == 1 and _closed == [["chosen", pick]], "choose adds the card at rank 1 and closes")
	check(bus.events_named(&"card_picked").size() == 1, "GameEvents card_picked emitted")
	bus.record = false
	check(rs.owned_cards().size() == 1 and rs.owned_cards()[0].id == pick, "owned_cards() lists the pick")
	# free rerolls first (Spare Coin)
	await reset({"lg_spare": 1})
	check(rs.free_rerolls == 1, "Spare Coin I: 1 free reroll")
	rs.open_offer(3)
	player.points = 0
	check(rs.reroll_cost() == 0 and rs.reroll() and rs.free_rerolls == 0, "free reroll used first (no points)")
	check(rs.reroll_cost() == 150, "then paid rerolls start at 50 x n (r3: 150)")
	rs.skip()
	# banish
	await reset({"lg_spare": 1, "lg_wide": 1, "lg_black": 1})
	check(rs.offer_size() == 4 and rs.banishes_left == 3, "Wider Spread: 4 cards; Black Ledger: 3 banishes")
	rs.open_offer(2)
	var b0: String = rs.offer[0]
	check(rs.banish(b0) and not (b0 in rs.offer) and rs.offer.size() == 4 and rs.banishes_left == 2, "banish removes the card and redraws the slot")
	check(not rs.eligible(b0), "banished card never offered again this match")
	check(not rs.banish(rs.offer[1]), "only 1 banish per offer")
	rs.skip()
	# eligibility
	await reset({})
	check(not rs.eligible("m_caromshot") and rs.eligible("c_deep_pockets"), "branch cards locked without their branch root")
	await reset({"mk_root": 1})
	check(rs.eligible("m_caromshot") and not rs.eligible("L_skullburst"), "mk_root unlocks Marksman normal cards, not legendaries")
	for i in 3:
		rs.add_card("c_deep_pockets")
	check(rs.card_rank("c_deep_pockets") == 3 and not rs.eligible("c_deep_pockets"), "maxed cards leave the pool")
	await reset({"so_ram": 1, "so_twin": 1, "so_breacher": 1})
	check(rs.eligible("L_breakline") and not rs.eligible("L_redline"), "class legendary: Soldier gets Breakline, not Redline")
	# Gilded Ledger
	await reset({"lg_spare": 1, "lg_lucky": 2, "lg_gilded": 1, "mk_root": 1, "mk_aim": 1, "mk_spotter": 1, "mk_legend": 1})
	var g5: Array = rs.open_offer(5)
	check(g5.filter(func(x): return x.tier == "legendary").size() == 3, "Gilded Ledger: milestone offers all legendary")
	rs.skip()
	# synergy weight
	check(near(rs.weight("m_caromshot"), 10.0 * 1.5 * 1.5), "offer weight: synergy x1.5 (choice owned) x Hall of Marks x1.5 (%.1f)" % rs.weight("m_caromshot"))
	# match lifecycle
	rs.add_card("c_bounty")
	rs.clear()
	check(rs.cards.is_empty() and Engine.time_scale == 1.0, "RunState.clear() wipes cards and time scale")


# ---------------------------------------------------------------- effect scripts (one+ check each)

func _effect_checks() -> void:
	await reset({})
	var base_hp: int = player.max_health
	var w = player.current_weapon()

	# stat_mod
	await reset({"sv_root": 1, "sv_skin": 1})
	check(player.max_health == base_hp + 10, "stat_mod: Thick Skin I +10 max health (%d)" % player.max_health)
	await reset({"sv_root": 1, "sv_skin": 3})
	check(player.max_health == base_hp + 30, "stat_mod: Thick Skin III +30 max health")

	# conditional_damage (Glass Sight)
	await reset({"mk_key": 1})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun", "is_headshot": true}), 150.0)
		and near(player.mod_stat("damage_out", 100.0, {"source": "gun", "is_headshot": false}), 70.0),
		"conditional_damage: Glass Sight precision x1.5, body x0.7")

	# stacking_damage (Steady Cadence)
	await reset({"mk_cadence": 1})
	var z = zombie(Vector3(4, 0, 0))
	await wait(1)
	for i in 3:
		hit(z, 10.0, {"is_headshot": true})
	var st = eff("stacking_damage")
	check(st != null and st.stacks == 3 and near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 109.0),
		"stacking_damage: Steady Cadence 3 stacks = +9%")
	player._ev(&"shot_missed", {"weapon": w})
	check(st.stacks == 0, "stacking_damage: a miss resets the stacks")

	# force_precision (Called Shot)
	await reset({"mk_called": 1})
	z = zombie(Vector3(4, 0, 0), 100)
	await wait(1)
	check(player.mod_stat("force_precision", 0.0, {"target": z}) == 0.0, "force_precision: unmarked target not forced")
	z.apply_status("mark", {"dur": 5.0, "amp": 0.1})
	check(player.mod_stat("force_precision", 0.0, {"target": z}) >= 1.0, "force_precision: Called Shot marked target = precision")

	# refill_mag (Steady Eye)
	await reset({"mk_root": 1})
	z = zombie(Vector3(4, 0, 0), 10)
	await wait(1)
	w.ammo = 2
	hit(z, 100.0, {"is_headshot": true})
	check(w.ammo == 3, "refill_mag: Steady Eye precision kill +1 round (%d)" % w.ammo)

	# refund_grenade (Short Fuse)
	await reset({"sp_root": 1})
	z = zombie(Vector3(4, 0, 0), 10)
	await wait(1)
	player._grenade_cd = player.grenade_cooldown
	hit(z, 100.0, {"source": "grenade"})
	check(near(player._grenade_cd, player.grenade_cooldown * 0.8, 0.05), "refund_grenade: Short Fuse grenade kill refunds 20%")

	# heal (Red Harvest)
	await reset({"sv_redharvest": 1})
	z = zombie(Vector3(4, 0, 0), 10)
	await wait(1)
	player.health = 50
	hit(z, 100.0, {"is_headshot": true})
	check(player.health == 54, "heal: Red Harvest precision kill heals 4 (%d)" % player.health)

	# grant_overshield (Scrap Plating) + overshield absorbs first
	await reset({"sv_root": 1})
	bus.emit_event(&"round_started", {"player": player, "round": 1})
	check(near(player.overshield, 20.0), "grant_overshield: Scrap Plating 20 overshield at round start")
	var hp0: int = player.health
	player.take_damage(30.0)
	check(near(player.overshield, 0.0) and player.health == hp0 - 10, "overshield absorbs before health (30 dmg -> 20 shield + 10 HP)")

	# damage_in_mod (Last Gasp)
	await reset({"sv_gasp": 1})
	check(near(player.mod_stat("damage_in", 100.0), 100.0), "damage_in_mod: Last Gasp inactive at full health")
	player.health = int(player.max_health * 0.2)
	check(near(player.mod_stat("damage_in", 100.0), 80.0), "damage_in_mod: Last Gasp -20% below 30% health")

	# cheat_death (Second Heartbeat)
	await reset({}, ["L_second_heartbeat"])
	player.health = 10
	player.take_damage(1000.0)
	check(player.health == 1 and not player.dead and player.invulnerable_t >= 2.9 and near(player.overshield, 50.0),
		"cheat_death: lethal hit -> 1 HP, 3 s invulnerable, 50 overshield")
	var lc: Dictionary = player._ev(&"lethal_damage", {"prevent": false})
	check(not lc.prevent and eff("cheat_death").uses_left == 0, "cheat_death: once per match")
	player.invulnerable_t = 0.0

	# reflect_damage (Bramble Hide)
	await reset({}, ["L_bramble"])
	z = zombie(Vector3(4, 0, 0), 1000)
	await wait(1)
	player.take_damage(10.0, z)
	check(near(z.health, 970.0), "reflect_damage: Bramble Hide returns 3x the hit (%.0f)" % z.health)

	# on_event_explode: Rolling Thunder, Skullburst chain, Crater Drop (Reverb Core is a `reaction` card, below)
	await reset({"sp_thunder": 1})
	var df = eff("on_event_explode")
	var za = zombie(Vector3(4, 0, 0), 10)
	var zb = zombie(Vector3(4, 0, 1.0), 1000)
	await wait(1)
	hit(za, 100.0, {"source": "grenade"})
	check(df.blasts == 1 and zb.health < 1000, "on_event_explode: Rolling Thunder grenade kill re-explodes (neighbour %.0f)" % zb.health)
	await reset({}, ["L_skullburst"])
	var row := []
	for i in 5:
		row.append(zombie(Vector3(4 + i * 1.2, 0, 0), 60))
	await wait(1)
	hit(row[0], 1000.0, {"is_headshot": true})
	var sb = eff("on_event_explode")
	check(sb.blasts >= 2 and int(sb.last_blast.link) >= 2 and int(sb.last_blast.link) <= 4,
		"on_event_explode: Skullburst chains (%d blasts, link %d, max 4)" % [sb.blasts, int(sb.last_blast.get("link", 0))])
	check(int(sb.last_blast.get("depth", 0)) <= runner.MAX_DEPTH + 1, "chain depth guard holds (depth %d)" % int(sb.last_blast.get("depth", 0)))
	await reset({}, ["L_crater_drop"])
	z = zombie(Vector3(2, 0, 0), 1000)
	await wait(1)
	player._ev(&"landed", {"fall_speed": 2.0})
	var cd = eff("on_event_explode")
	check(cd.blasts == 0, "on_event_explode: Crater Drop ignores soft landings")
	player._ev(&"landed", {"fall_speed": 6.0})
	check(cd.blasts == 1 and near(float(cd.last_blast.damage), 90.0) and z.health < 1000, "on_event_explode: Crater Drop 15 x fall speed")

	# on_event_ray (Ricochet Verdict)
	await reset({"mk_root": 1, "mk_verdict": 1})
	za = zombie(Vector3(4, 0, 0), 10)
	zb = zombie(Vector3(4, 0, 3), 1000)
	await wait(1)
	hit(za, 100.0, {"is_headshot": true})
	check(near(zb.health, 940.0), "on_event_ray: Ricochet Verdict precision kill rays 60%% to the nearest (%.0f)" % zb.health)

	# element_arc (Volt Coil; Forked Current chains)
	await reset({"sp_root": 1, "sp_volt_coil": 1})
	za = zombie(Vector3(4, 0, 0), 10000)
	zb = zombie(Vector3(4, 0, 2), 10000)
	await wait(1)
	hit(za, 100.0, {"element": "ballistic"})
	check(near(zb.health, 10000.0), "element_arc: Ballistic hits do not arc")
	hit(za, 100.0, {"element": "volt"})
	check(near(zb.health, 9965.0), "element_arc: Volt Coil Volt hit arcs 35%% (%.0f)" % zb.health)
	await reset({"sp_root": 1, "sp_forked": 1})
	za = zombie(Vector3(4, 0, 0), 10000)
	zb = zombie(Vector3(4, 0, 2), 10000)
	var zc = zombie(Vector3(4, 0, 4), 10000)
	await wait(1)
	hit(za, 100.0, {"element": "volt"})
	check(zb.health < 10000 and near(zc.health, 10000.0), "element_arc: Forked Current chains a Volt hit one hop onward")

	# element_dot (Kindling burn; Spreading Cinders spread)
	await reset({"sp_root": 1, "sp_kindling": 1})
	z = zombie(Vector3(4, 0, 0), 10000)
	await wait(1)
	hit(z, 100.0, {"element": "blaze"})
	check(z.has_status("burn") and near(float(z.status("burn").dps), 20.0), "element_dot: Kindling burn 20%/s of the hit")
	var hb: float = z.health
	await wait(70)
	check(z.health <= hb - 14.0, "burn status ticks damage over time (%.0f -> %.0f)" % [hb, z.health])
	# points: the ignite hit pays points-per-hit once; burn ticks pay nothing
	await reset({"sp_root": 1, "sp_kindling": 1})
	z = zombie(Vector3(4, 0, 0), 10000)
	z.hit.connect(main._on_zombie_hit) # same wiring as main._spawn_zombie
	await wait(2)
	player.points = 0
	hit(z, 100.0, {"element": "blaze"})
	var after_ignite: int = player.points
	var hb2: float = z.health
	await wait(70)
	check(after_ignite == main.points_per_hit and main.points_per_hit > 0, "ignite hit pays points-per-hit once (%d)" % after_ignite)
	check(z.health <= hb2 - 14.0 and player.points == after_ignite, "burn ticks pay no points per hit (%d -> %d, %.0f HP burned)" % [after_ignite, player.points, hb2 - z.health])
	await reset({"sp_root": 1, "sp_cinders": 1})
	za = zombie(Vector3(4, 0, 0), 10)
	zb = zombie(Vector3(4, 0, 1.5), 10000)
	await wait(1)
	za.apply_status("burn", {"dps": 5.0, "dur": 3.0, "source": player})
	hit(za, 100.0)
	check(zb.has_status("burn") and float(zb.status("burn").dps) >= 10.0, "element_dot: Spreading Cinders spreads burn on death")

	# trail_hazard (Skid Marks)
	await reset({"fr_skid": 1})
	z = zombie(Vector3(0.8, 0, 0), 10000)
	await wait(1)
	player._ev(&"slide_tick", {})
	var th = eff("trail_hazard")
	check(th.patches.size() == 1, "trail_hazard: slide drops a fire patch")
	await wait(40)
	check(z.health < 10000, "trail_hazard: patch burns zombies standing in it (%.0f)" % z.health)

	# element_debuff (Rot Bloom)
	await reset({"sp_root": 1}, ["s_rot_bloom"])
	za = zombie(Vector3(4, 0, 0), 100)
	zb = zombie(Vector3(4, 0, 1.5), 1000)
	await wait(1)
	hit(za, 10.0, {"element": "blight"})
	check(za.has_status("rot") and near(za.damage_taken_mult(), 1.1), "element_debuff: Blight hit applies Rot (+10% damage taken)")
	hit(za, 1000.0)
	check(zb.has_status("rot") and zb.health < 1000, "element_debuff: rotting zombie bursts on death and spreads Rot")

	# apply_status (Spotter mark)
	await reset({"mk_root": 1, "mk_aim": 1, "mk_spotter": 1})
	z = zombie(Vector3(4, 0, 0), 10000)
	await wait(1)
	hit(z, 10.0, {"is_headshot": true})
	check(z.has_status("mark") and near(z.damage_taken_mult(), 1.15), "apply_status: Spotter marks (+15% damage taken)")
	z.apply_status("slow", {"dur": 1.0, "amp": 0.5})
	check(near(z.slow_mult(), 0.5), "enemy slow status halves move speed")

	# drop_pickup + heal (Bone Harvest)
	await reset({"sv_root": 1, "sv_skin": 1, "sv_harvest": 1})
	z = zombie(Vector3(1.5, 0, 0), 10)
	await wait(1)
	player.health = 50
	hit(z, 100.0, {"source": "melee"})
	check(eff("drop_pickup").dropped == 1 and player.health == 60, "drop_pickup: Bone Harvest melee kill drops ammo + heals 10")

	# ability_mod (Twin Stride charges) + §24 Breach Rush tuned by Ram's Shoulder
	await reset({"so_ram": 1, "so_twin": 1})
	check(player.ability_charges_max == 2, "ability_mod: Twin Stride 2 Breach Rush charges")
	check(near(player.mod_stat("ab_rush_damage", 45.0), 85.0) and near(player.mod_stat("ab_rush_radius", 1.6), 2.1), "Ram's Shoulder: rush damage 45 -> 85, width 1.6 -> 2.1")
	z = zombie(Vector3(0.9, 0, 0), 1000)
	await wait(1)
	player.use_ability()
	player.ability.process_active(player, 0.016)
	check(player.ability is BreachRushAbility and player.ability.hits == 1 and z.health < 1000.0 and z.health > 800.0,
		"Breach Rush hits each zombie once (%.0f)" % z.health)
	player.set_ability_active_time(0.0)

	# ability_refund (Breacher's Rhythm)
	await reset({"so_ram": 1, "so_twin": 1, "so_breacher": 1})
	z = zombie(Vector3(4, 0, 0), 10)
	await wait(1)
	player._ev(&"ability_used", {"ability": player.ability})
	player.ability_charges = 0
	player._ability_cd = 5.0
	hit(z, 100.0)
	check(player.ability_charges == 1, "ability_refund: kill within 1 s of a Breach Rush refunds a charge")

	# grenade_mod (Powder Keg Frame charges/cd, Bomblet Packing)
	await reset({})
	var gcd: float = player.grenade_cooldown
	await reset({"sp_key": 1})
	check(player.grenade_charges_max == 2 and near(player.grenade_cooldown, gcd * 1.4, 0.05), "grenade_mod: Powder Keg Frame 2 charges, cooldown x1.4")
	await reset({"sp_bomblet": 1})
	player._ev(&"grenade_detonated", {"pos": player.global_position + Vector3(5, 0, 0), "data": player.grenade_data})
	check(eff("grenade_mod").bomblets == 2, "grenade_mod: Bomblet Packing 2 bomblets")


	# shot_counter (Phantom Mag)
	await reset({}, ["L_phantom_mag"])
	w.ammo = 5
	for i in 6:
		player._ev(&"shot_fired", {"weapon": w})
	var sc = eff("shot_counter")
	check(sc.phantom and w.ammo == 6 and near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 200.0),
		"shot_counter: Phantom Mag 6th shot is free and +100%")

	# cooldown_reset (Marrow Gnaw)
	await reset({"sv_marrow": 1})
	z = zombie(Vector3(1.5, 0, 0), 10)
	await wait(1)
	player._melee_cd = 1.0
	hit(z, 1000.0, {"source": "melee"})
	check(player._melee_cd == 0.0, "cooldown_reset: Marrow Gnaw melee kill resets melee")

	# unlock_cards / offer_weight / offer_mod
	await reset({"mk_root": 1, "mk_aim": 1, "mk_spotter": 1, "mk_legend": 1})
	var uc: Array = runner.effects_of("unlock_cards").filter(func(e): return e.source_id == "mk_legend")
	check(not uc.is_empty() and "L_skullburst" in uc[0].cards() and rs.eligible("L_skullburst"), "unlock_cards: Hall of Marks opens Marksman legendaries")
	check(runner.has_stat("offer_weight:marksman"), "offer_weight: Hall of Marks answers offer_weight:marksman")
	await reset({"lg_spare": 2})
	check(rs.free_rerolls == 2, "offer_mod: Spare Coin II = 2 free rerolls")
	await reset({"lg_spare": 1, "lg_lucky": 2})
	check(near(runner.modify("offer_lucky_slot_chance", 0.0), 0.08), "offer_mod: Lucky Find II 8% legendary slot chance")
	rs.rng.seed = 7
	var lucky := 0
	for i in 300:
		for id in rs.roll_offer(3):
			if rs.card_def(id).get("tier", "") == "legendary":
				lucky += 1
	check(lucky > 20 and lucky < 140, "Lucky Find: normal rounds roll some legendaries (%d / 900 slots)" % lucky)

	# Stoneblood keystone (heal + overshield per kill, no regen, cap 40)
	await reset({"sv_key": 1})
	check(player.regen_disabled and near(player.overshield_cap, 40.0), "Stoneblood: regen off, overshield cap 40")
	z = zombie(Vector3(4, 0, 0), 10)
	await wait(1)
	player.health = 50
	hit(z, 100.0)
	check(player.health == 54 and near(player.overshield, 6.0), "Stoneblood: kill heals 4 + 6 overshield")

	# Freerunner keystone (Hollow Bones)
	await reset({})
	var mw: int = player.max_wall_jumps
	var spd: float = player.walk_speed
	await reset({"fr_key": 1})
	check(player.max_wall_jumps == mw + 1 and player.walk_speed > spd * 1.14 and player.max_health == int(round(base_hp * 0.8)),
		"Hollow Bones: +1 wall jump, +15% speed, -20% max health")

	# Long Count (no falloff + beyond falloff bonus), Sky Plating, Wall Battery
	await reset({"mk_root": 1, "mk_aim": 1, "mk_longcount": 1})
	check(player.mod_stat("no_falloff", 0.0) > 0.0 and near(player.mod_stat("damage_out", 100.0, {"source": "gun", "distance": 40.0, "falloff_start": 20.0}), 115.0),
		"Long Count: no falloff, +15% beyond falloff range")
	await reset({"fr_root": 1, "fr_step": 1, "fr_skyplate": 1})
	z = zombie(Vector3(4, 0, 0), 10)
	await wait(1)
	hit(z, 100.0, {"airborne": true})
	check(near(player.overshield, 15.0), "Sky Plating: airborne kill +15 overshield")
	await reset({"fr_root": 1, "fr_step": 1, "fr_battery": 1})
	player._grenade_cd = player.grenade_cooldown
	player.global_position.y += 30.0
	for i in 4:
		player._ev(&"wall_jumped", {})
	check(near(player._grenade_cd, player.grenade_cooldown * 0.7, 0.05), "Wall Battery: 10% per wall jump, max 3 per airtime")
	player.global_position.y -= 30.0
	player.velocity = Vector3.ZERO
	await wait(20)

	# Slide Loader (finish reload)
	await reset({"fr_root": 1})
	w.ammo = 0
	w.reserve = 100
	player.reload()
	player._ev(&"slide_started", {})
	check(w.ammo == w.mag_size(), "refill_mag: Slide Loader finishes a reload instantly")

	# Scout tree (class switch): Fed Rush, Ghostline, Racing Heart, Redline
	await reset({"sc_fed": 1, "sc_ghost": 1, "sc_racing_heart": 1}, [], "scout")
	var acd: float = player.ability.cooldown if player.ability else 0.0
	check(player.ability != null and prog.class_active("sc_fed") and not prog.class_active("so_ram"), "class switch to Scout")
	player.set_ability_active_time(2.0)
	z = zombie(Vector3(4, 0, 0), 10)
	await wait(1)
	hit(z, 100.0)
	check(player.ability_active_time() > 2.3, "ability_mod: Fed Rush kills extend Hare's Break (%.2f)" % player.ability_active_time())
	check(near(player.mod_stat("fire_rate_mult", 1.0), 1.25), "Racing Heart: +25% fire rate while Hare's Break is active")
	runner.rng.seed = 3
	var dodged := 0
	for i in 200:
		var c: Dictionary = player._ev(&"damage_incoming", {"amount": 10.0, "raw": 10.0})
		if c.get("dodged", false):
			dodged += 1
	check(dodged > 60 and dodged < 140, "damage_in_mod: Ghostline ~50%% dodge while active (%d / 200)" % dodged)
	player.set_ability_active_time(0.0)
	await reset({"sc_fed": 1}, [], "scout")
	var acd0: float = player.ability.cooldown
	await reset({"sc_fed": 1, "sc_ghost": 1, "sc_racing_heart": 1}, ["L_redline"], "scout")
	var focus_k: float = float(player.get_stat_effects().from_armor.ability_cd_mult) if player.has_method("get_stat_effects") \
		else 1.0 - float(player.armor_stats.get("focus", 0)) * 0.004 # armor Focus scales the +4 s too (pre-§21b: linear)
	check(near(player.ability.cooldown, acd0 + 4.0 * focus_k, 0.3), "Racing Heart drawback: +4 s Hare's Break cooldown (x%.2f Focus: %.1f vs %.1f)" % [focus_k, player.ability.cooldown, acd0])
	check(player.mod_stat("force_precision", 0.0, {}) == 0.0, "Redline: no forced precision before the ability")
	player.set_ability_active_time(5.0)
	check(player.ability_active_time() > 0.0 and player.mod_stat("force_precision", 0.0, {}) >= 1.0, "Redline: while Hare's Break is active every hit is precision")
	player.set_ability_active_time(0.0)
	await reset({"so_ram": 1, "so_twin": 1, "so_breacher": 1}, ["L_breakline"])
	z = zombie(Vector3(2, 0, 0), 1000)
	await wait(1)
	player._ev(&"ability_ended", {"ability": player.ability})
	check(z.health < 1000, "on_event_explode: Breakline Charge blasts at Breach Rush end (%.0f)" % z.health)


# ---------------------------------------------------------------- every node and every card

func _card_checks() -> void:
	for id in prog.all_node_ids():
		var n: Dictionary = prog.get_skill(id)
		var cls: String = n.get("class", "")
		_equip_ability(cls, str(n.get("ability", ""))) # §23: ability-path nodes only run with their Q ability
		await reset({id: int(n.ranks)}, [], cls if cls != "" else "soldier")
		var got: int = runner.effects_from(id).size()
		check(got == n.effects.size() and got > 0, "node %s (%s): %d effect(s) wired" % [id, n.name, got])
	for id in rs.card_ids():
		if id == rs.CACHE_ID:
			continue
		var c: Dictionary = rs.card_def(id)
		var cls: String = c.get("class", "")
		var meta := {}
		_equip_ability(cls, str(c.get("ability", "")))
		await reset(meta, [], cls if cls != "" else "soldier")
		for i in int(c.ranks):
			rs.add_card(id)
		var got: int = runner.effects_from(id).size()
		var ok: bool = got == c.effects.size() and rs.card_rank(id) == int(c.ranks)
		var txt := true
		for r in range(1, int(c.ranks) + 1):
			txt = txt and not "{" in prog.format_description(c, r) and not "{" in prog.format_drawback(c, r)
		# plain stat cards must actually move their stat
		var moved := true
		for e in c.effects:
			if e.script == "stat_mod" and not e.params.has("while"):
				var s: String = e.params.stat
				var base := 1.0
				moved = moved and not near(runner.modify(s, base), base, 0.0001)
		check(ok and txt and moved, "card %s (%s): %d effect(s) at rank %d, text fills, stats move" % [id, c.name, got, int(c.ranks)])
	_equip_ability("", "")
	# specific card behaviour not covered above
	await _card_rework_checks()
	await reset({"fr_root": 1}, ["f_slide_guard"])
	check(near(player.mod_stat("damage_in", 100.0, {"sliding": true}), 80.0) and near(player.mod_stat("damage_in", 100.0, {"sliding": false}), 100.0),
		"Slide Guard: -20% damage while sliding")


# ---------------------------------------------------------------- Field Card dedupe rework (playtest #12 line 15)

func _kill_ev(extra: Dictionary = {}) -> void:
	_ev(&"enemy_killed", {"source": "gun", "damage": 10.0, "is_headshot": false, "element": "ballistic"}.merged(extra, true))


func _hurt_ev(dealt: int = 5) -> void:
	_ev(&"damage_taken", {"raw": dealt, "dealt": dealt, "absorbed": 0, "attacker": null, "health_frac": float(player.health) / maxf(float(player.max_health), 1.0)})


func _card_rework_checks() -> void:
	var w
	var z
	# Deep Pockets: free shots for the first seconds of a round (free_shots)
	await reset({}, ["c_deep_pockets"])
	w = player.current_weapon()
	w.ammo = 5
	_ev(&"shot_fired", {"weapon": w})
	check(w.ammo == 5, "Deep Pockets: no round-start window yet, a shot costs its round")
	_ev(&"round_started", {"round": 1})
	w.ammo = 5
	_ev(&"shot_fired", {"weapon": w, "ammo_after": 5})
	check(w.ammo == 6 and eff("free_shots").refunded == 1, "Deep Pockets: a shot in the window refunds its round")
	eff("free_shots").left = 0.0
	_ev(&"shot_fired", {"weapon": w})
	check(w.ammo == 6, "Deep Pockets: window over, shots cost ammo again")
	# Greased Hands: reload with a crowd around you slams a shockwave (reaction @crowded)
	await reset({}, ["c_greased"])
	w = player.current_weapon()
	var crowd := []
	for i in 4:
		crowd.append(zombie(Vector3(3, 0, i * 0.5), 10000))
	await wait(1)
	_ev(&"reload_finished", {"weapon": w})
	check(crowd[0].health < 10000 and eff("reaction").fired == 1, "Greased Hands: reloading in a crowd slams a shockwave (%.0f)" % crowd[0].health)
	var hp_c: float = crowd[0].health
	_ev(&"reload_finished", {"weapon": w})
	check(near(crowd[0].health, hp_c), "Greased Hands: internal cooldown (4 s) blocks the repeat")
	await reset({}, ["c_greased"])
	z = zombie(Vector3(3, 0, 0), 10000)
	await wait(1)
	_ev(&"reload_finished", {"weapon": player.current_weapon()})
	check(near(z.health, 10000.0), "Greased Hands: a lone zombie is not a crowd, no shockwave")
	# Patched Up: once per round, dropping under 30% heals
	await reset({}, ["c_patched"])
	player.health = 25
	_hurt_ev()
	check(player.health == 55, "Patched Up: under 30%% health heals 30 (%d)" % player.health)
	player.health = 20
	_hurt_ev()
	check(player.health == 20, "Patched Up: only once per round")
	_ev(&"round_started", {"round": 2})
	_hurt_ev()
	check(player.health == 50, "Patched Up: a new round re-arms it (%d)" % player.health)
	await reset({}, ["c_patched"])
	player.health = 80
	_hurt_ev()
	check(player.health == 80, "Patched Up: healthy players get nothing")
	player.health = 0
	_hurt_ev()
	check(player.health == 0, "Patched Up: never undoes a lethal hit")
	# Bounty Ledger: headshot kills pay flat bonus points
	await reset({}, ["c_bounty"])
	var pts0: int = player.points
	_kill_ev({"is_headshot": true})
	check(player.points == pts0 + 15, "Bounty Ledger: headshot kill pays 15 bonus points (%d)" % (player.points - pts0))
	_kill_ev()
	check(player.points == pts0 + 15, "Bounty Ledger: a body kill pays nothing extra")
	check(near(player.mod_stat("points_kill_mult", 1.0), 1.0), "Bounty Ledger: no permanent kill-points multiplier any more")
	# Knuckle Wraps: damage taken -> melee x2 for 4 s (timed_buff, melee only)
	await reset({}, ["c_knuckles"])
	check(near(player.mod_stat("damage_out", 100.0, {"source": "melee"}), 100.0), "Knuckle Wraps: no bonus until you are hit")
	_hurt_ev()
	check(near(player.mod_stat("damage_out", 100.0, {"source": "melee"}), 200.0) and near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0),
		"Knuckle Wraps: after a hit melee x2, guns untouched")
	eff("timed_buff").left = 0.0
	check(near(player.mod_stat("damage_out", 100.0, {"source": "melee"}), 100.0), "Knuckle Wraps: the bonus ends")
	# Quick Pin: a grenade throw refills the mag, then rests
	await reset({}, ["c_quick_pin"])
	w = player.current_weapon()
	w.ammo = 3
	_ev(&"grenade_thrown", {})
	check(w.ammo == w.mag_size(), "Quick Pin: throwing a grenade refills the magazine")
	w.ammo = 3
	_ev(&"grenade_thrown", {})
	check(w.ammo == 3, "Quick Pin: 8 s internal cooldown")
	# Steady Pulse / Fast Mender
	await reset({}, ["c_steady_pulse"])
	_ev(&"ability_used", {"ability": player.ability})
	check(near(player.overshield, 20.0), "Steady Pulse: using the class ability grants 20 overshield")
	await reset({}, ["c_mender"])
	player.health = 20
	_ev(&"round_cleared", {"round": 1})
	check(player.health == 52, "Fast Mender: clearing a round heals 40%% of missing HP (%d)" % player.health)
	# Dead Reckoning: headshot kill opens a window where every hit is precision
	await reset({"mk_root": 1}, ["m_caromshot"])
	z = zombie(Vector3(4, 0, 0), 10000)
	await wait(1)
	check(player.mod_stat("force_precision", 0.0, {"target": z}) == 0.0, "Dead Reckoning: nothing before a precision kill")
	_kill_ev({"is_headshot": true})
	check(player.mod_stat("force_precision", 0.0, {"target": z}) >= 1.0, "Dead Reckoning: after a headshot kill every hit is precision")
	eff("timed_buff").left = 0.0
	check(player.mod_stat("force_precision", 0.0, {"target": z}) == 0.0, "Dead Reckoning: the window closes")
	# Held Breath: hold aim to charge the next shot
	await reset({"mk_root": 1}, ["m_heel_round"])
	w = player.current_weapon()
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun", "last_round": true}), 100.0), "Held Breath: no last-round bonus any more")
	player.ads_active = true
	eff("armed_shot").tick(0.5)
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0), "Held Breath: half a second of aim is not enough")
	eff("armed_shot").tick(0.6)
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 220.0), "Held Breath: aimed 1 s, the next shot +120%% (%.0f)" % player.mod_stat("damage_out", 100.0, {"source": "gun"}))
	player._ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0), "Held Breath: the charge is spent")
	player.ads_active = false
	# Cold Open: first shot of a round
	await reset({"mk_root": 1}, ["m_still_water"])
	w = player.current_weapon()
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun", "still": true}), 100.0), "Cold Open: no standing-still bonus, nothing armed before a round starts")
	_ev(&"round_started", {"round": 1})
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 300.0), "Cold Open: first shot of the round +200%")
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0), "Cold Open: only the first shot")
	_ev(&"round_started", {"round": 2})
	eff("armed_shot")._armed_at -= 30.0
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0), "Cold Open: the charge fades after its 10 s window")
	# Tally Marks: 4 headshot kills in 6 s refill the mag + overshield
	await reset({}, ["m_tally"])
	w = player.current_weapon()
	w.ammo = 1
	for i in 3:
		_kill_ev({"is_headshot": true})
	check(w.ammo == 1 and near(player.overshield, 0.0), "Tally Marks: 3 precision kills is not a chain yet")
	_kill_ev({"is_headshot": false})
	_kill_ev({"is_headshot": true})
	check(w.ammo == w.mag_size() and near(player.overshield, 10.0) and eff("kill_chain").chains == 1, "Tally Marks: the 4th precision kill refills the mag + 10 overshield")
	# Powder Burn: a grenade going off near you grants overshield
	await reset({"sp_root": 1}, ["s_daisy_fuse"])
	_ev(&"grenade_detonated", {"pos": player.global_position + Vector3(30, 0, 0), "data": player.grenade_data})
	check(near(player.overshield, 0.0), "Powder Burn: a far-off blast does nothing")
	_ev(&"grenade_detonated", {"pos": player.global_position + Vector3(4, 0, 0), "data": player.grenade_data})
	check(near(player.overshield, 20.0), "Powder Burn: a grenade within 8 m grants 20 overshield")
	# Static Fork: volt kills slow neighbours
	await reset({"sp_root": 1}, ["s_static_fork"])
	var za = zombie(Vector3(4, 0, 0), 10000)
	var zb = zombie(Vector3(4, 0, 2), 10000)
	var zc = zombie(Vector3(4, 0, 12), 10000)
	await wait(1)
	_kill_ev({"element": "ballistic", "target": za})
	check(not zb.has_status("slow"), "Static Fork: ballistic kills do nothing")
	_kill_ev({"element": "volt", "target": za})
	check(zb.has_status("slow") and not zc.has_status("slow"), "Static Fork: a volt kill slows zombies within 5 m")
	# Cinder Stride: blaze kill -> move speed
	await reset({"sp_root": 1}, ["s_cinder"])
	var ms0: float = player.mod_stat("move_speed", 1.0)
	_kill_ev({"element": "ballistic"})
	check(near(player.mod_stat("move_speed", 1.0), ms0), "Cinder Stride: only blaze kills")
	_kill_ev({"element": "blaze"})
	check(player.mod_stat("move_speed", 1.0) > ms0 + 0.1, "Cinder Stride: a blaze kill grants +15%% move speed (%.2f -> %.2f)" % [ms0, player.mod_stat("move_speed", 1.0)])
	# Widow's Wage: low-health kills pay points
	await reset({"sv_root": 1}, ["v_bloodwick"])
	pts0 = player.points
	_kill_ev()
	check(player.points == pts0, "Widow's Wage: healthy kills pay nothing extra")
	player.health = 30
	_kill_ev()
	check(player.points == pts0 + 10, "Widow's Wage: a kill under 40%% health pays 10 bonus points (%d)" % (player.points - pts0))
	# Kill Plating: kills soon after taking damage grant overshield
	await reset({"sv_root": 1}, ["v_kill_plating"])
	var shield0: float = player.overshield
	_kill_ev()
	check(near(player.overshield, shield0), "Kill Plating: no recent damage, no shield")
	player.take_damage(5.0)
	var shield1: float = player.overshield
	_kill_ev()
	check(near(player.overshield, shield1 + 8.0), "Kill Plating: a kill right after being hit grants 8 overshield")
	# Clean Sheet: flawless round pays
	await reset({}, ["v_grit"])
	player.health = 50
	pts0 = player.points
	_ev(&"round_started", {"round": 3})
	_ev(&"round_cleared", {"round": 3})
	check(player.points == pts0 + 15, "Clean Sheet: and 5 points x the round number (%d)" % (player.points - pts0))
	check(near(player.overshield, 25.0) and player.health == 70 and eff("flawless_round").paid == 1, "Clean Sheet: untouched round pays overshield + heal (%.0f / %d)" % [player.overshield, player.health])
	await reset({}, ["v_grit"])
	_ev(&"round_started", {"round": 3})
	_hurt_ev(8)
	_ev(&"round_cleared", {"round": 3})
	check(eff("flawless_round").paid == 0 and near(player.overshield, 0.0), "Clean Sheet: a round where you lost health pays nothing")
	# Gleaner: every 12th kill drops a pickup
	await reset({"sv_root": 1}, ["v_gleaner"])
	for i in 11:
		_kill_ev()
	check(eff("kill_chain").dropped == 0, "Gleaner: 11 kills drop nothing")
	_kill_ev()
	check(eff("kill_chain").dropped == 1, "Gleaner: the 12th kill drops a pickup")
	# Rail Slide / Spring Heels / Updraft Aim
	await reset({"fr_root": 1}, ["f_rail_slide"])
	w = player.current_weapon()
	_ev(&"slide_ended", {})
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 140.0), "Rail Slide: the first shot after a slide +40%")
	_ev(&"shot_fired", {"weapon": w})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0), "Rail Slide: only one shot")
	await reset({"fr_root": 1}, ["f_spring_heels"])
	var jm0: float = player.mod_stat("jump_mult", 1.0)
	_ev(&"slide_ended", {})
	check(player.mod_stat("jump_mult", 1.0) > jm0 + 0.2, "Spring Heels: after a slide you jump higher (%.2f -> %.2f)" % [jm0, player.mod_stat("jump_mult", 1.0)])
	eff("timed_buff").left = 0.0
	check(near(player.mod_stat("jump_mult", 1.0), jm0), "Spring Heels: the boost ends")
	await reset({"fr_root": 1}, ["f_updraft_aim"])
	check(near(player.mod_stat("spread_mult", 1.0, {}), 1.0), "Updraft Aim: no spread change on the ground")
	_ev(&"jumped", {})
	check(near(player.mod_stat("spread_mult", 1.0, {}), 0.25), "Updraft Aim: a jump tightens spread to 25% for a moment")
	# Lantern Hours: growth resets under 30% health
	await reset({}, ["t_lantern_hours"])
	var rg = eff("round_growth")
	_ev(&"round_cleared", {"round": 1})
	_ev(&"round_cleared", {"round": 2})
	check(rg.rounds == 2 and near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 104.0), "Lantern Hours: +2% per cleared round")
	player.health = 60
	_hurt_ev()
	check(rg.rounds == 2, "Lantern Hours: a scratch keeps the growth")
	player.health = 20
	_hurt_ev()
	check(rg.rounds == 0 and near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0), "Lantern Hours: dropping under 30%% health wipes the growth")
	# Reverb Core
	await reset({}, ["L_reverb_core"])
	z = zombie(Vector3(2, 0, 0), 1000)
	await wait(1)
	_ev(&"ability_used", {"ability": player.ability})
	check(z.health < 1000, "Reverb Core: a shockwave on ability use (%.0f)" % z.health)
	# Mercy Line: finish weak zombies, never a boss
	await reset({"mk_root": 1}, ["L_mercy_line"])
	z = zombie(Vector3(4, 0, 0), 100)
	await wait(1)
	z.health = 24
	var res := hit(z, 5.0)
	check(res.killed or z.health <= 0, "Mercy Line: a hit leaving a zombie under 20%% health finishes it")
	var zh = zombie(Vector3(4, 0, 3), 100)
	await wait(1)
	hit(zh, 5.0)
	check(zh.health > 0, "Mercy Line: a healthy zombie is not executed")
	# Livewire Lattice: standing still zaps nearby zombies
	await reset({"sp_root": 1}, ["L_livewire"])
	za = zombie(Vector3(4, 0, 0), 10000)
	zb = zombie(Vector3(4, 0, 3), 10000)
	await wait(1)
	player.velocity = Vector3.ZERO
	await wait(70)
	check(za.health < 10000 and zb.health < 10000 and eff("aura_zap").zaps >= 1, "Livewire Lattice: standing still zaps nearby zombies (%.0f / %.0f)" % [za.health, zb.health])
	# Pyre Walker: taking damage ignites the crowd
	await reset({"sp_root": 1}, ["L_pyre_walker"])
	za = zombie(Vector3(3, 0, 0), 10000)
	await wait(1)
	_hurt_ev()
	check(za.has_status("burn"), "Pyre Walker: taking damage ignites zombies within 5 m")
	# Surveyor's Charge
	await reset({"sp_root": 1}, ["L_cluster"])
	za = zombie(Vector3(4, 0, 0), 10000)
	await wait(1)
	_ev(&"grenade_detonated", {"pos": za.global_position, "data": player.grenade_data})
	check(za.has_status("mark"), "Surveyor's Charge: a detonation marks zombies in the blast")
	# Scrapwall: breaking your shield buys 2 s of invulnerability and a shockwave
	await reset({"sv_root": 1}, ["L_scrapwall"])
	z = zombie(Vector3(2, 0, 0), 10000)
	await wait(1)
	player.overshield = 0.0
	_ev(&"damage_taken", {"raw": 10, "dealt": 10, "absorbed": 0, "attacker": null, "health_frac": 0.9})
	check(player.invulnerable_t <= 0.1, "Scrapwall: a hit that did not break a shield does nothing")
	_ev(&"damage_taken", {"raw": 10, "dealt": 5, "absorbed": 5, "attacker": null, "health_frac": 0.9})
	check(player.invulnerable_t >= 1.9 and z.health < 10000, "Scrapwall: breaking the shield gives 2 s invulnerability + shockwave")
	# Grave Feast
	await reset({"sv_root": 1}, ["L_grave_feast"])
	w = player.current_weapon()
	player.health = 40
	player._melee_cd = 1.0
	for i in 2:
		_kill_ev({"source": "melee"})
	check(player.health == 40, "Grave Feast: 2 melee kills is not a chain")
	_kill_ev({"source": "gun"})
	_kill_ev({"source": "melee"})
	check(player.health == player.max_health and player._melee_cd == 0.0, "Grave Feast: the 3rd melee kill heals fully and resets melee")
	# Undertow Glide
	await reset({}, ["L_undertow"])
	z = zombie(Vector3(4, 0, 0), 10000)
	await wait(1)
	_ev(&"slide_started", {})
	check(z.has_status("slow"), "Undertow Glide: starting a slide slows zombies nearby")
	# Unstruck Colors / Chalk Outline
	_equip_ability("soldier", "rally_banner")
	await reset({}, ["L_unstruck"])
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 100.0), "Unstruck Colors: nothing before the ability")
	_ev(&"ability_used", {"ability": player.ability})
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun"}), 125.0), "Unstruck Colors: ability use gives +25% damage for 8 s")
	_equip_ability("scout", "chalk_mark")
	await reset({"sc_fed": 1}, ["L_chalk_outline"], "scout")
	z = zombie(Vector3(4, 0, 0), 10000)
	await wait(1)
	player._ability_cd = 20.0
	_kill_ev({"target": z})
	check(player._ability_cd == 20.0, "Chalk Outline: killing an unmarked zombie does nothing")
	z.apply_status("mark", {"dur": 5.0, "amp": 0.1})
	_kill_ev({"target": z})
	check(player._ability_cd == 0.0, "Chalk Outline: killing a marked zombie resets the ability cooldown")
	_equip_ability("", "")


# ---------------------------------------------------------------- 60% / 5 s refund cap

func _refund_cap_checks() -> void:
	await reset({})
	var cd: float = player.grenade_cooldown
	player._grenade_cd = cd
	var got := 0.0
	for i in 4:
		got += player.refund_grenade(0.2)
	check(near(got, 0.6) and near(player._grenade_cd, cd * 0.4, 0.05), "refund cap: 4 x 20% inside 5 s refunds only 60%")
	check(near(player.grenade_refund_room(), 0.0), "refund cap: no room left in the window")
	player._clock += 5.1
	check(near(player.refund_grenade(0.2), 0.2), "refund cap: window rolls after 5 s")
	# the loop case: Short Fuse grenade kills chaining
	await reset({"sp_root": 1})
	player._grenade_cd = player.grenade_cooldown
	for i in 5:
		var z = zombie(Vector3(4, 0, i * 0.6), 10)
		await wait(1)
		hit(z, 100.0, {"source": "grenade"})
	check(near(player._grenade_cd, player.grenade_cooldown * 0.4, 0.1), "refund cap: 5 Short Fuse grenade kills capped at 60%")
	player._grenade_cd = 0.0
	check(near(player.refund_grenade(0.2), 0.0), "refund does nothing while the grenade is ready")


# ---------------------------------------------------------------- time-scale flag

func _time_scale_checks() -> void:
	# Kite String, flag OFF: slow aura + 15% damage reduction, no Engine.time_scale change
	await reset({"fr_root": 1, "fr_step": 1, "fr_battery": 1, "fr_legend": 1}, ["L_kite_string"])
	var home: Vector3 = player.global_position
	var z = zombie(Vector3(4, 0, 0), 10000)
	await wait(2)
	player.global_position = home + Vector3(0, 6, 0)
	await wait(6)
	check(player.is_airborne() and Engine.time_scale == 1.0, "Kite String flag off: airborne, time scale untouched")
	check(z.has_status("slow"), "Kite String flag off: slows zombies near you")
	check(near(player.mod_stat("damage_in", 100.0), 85.0), "Kite String flag off: -15% damage taken while airborne")
	check(near(player.mod_stat("damage_out", 100.0, {"source": "gun", "airborne": true}), 100.0), "Kite String: no permanent airborne damage bonus any more")
	player.global_position = home
	player.velocity = Vector3.ZERO
	await wait(10)
	# flag ON: real time scale while airborne, released on landing
	ProjectSettings.set_setting("skills/allow_time_scale", true)
	player.global_position = home + Vector3(0, 6, 0)
	await wait(6)
	check(near(Engine.time_scale, 0.75), "Kite String flag on: time scale 0.75 while airborne (%.2f)" % Engine.time_scale)
	check(near(player.mod_stat("damage_in", 100.0), 100.0), "Kite String flag on: no fallback damage reduction")
	player.global_position = home
	player.velocity = Vector3.ZERO
	for i in 120:
		await physics_frame
		if player.is_on_floor():
			break
	await wait(3)
	check(Engine.time_scale == 1.0, "Kite String flag on: time scale restored on landing")
	ProjectSettings.set_setting("skills/allow_time_scale", false)

	# Second Breath, flag OFF: slow aura + 30% DR for 2.5 s
	await reset({"sv_root": 1, "sv_skin": 1, "sv_breath": 1})
	z = zombie(Vector3(4, 0, 0), 10000)
	await wait(1)
	player.health = int(player.max_health * 0.35)
	player.take_damage(10.0)
	check(Engine.time_scale == 1.0 and z.has_status("slow"), "Second Breath flag off: zombies slowed, no time scale")
	check(near(player.mod_stat("damage_in", 100.0), 70.0), "Second Breath: -30% damage taken during the window")
	# flag ON: Engine.time_scale 0.5 for 2.5 real seconds
	await reset({"sv_root": 1, "sv_skin": 1, "sv_breath": 1})
	ProjectSettings.set_setting("skills/allow_time_scale", true)
	player.health = int(player.max_health * 0.35)
	player.take_damage(10.0)
	check(near(Engine.time_scale, 0.5), "Second Breath flag on: time scale 0.5 (%.2f)" % Engine.time_scale)
	rs.tick_time_scale(1.0)
	check(near(Engine.time_scale, 0.5), "time scale held for its duration")
	rs.tick_time_scale(2.0)
	check(Engine.time_scale == 1.0, "time scale restored after 2.5 real seconds")
	player.health = int(player.max_health * 0.2)
	player.take_damage(5.0)
	check(Engine.time_scale == 1.0, "Second Breath: 45 s internal cooldown")
	rs.request_time_scale("a", 0.7, -1.0)
	rs.request_time_scale("b", 0.4, -1.0)
	check(near(Engine.time_scale, 0.4), "stacked time-scale requests: lowest wins")
	rs.release_time_scale("b")
	check(near(Engine.time_scale, 0.7), "releasing one request falls back to the next")
	rs.clear()
	check(Engine.time_scale == 1.0, "RunState.clear() (game over) restores time scale")
	ProjectSettings.set_setting("skills/allow_time_scale", false)
	rs.request_time_scale("c", 0.5, 1.0)
	check(Engine.time_scale == 1.0, "flag off: time-scale requests ignored")


# ---------------------------------------------------------------- main.gd round flow

func _flow_checks() -> void:
	await reset({})
	check(prog.respec_allowed, "respec allowed at round 0")
	check(main.run_pick_menu != null and main.run_pick_menu.is_inside_tree(), "a run-pick chooser is instanced (%s)" % main.run_pick_menu.get_script().resource_path.get_file())
	check(main._zombie_stats(1).damage == 10 and main._zombie_stats(10).damage == 19, "zombie damage exports: 10 + 1 per round (Economy v2 wave_base, was +2; got %d)" % main._zombie_stats(10).damage)
	var z_hp_round: int = main.current_round
	main.current_round = 3
	main._to_spawn = 0
	main._alive = 0
	main._offer_pending = true
	main._offer_delay = 0.0
	await wait(3)
	check(rs.offer_open and paused and rs.offer_round == 3, "round cleared -> offer opens and the game pauses")
	var pts: int = player.points
	rs.skip()
	await wait(1)
	check(not paused and not main._offer_pending and near(main._break_timer, main.round_break, 0.2) and player.points == pts + 75,
		"offer closed -> unpaused, round break starts, skip paid 75 at r3 (25 x round)")
	main._break_timer = 99999.0
	main.current_round = z_hp_round


# ---------------------------------------------------------------- playtest #13: Field Card types

func _ev(name: StringName, extra: Dictionary = {}) -> void:
	var p := {"player": player}
	p.merge(extra, true)
	bus.emit_event(name, p)


func _card_type_checks() -> void:
	var types := ["instant", "echo", "growing", "fleeting", "hoard", "wager", "counter", "reactive"]
	var seen := {}
	var label_ok := true
	for c in rs.data.cards:
		if str(c.get("type", "")) in types:
			seen[str(c.type)] = true
			var e: Dictionary = rs.offer_entry(str(c.id))
			label_ok = label_ok and str(e.get("type_label", "")) != "" and str(e.get("type_hint", "")) != ""
	check(seen.size() == 8 and label_ok, "8 new Field Card types each have a card, a type_label and a type_hint (%d)" % seen.size())

	# Instant: pays once on pick, not again on a stat rebuild
	await reset({})
	var w = player.current_weapon()
	w.ammo = 0
	w.reserve = 0
	rs.offer_round = 4
	player._grenade_cd = 9.0
	rs.add_card("t_hand_me_down")
	check(w.ammo == w.mag_size() and w.reserve > 0 and player.points == 160 and player._grenade_cd <= 0.0,
		"Hand-Me-Down (instant): mag+reserve filled, grenade ready, +40 x round points (%d pts, cd %.1f)" % [player.points, player._grenade_cd])
	player.apply_stats()
	check(player.points == 160, "Hand-Me-Down pays only on its own pick, not on a rebuild")

	# Echo: ranks up an owned card; with nothing to rank it pays points
	await reset({}, ["t_lantern_hours"])
	rs.add_card("t_copycat_ink")
	check(rs.cards.get("t_lantern_hours", 0) == 2, "Copycat Ink (echo) ranks up an owned card (rank %d)" % rs.cards.get("t_lantern_hours", 0))
	await reset({})
	rs.offer_round = 2
	rs.add_card("t_copycat_ink")
	check(player.points == 60, "Copycat Ink with nothing to rank pays 30 x round (%d)" % player.points)

	# Growing
	await reset({}, ["t_lantern_hours"])
	var z := zombie(Vector3(0, 0, -4))
	var d0: float = hit(z, 100.0).damage
	for i in 3:
		_ev(&"round_cleared", {"round": i + 1})
	var d1: float = hit(z, 100.0).damage
	check(near(d0, 100.0) and near(d1, 106.0), "Lantern Hours (growing): +2%% gun damage per cleared round (%.1f -> %.1f)" % [d0, d1])
	for i in 20:
		_ev(&"round_cleared", {"round": i + 4})
	check(near(hit(z, 100.0).damage, 120.0), "Lantern Hours caps at +20% at rank 1")

	# Fleeting: strong, then removed after 2 cleared rounds
	await reset({}, ["t_borrowed_hour"])
	z = zombie(Vector3(0, 0, -4))
	var ws: float = player.walk_speed
	var fd: float = hit(z, 100.0).damage
	_ev(&"round_cleared", {"round": 1})
	var left := -9
	for oc in rs.owned_cards():
		if oc.id == "t_borrowed_hour":
			left = int(oc.get("rounds_left", -9))
	_ev(&"round_cleared", {"round": 2})
	await wait(2)
	check(near(fd, 150.0) and left == 1, "Borrowed Hour (fleeting): +50%% damage, owned_cards shows rounds_left (%.0f, %d)" % [fd, left])
	check(not rs.cards.has("t_borrowed_hour") and near(hit(z, 100.0).damage, 100.0) and player.walk_speed < ws,
		"Borrowed Hour expires after 2 rounds: card removed, damage and speed back to normal")

	# Hoard
	await reset({}, ["t_tithe_jar"])
	player.points = 1000
	_ev(&"round_started", {"round": 2})
	var p1: int = player.points
	player.points = 100000
	_ev(&"round_started", {"round": 3})
	check(p1 == 1050 and player.points == 100300, "Tithe Jar (hoard): 5%% interest at round start, capped at 300 (%d, %d)" % [p1, player.points])

	# Wager
	await reset({}, ["t_crooked_oath"])
	z = zombie(Vector3(0, 0, -4))
	check(near(hit(z, 100.0).damage, 130.0) and near(player.mod_stat("damage_in", 100.0, {}), 115.0) and rs.offer_entry("t_crooked_oath").drawback != "",
		"Crooked Oath (wager): +30% damage dealt, +15% damage taken, drawback shown")

	# Counter
	await reset({}, ["t_toll_counter"])
	var near_z := zombie(Vector3(2, 0, 0))
	var hp0: float = near_z.health
	for i in 14:
		_ev(&"enemy_killed", {"source": "gun", "target": null})
	var mid: float = near_z.health
	_ev(&"enemy_killed", {"source": "gun", "target": null})
	await wait(2)
	check(near(mid, hp0) and near_z.health < hp0, "Toll Counter (counter): the 15th kill rings a shockwave (%.0f -> %.0f)" % [hp0, near_z.health])

	# Reactive
	await reset({}, ["t_empty_cradle"])
	var ws0: float = player.walk_speed
	_ev(&"reload_finished", {"weapon": player.current_weapon()})
	var ws1: float = player.walk_speed
	var fr: float = player.mod_stat("fire_rate_mult", 1.0, {})
	for i in 200: # 3 s buff
		await physics_frame
	check(ws1 > ws0 * 1.1 and near(fr, 1.1) and near(player.walk_speed, ws0), "Empty Cradle (reactive): reload gives a 3 s speed + fire-rate burst that wears off (%.2f/%.2f/%.2f)" % [ws0, ws1, player.walk_speed])
