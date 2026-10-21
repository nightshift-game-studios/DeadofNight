extends SceneTree
## Headless test:  godot --headless --path . -s res://tests/weapon_attrs_test.gd
## Playtest #33 named weapon attributes (WEAPON_ATTRS.md): counts per rarity, playstyle minimum, seeded rolls,
## the item dict "attributes" field, Merchant decoration, and every new attribute effect in PerkSystem.
## Exit code = number of failures. Untyped item refs on purpose (see TEAM notes on class_name in tests).

const PERKS := "res://scripts/gear/perk_system.gd"

var _fails := 0
var _passes := 0
var gdb
var main
var player
var PS


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func near(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	gdb = root.get_node("GearDB")
	PS = load(PERKS)
	_roll_checks()
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
	await wait(30)
	_merchant_checks()
	await _effect_checks()
	print("WEAPON ATTRS TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


func _sig_ids() -> Array:
	return gdb.perks.keys().filter(func(k): return bool(gdb.perks[k].get("signature", false)))


func _roll_checks() -> void:
	var want := [0, 1, 2, 3, 3]
	var names := {}
	var names_ok := true
	for k in gdb.perks:
		var n := str(gdb.perks[k].name).to_lower()
		names_ok = names_ok and not names.has(n) and str(gdb.perks[k].get("tag", "")) != "" and str(gdb.perks[k].get("description", "")) != ""
		names[n] = true
	check(gdb.perks.size() >= 19 and names_ok, "%d perks/attributes, unique names, each with a tag and description" % gdb.perks.size())
	check(gdb.attribute_pool().size() >= 16 and _sig_ids().all(func(s): return not (s in gdb.attribute_pool())), "attribute pool excludes Mythic signatures")
	var counts_ok := true
	var ps_ok := true
	var sig_ok := true
	for rar in 5:
		check(gdb.attribute_count(rar) == want[rar], "rarity %d rolls %d attributes" % [rar, gdb.attribute_count(rar)])
		for i in 40:
			seed(1000 + i * 7 + rar)
			var w = gdb.roll_weapon("", rar, 5)
			var arch_sig := str(gdb.weapons.get(w.archetype, {}).get("mythic", {}).get("perk", "")) if rar == 4 else ""
			var rolled: Array = w.perks.slice(1) if arch_sig != "" else w.perks.duplicate()
			if rolled.size() != want[rar]:
				counts_ok = false
				print("  ", w.archetype, " r", rar, " ", w.perks)
			if rar >= 3 and not rolled.any(func(p): return bool(gdb.perks[p].get("playstyle", false))):
				ps_ok = false
			if arch_sig != "" and (w.perks[0] != arch_sig or not w.attributes()[0].signature):
				sig_ok = false
			var uniq := {}
			for p in w.perks:
				uniq[p] = true
			counts_ok = counts_ok and uniq.size() == w.perks.size()
	check(counts_ok, "rolled counts Common 0 / Uncommon 1 / Rare 2 / Legendary 3 / Mythic 3 + signature, no duplicates")
	check(ps_ok, "every Legendary and Mythic has at least one playstyle attribute")
	check(sig_ok, "Mythic keeps its archetype signature first, flagged signature in attributes()")
	# seeded: same attr_seed -> same attributes; peers rebuild from the dict
	seed(4242)
	var a = gdb.roll_weapon("", 3, 5)
	var b = load("res://scripts/items/weapon_item.gd").new()
	b.archetype = a.archetype
	b.rarity = a.rarity
	b.attr_seed = a.attr_seed
	gdb.roll_attributes(b)
	check(b.perks == a.perks, "same attr_seed + rarity re-rolls the same attributes (%s)" % [a.perks])
	seed(4242)
	var a2 = gdb.roll_weapon("", 3, 5)
	check(a2.perks == a.perks and a2.attr_seed == a.attr_seed, "same global seed (Merchant / host) -> identical weapon attributes")
	var d: Dictionary = a.to_dict()
	var rows: Array = d.get("attributes", [])
	var row_ok: bool = rows.size() == 3 and d.get("attr_seed") == a.attr_seed
	for r in rows:
		for k in ["id", "name", "description", "tag", "playstyle", "signature", "glyph", "icon_color"]:
			row_ok = row_ok and r.has(k)
		row_ok = row_ok and str(r.icon_color).begins_with("#")
	check(row_ok, "to_dict carries attr_seed + attributes rows {id,name,description,tag,playstyle,signature,glyph,icon_color}")
	var c = load("res://scripts/items/item.gd").from_dict(d) if load("res://scripts/items/item.gd").has_method("from_dict") else null
	if c != null:
		check(c.perks == a.perks and c.attr_seed == a.attr_seed, "from_dict round-trips perks + attr_seed")


func _merchant_checks() -> void:
	var m = root.get_node_or_null("Merchant")
	if m == null:
		check(false, "Merchant autoload present")
		return
	var stock: Array = m.get_stock()
	var ok := stock.size() > 0
	for o in stock:
		var at: Array = o.get("attributes", [])
		ok = ok and at.size() == (o.perks as Array).size() and at.size() >= gdb.attribute_count(int(o.rarity))
	check(ok, "Merchant stock entries carry attributes rows (%d offers)" % stock.size())


func _weapon(perk_id: String):
	var w = player.current_weapon()
	w.perks.assign([perk_id])
	w.buffs.clear()
	w.ammo = w.mag_size()
	return w


func _zombie(offset: Vector3):
	var z = main.ZOMBIE_SCENE.instantiate()
	z.setup(100000, 0.0, 0)
	main.zombies_root.add_child(z)
	z.global_position = player.global_position + offset
	return z


func _effect_checks() -> void:
	var keep: Array = player.current_weapon().perks.duplicate()
	var w = _weapon("tail_rounds")
	w.ammo = w.mag_size() - 1
	var full: float = PS.damage_mult(w, player)
	w.ammo = 0
	check(near(full, 1.0) and near(PS.damage_mult(w, player), 1.3), "Tail Rounds: +30% on the last 30% of the mag")
	w = _weapon("opening_hymn")
	w.ammo = w.mag_size() - 1
	var first: float = PS.damage_mult(w, player)
	w.ammo = w.mag_size() - 5
	check(near(first, 1.35) and near(PS.damage_mult(w, player), 1.0), "Opening Hymn: +35% on the first 3 rounds of a mag")
	w = _weapon("graveside_calm")
	player.velocity = Vector3.ZERO
	await wait(45)
	check(near(PS.damage_mult(w, player), 1.2), "Graveside Calm: +20% after standing still")
	w = _weapon("runaway_fire")
	var calm: float = PS.damage_mult(w, player)
	player.velocity = Vector3(8, 0, 0)
	check(near(calm, 1.0) and near(PS.damage_mult(w, player), 1.15) and PS.spread_mult(w, player) < 1.0, "Runaway Fire: +15% damage and tighter spread at speed")
	player.velocity = Vector3.ZERO
	w = _weapon("ember_will")
	var hp: int = player.health
	player.health = int(player.max_health * 0.3)
	var low: float = PS.damage_mult(w, player)
	player.health = hp
	check(near(low, 1.3) and near(PS.damage_mult(w, player), 1.0), "Ember Will: +30% under 40% health")
	w = _weapon("spent_breath")
	var rm_full: float = PS.reload_mult(w)
	w.ammo = 0
	check(near(rm_full, 1.0) and near(PS.reload_mult(w), 0.6), "Spent Breath: 40% faster reload from empty")
	w = _weapon("bracewire")
	player.ads_active = true
	var ads: float = PS.spread_mult(w, player)
	player.ads_active = false
	check(near(ads, 0.65) and near(PS.spread_mult(w, player), 1.0), "Bracewire: -35% spread while aiming")
	w = _weapon("pocket_salvage")
	w.ammo = 0
	w.reserve = 100
	PS.on_kill(w, player)
	check(w.ammo == maxi(ceili(w.mag_size() * 0.2), 1) and w.reserve == 100 - w.ammo, "Pocket Salvage: a kill moves 20% of a mag from reserve")
	# on-hit statuses (chance forced to 1 for the test)
	var z = _zombie(Vector3(0, 0, -4))
	var z2 = _zombie(Vector3(2, 0, -4))
	await wait(3)
	var saved := {}
	for id in ["smolder_shot", "mire_rounds", "pale_brand", "arc_tether"]:
		saved[id] = gdb.perks[id].get("chance", 1.0)
		gdb.perks[id]["chance"] = 1.0
	for pair in [["smolder_shot", "burn"], ["mire_rounds", "slow"], ["pale_brand", "mark"]]:
		w = _weapon(pair[0])
		PS.on_hit(w, player, z.global_position + Vector3(0, 1, 0), 50.0, z)
		check(z.has_status(pair[1]), "%s applies %s on hit" % [gdb.perks[pair[0]].name, pair[1]])
	var hp2: float = z2.health
	w = _weapon("arc_tether")
	PS.on_hit(w, player, z.global_position + Vector3(0, 1, 0), 100.0) # no target: resolved from pos
	await wait(2)
	check(z2.health < hp2, "Arc Tether: arcs 40%% of the hit to a nearby zombie (%.0f -> %.0f)" % [hp2, z2.health])
	for id in saved:
		gdb.perks[id]["chance"] = saved[id]
	player.current_weapon().perks.assign(keep)
	z.queue_free()
	z2.queue_free()
