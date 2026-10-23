extends SceneTree
## Boss catalog, cadence, HP, payouts, telegraph constants (Skillz).
##   godot --headless --path . -s res://tests/boss_test.gd

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var B = load("res://scripts/enemies/boss_catalog.gd")
	var D = load("res://scripts/world/difficulty.gd")
	B.reload()
	D.set_active("")

	# ------------------------------------------------------------ data shape
	var ids: Array = B.ids()
	check(ids.has("bellwether") and ids.has("choir_host") and ids.has("lantern_stalker") and ids.size() == 3,
		"three original bosses: Bellwether, Choir Host, Lantern Stalker")
	check(B.display_name("bellwether") == "Bellwether" and B.display_name("choir_host") == "Choir Host"
		and B.display_name("lantern_stalker") == "Lantern Stalker", "display names match design")
	check(is_equal_approx(float(B.get_boss("bellwether").legacy_hp_mult), 8.0)
		and is_equal_approx(float(B.get_boss("choir_host").legacy_hp_mult), 5.0)
		and is_equal_approx(float(B.get_boss("lantern_stalker").legacy_hp_mult), 4.5), "legacy_hp_mult 8 / 5 / 4.5 kept for reference (HP is TTK-driven now)")
	check(is_equal_approx(float(B.echo_cfg().hp_mult), 0.15), "Choir echo adds 0.15x HP (squishy: the threat is the swarm, not a DPS sink)")

	# ------------------------------------------------------------ telegraph constants
	var bt: Dictionary = B.telegraph("bellwether")
	var ct: Dictionary = B.telegraph("choir_host")
	var lt: Dictionary = B.telegraph("lantern_stalker")
	check(is_equal_approx(float(bt.slam_windup), 1.2), "Bellwether slam windup 1.2s")
	check(is_equal_approx(float(bt.enrage_hp_frac), 0.5), "Bellwether enrages at 50% HP")
	check(is_equal_approx(float(ct.shield_hp_frac), 0.3), "Choir shield = 30% HP")
	check(int(ct.echo_count_min) == 2 and int(ct.echo_count_max) == 3, "Choir spawns 2–3 echoes")
	check(is_equal_approx(float(lt.beam_windup), 0.8), "Lantern beam windup 0.8s")

	# ------------------------------------------------------------ HP formula
	# Round 10 normal = 90 + 35*9 = 405
	check(B.normal_hp(10) == 405 and B.normal_hp(1) == 90, "normal HP round 1=90, round 10=405")
	check(B.echo_hp(10) == 61, "echo r10 HP = round(405*0.15)=61 (%d)" % B.echo_hp(10))
	var T: Dictionary = B.tuning()
	for id in ids:
		var ttk := float(B.get_boss(id).ttk)
		var want := int(round(B.ref_dps(10) * ttk * B.dps_eff(id)))
		check(B.boss_hp(id, 10, 90, 35, "easy") == want, "%s r10 easy HP = ref_dps x ttk x dps_eff = %d" % [id, want])
		check(B.boss_hp(id, 10, 90, 35, "easy") >= int(B.normal_hp(10) * float(B.get_boss(id).legacy_hp_mult) * 1.3),
			"%s r10 easy HP is >= 1.3x the pre-rework HP (playtest #15: WAY harder)" % id)
		# difficulty ladder: HP, damage, enrage, adds, cooldowns all go the right way
		var hp_e: int = B.boss_hp(id, 10, 90, 35, "easy")
		var hp_m: int = B.boss_hp(id, 10, 90, 35, "medium")
		var hp_h: int = B.boss_hp(id, 10, 90, 35, "hard", 1, 1)
		check(hp_e < hp_m and hp_m < hp_h, "%s HP rises easy < medium < hard (%d/%d/%d)" % [id, hp_e, hp_m, hp_h])
		check(B.hit_damage(id, "melee", 10, "easy") < B.hit_damage(id, "melee", 10, "hard"), "%s melee damage rises with difficulty" % id)
		check(B.enrage_time(id, "easy") > B.enrage_time(id, "medium") and B.enrage_time(id, "medium") > B.enrage_time(id, "hard"),
			"%s enrage timer shortens with difficulty" % id)
		# co-op: HP x (1 + 1.1 per extra player), exactly
		var p1: int = B.boss_hp(id, 10, 90, 35, "easy", 1)
		var p4: int = B.boss_hp(id, 10, 90, 35, "easy", 4)
		check(abs(p4 - int(round(p1 * 4.3))) <= 2, "%s 4 players = %d HP (x4.3 of %d)" % [id, p4, p1])
		check(B.boss_hp(id, 10, 90, 35, "easy", 2) > p1 and B.boss_hp(id, 10, 90, 35, "easy", 2) < p4, "%s HP monotonic in players" % id)
		# multi-boss rounds: each boss has less HP than a lone boss on the same difficulty, total HP still higher
		var one: int = B.boss_hp(id, 11, 90, 35, "hard", 1, 1)
		var two: int = B.boss_hp(id, 11, 90, 35, "hard", 1, 2)
		var three: int = B.boss_hp(id, 11, 90, 35, "hard", 1, 3)
		check(two < one and three < two and two * 2 > one and three * 3 > one, "%s multi-boss HP split %d / %d / %d" % [id, one, two, three])
		# stages and damage fractions
		var stg: Array = B.get_boss(id).stages
		check(stg.size() == 2 and float(stg[0]) > float(stg[1]), "%s has 2 HP stage thresholds (3 phases)" % id)
		check(B.stage_for(id, 1.0) == 0 and B.stage_for(id, float(stg[0]) - 0.01) == 1 and B.stage_for(id, float(stg[1]) - 0.01) == 2
			and B.stage_for(id, 0.0) == 2, "%s stage_for thresholds" % id)
		check(B.hit_damage(id, "melee", 10, "easy", true) > B.hit_damage(id, "melee", 10, "easy"), "%s Frenzy raises damage" % id)
		check(B.cooldown_mult("easy", 1, true, id) < B.cooldown_mult("easy", 1, false, id), "%s Frenzy shortens cooldowns" % id)
		var worst := 0
		for k in B.get_boss(id).damage:
			worst = maxi(worst, B.hit_damage(id, str(k), 10, "hard"))
		check(worst < 100, "%s no single hit one-shots a 100 HP player on hard (max %d)" % [id, worst])
	check(B.hit_damage("bellwether", "slam", 10, "easy") >= 50, "Bellwether slam is a real threat (>= 50 on easy r10: %d)" % B.hit_damage("bellwether", "slam", 10, "easy"))
	check(B.hit_damage("bellwether", "slam", 10, "hard") > B.hit_damage("bellwether", "slam", 10, "medium")
		and B.hit_damage("bellwether", "slam", 10, "medium") > B.hit_damage("bellwether", "slam", 10, "easy"), "Bellwether slam rises with difficulty")
	# round slope: later rounds hit harder, never below the floor
	check(B.hit_damage("bellwether", "slam", 21, "medium") > B.hit_damage("bellwether", "slam", 11, "medium")
		and B.hit_damage("bellwether", "slam", 1, "easy") >= int(round(float(B.get_boss("bellwether").damage.slam) * 100.0 * 0.7)) - 1,
		"damage round slope + floor")
	# adds: scale with difficulty and party, capped
	check(B.adds_count(2.0, "easy", 1) == 2 and B.adds_count(4.0, "hard", 1) > B.adds_count(4.0, "easy", 1) and B.adds_count(2.0, "easy", 4) == 5,
		"adds_count: easy 2, hard > easy, 4 players 5 (%d/%d/%d)" % [B.adds_count(2.0, "easy", 1), B.adds_count(4.0, "hard", 1), B.adds_count(2.0, "easy", 4)])
	check(B.adds_cap(1) == 6 and B.adds_cap(2) == 8 and B.adds_cap(4) == 12 and B.adds_cap(8) == 12, "add cap 6 / 8 / 12, hard max 12")
	check(B.cooldown_mult("easy", 4) < B.cooldown_mult("easy", 1) and B.cooldown_mult("easy", 8) >= 0.75 - 0.001, "co-op cuts cooldowns, floored 0.75")
	var bud: Dictionary = B.budgets("easy")
	check(bud.has("ttk_min") and bud.has("ttk_max") and bud.has("damage_max"), "sim budgets present for easy")
	for d in ["easy", "medium", "hard"]:
		var bb: Dictionary = B.budgets(d)
		check(float(bb.ttk_min) < float(bb.ttk_max) and float(bb.damage_max) < 400.0, "%s budget sane (ttk %s-%s, dmg <= %s)" % [d, bb.ttk_min, bb.ttk_max, bb.damage_max])
	# nominal TTK (HP / (ref_dps x dps_eff)) sits inside every difficulty's budget window for every boss
	for d in ["easy", "medium", "hard"]:
		for id in ids:
			var nt: float = B.ttk_target(id, 10, d)
			var bb2: Dictionary = B.budgets(d)
			check(nt >= float(bb2.ttk_min) and nt <= float(bb2.ttk_max), "%s %s nominal TTK %.0fs inside budget %s-%s" % [id, d, nt, bb2.ttk_min, bb2.ttk_max])
	# Frenzy lands before the budget ceiling (an enrage timer that never fires is no enrage)
	for d in ["easy", "medium", "hard"]:
		for id in ids:
			check(B.enrage_time(id, d) < float(B.budgets(d).ttk_max) * 2.2 and B.enrage_time(id, d) > float(B.budgets(d).ttk_max) * 0.75,
				"%s %s Frenzy at %.0fs (budget ttk_max %s)" % [id, d, B.enrage_time(id, d), B.budgets(d).ttk_max])
	# supply drop (ammo for a boss-sized HP pool)
	check(str(T.supply_drop.item) == "ammo_box" and int(T.supply_drop.count_per_player) >= 1, "stage supply drop configured")

	# ------------------------------------------------------------ payouts (halved economy: 50 kill)
	check(B.kill_points("bellwether", 50) == 400, "Bellwether kill = 8x50 = 400")
	check(B.kill_points("choir_host", 50) == 300, "Choir Host kill = 6x50 = 300")
	check(B.kill_points("lantern_stalker", 50) == 250, "Lantern kill = 5x50 = 250")
	check(B.gravemark_reward("bellwether") == 2 and B.gravemark_reward("choir_host") == 2
		and B.gravemark_reward("lantern_stalker") == 3, "Gravemark 2 / 2 / 3")
	check(B.gravemark_scaled("lantern_stalker", "easy") == 3
		and B.gravemark_scaled("lantern_stalker", "hard") == int(round(3.0 * 1.75)),
		"Gravemark scales with Difficulty.rare_currency_drop_mult")

	# ------------------------------------------------------------ cadence via Difficulty
	check(D.boss_rounds(25, "easy") == [10, 20], "easy boss rounds 10/20")
	check(D.is_boss_round(10, "easy") and not D.is_boss_round(9, "easy"), "is_boss_round easy")
	check(D.boss_count(10, "easy") == 1 and D.boss_count(11, "hard") == 2 and D.boss_count(21, "hard") == 3,
		"boss_count easy=1, hard r11=2, r21=3")

	# ------------------------------------------------------------ roster rules
	check(B.pick_roster(9, "easy") == [], "non-boss round -> empty roster")
	check(B.pick_roster(10, "easy") == ["bellwether"], "easy first cadence: Bellwether solo")
	check(B.pick_roster(20, "easy") == ["choir_host"], "easy second cadence solo: Choir Host alternate")
	check(B.pick_roster(8, "medium") == ["bellwether"], "medium first: Bellwether")
	check(B.pick_roster(16, "medium") == ["choir_host"], "medium second solo: Choir Host (alt index 0)")
	check(B.pick_roster(24, "medium") == ["lantern_stalker"], "medium third solo: Lantern (alt index 1)")
	check(B.pick_roster(6, "hard") == ["bellwether"], "hard r6 count1: Bellwether")
	check(B.pick_roster(11, "hard") == ["bellwether", "choir_host"], "hard r11: Bellwether + Choir Host")
	check(B.pick_roster(21, "hard") == ["bellwether", "choir_host", "lantern_stalker"],
		"hard r21: all three")

	# ------------------------------------------------------------ scripts load / constants on instances
	for id in ["bellwether", "choir_host", "lantern_stalker"]:
		var path: String = B.script_path(id)
		check(ResourceLoader.exists(path), "script exists for %s (%s)" % [id, path])
		var scr = load(path)
		var ok: bool = scr != null and scr.can_instantiate()
		check(ok, "script loads and compiles for %s" % id)

	# Telegraph helper + spit compile
	check(load("res://scripts/enemies/boss_telegraph.gd") != null, "boss_telegraph.gd loads")
	check(load("res://scripts/enemies/blight_spit.gd") != null, "blight_spit.gd loads")
	check(load("res://scripts/enemies/boss_common.gd") != null, "boss_common.gd loads")

	# Choir shield: ref_dps x shield_secs (x stage, x party) -- a break window, not a % of HP
	var sh: float = B.ref_dps(10) * float(ct.shield_secs)
	check(sh > 300.0 and sh < float(B.boss_hp("choir_host", 10, 90, 35, "easy")) * 0.15, "Choir shield pool %.0f = a few seconds of DPS, < 15%% of HP" % sh)

	# Cycle index
	check(B.boss_cycle_index(10, "easy") == 0 and B.boss_cycle_index(20, "easy") == 1
		and B.boss_cycle_index(9, "easy") == -1, "boss_cycle_index")

	print("boss_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
