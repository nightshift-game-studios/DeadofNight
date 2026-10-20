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


## Wall-clock wait past the wheel debounce (the gun swap's view-model build can stall frames).
func past_debounce(player) -> void:
	while Time.get_ticks_msec() / 1000.0 - player._wheel_swap_at < player.WHEEL_SWAP_DEBOUNCE + 0.02:
		await process_frame


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

	# ---------------------------------------------------------------- #7 mouse wheel cycles weapons
	inv.equip_weapon_slot("primary")
	await secs(0.3)
	# (headless can't capture the mouse, and player._unhandled_input spends an uncaptured click on capturing it,
	#  so drive wheel_swap() directly, the same call the wheel branch makes)
	var src := FileAccess.get_file_as_string("res://scripts/player.gd")
	check(src.contains("MOUSE_BUTTON_WHEEL_DOWN else -1)") and src.contains("wheel_swap(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN"),
		"#7 _unhandled_input: wheel down -> +1, wheel up -> -1")
	player._wheel_swap_at = -10.0
	check(inv.cycle_weapon_item(1) == sec and inv.cycle_weapon_item(-1) == sec, "#7 Inventory.cycle_weapon_item by item (2 guns, heavy empty skipped)")
	check(player.wheel_swap(1) and player.current_weapon() == sec, "#7 wheel down -> next weapon (secondary)")
	var again: bool = player.wheel_swap(1)
	check(not again and player.current_weapon() == sec, "#7 a second notch inside the debounce is ignored (again=%s cur=%s)" % [again, player.current_weapon().archetype])
	await past_debounce(player)
	check(player.wheel_swap(-1) and player.current_weapon() == pri, "#7 wheel up -> previous weapon (primary)")
	await past_debounce(player)
	check(player.wheel_swap(-1) and player.current_weapon() == sec, "#7 wraps around")
	check(not inv.equip_weapon_item(null), "#7 equip_weapon_item(null) refused")
	inv.equip_weapon_slot("primary")
	await secs(0.3)

	# ---------------------------------------------------------------- #3 hold E equips a ground item
	var gdb = root.get_node("GearDB")
	var near := func(item) -> Node:
		main.spawn_pickup(item, player.global_position, false)
		for i in 30:
			await physics_frame
			for n in player._nearby:
				if is_instance_valid(n) and n.get("item") == item:
					return n
		return null
	var g1 = gdb.roll_weapon("auto_rifle", 2, 3)
	var p1 = await near.call(g1)
	check(p1 != null and p1.can_hold_interact() and p1.get_prompt().contains("hold: equip"), "#3 gear pickup is hold-able, prompt says so")
	Input.action_release("interact")
	player._interact()
	await wait(3)
	check(inv.backpack[g1.slot].has(g1) and not is_instance_valid(p1), "#3 tap E still picks up into the backpack")
	var g2 = gdb.roll_weapon("scout_rifle", 2, 3)
	var was = inv.equipped[g2.slot]
	var p2 = await near.call(g2)
	Input.action_press("interact")
	player._interact()
	await secs(0.2)
	check(is_instance_valid(p2) and hud._hold_ring.visible and hud.hold_progress > 0.2 and hud.hold_progress < 1.0,
		"#3 holding: ring visible, filling (%.2f)" % hud.hold_progress)
	await secs(0.35)
	check(inv.equipped[g2.slot] == g2 and player.current_weapon() == g2 and not is_instance_valid(p2), "#3 hold 0.4 s: equipped and drawn")
	check(inv.backpack[g2.slot].has(was) and was.seen, "#3 the old piece went to the backpack")
	check(not hud._hold_ring.visible, "#3 ring hidden after")
	Input.action_release("interact")
	# full backpack: the old piece drops where the new one lay
	var bsize: int = inv.backpack_size
	while inv.backpack[g2.slot].size() < bsize:
		inv.backpack[g2.slot].append(gdb.roll_weapon("smg", 0, 1))
	var g3 = gdb.roll_weapon("hand_cannon", 3, 3)
	var p3 = await near.call(g3)
	Input.action_press("interact")
	player._interact()
	await secs(0.55)
	Input.action_release("interact")
	await wait(3)
	var dropped := false
	for n in main.pickups_root.get_children():
		if n.get("item") == g2:
			dropped = true
			player.set_nearby_interactable(n, false)
			n.free()
	check(inv.equipped[g3.slot] == g3 and dropped, "#3 backpack full: equipped, and the old gun lies on the ground")
	# armor
	var a9 = gdb.roll_armor("helmet", 2, 3)
	var pa = await near.call(a9)
	Input.action_press("interact")
	player._interact()
	await secs(0.55)
	Input.action_release("interact")
	check(inv.equipped.helmet == a9, "#3 armor equips by hold too")
	# consumables / chests act at once (no hold)
	var cons_ok := true
	for c in main.get_tree().get_nodes_in_group("chests"):
		if c.has_method("can_hold_interact") and c.can_hold_interact():
			cons_ok = false
	check(cons_ok and not FileAccess.get_file_as_string("res://scripts/items/chest.gd").contains("can_hold_interact"), "#3 chests / doors keep tap-to-use")
	var src2 := FileAccess.get_file_as_string("res://scripts/items/inventory.gd")
	check(src2.contains("func equip_refusal") and src2.contains("slot_refusal"), "#3 Inventory.equip_refusal hook for Skillz's slot rule")
	if inv.backpack[g1.slot].has(g1):
		inv.equip(g1)
	for i in range(inv.backpack[g2.slot].size() - 1, -1, -1):
		inv.backpack[g2.slot].remove_at(i)
	inv.equip_weapon_slot("primary")
	await secs(0.4)
	pri = inv.equipped.primary
	sec = inv.equipped.secondary

	# ---------------------------------------------------------------- #18 '!' only for Rare+ or upgrades
	var Inv = load("res://scripts/items/inventory.gd")
	var iv = Inv.new()
	root.add_child(iv)
	iv.stash_cap = -1
	var base = gdb.roll_weapon("sidearm", 1, 1) # Uncommon equipped primary
	iv.add_item(base)
	var c0 = gdb.roll_weapon("hand_cannon", 0, 1)
	var u0 = gdb.roll_weapon("auto_rifle", 1, 1)
	var r0 = gdb.roll_weapon("scout_rifle", 2, 1)
	var l0 = gdb.roll_weapon("hand_cannon", 3, 1)
	for it in [c0, u0, r0, l0]:
		iv.add_item(it)
	check(c0.seen and u0.seen, "#18 Common / same-rarity Uncommon below Rare: no '!'")
	check(not r0.seen and not l0.seen, "#18 Rare and Legendary: '!'")
	check(iv.unseen_count("primary") == 2, "#18 unseen_count counts only those (%d)" % iv.unseen_count("primary"))
	var hb = gdb.roll_armor("helmet", 0, 1)
	iv.add_item(hb) # Common helmet equipped
	var hu = gdb.roll_armor("helmet", 1, 1)
	iv.add_item(hu)
	check(not hu.seen and iv.is_upgrade(hu), "#18 Uncommon over an equipped Common: upgrade -> '!'")
	var hc = gdb.roll_armor("helmet", 0, 2)
	iv.add_item(hc)
	check(hc.seen and not iv.is_upgrade(hc), "#18 Common next to a Common: no '!'")
	iv.queue_free()

	#SECTIONS

	print("feel_test: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
