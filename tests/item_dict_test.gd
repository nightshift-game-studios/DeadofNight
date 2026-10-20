extends SceneTree
## Item.from_dict(to_dict()) round trip for every item class (Netz, co-op loot grants).
##   godot --headless --path . -s res://tests/item_dict_test.gd   (exit code = failures)

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


## to_dict() after a JSON-ish wire trip (var_to_bytes, what RPCs do) and rebuild.
func _wire(d: Dictionary) -> Dictionary:
	return bytes_to_var(var_to_bytes(d))


func _same(a: Dictionary, b: Dictionary) -> bool:
	return JSON.stringify(a, "", true) == JSON.stringify(b, "", true)


func _run() -> void:
	var gear = root.get_node("GearDB")
	# loaded at runtime: the item classes reference the GearDB autoload, which a -s script can't see at compile time
	var Item = load("res://scripts/items/item.gd")
	var WeaponItem = load("res://scripts/items/weapon_item.gd")
	var ArmorItem = load("res://scripts/items/armor_item.gd")
	var ConsumableItem = load("res://scripts/items/consumable_item.gd")
	var n_w := 0
	var ok_w := true
	var bad := ""
	for arch in gear.weapons.keys():
		for r in [0, 2, 3, 4]: # common, rare, legendary, mythic
			var w = gear.roll_weapon(str(arch), r, 5)
			if w == null:
				continue
			n_w += 1
			var d: Dictionary = w.to_dict()
			var back = Item.from_dict(_wire(d))
			var ok: bool = back != null and is_instance_of(back, WeaponItem) and _same(back.to_dict(), d) and back.arch == w.arch \
				and back.element == w.element and back.ammo == back.mag_size()
			if not ok:
				ok_w = false
				bad = "(first mismatch: %s r%d)" % [arch, r]
	check(n_w > 0 and ok_w, "weapons: %d rolled weapons round-trip to_dict -> from_dict -> to_dict identically %s" % [n_w, bad])
	var n_a := 0
	var ok_a := true
	for i in 12:
		var a = gear.roll_armor() if gear.has_method("roll_armor") else null
		if a == null:
			break
		n_a += 1
		var d: Dictionary = a.to_dict()
		var back = Item.from_dict(_wire(d))
		if back == null or not is_instance_of(back, ArmorItem) or not _same(back.to_dict(), d) or back.slot_label != a.slot_label:
			ok_a = false
	check(n_a > 0 and ok_a, "armor: %d rolled armor pieces round-trip identically" % n_a)
	for id in ["health_pack", "ammo_box", "heavy_ammo"]:
		var c = gear.consumable(id)
		var back = Item.from_dict(_wire(c.to_dict()))
		check(is_instance_of(back, ConsumableItem) and back.id == id and _same(back.to_dict(), c.to_dict()) and back.effect == c.effect \
			and back.amount == c.amount, "consumable %s round-trips (effect + amount kept)" % id)
	var w2 = gear.roll_weapon(str(gear.weapons.keys()[0]), 1, 1)
	var b2 = Item.from_dict(w2.to_dict())
	check(b2.item_id == w2.item_id and b2.rarity == w2.rarity and b2.item_power == w2.item_power and b2.perks == w2.perks,
		"weapon keeps item_id, rarity, item power and perks")
	check(Item.from_dict({}) == null and Item.from_dict({"class": "nope"}) == null, "unknown / empty dict -> null")
	print("ITEM DICT TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
