extends SceneTree
## Headless smoke test:  godot --headless --path . -s res://tests/smoke_test.gd
## Loads the main scene, exercises every system and prints PASS/FAIL lines.
## Exit code = number of failures. Uses its own save file, never the real one.

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


func _release_all() -> void:
	for a in ["move_forward", "sprint", "crouch", "jump"]:
		Input.action_release(a)


func _run() -> void:
	var progress = root.get_node("Progress")
	var gear = root.get_node("GearDB")
	progress.save_path = "user://progress_smoke_test.cfg" # never touch the real save
	progress.reset_skills()
	progress.xp = 1000 # skill points for testing
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240: # scene switch can lag a few frames on a loaded machine
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	var main = current_scene
	main._break_timer = 9999.0 # hold round 1 until we're ready
	var player = main.get_node("Player")
	var inv = player.inventory

	# ---------------------------------------------------------------- data
	check(gear.weapon_list.size() >= 9, "weapons.json loaded (%d archetypes)" % gear.weapon_list.size())
	check(gear.perks.size() >= 6, "perks.json loaded (%d perks)" % gear.perks.size())
	check(gear.loot.get("tables", {}).has("zombie") and gear.loot.tables.has("chest"), "loot tables loaded")
	check(gear.grenades.has("frag") and gear.grenades.has("pulse"), "grenades.json loaded (frag + pulse)")
	for a in gear.weapon_list:
		var mp: String = a.get("model", "")
		check(ResourceLoader.exists(mp), "model exists for %s (%s)" % [a.id, mp])

	# ---------------------------------------------------------------- starter loadout
	check(inv.equipped.primary != null and inv.equipped.primary.archetype == "sidearm", "starter primary = sidearm")
	check(inv.equipped.secondary != null, "starter secondary weapon equipped")
	var armor_ok := true
	for s in inv.ARMOR_SLOTS:
		armor_ok = armor_ok and inv.equipped[s] != null
	check(armor_ok, "starter armor in all 5 slots")
	check(inv.average_item_power() >= 90 and inv.average_item_power() <= 110, "starter avg item power ~100 (%d)" % inv.average_item_power())
	check(player.gun_model_root.get_child_count() > 0, "view model loaded from glb")

	# ---------------------------------------------------------------- random rolls
	var rolls_ok := true
	var perks_ok := true
	var names_seen := {}
	for i in 300:
		var r := randi_range(0, 4)
		var w = gear.roll_weapon("", r, randi_range(1, 30))
		names_seen[w.archetype] = true
		for s in w.stats:
			if w.stats[s] < 1 or w.stats[s] > 100:
				rolls_ok = false
		var want: int = Rarity.PERK_SLOTS[r] + (1 if r == Rarity.MYTHIC else 0)
		if w.perks.size() != want or w.rarity != r:
			perks_ok = false
		if w.mag_size() < 1 or w.damage() <= 0.0 or w.fire_interval() <= 0.0:
			rolls_ok = false
	check(rolls_ok, "300 weapon rolls: stats in 1..100, derived values sane")
	check(perks_ok, "perk count matches rarity")
	check(names_seen.size() >= 8, "rolls cover archetypes (%d)" % names_seen.size())
	var a1 = gear.roll_armor("helmet", Rarity.LEGENDARY, 8)
	check(a1.slot == "helmet" and a1.stat_total() > 0, "armor roll (total %d)" % a1.stat_total())
	var counts := [0, 0, 0, 0, 0]
	for i in 2000:
		counts[gear.roll_rarity(gear.loot.tables.zombie.rarity_weights)] += 1
	check(counts[0] > counts[2] and counts[2] > counts[4], "rarity weights respected %s" % str(counts))
	var chest_loot: Array = gear.roll_table("chest", 3)
	check(chest_loot.size() == 2, "chest table rolls 2 items")
	check(gear.roll_item_power(Rarity.RARE, 10) > gear.roll_item_power(Rarity.RARE, 1), "item power scales with round")
	check(gear.roll_item_power(Rarity.MYTHIC, 5) > gear.roll_item_power(Rarity.COMMON, 5), "item power rarity bonus")

	# ---------------------------------------------------------------- item power -> stats + damage
	var sum_lo := 0.0
	var sum_hi := 0.0
	var arm_lo := 0
	var arm_hi := 0
	for i in 200:
		var wl = gear.roll_weapon("auto_rifle", Rarity.RARE, 1, "", 100)
		var wh = gear.roll_weapon("auto_rifle", Rarity.RARE, 1, "", 220)
		for s in wl.stats:
			sum_lo += wl.stats[s]
			sum_hi += wh.stats[s]
		arm_lo += gear.roll_armor("chest", Rarity.RARE, 1, 100).stat_total()
		arm_hi += gear.roll_armor("chest", Rarity.RARE, 1, 220).stat_total()
	check(sum_hi > sum_lo, "higher item power -> higher weapon stat rolls (avg %.1f -> %.1f)" % [sum_lo / 200.0, sum_hi / 200.0])
	check(arm_hi > arm_lo, "higher item power -> higher armor stat totals (avg %.1f -> %.1f)" % [arm_lo / 200.0, arm_hi / 200.0])
	var wp = gear.roll_weapon("hand_cannon", Rarity.LEGENDARY, 1, "", 100)
	var wp2 = gear.item_from_dict(wp.to_dict())
	wp2.item_power = 160
	check(wp2.stats == wp.stats and wp2.damage() > wp.damage(),
		"same rolls, higher item power -> more damage (%.1f -> %.1f)" % [wp.damage(), wp2.damage()])
	check(int(JSON.parse_string(JSON.stringify(wp.to_dict())).item_power) == 100, "item power saved in item data")
	# Balance: Impact is excluded from the IP stat bonus, so the IP damage multiplier is the only
	# IP damage dial and IP 400 = 2.2x (see damage_table.md).
	# Owned by gear/IP balance (G4M3N). Seeded: with stat_variance=12, SE of |mean_400-mean_100|
	# over 300 rolls is ~0.6; threshold 1.5 is only ~2.6σ (~1% flake). Seed keeps it deterministic.
	check("impact" in gear.item_power_cfg().get("ip_stat_exclude", []), "Impact excluded from the IP stat bonus (loot_tables.json)")
	var dmg_lo := 0.0
	var dmg_hi := 0.0
	var imp_lo := 0.0
	var imp_hi := 0.0
	seed(0xDEAD0F42) # deterministic Impact / damage averages across fresh extracts
	for i in 300:
		var a100 = gear.roll_weapon("hand_cannon", Rarity.RARE, 1, "", 100)
		var a400 = gear.roll_weapon("hand_cannon", Rarity.RARE, 1, "", 400)
		dmg_lo += a100.damage()
		dmg_hi += a400.damage()
		imp_lo += a100.stats.impact
		imp_hi += a400.stats.impact
	check(absf(imp_hi - imp_lo) / 300.0 < 1.5, "Impact rolls don't grow with IP (avg %.1f @100 vs %.1f @400)" % [imp_lo / 300.0, imp_hi / 300.0])
	check(absf(dmg_hi / dmg_lo - 2.2) < 0.06, "IP 400 total damage ~2.2x IP 100 (%.3fx over 300 rolls)" % (dmg_hi / dmg_lo))
	var wp4 = gear.item_from_dict(wp.to_dict())
	wp4.item_power = 400
	check(is_equal_approx(wp4.damage() / wp.damage(), 2.2), "same rolls at IP 400 = exactly 2.2x damage (%.3fx)" % (wp4.damage() / wp.damage()))

	# ---------------------------------------------------------------- roll quality (0-1, saved, derived for old saves)
	var rq_ok := true
	for i in 200:
		var rw = gear.roll_weapon("", randi_range(0, 4), randi_range(1, 30))
		var ra = gear.roll_armor("", randi_range(0, 4), randi_range(1, 30))
		if rw.roll_quality < 0.0 or rw.roll_quality > 1.0 or ra.roll_quality < 0.0 or ra.roll_quality > 1.0:
			rq_ok = false
	check(rq_ok, "200 weapon + armor rolls: roll_quality in 0..1")
	check(gear.loot.has("roll_quality") and gear.roll_quality_cfg().has("weapon_stat_weights"), "roll_quality settings in loot_tables.json")
	var rqd: Dictionary = JSON.parse_string(JSON.stringify(wp.to_dict()))
	check(rqd.has("roll_quality") and absf(float(gear.item_from_dict(rqd).roll_quality) - wp.roll_quality) < 0.002,
		"roll_quality saved + restored (%.3f)" % wp.roll_quality)
	var hi_roll = gear.roll_weapon("scout_rifle", Rarity.RARE, 1, "", 100)
	var lo_roll = gear.item_from_dict(hi_roll.to_dict())
	for st in hi_roll.stats:
		hi_roll.stats[st] = 100
		lo_roll.stats[st] = 1
	var mk := {}
	for m in gear.manufacturers:
		if m.name == hi_roll.manufacturer:
			mk = m.get("stat_mods", {})
	check(gear.weapon_roll_quality(hi_roll, hi_roll.arch, mk) > gear.weapon_roll_quality(lo_roll, lo_roll.arch, mk),
		"better stats -> higher roll_quality")
	rqd.erase("roll_quality")
	var derived = gear.item_from_dict(rqd)
	check(absf(derived.roll_quality - wp.roll_quality) < 0.02,
		"missing roll_quality derived from stats (%.3f vs rolled %.3f)" % [derived.roll_quality, wp.roll_quality])
	var arm_rq = gear.roll_armor("chest", Rarity.LEGENDARY, 1, 100)
	var ad: Dictionary = JSON.parse_string(JSON.stringify(arm_rq.to_dict()))
	ad.erase("roll_quality")
	check(absf(gear.item_from_dict(ad).roll_quality - arm_rq.roll_quality) < 0.02, "armor roll_quality derived on load")
	# Legacy save: a whole loadout written before item_power / roll_quality existed
	var legacy: Dictionary = JSON.parse_string(JSON.stringify(inv.to_save_dict()))
	for s in legacy.equipped:
		if legacy.equipped[s]:
			legacy.equipped[s].erase("item_power")
			legacy.equipped[s].erase("roll_quality")
		for bd in legacy.backpack.get(s, []):
			bd.erase("item_power")
			bd.erase("roll_quality")
	var inv_legacy = load("res://scripts/items/inventory.gd").new()
	root.add_child(inv_legacy)
	inv_legacy.load_save_dict(legacy)
	var legacy_ok := inv_legacy.equipped.primary != null
	for s in inv_legacy.equipped:
		var it = inv_legacy.equipped[s]
		if it and (it.item_power != 100 or it.roll_quality < 0.0 or it.roll_quality > 1.0):
			legacy_ok = false
	check(legacy_ok and inv_legacy.average_item_power() == 100,
		"legacy save loads: item_power defaults to 100, roll_quality derived in 0..1")
	inv_legacy.queue_free()

	# ---------------------------------------------------------------- headshot multiplier (data-driven)
	check(is_equal_approx(gear.headshot_default, 2.0), "headshot_multiplier_default = 2.0 (weapons.json)")
	var hs_ok := true
	for a in gear.weapon_list:
		if not a.has("headshot_multiplier"):
			hs_ok = false
	check(hs_ok, "every archetype has a headshot_multiplier")
	var hsw = gear.roll_weapon("hand_cannon", Rarity.RARE, 1)
	check(is_equal_approx(hsw.headshot_mult(), float(hsw.arch.headshot_multiplier)) and is_equal_approx(hsw.headshot_mult(), 2.0),
		"hand cannon headshot x%.1f" % hsw.headshot_mult())
	var no_key: Dictionary = hsw.arch.duplicate()
	no_key.erase("headshot_multiplier")
	hsw.arch = no_key
	check(is_equal_approx(hsw.headshot_mult(), gear.headshot_default), "missing headshot_multiplier falls back to the default")

	# ---------------------------------------------------------------- renamed terms (no Destiny-derived ids)
	check(inv.WEAPON_SLOTS == ["primary", "secondary", "heavy"], "weapon slots Primary/Secondary/Heavy")
	check(a1.STAT_ORDER == ["agility", "toughness", "vitality", "ordnance", "focus", "brawn"], "armor stats renamed")
	check(Rarity.IDS[Rarity.MYTHIC] == "mythic", "top tier is Mythic")
	var els := {}
	for i in 60:
		els[gear.roll_weapon("", -1, 1, "secondary").element] = true
	check(els.keys().all(func(e): return e in ["volt", "blaze", "blight"]), "secondary elements are volt/blaze/blight %s" % str(els.keys()))
	var banned := ["Ace of Graves", "Last Word", "Rampage", "Outlaw", "Kill Clip", "Demolitionist", "Firmly Planted", "Leech",
		"Kinetic", "Exotic", "Engram",
		# skill tree / Field Cards: series terms and well-known perk / skill names (Destiny, Borderlands, CoD, Diablo)
		"Destiny", "Borderlands", "Diablo", "Call of Duty", "Juggernog", "Quick Revive", "Double Tap", "Stamin",
		"Speed Cola", "Flopper", "Deadshot", "Mule Kick", "Widow's Wine", "Electric Cherry", "Pack-a-Punch", "Elemental Pop",
		"Triple Tap", "Fourth Time", "Feeding Frenzy", "Heal Clip", "Golden Gun", "Gjallar", "Vault Hunter", "Siren",
		"Moxxi", "Nephalem", "Paragon", "Whirlwind", "Thorns", "Overclock", "Double Time", "Hang Time", "Final Round",
		"Second Chance", "Martyrdom", "Tombstone", "Dead Silence", "Ghost Ride", "Mayhem", "Phaselock", "Fade Away",
		"Bloodlust", "Ignition Shot", "Sword of Gods"]
	var all_names: Array = []
	for nid in progress.all_node_ids(): # every meta-tree node name ...
		all_names.append(str(progress.get_skill(nid).name))
	for cid in root.get_node("RunState").card_ids(): # ... and every Field Card name
		all_names.append(str(root.get_node("RunState").card_def(cid).name))
	for pid in gear.perks:
		all_names.append(str(gear.perks[pid].name))
	for a in gear.weapon_list:
		all_names.append_array(a.get("names", []))
		if a.has("mythic"):
			all_names.append(a.mythic.name)
	var allowed := ["Ninth Siren"] # existing weapon name, approved by Jason 2026-10-19
	var clean := true
	for n in all_names:
		if n in allowed:
			continue
		for b in banned:
			if b.to_lower() in n.to_lower():
				clean = false
				print("  banned name: ", n)
	check(clean, "no homage weapon/perk names (%d names checked)" % all_names.size())
	check(gear.perks.has("bloodrush") and gear.perks.has("fever_hands") and not gear.perks.has("rampage"), "renamed perk ids")

	# ---------------------------------------------------------------- inventory
	var hc = gear.roll_weapon("hand_cannon", Rarity.LEGENDARY, 8)
	check(inv.add_item(hc), "add legendary hand cannon")
	check(hc in inv.backpack.primary, "goes to primary backpack (slot occupied)")
	inv.equip(hc)
	check(inv.equipped.primary == hc and inv.backpack.primary.size() == 1, "equip swaps old sidearm into backpack")
	inv.equip_weapon_slot("secondary")
	check(inv.get_equipped_weapon() == inv.equipped.secondary, "switch to secondary slot")
	inv.equip_index(0)
	check(inv.get_equipped_weapon() == hc, "switch back with index 0")
	var sd: Dictionary = inv.to_save_dict()
	var json_round: Dictionary = JSON.parse_string(JSON.stringify(sd))
	var inv2 = load("res://scripts/items/inventory.gd").new()
	root.add_child(inv2)
	inv2.load_save_dict(json_round)
	check(inv2.equipped.primary.display_name == hc.display_name and inv2.equipped.primary.perks == hc.perks,
		"to_save_dict -> JSON -> load_save_dict round trip (vault-ready)")
	inv2.queue_free()
	var junk = inv.backpack.primary[0]
	inv.dismantle(junk)
	check(not (junk in inv.backpack.primary), "dismantle removes item")

	# Armor stats -> gameplay
	var walk0: float = player.walk_speed
	var gcd0: float = player.grenade_cooldown
	var res0: float = player.damage_reduction
	var legs = gear.roll_armor("legs", Rarity.MYTHIC, 8)
	for s in legs.stats:
		legs.stats[s] = 0
	legs.stats.agility = 40
	legs.stats.ordnance = 40
	legs.stats.toughness = 40
	inv.add_item(legs)
	inv.equip(legs)
	check(player.walk_speed > walk0, "Agility raises speed (%.2f -> %.2f)" % [walk0, player.walk_speed])
	check(player.grenade_cooldown < gcd0, "Ordnance lowers grenade cooldown (%.1f -> %.1f)" % [gcd0, player.grenade_cooldown])
	check(player.damage_reduction > res0, "Toughness adds damage reduction (%.2f)" % player.damage_reduction)
	check(inv.total_armor_stats().agility <= 100, "stat totals capped at 100")

	# Consumables
	inv.add_item(gear.consumable("health_pack"))
	player.take_damage(60)
	var hp_before: int = player.health
	check(inv.use_bag_item(0, player), "use health pack")
	check(player.health > hp_before, "health pack healed (%d -> %d)" % [hp_before, player.health])

	# ---------------------------------------------------------------- shooting
	await wait(40) # swap delay
	var w0 = inv.get_equipped_weapon()
	var mag: int = w0.ammo
	player.shoot()
	check(w0.ammo == mag - 1, "shooting uses ammo")
	w0.ammo = 0
	player.reload()
	await wait(int(w0.reload_time() * player.reload_multiplier * 60.0) + 20)
	check(w0.ammo == w0.mag_size(), "reload refills magazine")

	# ---------------------------------------------------------------- movement
	player.global_position = Vector3(0, 0.2, 6)
	player.rotation.y = 0.0
	player.velocity = Vector3.ZERO
	await wait(20)
	check(player.is_on_floor(), "player on floor at test spot")
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await wait(40)
	var spd: float = Vector2(player.velocity.x, player.velocity.z).length()
	check(spd > player.walk_speed, "sprinting (%.1f m/s)" % spd)
	Input.action_press("crouch")
	await wait(2)
	check(player.move_state == player.Move.SLIDE, "sprint + crouch = slide")
	var s0: float = Vector2(player.velocity.x, player.velocity.z).length()
	check(s0 > player.sprint_speed, "slide boost (%.1f m/s)" % s0)
	Input.action_release("move_forward")
	Input.action_release("sprint")
	await wait(20)
	var s1: float = Vector2(player.velocity.x, player.velocity.z).length()
	check(s1 < s0, "slide friction decays speed (%.1f -> %.1f)" % [s0, s1])
	check(player.head.position.y < 1.4, "camera lowered while sliding (%.2f)" % player.head.position.y)
	await wait(90)
	check(player.move_state == player.Move.CROUCH, "slide ends in crouch while C held")
	check(player.is_crouched(), "is_crouched() true")
	_release_all()
	await wait(30)
	check(player.move_state == player.Move.NORMAL, "release C stands up")
	# Wall jump in the brick alley (walls at x = -15.2 / -11.4)
	player.global_position = Vector3(-14.4, 3.0, -8)
	player.velocity = Vector3.ZERO
	await wait(12) # airborne and past coyote time
	var left0: int = player._wall_jumps_left
	Input.action_press("jump")
	await wait(1)
	Input.action_release("jump")
	check(player.velocity.y > 3.0 and player._wall_jumps_left == left0 - 1,
		"wall jump (vy %.1f, left %d -> %d)" % [player.velocity.y, left0, player._wall_jumps_left])
	check(player.velocity.x > 0.5, "wall jump pushes away from wall (vx %.1f)" % player.velocity.x)
	player.global_position = Vector3(0, 0.2, 6)
	player.velocity = Vector3.ZERO
	await wait(20)

	# ---------------------------------------------------------------- chest
	var chests := main.get_tree().get_nodes_in_group("chests")
	if chests.is_empty():
		for n in main.find_children("*", "StaticBody3D", true, false):
			if n.has_method("rearm"):
				chests.append(n)
	check(chests.size() >= 3, "3 chests in arena (%d)" % chests.size())
	var pick_before: int = main.pickups_root.get_child_count()
	chests[0].interact(player)
	await wait(2)
	check(main.pickups_root.get_child_count() == pick_before + 2, "chest spawns 2 pickups")
	check(not chests[0].can_interact(), "chest can't be reopened this round")
	var pk = main.pickups_root.get_child(main.pickups_root.get_child_count() - 1)
	var n_items := 0
	for s in inv.backpack:
		n_items += inv.backpack[s].size()
	n_items += inv.bag.size()
	pk.interact(player)
	await wait(2)
	var n_items2 := 0
	for s in inv.backpack:
		n_items2 += inv.backpack[s].size()
	n_items2 += inv.bag.size()
	check(n_items2 >= n_items or not is_instance_valid(pk), "pickup collected with interact()")

	# ---------------------------------------------------------------- menus
	main.character_screen.open()
	await wait(2)
	check(main.character_screen.visible and paused, "character screen opens and pauses")
	main.character_screen._expanded = "primary"
	main.character_screen.refresh()
	main.character_screen.debug_show_tooltip(inv.equipped.primary, Vector2(300, 100))
	await process_frame
	check(main.character_screen._tooltip.visible, "tooltip shows")
	# comparison deltas vs equipped (stash item vs equipped primary)
	var better = gear.roll_weapon(inv.equipped.primary.archetype, Rarity.RARE, 1, "", inv.equipped.primary.item_power + 25)
	for s in better.stats:
		better.stats[s] = mini(inv.equipped.primary.stats[s] + 10, 100)
	inv.add_item(better)
	var rows: Array = inv.compare(better)
	check(rows.size() >= 6 and rows[0].better and rows[0].text.begins_with("+"), "compare: damage delta is + (%s)" % (rows[0].text if rows.size() else "-"))
	var pc: Dictionary = inv.compare_power(better)
	check(pc.get("better", false) and pc.text == "+25", "compare_power: item power delta +25 (%s)" % pc.get("text", ""))
	main.character_screen.debug_show_tooltip(better, Vector2(300, 100))
	await process_frame
	check(main.character_screen._last_card_rows.size() == rows.size() and not main.character_screen._last_card_power.is_empty(),
		"card shows stat + item power comparison")
	main.character_screen.close()
	main.hud.show_hint("Pick up test item", "interact")
	check(main.hud._prompt.visible and main.hud._prompt_key.text == "E", "hud.show_hint resolves the interact key (%s)" % main.hud._prompt_key.text)
	main.hud.show_hint("", "")
	check(not main.hud._prompt.visible, "hud.show_hint('') hides the hint")
	check(not paused, "character screen closes")
	main.skill_menu.open(); await process_frame; main.skill_menu.close()

	# ---------------------------------------------------------------- skills + ability
	# v2 tree: tough_1 is gone; Thick Skin (sv_skin) rank 1 = +10 max health (needs Scrap Plating)
	check(progress.buy_rank("sv_root") and progress.buy_rank("sv_skin"), "buy sv_root + sv_skin")
	main._on_skill_unlocked("sv_skin")
	check(player.max_health == 110, "max health bonus applied (%d)" % player.max_health)
	player.use_ability()
	check(player._ability_cd > 0.0, "ability on cooldown after use")

	# ---------------------------------------------------------------- UI pass 2 (Gooey): skill tree, Field Cards, HUD
	var stm = main.skill_menu
	progress.xp += 2500 # a few more points for buying through the menu
	stm.open()
	await wait(3)
	check(stm._rail_tabs.size() == progress.branches().size() and progress.branches().size() == 7,
		"skill tree rail lists all 7 branches (%d tabs)" % stm._rail_tabs.size())
	check(stm._nodes.size() == progress.all_node_ids().size(), "skill tree: a tile per node (%d/%d)" % [stm._nodes.size(), progress.all_node_ids().size()])
	var clip_r: Rect2 = stm._clip.get_global_rect().grow(1.0)
	var vp_r := Rect2(Vector2.ZERO, stm.get_viewport().get_visible_rect().size).grow(1.0)
	var fit_ok := true
	for id in stm._nodes:
		var tr: Rect2 = stm._nodes[id].get_global_rect()
		fit_ok = fit_ok and clip_r.encloses(tr) and vp_r.encloses(tr)
	check(fit_ok, "skill tree: all 7 branches fit on screen without panning")
	progress.skill_ranks["mk_key"] = 1 # temporarily own a keystone to see the exclusion state
	var states_ok: bool = stm.ui_state("sv_root") in ["owned", "maxed"] and stm.ui_state("lg_spare") in ["available", "unaffordable"] \
		and stm.ui_state("lg_gilded") == "locked" and stm.ui_state("sp_key") == "excluded"
	progress.skill_ranks.erase("mk_key")
	check(states_ok, "skill tree node states: owned / available / locked / excluded")
	var ub := [0]
	stm.skill_unlocked.connect(func(_id): ub[0] += 1)
	var r0: int = progress.rank("lg_spare")
	stm._nodes["lg_spare"].pressed.emit()
	await process_frame
	check(progress.rank("lg_spare") == r0 + 1 and ub[0] == 1 and stm.ui_state("lg_spare") in ["owned", "maxed"],
		"buying a tile in the menu calls Progress.buy_rank (rank %d -> %d)" % [r0, progress.rank("lg_spare")])
	check(stm._nodes["lg_spare"] == stm._nodes.get("lg_spare") and stm._built, "skill tree updates in place (no rebuild)")
	stm.close()
	await process_frame
	var rpm = main.run_pick_menu
	var rs_ui = root.get_node("RunState")
	check(rpm != null and rpm.get_script().resource_path == "res://scripts/ui/run_pick_menu.gd", "run_pick_menu.gd replaces the TEMP chooser")
	rs_ui.open_offer(5)
	await wait(2)
	var n_leg: int = rs_ui.offer_entries().filter(func(e): return str(e.tier) == "legendary").size()
	check(rpm.visible and rpm.card_buttons.size() == 3 and n_leg == 2 and paused, "milestone offer: menu shows 3 cards, 2 legendary (%d)" % n_leg)
	rs_ui.offer = ["c_deep_pockets", "c_greased", "c_bounty"] # benign normals for the rest of the run
	rs_ui.offer_is_milestone = false
	rs_ui.offer_ready.emit(rs_ui.offer_entries(), false)
	await process_frame
	rs_ui.free_rerolls = 1
	check(rpm.do_reroll() and rs_ui.free_rerolls == 0 and rpm.visible and rpm.card_buttons.size() == 3, "run pick menu: reroll (free) redraws the offer")
	rs_ui.offer = ["c_deep_pockets", "c_greased", "c_bounty"]
	rs_ui.offer_ready.emit(rs_ui.offer_entries(), false)
	await process_frame
	rs_ui.banishes_left = 1
	check(rpm.banish_at(2) and rs_ui.banished_ids.has("c_bounty") and rs_ui.banishes_left == 0 and rpm.visible,
		"run pick menu: banish removes the card and redraws its slot")
	rs_ui.offer[1] = "c_greased"
	rs_ui.offer_ready.emit(rs_ui.offer_entries(), false)
	await process_frame
	check(rpm.take(0) and rs_ui.card_rank("c_deep_pockets") == 1 and not rpm.visible and not paused, "run pick menu: take card 1 (rank 1, menu closes, unpaused)")
	main._break_timer = 9999.0
	rs_ui.open_offer(3)
	await process_frame
	var pts_s: int = player.points
	var sk_r: int = rs_ui.skip_reward()
	check(rpm.do_skip() == sk_r and player.points == pts_s + sk_r and not rpm.visible and not paused, "run pick menu: skip pays %d points and closes" % sk_r)
	main._break_timer = 9999.0
	await process_frame
	check(main.hud._cards_strip.get_child_count() >= 1, "HUD run-card strip shows owned Field Cards")
	main.character_screen.open()
	await process_frame
	check(main.character_screen._right.find_child("FieldCards", true, false) != null, "character screen lists Field Cards")
	main.character_screen.close()
	player.overshield = 20.0
	player.overshield_changed.emit(player.overshield, player.overshield_cap)
	await process_frame
	check(main.hud.shield_visible(), "HUD overshield segment appears with overshield > 0")
	player.overshield = 0.0
	player.overshield_changed.emit(0.0, player.overshield_cap)
	await process_frame
	check(not main.hud.shield_visible(), "HUD overshield segment hides at 0")
	player.grenade_charges_changed.emit(1, 2)
	check(main.hud._indicators.grenade.max_charges == 2 and main.hud._indicators.grenade.charges == 1, "HUD grenade badge shows charge pips (1/2)")
	player.grenade_charges_changed.emit(player.grenade_charges, player.grenade_charges_max)

	# ---------------------------------------------------------------- UI pass 3 (Gooey): map picker, armor models
	var mp = main.map_picker
	check(mp != null and mp == main.get_node_or_null("MapPicker") and mp.get_script().resource_path == "res://scripts/ui/map_picker.gd",
		"main.map_picker is the MapPicker instance")
	var ev_m := InputEventAction.new()
	ev_m.action = "map_next"
	ev_m.pressed = true
	root.push_input(ev_m)
	await process_frame
	var map_before: String = MapRegistry.current_id()
	check(mp.visible and current_scene == main and paused and MapRegistry.current_id() == map_before and main.map_id == map_before,
		"M before round 1 opens main.map_picker (map not cycled, still %s)" % map_before)
	check(mp._rows.size() == MapRegistry.list().size() and mp._rows.size() >= 2, "map picker lists every map (%d)" % mp._rows.size())
	check(mp._sel == MapRegistry.current_id() and mp._cur_tag.visible, "map picker marks the current map (%s)" % mp._sel)
	var rw: Dictionary = mp.map_meta("rustwell_foundry")
	check(rw.doors.size() == 6 and rw.areas.size() >= 4 and mp.hint_lines(rw).size() >= 2 and mp.map_meta("arena").doors.is_empty(),
		"map picker door/area hint from the map scene (%d doors, %d areas)" % [rw.doors.size(), rw.areas.size()])
	mp.select_row("rustwell_foundry")
	check(not mp._cur_tag.visible and mp._preview.meta == rw, "map picker detail follows the selection")
	var stub_src := GDScript.new()
	stub_src.source_code = "extends Node\nvar current_round := 0\nvar _game_over := false\nvar calls := []\nfunc restart_with_map(id: String) -> bool:\n\tcalls.append(id)\n\treturn MapRegistry.select(id)\n"
	stub_src.reload()
	var stub: Node = stub_src.new()
	mp.main = stub
	var loaded: bool = mp.load_map("rustwell_foundry")
	check(loaded and stub.calls == ["rustwell_foundry"] and MapRegistry.current_id() == "rustwell_foundry", "map picker load calls main.restart_with_map(id) -> MapRegistry.select")
	MapRegistry.select("")
	mp.main = main
	stub.free()
	mp.visible = true
	mp.close()
	await process_frame
	main.current_round = 3
	root.push_input(ev_m)
	await process_frame
	check(not mp.visible and not mp.can_open() and current_scene == main, "M is ignored mid-match (round 3)")
	main.current_round = 0
	main._game_over = true
	check(mp.can_open(), "map picker allowed at game over")
	main._game_over = false
	var cs = main.character_screen
	cs.open()
	await process_frame
	var shown: Dictionary = cs.armor_models_shown()
	var eq_slots: Array = inv.ARMOR_SLOTS.filter(func(sl): return inv.equipped.get(sl) != null)
	check(eq_slots.size() == 5 and eq_slots.all(func(sl): return shown.has(sl)), "armor display model loaded for each equipped slot %s" % str(shown.keys()))
	check(shown.get("class_item", "") == "sash" and not cs._mannequin["chest"].visible, "soldier class item = sash; primitives hidden under models")
	var prev_pc = player.player_class
	player.player_class = load("res://resources/classes/scout.tres")
	cs.refresh()
	check(cs.armor_models_shown().get("class_item", "") == "cloak", "scout class item = cloak")
	player.player_class = prev_pc
	cs.model_path_override = {"helmet": "res://assets/models/armor/display/missing_helmet.glb"}
	cs.refresh()
	check(not cs.armor_models_shown().has("helmet") and cs._mannequin["helmet"].visible and cs.armor_models_shown().has("chest"),
		"missing armor model falls back to the primitive (helmet)")
	cs.model_path_override = {}
	cs.refresh()
	check(ResourceLoader.exists(cs.armor_icon_path(inv.equipped.chest)), "armor tile/card icon exists (%s)" % cs.armor_icon_path(inv.equipped.chest).get_file())
	cs.close()
	await process_frame

	# ---------------------------------------------------------------- UI pass 4 (Gooey): Settings + pause
	var SettingsScript = load("res://scripts/autoload/settings.gd")
	var st = root.get_node("Settings") # autoload (G4M3N registered)
	check(st != null and st == SettingsScript.get_or_create(root), "Settings autoload present; get_or_create returns it")
	var cfg_path: String = st.SAVE_PATH
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg_path))
	st.reset_to_defaults()
	check(st.ads_mode == "hold" and st.motion_blur == false and is_equal_approx(st.fov, 75.0), "settings defaults: ads_mode=hold, motion_blur=false, fov=75")
	st.set_ads_mode("toggle")
	st.set_motion_blur(true)
	st.set_fov(90.0)
	st.set_bus_volume("Music", 0.42)
	st.set_mouse_sensitivity(0.005)
	st.set_invert_y(true)
	st.set_fullscreen(false)
	st.set_vsync(true)
	# Round-trip via disk on the same autoload instance (do not free /root/Settings — player stays connected)
	st.save_to_disk()
	st.load_from_disk()
	st.apply_all()
	check(st.ads_mode == "toggle" and st.motion_blur == true and is_equal_approx(st.fov, 90.0), "settings persist ads_mode + motion_blur + fov")
	check(is_equal_approx(st.vol_Music, 0.42) and is_equal_approx(st.mouse_sensitivity, 0.005) and st.invert_y, "settings persist volume + sensitivity + invert_y")
	var music_idx := AudioServer.get_bus_index("Music")
	check(music_idx >= 0 and absf(AudioServer.get_bus_volume_db(music_idx) - linear_to_db(0.42)) < 0.15, "Music bus volume applied on load")
	# Rebind + conflict swap
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_P
	var r1: Dictionary = st.rebind("jump", ev, true)
	var has_jump := false
	for e in InputMap.action_get_events("jump"):
		has_jump = has_jump or (e is InputEventKey and e.physical_keycode == KEY_P)
	check(r1.ok and has_jump, "rebind jump to P")
	var r2: Dictionary = st.rebind("melee", ev, true)
	var has_melee := false
	has_jump = false
	for e in InputMap.action_get_events("melee"):
		has_melee = has_melee or (e is InputEventKey and e.physical_keycode == KEY_P)
	for e in InputMap.action_get_events("jump"):
		has_jump = has_jump or (e is InputEventKey and e.physical_keycode == KEY_P)
	check(r2.ok and str(r2.conflict) == "jump" and has_melee and not has_jump, "rebind conflict swaps off jump onto melee")
	st.reset_binding("jump")
	st.reset_binding("melee")
	st.reset_to_defaults()
	await process_frame
	# Pause + settings menus
	var pm = main.pause_menu
	var sm = main.settings_menu
	check(pm != null and sm != null and pm == main.get_node("PauseMenu") and sm == main.get_node("SettingsMenu"),
		"main owns pause_menu + settings_menu")
	main.current_round = 0
	main._game_over = false
	pm.open()
	await process_frame
	check(pm.visible and paused and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "pause menu opens (paused, mouse free)")
	pm._open_settings()
	await process_frame
	check(sm.visible and not pm.visible and paused, "Settings opens from pause (still paused)")
	sm._select_tab("gameplay")
	check(sm._tab == "gameplay", "settings gameplay tab")
	sm.close()
	await process_frame
	check(not sm.visible and pm.visible and paused, "closing settings returns to pause")
	pm.close()
	await process_frame
	check(not pm.visible and not paused, "closing pause unpauses")
	# Esc mid-round opens pause without cycling mouse-only
	main.current_round = 2
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var esc := InputEventKey.new()
	esc.physical_keycode = KEY_ESCAPE
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	await process_frame
	check(pm.visible and paused, "Esc mid-round opens the pause menu")
	pm.close()
	await process_frame
	main.current_round = 0 # restore — later smoke advances from round 0 → 1
	main._break_timer = 9999.0
	# Player look settings (G4M3N hooked player.gd)
	st.reset_to_defaults()
	await process_frame
	check(is_equal_approx(player.mouse_sensitivity, st.mouse_sensitivity) and player.invert_y == st.invert_y and is_equal_approx(player.camera.fov, st.fov),
		"player matches Settings defaults (sens %.4f, invert %s, fov %.0f)" % [player.mouse_sensitivity, player.invert_y, player.camera.fov])
	st.set_mouse_sensitivity(0.0075)
	st.set_invert_y(true)
	st.set_fov(95.0)
	await process_frame
	check(is_equal_approx(player.mouse_sensitivity, 0.0075) and player.invert_y == true and is_equal_approx(player.camera.fov, 95.0),
		"live Settings change updates player look (sens/invert/fov)")
	st.reset_to_defaults()
	await process_frame
	check(is_equal_approx(player.mouse_sensitivity, st.mouse_sensitivity) and player.invert_y == false and is_equal_approx(player.camera.fov, st.fov),
		"reset_to_defaults restores player look")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg_path))

	# ---------------------------------------------------------------- UI pass 4 part 2 (Gooey): unseen '!' badges + stash counter + card summary
	check(UIStyle.card_blurb({"summary": "Bigger magazines.", "description": "+20% mag size at rank 1"}) == "Bigger magazines.",
		"card_blurb prefers summary over description")
	check(UIStyle.card_blurb({"description": "A long description with no summary field at all here xx"}).begins_with("A long description"),
		"card_blurb falls back to truncated description")
	var bang_style: PanelContainer = UIStyle.unseen_badge(14)
	check(bang_style != null and bang_style.name == "UnseenBadge", "UIStyle.unseen_badge builds a named plate")
	bang_style.free()
	# Deterministic unseen stash item: clear leftover unseen from earlier pickups, then
	# put ONE known secondary into the backpack (slot fixed, seen=false). Avoid WeaponItem.new()
	# here — naming that class in this -s script trips a GearDB↔WeaponItem parse cycle.
	inv.mark_all_seen()
	await process_frame
	if inv.equipped.get("secondary") == null:
		var filler = gear.roll_weapon("smg", Rarity.COMMON, 1, "secondary")
		filler.seen = true
		inv.add_item(filler)
		inv.mark_all_seen()
	var unseen_w = gear.roll_weapon("smg", Rarity.RARE, 2, "secondary")
	unseen_w.seen = false
	unseen_w.display_name = "TEST UNSEEN SMG"
	unseen_w.slot = "secondary"
	check(inv.add_item(unseen_w) and inv.backpack.secondary.has(unseen_w) and not unseen_w.seen,
		"explicit unseen secondary landed in stash (not auto-equipped)")
	check(inv.unseen_count("secondary") == 1 and inv.has_unseen("secondary"), "unseen secondary in stash")
	main.hud._bind_player()
	main.hud.refresh_unseen_hint()
	check(main.hud._unseen_chip != null and main.hud._unseen_chip.visible and int(main.hud._unseen_count_label.text) >= 1,
		"HUD unseen hint shows with count (%s)" % (main.hud._unseen_count_label.text if main.hud._unseen_count_label else "?"))
	cs = main.character_screen
	cs.open()
	await process_frame
	cs._expanded = "secondary"
	cs.refresh()
	await process_frame
	var stash_lbl: Label = cs._stash_label
	check(stash_lbl != null and stash_lbl.name == "StashCount" and stash_lbl.text.contains("/"),
		"character screen stash counter %s" % (stash_lbl.text if stash_lbl else "?"))
	var carried0: int = inv.carried_count()
	check(stash_lbl.text.begins_with("%d/" % carried0), "stash counter matches carried_count (%s)" % stash_lbl.text)
	var slot_wrap = null
	for side in [cs._left, cs._right]:
		for c in side.get_children():
			if c.has_meta("slot") and str(c.get_meta("slot")) == "secondary":
				slot_wrap = c
				break
	var slot_bang = slot_wrap.find_child("SlotUnseen", true, false) if slot_wrap else null
	check(slot_bang != null and (slot_bang as CanvasItem).visible, "slot header '!' badge when has_unseen(secondary)")
	var tile_bang: Node = null
	if slot_wrap:
		for n in slot_wrap.find_children("*", "Button", true, false):
			if n.has_meta("gear") and n.get_meta("gear") == unseen_w:
				tile_bang = n.find_child("UnseenBadge", true, false)
				break
	check(tile_bang != null and (tile_bang as CanvasItem).visible, "stash tile '!' badge for unseen item")
	# Hover marks seen; await seen_changed → in-place badge hide
	cs._on_tile_hover(unseen_w, false)
	await process_frame
	await process_frame
	check(unseen_w.seen and not inv.has_unseen("secondary"), "hover mark_seen clears unseen for that item")
	check(tile_bang != null and is_instance_valid(tile_bang) and not (tile_bang as CanvasItem).visible, "tile badge hidden after seen_changed")
	check(slot_bang != null and is_instance_valid(slot_bang) and not (slot_bang as CanvasItem).visible, "slot badge hidden after seen_changed")
	main.hud.refresh_unseen_hint()
	# Legacy/seen items show no badges (Skillz: missing 'seen' key loads as true)
	var leg = gear.roll_weapon("smg", Rarity.COMMON, 1, "secondary")
	leg.seen = true
	leg.display_name = "LEGACY SEEN SMG"
	inv.add_item(leg)
	cs.refresh()
	await process_frame
	var leg_bang = null
	for side in [cs._left, cs._right]:
		for n in side.find_children("*", "Button", true, false):
			if n.has_meta("gear") and n.get_meta("gear") == leg:
				leg_bang = n.find_child("UnseenBadge", true, false)
	check(leg_bang == null or not leg_bang.visible, "legacy/seen item shows no '!' badge")
	# Stash counter colour: temporarily lower stash_cap so we hit warning/full without flooding the bag
	var cap_saved: int = inv.stash_cap
	inv.stash_cap = maxi(inv.carried_count(), 1)
	cs._refresh_stash_count(inv)
	await process_frame
	check(stash_lbl.text == "%d/%d" % [inv.carried_count(), inv.stash_cap], "stash counter full text %s" % stash_lbl.text)
	check(stash_lbl.get_theme_color("font_color") == UIStyle.BAD, "stash counter red when full")
	inv.stash_cap = maxi(inv.carried_count() + 2, inv.carried_count())  # near but not full if carried high
	# Force warning band: cap such that carried >= 85%
	if inv.carried_count() > 0:
		inv.stash_cap = int(ceili(float(inv.carried_count()) / 0.85))
		if inv.carried_count() < inv.stash_cap:
			cs._refresh_stash_count(inv)
			await process_frame
			var warn_c: Color = UIStyle.RUST.lightened(0.25)
			check(stash_lbl.get_theme_color("font_color") == warn_c or inv.carried_count() >= inv.stash_cap,
				"stash counter warning near cap (or already full)")
	inv.stash_cap = cap_saved
	cs._refresh_stash_count(inv)
	# Field Cards one-line rows use summary
	if not rs_ui.cards.has("c_deep_pockets"):
		rs_ui.cards["c_deep_pockets"] = 1
		if rs_ui.has_signal("cards_changed"):
			rs_ui.cards_changed.emit()
	cs.refresh()
	await process_frame
	var fc = cs._right.find_child("FieldCards", true, false)
	var row_ok := false
	if fc:
		for child in fc.get_children():
			var texts: PackedStringArray = []
			for lab in child.find_children("*", "Label", true, false):
				texts.append(lab.text)
			var joined := " ".join(texts)
			if "Bigger magazines" in joined or "magazine" in joined.to_lower():
				row_ok = true
				break
			# Prefer that description numbers are NOT the only line when summary exists
			var def: Dictionary = rs_ui.card_def("c_deep_pockets")
			var sum: String = str(def.get("summary", ""))
			if sum != "" and sum in joined:
				row_ok = true
				break
	check(row_ok or UIStyle.card_blurb(rs_ui.card_def("c_deep_pockets")) != "", "Field Card row can use entry.summary")
	# Enrich path: field_card_row with summary
	var sample := {"id": "c_deep_pockets", "name": "Deep Pockets", "tier": "normal", "branch": "ordnance",
		"rank": 1, "ranks": 3, "summary": "Bigger magazines.", "description": "+20% mag (rank 1)"}
	var fr: PanelContainer = UIStyle.field_card_row(sample, 330, 0.0, true)
	var fr_txt := ""
	for lab in fr.find_children("*", "Label", true, false):
		fr_txt += lab.text + "|"
	check("Bigger magazines." in fr_txt and "+20%" not in fr_txt, "inline field_card_row shows summary not numbers")
	fr.free()
	cs.close()
	await process_frame
	inv.mark_all_seen()
	main.hud.refresh_unseen_hint()
	check(not main.hud._unseen_chip.visible, "HUD unseen hint hides when nothing unseen")

	# ---------------------------------------------------------------- audio
	var sfx = root.get_node_or_null("Sfx")
	check(sfx != null, "Sfx autoload present")
	var buses_ok := true
	for b in ["Master", "Music", "SFX", "UI", "Ambience"]:
		buses_ok = buses_ok and AudioServer.get_bus_index(b) >= 0
	check(buses_ok and AudioServer.get_bus_send(AudioServer.get_bus_index("Music")) == &"Master", "audio buses Master/Music/SFX/UI/Ambience")
	var total_streams := 0
	for k in sfx.bank:
		total_streams += sfx.bank[k].size()
	check(total_streams == 148, "all 148 audio files load into the bank (%d)" % total_streams)
	var keys_missing := []
	for k in ["sidearm_fire", "hand_cannon_fire", "auto_rifle_fire", "scout_rifle_fire", "smg_fire", "shotgun_fire",
			"pulse_rifle_burst", "sniper_fire", "rocket_launcher_fire", "rocket_explosion", "reload_mag_out", "reload_mag_in",
			"dry_fire", "weapon_swap", "impact_flesh", "impact_concrete", "impact_metal",
			"zombie_idle_groan", "zombie_aggro_scream", "zombie_attack_swipe", "zombie_hurt", "zombie_death", "zombie_footstep", "zombie_shuffle",
			"footstep_concrete", "jump", "land", "slide", "wall_jump_push", "player_hurt", "player_death", "melee_swing", "dash",
			"adrenaline_boost", "frag_throw", "frag_bounce", "frag_explode", "tremor_charge_pulse_loop", "heartbeat_low_health_loop",
			"round_start_stinger", "round_end_stinger", "game_over_sting", "menu_open", "menu_close", "ui_hover", "ui_equip",
			"ui_scrap_dismantle", "ui_skill_unlock", "points_tick", "chest_open", "loot_drop_common", "loot_drop_mythic",
			"music_main_menu_loop", "music_between_rounds_loop", "music_combat_loop", "ambience_wind_industrial_loop"]:
		if not sfx.has(k):
			keys_missing.append(k)
	check(keys_missing.is_empty(), "key sound streams load (missing: %s)" % str(keys_missing))
	var fire_ok := true
	for a in gear.weapon_list:
		fire_ok = fire_ok and sfx.has(str(a.get("fire_sfx", a.id + "_fire")))
	check(fire_ok, "every weapon archetype has a fire sound")
	var loops_ok := true
	for path in ["res://assets/audio/music/music_combat_loop.ogg", "res://assets/audio/music/music_between_rounds_loop.ogg",
			"res://assets/audio/music/music_main_menu_loop.ogg", "res://assets/audio/ambience/ambience_wind_industrial_loop.ogg"]:
		var o = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		loops_ok = loops_ok and o is AudioStreamOggVorbis and o.loop
	for path in ["res://assets/audio/sfx/player/heartbeat_low_health_loop.wav", "res://assets/audio/sfx/world/tremor_charge_pulse_loop.wav"]:
		var wv = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		loops_ok = loops_ok and wv is AudioStreamWAV and wv.loop_mode == AudioStreamWAV.LOOP_FORWARD and wv.loop_begin == 0
	check(loops_ok, "OGG loops + forward-looping WAVs set in the import files")
	check(sfx.music_state == "menu" and sfx.current_music_stream() != null \
		and sfx.current_music_stream().resource_path.ends_with("music_main_menu_loop.ogg"), "pre-round music = menu loop (%s)" % sfx.music_state)
	check(sfx._ambience.playing and AudioServer.get_bus_volume_db(AudioServer.get_bus_index("Ambience")) < -6.0, "ambience loop on, low")
	check(sfx.surface_of(main.get_node("NavigationRegion3D/Arena/Platform")) == "metal" and sfx.surface_of(main.get_node("NavigationRegion3D/Arena/WallN")) == "concrete",
		"impact surfaces: platform = metal, wall = concrete")
	var p_hp: int = player.health
	player.health = int(player.max_health * 0.2)
	await wait(3)
	check(sfx.heartbeat_playing(), "heartbeat loop at low health")
	player.health = p_hp
	await wait(3)
	check(not sfx.heartbeat_playing(), "heartbeat stops when healthy")

	# ---------------------------------------------------------------- round 1 + combat
	main._break_timer = 0.1
	await wait(300)
	check(main.current_round == 1, "round 1 started")
	check(sfx.music_state == "combat" and sfx.current_music_stream().resource_path.ends_with("music_combat_loop.ogg"),
		"music switches to the combat loop during a round")
	var zombies: Array = main.get_node("Zombies").get_children()
	check(zombies.size() > 0, "zombies spawned (%d)" % zombies.size())
	check(main.nav_region.navigation_mesh.get_polygon_count() > 0,
		"navmesh baked (%d polys)" % main.nav_region.navigation_mesh.get_polygon_count())
	if zombies.size() > 0:
		var z = zombies[0]
		check(z._anim != null, "zombie has AnimationPlayer from glb")
		check(z.head_hitbox != null and z.head_hitbox.get_parent() is BoneAttachment3D and z.head_hitbox.get_parent().bone_name == "Head",
			"head hitbox rides the 'Head' bone (BoneAttachment3D)")
		check(absf(z.model_root.rotation.y) < 0.01, "model faces -Z without the 180-degree flip")
		# Chase: deterministic. Freeze the others, put this zombie at a fixed far spawn point and measure
		# the remaining NAVMESH path length (straight-line distance grows when it walks around cover).
		for zz in zombies:
			if zz != z:
				zz.set_physics_process(false)
				zz.global_position = Vector3(12.0 + zombies.find(zz) * 0.9, 0.1, -17.5) # parked by the NE spawn
		var nav_map: RID = z.agent.get_navigation_map()
		var path_len := func(from: Vector3) -> float:
			var pts: PackedVector3Array = NavigationServer3D.map_get_path(nav_map, from, player.global_position, true)
			var L := 0.0
			for i in range(1, pts.size()):
				L += pts[i].distance_to(pts[i - 1])
			return L
		var chase_ok := true
		var chase_log := []
		for start in [Vector3(-17, 0.1, 17), Vector3(17, 0.1, 8), Vector3(-4.5, 0.1, 9.8)]: # last one used to snag on a crate
			z.global_position = start
			z.velocity = Vector3.ZERO
			z.knockback = Vector3.ZERO
			await wait(2)
			var l0: float = path_len.call(z.global_position)
			await wait(90)
			var l1: float = path_len.call(z.global_position)
			chase_log.append("%.1f->%.1f" % [l0, l1])
			chase_ok = chase_ok and l1 < l0 - 0.5 * z.speed # covered at least half its 1.5 s of walking
		check(chase_ok, "zombie chases player along the navmesh (path %s)" % ", ".join(chase_log))
		for zz in zombies:
			zz.set_physics_process(true)
	player.max_health = 100000 # don't die during the combat checks
	player.health = 100000
	# Grenade: throw, then force-detonate next to a zombie
	player._grenade_cd = 0.0
	player.throw_grenade()
	check(player._grenade_cd > 0.0, "grenade on cooldown after throw")
	await wait(2)
	var gren: Array = main.find_children("*", "RigidBody3D", true, false)
	check(gren.size() > 0 and gren[0].get_script().resource_path.ends_with("grenade.gd"), "grenade rigid body spawned")
	zombies = main.get_node("Zombies").get_children()
	if zombies.size() > 0:
		var z = zombies[0]
		z.set_physics_process(false)
		z.global_position = Vector3(8, 0.1, 8)
		var hp0: float = z.health
		load("res://scripts/combat/explosion.gd").explode(main, Vector3(8, 0.5, 8.5), 5.0, 60.0, 8.0, Color.ORANGE, player, null, 1.0)
		check(z.health < hp0, "explosion damages zombie (%.0f -> %.0f)" % [hp0, z.health])
		check(z.knockback.length() > 0.5, "explosion knocks zombie back")
		z.set_physics_process(true)
		# Falloff: far zombie takes less
		var close_dmg: float = hp0 - z.health
		if zombies.size() > 1:
			var z2 = zombies[1]
			z2.global_position = Vector3(-8, 0.1, -8)
			var h2: float = z2.health
			load("res://scripts/combat/explosion.gd").explode(main, Vector3(-8, 0.5, -3.8), 5.0, 60.0, 0.0, Color.ORANGE, player, null, 1.0)
			check(h2 - z2.health < close_dmg and h2 - z2.health > 0.0, "damage falls off with distance")
	# Zombie health bar: hidden until damaged, shown after the explosion above
	zombies = main.get_node("Zombies").get_children()
	var hb_target = null
	for zz in zombies:
		if not zz._dead and zz.health < zz.max_health:
			hb_target = zz
	check(hb_target != null and hb_target.health_bar != null and hb_target.health_bar.visible,
		"zombie health bar appears once damaged")
	var fresh = null
	for zz in zombies:
		if not zz._dead and zz.health >= zz.max_health:
			fresh = zz
	if fresh:
		check(not fresh.health_bar.visible, "undamaged zombie has no health bar")
	check(main.find_children("*", "Label3D", true, false).filter(func(l): return l.get_parent() == main).is_empty(),
		"no floating damage numbers spawned")
	# hit_registered: hitscan head vs body, kill flag, HUD hit marker
	var hits: Array = []
	var rec := func(t, d, h, k): hits.append({"t": t, "d": d, "head": h, "kill": k})
	player.hit_registered.connect(rec)
	var shoot_z = null
	for zz in main.get_node("Zombies").get_children():
		if not zz._dead:
			if shoot_z == null:
				shoot_z = zz
			else:
				zz.set_physics_process(false)
				zz.global_position = Vector3(30, 0.1, 30)
	inv.equip_weapon_slot("primary")
	await wait(60)
	var sw = inv.get_equipped_weapon()
	if shoot_z and sw and not sw.is_projectile():
		shoot_z.set_physics_process(false)
		shoot_z.health = 1000000.0
		shoot_z.max_health = 1000000
		player.global_position = Vector3(-8.0, 0.1, 6.0) # open lane, clear of the car/props
		player.velocity = Vector3.ZERO
		player.rotation.y = 0.0
		player.head.rotation.x = 0.0
		await wait(2)
		var cam_pos: Vector3 = player.camera.global_position
		var fwd: Vector3 = -player.camera.global_basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var shots := {}
		shoot_z.global_position = Vector3(cam_pos.x, 0.0, cam_pos.z) + fwd * 3.5
		shoot_z.rotation.y = atan2(fwd.x, fwd.z) # face the player
		shoot_z._attack_anim_t = 0.0
		shoot_z._play("walk", 0.0)
		await wait(3)
		check(shoot_z._anim.is_playing() and shoot_z._anim.current_animation.ends_with("Walk"),
			"target zombie is playing its walk animation (%s)" % shoot_z._anim.current_animation)
		check(shoot_z.head_center().y - shoot_z.global_position.y < 1.5, "hunched head sits low while walking (%.2f m)" % (shoot_z.head_center().y - shoot_z.global_position.y))
		for kind in ["head", "body"]:
			await wait(7) # let the walk cycle move the head
			# aim the camera at the animated head bone / the chest
			var aim: Vector3 = shoot_z.head_center() if kind == "head" else shoot_z.global_position + Vector3(0, 0.95, 0)
			var d: Vector3 = aim - player.camera.global_position
			player.rotation.y = atan2(-d.x, -d.z)
			player.head.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())
			await wait(1)
			sw.ammo = sw.mag_size()
			player._cooldown = 0.0
			player._swap_t = 0.0
			player._reloading = false
			hits.clear()
			player.shoot()
			shots[kind] = hits.duplicate()
		var hh: Array = shots.head
		var bh: Array = shots.body
		check(hh.size() > 0 and hh[0].t == shoot_z and hh[0].head, "hit_registered fires on a headshot (is_headshot=true)")
		check(bh.size() > 0 and not bh[0].head, "hit_registered body hit (is_headshot=false)")
		if hh.size() > 0 and bh.size() > 0:
			check(absf(hh[0].d / bh[0].d - sw.headshot_mult()) < 0.05,
				"headshot damage = %.2fx body (%.1f vs %.1f)" % [hh[0].d / bh[0].d, hh[0].d, bh[0].d])
		check(main.hud._hit_marker.is_showing() and main.hud._last_hit.get("target") == shoot_z, "HUD hit marker shown from hit_registered")
		shoot_z.health = 1.0
		await wait(3)
		player._cooldown = 0.0
		hits.clear()
		player.shoot()
		check(hits.size() > 0 and hits[0].kill, "hit_registered reports the kill (is_kill=true)")
		check(not shoot_z.health_bar.visible, "health bar hidden on death")
	else:
		check(false, "hit test setup (zombie + hitscan weapon)")
	player.hit_registered.disconnect(rec)
	check(main.hit_sfx != null and main.hit_sfx.counts().has("head"), "hit sfx stub loaded (streams %s)" % str(main.hit_sfx.counts()))
	var hsc: Dictionary = main.hit_sfx.counts()
	check(hsc.body == 3 and hsc.head == 3 and hsc.kill == 2, "hitmarker streams found by HitSfx (%s)" % str(hsc))

	# Zombie voice cap: many zombies talking at once never exceeds MAX_ZOMBIE_VOICES
	var zs: Array = []
	for i in 12:
		var zn = load("res://scenes/enemy.tscn").instantiate()
		main.get_node("Zombies").add_child(zn)
		zn.set_physics_process(false)
		zn.global_position = Vector3(-16 + i * 0.9, 0.1, -16)
		zs.append(zn)
	await wait(2)
	var accepted := 0
	for zn in zs:
		if sfx.zombie_voice(zn.voice, "zombie_idle_groan", 0):
			accepted += 1
	await wait(1)
	check(sfx.active_zombie_voices() <= sfx.MAX_ZOMBIE_VOICES and accepted <= sfx.MAX_ZOMBIE_VOICES,
		"zombie voices capped at %d (%d of 12 groans accepted, %d active)" % [sfx.MAX_ZOMBIE_VOICES, accepted, sfx.active_zombie_voices()])
	check(sfx.zombie_voice(zs[11].voice, "zombie_death", 3), "a death scream steals a groan slot when full")
	for zn in zs:
		zn.take_damage(1000000.0)
	await wait(2)

	# Rocket launcher
	var rl = gear.roll_weapon("rocket_launcher", Rarity.RARE, 120)
	inv.add_item(rl)
	inv.equip(rl)
	inv.equip_weapon_slot("heavy")
	await wait(80)
	check(inv.get_equipped_weapon() == rl, "power weapon equipped")
	var ammo0: int = rl.ammo
	player.shoot()
	await wait(2)
	check(rl.ammo == ammo0 - 1 and true, "rocket fired")
	# Points + kill
	zombies = main.get_node("Zombies").get_children()
	var pts: int = player.points
	var k0: int = main.kills
	for zz in zombies:
		if not zz._dead:
			zz.take_damage(100000.0)
			break
	await wait(2)
	check(player.points > pts and main.kills == k0 + 1, "points + kill counted (%d -> %d)" % [pts, player.points])

	# Clear the round -> round 2 tougher, chests re-armed
	for zz in main.get_node("Zombies").get_children():
		if not zz._dead:
			zz.take_damage(1000000.0)
	main._to_spawn = 0
	await wait(5)
	check(main._alive == 0 and sfx.music_state == "break" and sfx.current_music_stream().resource_path.ends_with("music_between_rounds_loop.ogg"),
		"music crossfades to the between-rounds loop when the round is cleared (%s)" % sfx.music_state)
	main._alive = 0
	# Field Card offer after every cleared round: resolve it (skip) so the break can run
	main._offer_delay = 0.0
	await wait(3)
	var rs = root.get_node("RunState")
	if rs.offer_open:
		rs.skip()
	main._break_timer = 0.05
	await wait(10)
	check(main.current_round == 2, "round 2 started")
	check(sfx.music_state == "combat", "combat music again in round 2")
	check(main._zombie_stats(2).health > main._zombie_stats(1).health, "round 2 zombies tougher")
	check(chests[0].can_interact(), "chest re-armed for new round")

	# Game over saves progression
	player.max_health = 100
	player.health = 100
	player.damage_reduction = 0.0
	player.take_damage(1000000)
	await wait(2)
	check(main._game_over, "game over on death")
	check(sfx.music_state == "menu", "menu music on the game-over screen")
	check(progress.best_round >= 2, "best round saved (%d)" % progress.best_round)
	var cfg := ConfigFile.new()
	check(cfg.load(progress.save_path) == OK, "progress file written")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(progress.save_path))
	print("SMOKE TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
