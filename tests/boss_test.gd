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
	check(is_equal_approx(float(B.get_boss("bellwether").hp_mult), 8.0)
		and is_equal_approx(float(B.get_boss("choir_host").hp_mult), 5.0)
		and is_equal_approx(float(B.get_boss("lantern_stalker").hp_mult), 4.5), "hp_mult 8 / 5 / 4.5")
	check(is_equal_approx(float(B.echo_cfg().hp_mult), 0.4), "Choir echo adds 0.4x HP")

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
	check(B.boss_hp("bellwether", 10, 90, 35, "easy") == 3240, "Bellwether r10 easy HP = 405*8 = 3240")
	check(B.boss_hp("choir_host", 10, 90, 35, "easy") == 2025, "Choir Host r10 easy HP = 405*5 = 2025")
	check(B.boss_hp("lantern_stalker", 10, 90, 35, "easy") == 1823, "Lantern r10 easy HP = round(405*4.5)=1823")
	check(B.echo_hp(10) == 162, "echo r10 HP = round(405*0.4)=162")
	var hard_bw: int = B.boss_hp("bellwether", 10, 90, 35, "hard")
	check(hard_bw == int(round(405.0 * 8.0 * 1.3)), "Bellwether r10 hard applies Difficulty boss hp_mult 1.3 (%d)" % hard_bw)

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

	# Choir shield math (pure): 30% of boss HP
	var ch_hp: int = B.boss_hp("choir_host", 10, 90, 35, "easy")
	check(int(round(ch_hp * 0.3)) == int(round(2025 * 0.3)), "Choir shield pool = 30%% of %d" % ch_hp)

	# Cycle index
	check(B.boss_cycle_index(10, "easy") == 0 and B.boss_cycle_index(20, "easy") == 1
		and B.boss_cycle_index(9, "easy") == -1, "boss_cycle_index")

	print("boss_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
