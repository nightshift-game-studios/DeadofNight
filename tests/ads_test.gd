extends SceneTree
## ADS profile tables + mode resolution (Skillz). No player.gd required.
##   godot --headless --path . -s res://tests/ads_test.gd

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
	var A = load("res://scripts/combat/ads_profile.gd")

	check(is_equal_approx(A.HIP_FOV, 75.0), "hip FOV 75")
	check(is_equal_approx(A.SPREAD_MULT, 0.45), "ADS spread_mult 0.45")
	check(is_equal_approx(A.MOVE_SPEED_MULT, 0.7), "ADS move_speed_mult 0.7")

	check(A.family_for_archetype("sidearm") == "sidearm" and A.family_for_archetype("smg") == "smg", "sidearm/smg families")
	check(A.family_for_archetype("auto_rifle") == "rifle" and A.family_for_archetype("scout_rifle") == "rifle"
		and A.family_for_archetype("pulse_rifle") == "rifle", "rifles -> rifle family")
	check(A.family_for_archetype("shotgun") == "shotgun" and A.family_for_archetype("sniper_rifle") == "sniper",
		"shotgun / sniper families")
	check(A.family_for_archetype("unknown_gun") == "rifle", "unknown archetype defaults to rifle")

	check(is_equal_approx(A.ads_fov("sidearm"), 65.0) and is_equal_approx(A.ads_fov("smg"), 65.0), "sidearm/smg ADS FOV 65")
	check(is_equal_approx(A.ads_fov("auto_rifle"), 55.0), "rifle ADS FOV 55")
	check(is_equal_approx(A.ads_fov("shotgun"), 60.0), "shotgun ADS FOV 60")
	check(is_equal_approx(A.ads_fov("sniper_rifle"), 35.0), "sniper ADS FOV 35")

	check(is_equal_approx(A.spread_mult(true), 0.45) and is_equal_approx(A.spread_mult(false), 1.0), "spread_mult toggles")
	check(is_equal_approx(A.move_speed_mult(true), 0.7) and is_equal_approx(A.move_speed_mult(false), 1.0), "move_speed_mult toggles")
	check(is_equal_approx(A.target_fov(false, "sniper_rifle", 75.0), 75.0)
		and is_equal_approx(A.target_fov(true, "sniper_rifle", 75.0), 35.0), "target_fov hip vs ADS")

	check(A.resolve_mode(null) == "hold", "missing Settings -> hold")
	var fake_hold := {"ads_mode": "hold"}
	var fake_toggle := {"ads_mode": "toggle"}
	var fake_bad := {"ads_mode": "nope"}
	check(A.resolve_mode(fake_hold) == "hold" and A.resolve_mode(fake_toggle) == "toggle"
		and A.resolve_mode(fake_bad) == "hold", "resolve_mode hold|toggle|fallback")

	# Hold mode
	check(A.next_ads_state(false, "hold", true, true) == true, "hold: press -> ads on")
	check(A.next_ads_state(true, "hold", true, false) == true, "hold: held -> stays on")
	check(A.next_ads_state(true, "hold", false, false) == false, "hold: release -> ads off")

	# Toggle mode
	check(A.next_ads_state(false, "toggle", true, true) == true, "toggle: just_pressed off->on")
	check(A.next_ads_state(true, "toggle", true, false) == true, "toggle: held does not flip")
	check(A.next_ads_state(true, "toggle", false, false) == true, "toggle: release keeps ads")
	check(A.next_ads_state(true, "toggle", true, true) == false, "toggle: just_pressed on->off")

	check(A.wants_scope_overlay("sniper_rifle") and not A.wants_scope_overlay("smg"), "scope overlay only for sniper")
	check(A.INPUT_ACTION == "ads" and A.FALLBACK_ACTION == "aim", "input ads with aim fallback")

	# Settings autoload if present
	var s := root.get_node_or_null("Settings")
	if s:
		check(A.resolve_mode(s) in ["hold", "toggle"], "live Settings.ads_mode readable")
		if s.has_method("set_ads_mode"):
			s.set_ads_mode("toggle")
			check(A.resolve_mode(s) == "toggle", "Settings set_ads_mode toggle")
			s.set_ads_mode("hold")
			check(A.resolve_mode(s) == "hold", "Settings set_ads_mode hold")
	else:
		check(true, "Settings autoload absent in this run (skipped live checks)")

	print("ads_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
