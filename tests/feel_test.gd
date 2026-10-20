extends SceneTree
## Playtest 2026-10-20 feel fixes (G4M3N): #1 muzzle flash, #5 ADS crosshair, #6 swap auto-reload, #7 wheel swap,
## #3 hold-E equip, #18 loot '!' only for Rare+ / upgrades.
##   godot --headless --path . -s res://tests/feel_test.gd

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


func secs(t: float) -> void:
	await create_timer(t).timeout


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var progress = root.get_node("Progress")
	progress.save_path = "user://progress_feel_test.cfg"
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	var main = current_scene
	main._break_timer = 9999.0
	var player = main.get_node("Player")
	await wait(10)

	# ---------------------------------------------------------------- #1 muzzle flash
	var fq := player.get_node("Head/Camera3D/Gun/Muzzle/Flash/FlashQuad") as MeshInstance3D
	var fl := player.get_node("Head/Camera3D/Gun/Muzzle/Flash/FlashLight") as OmniLight3D
	var qm := fq.mesh as QuadMesh
	var mat := qm.material as StandardMaterial3D
	check(qm.size.x <= 0.08 and qm.size.y <= 0.08, "#1 flash sprite smaller (%s, was 0.12)" % qm.size)
	check(mat.emission_energy_multiplier <= 2.0 and mat.albedo_color.a <= 0.8, "#1 flash sprite dimmer (emission %.1f, was 4)" % mat.emission_energy_multiplier)
	check(fl.light_energy <= 1.5 and fl.omni_range <= 3.0, "#1 flash light dimmer / shorter (energy %.1f range %.1f, was 3 / 4)" % [fl.light_energy, fl.omni_range])
	check(fl.get_parent() == player.flash and fq.get_parent() == player.flash, "#1 one flash node shared by every gun")

	# ---------------------------------------------------------------- #5 no crosshair while ADS
	var hud = main.hud
	check(hud.has_method("set_ads") and player.is_connected("ads_changed", hud.set_ads), "#5 hud listens to player.ads_changed")
	var all_vis := func(v: bool) -> bool:
		return hud._cross_parts.all(func(c): return c.visible == v)
	check(not hud.ads_hidden and all_vis.call(true), "#5 hip: crosshair visible")
	Input.action_press(load("res://scripts/combat/ads_profile.gd").input_action())
	await wait(6)
	check(player.ads_active and hud.ads_hidden and all_vis.call(false), "#5 ADS (irons): crosshair ticks + dot hidden")
	check(hud._hit_marker.visible, "#5 ADS: the hit marker still draws")
	Input.action_release(load("res://scripts/combat/ads_profile.gd").input_action())
	await wait(6)
	check(not player.ads_active and all_vis.call(true), "#5 leaving ADS brings the crosshair back")
	hud.set_scoped(true)
	hud.set_ads(true)
	check(all_vis.call(false), "#5 scoped optics: hidden too")
	hud.set_ads(false)
	hud.set_scoped(false)

	# ---------------------------------------------------------------- #6 swap to an empty gun auto-reloads
	var inv = player.inventory
	inv.equip_weapon_slot("primary")
	await wait(3)
	var sec = inv.equipped.secondary
	sec.ammo = 0
	sec.reserve = 40
	inv.equip_weapon_slot("secondary")
	await wait(2)
	check(not player._reloading, "#6 reload waits for the swap (raise) time")
	await secs(sec.swap_time() + 0.15)
	check(player._reloading and player.current_weapon() == sec, "#6 swapping to an empty mag with reserve starts the reload")
	await secs(sec.reload_time() * float(player.reload_multiplier) + 0.5)
	check(sec.ammo > 0, "#6 ... and it finishes (ammo %d)" % sec.ammo)
	var pri = inv.equipped.primary
	pri.ammo = 0
	pri.reserve = 0
	inv.equip_weapon_slot("primary")
	await secs(pri.swap_time() + 0.2)
	check(not player._reloading, "#6 no reload with no reserve")
	sec.ammo = 0
	sec.reserve = 40
	inv.equip_weapon_slot("secondary")
	await wait(2)
	inv.equip_weapon_slot("primary")
	await secs(sec.swap_time() + 0.2)
	check(not player._reloading and player.current_weapon() == pri, "#6 swapping away before the raise cancels it")
	pri.reserve = 50
	pri.ammo = pri.mag_size()
	sec.ammo = sec.mag_size()

	#SECTIONS

	print("feel_test: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
