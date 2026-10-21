extends SceneTree
## Scope overlay test (Gooey):  godot --headless --path . -s res://tests/scope_test.gd
## Real main.tscn with the G4M3N hooks applied: show/hide on every trigger (ADS on/off, death, swap, pause,
## return home), viewmodel visibility, HUD crosshair dim + centred hit marker, non-scoped weapons, Armory
## scope_overlay flag (Longwatch 6x on a Scout), fallback without the player hook, and resize / aspect ratios.
## Exit code = number of failures. Uses its own save file.

const SCOPE := "res://scripts/ui/scope_overlay.gd"

var _fails := 0
var _passes := 0
var main
var player
var inv
var ov
var gear
var settings


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func wait(frames: int) -> void:
	for i in frames:
		await process_frame


func wait_s(t: float) -> void:
	var end := Time.get_ticks_msec() + int(t * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func ads(on: bool) -> void:
	if on:
		Input.action_press("ads")
	else:
		Input.action_release("ads")
	await wait(4)


func give(arch: String):
	var w = gear.roll_weapon(arch, 2, 1)
	inv.add_item(w)
	inv.equip(w)
	inv.equip_weapon_slot(w.slot)
	await wait(2)
	return w


func scoped_ok() -> bool:
	return ov.active and ov.visible and not player.gun.visible


func unscoped_ok() -> bool:
	return not ov.active and player.gun.visible


func _run() -> void:
	var prog = root.get_node("Progress")
	gear = root.get_node("GearDB")
	settings = root.get_node_or_null("Settings")
	prog.save_path = "user://progress_scope_test.cfg"
	var old_mode := "hold"
	if settings:
		old_mode = str(settings.ads_mode)
		settings.ads_mode = "hold" # in memory only, never saved
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await process_frame
	main = current_scene
	main._break_timer = 9999.0
	player = main.get_node("Player")
	inv = player.inventory
	var hud = main.get_node("HUD")
	await wait(5)

	# ---------------------------------------------------------------- hooks present
	ov = main.get("scope_overlay")
	check(ov != null and ov.get_parent() == main and ov.name == "ScopeOverlay", "main.gd hook: ScopeOverlay created under Main")
	check(player.has_method("set_viewmodel_hidden") and "viewmodel_hidden_by_scope" in player, "player.gd hook: set_viewmodel_hidden + flag")
	check(hud.has_method("set_scoped"), "hud.set_scoped exists")
	check(ov.layer < hud.layer, "overlay sits under the HUD layer (HUD stays visible)")
	check(not ov.visible and not ov.active, "starts hidden")

	# ---------------------------------------------------------------- non-scoped weapons
	var S = load(SCOPE)
	var A = load("res://scripts/armory/armory.gd")
	A.unequip_slot("scout_rifle", "optic") # a fresh baseline even if the loaded save had Longwatch on
	for a in ["sidearm", "hand_cannon", "auto_rifle", "scout_rifle", "smg", "shotgun", "pulse_rifle", "rocket_launcher"]:
		if gear.get_archetype(a).is_empty() if gear.has_method("get_archetype") else false:
			continue
		var w = gear.roll_weapon(a, 2, 1)
		check(not S.weapon_wants_scope(w), "no scope for %s" % a)
	check(S.weapon_wants_scope(gear.roll_weapon("sniper_rifle", 2, 1)), "sniper_rifle wants the scope")
	check(not S.weapon_wants_scope(null), "null weapon: no scope")

	check(player.inventory.get_equipped_weapon() != null and player.inventory.get_equipped_weapon().archetype == "sidearm", "starter sidearm in hand")
	await ads(true)
	check(player.ads_active, "sidearm ADS active")
	check(not ov.active and not ov.visible and player.gun.visible, "sidearm ADS: no overlay, viewmodel visible")
	await ads(false)
	var ar = await give("auto_rifle")
	await ads(true)
	check(player.ads_active and not ov.active and player.gun.visible, "auto_rifle ADS: no overlay")
	await ads(false)

	# ---------------------------------------------------------------- sniper: show / hide on ADS
	var sn = await give("sniper_rifle")
	check(inv.get_equipped_weapon() == sn, "sniper in hand")
	await wait_s(sn.swap_time() + 0.05)
	await ads(true)
	check(player.ads_active, "sniper ADS active")
	check(scoped_ok(), "sniper ADS: overlay up, viewmodel hidden")
	check(player.viewmodel_hidden_by_scope, "player flag set while scoped")
	check(hud.scoped, "HUD scoped flag on")
	var dim_ok := true
	for c in hud._cross_parts:
		dim_ok = dim_ok and c.modulate.a < 0.5
	check(dim_ok and hud._cross_parts.size() >= 9, "crosshair ticks + dot dimmed (%d parts)" % hud._cross_parts.size())
	check(hud._hit_marker.modulate.a > 0.99 and hud._hit_marker.visible, "hit marker not dimmed")
	var vs: Vector2 = hud.get_viewport().get_visible_rect().size
	var hm_c: Vector2 = hud._hit_marker.get_global_rect().get_center()
	check(hm_c.distance_to(vs * 0.5) < 1.5, "hit marker centred while scoped (%s vs %s)" % [hm_c, vs * 0.5])
	hud.on_hit_registered(null, 10.0, false, false)
	await wait(2)
	check(hud._hit_marker.visible, "hit marker shows during scope")
	await wait_s(0.16)
	check(is_equal_approx(ov._root.modulate.a, 1.0), "fade in completes in ~0.1 s (a=%.2f)" % ov._root.modulate.a)
	await ads(false)
	check(unscoped_ok() and not player.viewmodel_hidden_by_scope and not hud.scoped, "ADS off: overlay down, viewmodel + crosshair back")
	await wait_s(0.16)
	check(not ov.visible and ov._root.modulate.a < 0.01, "fade out completes and layer hides")

	# ---------------------------------------------------------------- swap
	await ads(true)
	check(scoped_ok(), "re-scope")
	inv.equip_weapon_slot(ar.slot)
	await wait(2)
	check(inv.get_equipped_weapon() == ar, "swapped to auto_rifle")
	check(not ov.active and not ov.visible and player.gun.visible, "swap: overlay hidden instantly, viewmodel back")
	await wait_s(ar.swap_time() + 0.1)
	check(not ov.active, "non-scoped weapon after swap stays unscoped")
	inv.equip_weapon_slot(sn.slot)
	await wait(2)
	check(not ov.active and player.gun.visible, "swap back to sniper: not scoped during swap")
	await wait_s(sn.swap_time() + 0.15)
	check(player.ads_active and scoped_ok(), "still holding ADS after swap: scope returns after swap time")

	# ---------------------------------------------------------------- pause
	paused = true
	await wait(3)
	check(not ov.active and not ov.visible and player.gun.visible and not hud.scoped, "pause: overlay hidden, viewmodel + crosshair restored")
	paused = false
	await wait(4)
	check(scoped_ok(), "unpause with ADS held: scope back")
	await ads(false)
	check(unscoped_ok(), "ADS off")
	if main.get("pause_menu") and main.pause_menu.has_method("open"):
		await ads(true)
		main.pause_menu.open()
		await wait(3)
		check(not ov.active and player.gun.visible, "pause menu open: overlay hidden")
		if main.pause_menu.has_method("close"):
			main.pause_menu.close()
		paused = false
		await ads(false)
		await wait(3)

	# ---------------------------------------------------------------- Armory scope flag (Longwatch 6x on Scout)
	var api = A.new()
	prog.add_gravemark(500, "test")
	for i in 4:
		api.purchase("upg_scout_rifle")
	var lw_ok: bool = api.purchase("longwatch_6x") and api.equip_attachment("scout_rifle", "optic", "longwatch_6x")
	check(lw_ok, "Longwatch 6x bought + equipped on scout_rifle")
	var sc = await give("scout_rifle")
	check(S.weapon_wants_scope(sc), "scout + Longwatch: Armory scope flag -> wants scope")
	await wait_s(sc.swap_time() + 0.05)
	await ads(true)
	check(scoped_ok(), "scout + Longwatch ADS: overlay up")
	check(ov.reticle_id == "longwatch_mil" and is_equal_approx(ov.lens_radius, 0.42), "Longwatch 6x: fine mil-dot reticle, lens 0.42 (%s)" % ov.reticle_id)
	check(is_equal_approx(ov.sway_amount, load("res://scripts/combat/ads_profile.gd").overlay_sway("scout_rifle")), "overlay sway follows AdsProfile.overlay_sway (%.4f)" % ov.sway_amount)
	await ads(false)
	check(unscoped_ok(), "scout ADS off")
	api.unequip("scout_rifle", "optic")
	check(not S.weapon_wants_scope(sc), "Longwatch removed: scout no longer scoped")
	# per-optic reticles (GOOEY_OPTICS §4): factory scope / Longwatch / Belfry; pending model keeps the factory scope
	check(S.reticle_for({"optic_id": "", "reticle_id": "factory_scope"}) == "factory_scope", "factory scope row → factory_scope")
	check(S.reticle_for({"optic_id": "belfry_8x", "reticle_id": "belfry_post"}) == "belfry_post", "Belfry 8x → belfry_post")
	check(S.reticle_for({"optic_id": "belfry_8x", "reticle_id": "belfry_post", "fallback": true}) == "factory_scope", "model not shipped (fallback) → factory scope overlay")
	check(S.reticle_for({"optic_id": "x", "reticle_id": "mystery"}) == "factory_scope", "unknown reticle_id → factory_scope")
	var bp: Dictionary = A.optic_profile("sniper_rifle", "belfry_8x")
	check(bool(bp.overlay) and S.reticle_for(bp) == ("factory_scope" if bool(bp.fallback) else "belfry_post"), "sniper + Belfry preview: overlay with %s" % S.reticle_for(bp))
	ov.set_reticle("belfry_post")
	check(is_equal_approx(ov.lens_radius, 0.38) and is_equal_approx(float(ov._mat.get_shader_parameter("soft_frac")), 0.016) and (ov._mat.get_shader_parameter("rim_color") as Color).a > 0.3, "Belfry: tunnel lens 0.38, soft 0.016, brass rim")
	check(ov._halo != null and ov._halo.material is CanvasItemMaterial and (ov._halo.material as CanvasItemMaterial).blend_mode == CanvasItemMaterial.BLEND_MODE_ADD, "Belfry lantern dot halo is additive")
	ov.set_reticle("factory_scope")
	check(is_equal_approx(ov.lens_radius, S.LENS_RADIUS) and (ov._mat.get_shader_parameter("rim_color") as Color).a == 0.0, "factory scope: lens 0.44, no rim")

	# ---------------------------------------------------------------- death
	inv.equip_weapon_slot(sn.slot)
	await wait_s(sn.swap_time() + 0.1)
	await ads(true)
	check(scoped_ok(), "scoped before death")
	player.take_damage(999999.0)
	await wait(4)
	check(player.dead, "player died")
	check(not ov.active and not ov.visible and not player.viewmodel_hidden_by_scope, "death: overlay hidden, viewmodel flag cleared")
	await ads(false)
	await wait(2)
	ov.show_scope() # make sure force_hide on return home has something to clear
	await wait(1)
	check(ov.active, "(forced up for return-home check)")

	# ---------------------------------------------------------------- return home
	main.return_to_home()
	check(not ov.active and not ov.visible and not player.viewmodel_hidden_by_scope, "return_to_home: force_hide before the scene change")
	for i in 240:
		if current_scene != main and current_scene != null:
			break
		await process_frame
	check(current_scene != null and current_scene.scene_file_path.ends_with("home.tscn"), "home scene loaded (%s)" % (current_scene.scene_file_path if current_scene else "null"))

	# ---------------------------------------------------------------- fallback without the player hook + resize
	await _standalone_checks(S)

	if settings:
		settings.ads_mode = old_mode
	print("scope_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


func _standalone_checks(S) -> void:
	var stub_src := GDScript.new()
	stub_src.source_code = """extends Node
signal ads_changed(active: bool)
signal died
signal weapon_changed(w)
var gun := Node3D.new()
var inventory
var ads_active := false
var dead := false
var velocity := Vector3.ZERO
"""
	stub_src.reload()
	var inv_src := GDScript.new()
	inv_src.source_code = "extends RefCounted\nvar w\nfunc get_equipped_weapon():\n\treturn w\n"
	inv_src.reload()
	var stub = stub_src.new()
	stub.inventory = inv_src.new()
	stub.inventory.w = gear.roll_weapon("sniper_rifle", 2, 1)
	stub.add_child(stub.gun)
	root.add_child(stub)

	for res in [Vector2i(1280, 720), Vector2i(800, 1280), Vector2i(3440, 1440), Vector2i(640, 480)]:
		var svp := SubViewport.new()
		svp.size = res
		svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(svp)
		var o = S.new()
		o.sway_enabled = false
		svp.add_child(o)
		await wait(2)
		var vs := Vector2(res)
		var short := minf(vs.x, vs.y)
		check(is_equal_approx(o.lens_radius_px(), S.LENS_RADIUS * short), "%dx%d: lens radius = %.0f px (short side)" % [res.x, res.y, o.lens_radius_px()])
		check(o._mat.get_shader_parameter("view_size") == vs, "%dx%d: shader view_size" % [res.x, res.y])
		check(o._lens.get_rect().size == vs and o._reticle.get_rect().size == vs, "%dx%d: lens + reticle fill the screen" % [res.x, res.y])
		check(o.lens_radius_px() * 2.0 <= short + 0.01, "%dx%d: lens fits inside the screen" % [res.x, res.y])
		# resize live
		svp.size = Vector2i(res.y, res.x)
		await wait(2)
		check(o._mat.get_shader_parameter("view_size") == Vector2(res.y, res.x), "%dx%d -> %dx%d: resize updates shader" % [res.x, res.y, res.y, res.x])
		if res == Vector2i(1280, 720):
			o.bind(stub, null)
			stub.ads_active = true
			stub.ads_changed.emit(true)
			check(o.active and not stub.gun.visible, "no player hook: overlay hides player.gun directly")
			stub.ads_changed.emit(false)
			check(not o.active and stub.gun.visible, "no player hook: gun restored")
			stub.ads_changed.emit(true)
			stub.died.emit()
			check(not o.active and stub.gun.visible, "stub died: hidden")
			o.sway_enabled = true
			stub.ads_changed.emit(true)
			stub.velocity = Vector3(5, 0, 0)
			await wait_s(0.6)
			var moving: float = o.sway_offset.length()
			check(moving > 0.0 and moving <= short * o.sway_amount * 1.5, "sway drift small while moving (%.2f px)" % moving)
			stub.velocity = Vector3.ZERO
			await wait_s(0.8)
			check(o.sway_offset.length() <= short * o.sway_amount * o.sway_still_mult * 1.6, "sway reduced while still (%.2f px)" % o.sway_offset.length())
			o.sway_enabled = false
			await wait_s(0.6)
			check(o.sway_offset.length() < 0.5, "sway_enabled=false: no drift")
			stub.ads_changed.emit(false)
		svp.queue_free()
	stub.queue_free()
	await wait(2)
