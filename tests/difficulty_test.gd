extends SceneTree
## Difficulty profiles (data/difficulty.json) + map assignment + reward scaling (Skillz).
##   godot --headless --path . -s res://tests/difficulty_test.gd   (exit code = failures)

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var D = load("res://scripts/world/difficulty.gd")
	var MR = load("res://scripts/world/map_registry.gd")
	var prog = root.get_node("Progress")
	var gear = root.get_node("GearDB")
	prog.save_path = "user://progress_difficulty_test.cfg"
	D.set_active("")

	# ------------------------------------------------------------ data + maps
	check(D.ids().has("easy") and D.ids().has("medium") and D.ids().has("hard") and D.default_id() == "easy", "profiles easy/medium/hard, default easy")
	var maps_ok := true
	for m in MR.list():
		maps_ok = maps_ok and D.is_valid(str(m.get("difficulty", "")))
	check(maps_ok, "every map in maps.json has a valid 'difficulty' field")
	check(D.for_map("arena") == "easy" and D.for_map("rustwell_foundry") == "medium" and D.for_map("drowned_cannery") == "hard",
		"Arena = easy, Rustwell Foundry = medium, Drowned Cannery = hard")
	check(D.for_map("no_such_map") == "easy", "unknown map / missing field -> default (easy)")
	var e: Dictionary = D.profile("easy")
	var neutral := true
	for k in e.wave:
		neutral = neutral and is_equal_approx(float(e.wave[k]), 1.0 if k.ends_with("_mult") else 0.0)
	check(neutral and D.xp_mult("easy") == 1.0 and D.loot_rarity_bias("easy") == 0.0 and D.rare_currency_drop_mult("easy") == 1.0,
		"easy is exactly the current tuning (all x1.0 / +0, rewards neutral)")
	check(D.active_id() == "easy" and D.xp_mult() == 1.0 and D.loot_rarity_bias() == 0.0, "nothing applied yet -> neutral default")
	var keys := ["health_mult", "health_ramp_mult", "speed_mult", "damage_mult", "count_mult", "count_ramp_mult"]
	var mono := true
	for k in keys:
		mono = mono and float(D.profile("easy").wave[k]) < float(D.profile("medium").wave[k]) and float(D.profile("medium").wave[k]) < float(D.profile("hard").wave[k])
	mono = mono and float(D.profile("hard").wave.spawn_interval_mult) < float(D.profile("medium").wave.spawn_interval_mult) \
		and float(D.profile("medium").wave.spawn_interval_mult) < 1.0
	check(mono, "wave pressure rises easy < medium < hard (HP, speed, damage, count, spawn rate)")
	var rew := true
	for f in ["xp_mult", "loot_rarity_bias", "rare_currency_drop_mult"]:
		rew = rew and D.call(f, "easy") < D.call(f, "medium") and D.call(f, "medium") < D.call(f, "hard")
	check(rew, "rewards rise easy < medium < hard (xp %.2f/%.2f/%.2f, rarity bias, rare currency)" % [D.xp_mult("easy"), D.xp_mult("medium"), D.xp_mult("hard")])

	# ------------------------------------------------------------ variants
	check(D.variant_share("soldier", 1, "easy") == 0.0 and D.variant_share("soldier", 1, "hard") > 0.0, "Hard: Soldiers from round 1 (Easy: from round 3)")
	var s3 := [D.variant_share("soldier", 3, "easy"), D.variant_share("soldier", 3, "medium"), D.variant_share("soldier", 3, "hard")]
	check(s3[0] < s3[1] and s3[1] < s3[2], "more Soldiers on harder profiles at round 3 (%.2f / %.2f / %.2f)" % s3)
	check(is_equal_approx(D.variant_share("soldier", 6, "easy"), 0.2), "easy mix unchanged vs zombies.json (r6 soldier 0.20)")
	var picks := {}
	for i in 400:
		var v: String = D.pick_variant(6, -1.0, "hard")
		picks[v] = int(picks.get(v, 0)) + 1
	check(int(picks.get("soldier", 0)) > 100, "pick_variant(hard) actually spawns more Soldiers (%s / 400)" % str(picks))

	# ------------------------------------------------------------ boss cadence
	check(D.boss_rounds(25, "easy") == [10, 20] and D.boss_rounds(25, "medium") == [8, 16, 24] and D.boss_rounds(25, "hard") == [6, 11, 16, 21],
		"boss rounds: easy 10/20, medium 8/16/24, hard 6/11/16/21")
	check(D.boss_count(6, "hard") == 1 and D.boss_count(11, "hard") == 2 and D.boss_count(21, "hard") == 3 and D.boss_count(7, "hard") == 0
		and D.boss_count(20, "easy") == 1, "boss count: hard 1 -> 2 -> 3 (capped), easy always 1")

	# ------------------------------------------------------------ rewards
	var bw: Array = D.bias_rarity_weights([1.0, 1.0, 1.0, 1.0, 1.0], 0.3)
	check(is_equal_approx(bw[0], 1.0) and absf(bw[4] - 2.8561) < 0.001 and D.bias_rarity_weights([5.0, 1.0], 0.0) == [5.0, 1.0],
		"rarity bias: tier weight x (1+bias)^tier, bias 0 unchanged")
	var w: Dictionary = gear.loot.tables.zombie.rarity_weights
	var avg := {}
	for id in ["easy", "hard"]:
		D.set_active(id)
		seed(1234)
		var t := 0
		for i in 3000:
			t += gear.roll_rarity(w, {}, 1)
		avg[id] = t / 3000.0
	check(avg.hard > avg.easy, "GearDB.roll_rarity reads the active profile (avg tier easy %.3f < hard %.3f)" % [avg.easy, avg.hard])
	D.set_active("hard")
	var raw: int = prog.xp_for_match(20, 5)
	var xp0: int = prog.xp
	var earned: int = prog.record_match(20, 5)
	check(earned == int(round(raw * 1.6)) and prog.xp == xp0 + earned, "record_match XP x1.6 on Hard (%d -> %d)" % [raw, earned])
	D.set_active("easy")
	check(prog.record_match(20, 5) == raw, "record_match XP unchanged on Easy (%d)" % raw)
	D.set_active("")

	# ------------------------------------------------------------ apply to the real main.gd exports
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	var main = current_scene
	main._break_timer = 9999.0
	var b := {"h": main.base_health, "hr": main.health_per_round, "n": main.first_round_zombies, "si": main.spawn_interval, "ma": main.max_alive}
	check(D.apply_to_main(main, "hard") == "hard" and main.base_health == int(round(b.h * 1.35)) and main.first_round_zombies == int(round(b.n * 1.3))
		and is_equal_approx(main.spawn_interval, b.si * 0.8) and main.max_alive == b.ma + 4, "apply_to_main(hard) scales main's wave exports (HP %d -> %d)" % [b.h, main.base_health])
	check(main._zombie_stats(1).health == main.base_health and D.active_id() == "hard", "main._zombie_stats picks up the scaled values; hard is active")
	D.apply_to_main(main, "hard")
	check(main.base_health == int(round(b.h * 1.35)), "applying twice doesn't compound")
	check(D.apply_to_main(main) == D.for_map(main.map_id) and main.base_health == b.h and main.health_per_round == b.hr, "apply_to_main() with no id uses the map's difficulty (arena = easy = base values)")
	D.set_active("")
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	print("DIFFICULTY TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
