extends SceneTree
## Grenade items + salvage / Scrap attachments (Skillz, playtest 2026-10-22 #2 + #5, DESIGN §25,
## /workspace/skillz/GRENADE_ITEMS_API.md, SCRAP_API.md).
##   godot --headless --path . -s res://tests/grenade_items_test.gd
## items      GearDB.roll_grenade / starter_grenade, rarity = type rarity, fittings, to_dict / from_dict, throw_data (+ static rebuild)
## inventory  "grenade" slot: equip / unequip changes the player's thrown grenade (charges kept), save v2, v1 stash migration
## loot       loot tables drop GrenadeItems; legacy grenade consumable becomes an item; pickup shows the grenade model
## salvage    yield 1/3/6/12/25 + IP, salvage_preview / salvage_table, always under every buy price
## shop       attachment rarity, Scrap prices, purchase_with(scrap / gravemark), default currency (Scrap since 2026-10-22; Gravemarks via purchase_with)
## merchant   grenade offers: deterministic, priced, buy_grenade grants a GrenadeItem
## Exit code = number of failures. Temp save only (user://grenade_items_test.cfg).

var _passes := 0
var _fails := 0


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
	var prog = root.get_node("Progress")
	var P = load("res://scripts/autoload/progress.gd")
	prog.save_path = "user://grenade_items_test.cfg"
	P.delete_save_files(prog.save_path)
	prog.reset_skills()
	prog.stash = {}
	prog.merchant = {}
	prog.scrap = 0
	prog.gravemarks = 0
	prog.armory = {"upgrades": {}, "owned": [], "equipped": {}}
	var gdb = root.get_node("GearDB")
	var A = load("res://scripts/armory/armory.gd")
	var GI = load("res://scripts/items/grenade_item.gd")
	var INV = load("res://scripts/items/inventory.gd")

	# ------------------------------------------------------------ items
	var rng := RandomNumberGenerator.new()
	rng.seed = 2510
	var ok_rarity := true
	var ok_fit := true
	for id in gdb.grenades:
		var g = gdb.roll_grenade(id, 5, -1, rng)
		ok_rarity = ok_rarity and g.rarity == Rarity.from_id(str(gdb.grenades[id].rarity)) and g.slot == "grenade" and g.grenade_id == id
		var want := int(gdb.grenade_items.fittings_per_rarity[Rarity.IDS[g.rarity]])
		ok_fit = ok_fit and g.fittings.size() == mini(want, gdb.grenade_fitting_pool(id).size())
	check(ok_rarity, "roll_grenade: every type, rarity = the type's rarity, slot grenade")
	check(ok_fit, "fittings per rarity 1/1/2/2/3 (capped by the type's pool)")
	check(not gdb.grenade_fitting_pool("cinderjar").has("short_wick") and not gdb.grenade_fitting_pool("frag").has("steeped")
		and gdb.grenade_fitting_pool("requiem_bell").has("steeped"), "fitting pool: Short Wick needs a fuse (Cinderjar is impact), Steeped only on effect grenades")
	var tg = gdb.roll_grenade("tallyhook", 1, 200, null, 0)
	tg.fittings = {"heavy_packing": 1.1, "wide_casing": 1.1, "quick_rearm": 0.9}
	var td: Dictionary = tg.throw_data()
	var base: Dictionary = gdb.grenade("tallyhook")
	var ipm := 1.0 + 100 * 0.003
	check(absf(float(td.damage) - float(base.damage) * 1.1 * ipm) < 0.01 and absf(float(td.radius) - float(base.radius) * 1.1) < 0.001
		and absf(float(td.cooldown) - float(base.cooldown) * 0.9) < 0.001 and absf(float(td.chain_range) - float(base.chain_range) * 1.1) < 0.001
		and str(td.variant) == "tallyhook" and str(td.rarity) == "rare" and int(td.item_power) == 200,
		"throw_data: grenades.json base x Fittings x Item Power (dmg %.0f -> %.0f, cd %.1f)" % [float(base.damage), float(td.damage), float(td.cooldown)])
	check(float(gdb.grenade("tallyhook").damage) == float(base.damage), "throw_data never edits GearDB's base data")
	var d: Dictionary = tg.to_dict()
	var back = gdb.item_from_dict(d)
	check(back.get_script() == GI and back.grenade_id == "tallyhook" and back.fittings == tg.fittings and back.item_power == 200 and back.item_id == tg.item_id
		and str(d.get("class")) == "grenade" and str(d.get("variant")) == "tallyhook" and d.get("fittings") is Dictionary and int(d.get("rarity")) == 2,
		"to_dict / item_from_dict round-trip (class, grenade_id, variant, rarity, item_power, fittings)")
	check(GI.throw_data_from_dict(d) == td, "GrenadeItem.throw_data_from_dict(to_dict) == throw_data (co-op host rebuild)")
	var bad := d.duplicate(true)
	bad["rarity"] = 4
	check(gdb.item_from_dict(bad).rarity == 2, "a dict with the wrong rarity loads as the type's rarity")
	var gone := d.duplicate(true)
	gone["grenade_id"] = "no_such"
	gone["variant"] = "no_such"
	check(gdb.item_from_dict(gone) == null, "removed grenade type -> null (dropped on load)")
	var st = gdb.starter_grenade("pulse")
	check(st.grenade_id == "pulse" and st.item_power == 100 and st.fittings.is_empty() and GI.throw_data_for("pulse", {}, 100).damage == gdb.grenade("pulse").damage,
		"starter_grenade(class id): IP 100, no fittings = the plain class grenade")
	check(tg.card_stats().size() == 4 and tg.fitting_rows().size() == 3 and str(tg.fitting_rows()[0].text) == "+10% damage" and tg.get_summary().contains("Tallyhook") == false and tg.get_summary().contains("chains"),
		"card_stats (4 rows) / fitting_rows text / summary")
	var spec: Dictionary = load("res://scripts/combat/grenade.gd").make_spec(null, td, Vector3.ZERO, Vector3.FORWARD, 7)
	check(spec.type_id == &"grenade" and spec.variant == &"tallyhook" and int(spec.rarity) == 2 and spec.data == td, "make_spec from item data: type grenade, variant id, rarity int, data = item stats")

	# ------------------------------------------------------------ salvage
	var y := [A.scrap_yield(0), A.scrap_yield(1), A.scrap_yield(2), A.scrap_yield(3), A.scrap_yield(4)]
	check(y == [1, 3, 6, 12, 25], "salvage yield C/U/R/L/M = 1/3/6/12/25 (%s)" % [y])
	var att_p: Array = A.attachment_price_table().map(func(r): return int(r.scrap))
	var M = load("res://scripts/merchant/merchant.gd").new()
	var below := true
	for r in 5:
		var top: int = A.scrap_yield(r, 210)
		below = below and top < int(att_p[r]) and top < M.price_for(r) and top < M.grenade_price_for(r) * 3
	check(att_p == [8, 14, 24, 40, 65] and below, "salvage < Scrap attachment price %s and < Merchant price at every rarity (even IP 210)" % [att_p])
	check(prog.salvage_table().size() == 5 and int(prog.salvage_table(200)[2].scrap) == 8, "Progress.salvage_table(ip): Rare at IP 200 = 6 + 2")
	var inv = INV.new()
	root.add_child(inv)
	var sg = gdb.roll_grenade("gravewell", 1, 150)
	inv.add_item(sg) # empty slot: auto-equips
	var sp: Dictionary = prog.salvage_preview(sg, inv)
	check(not sp.ok and sp.reason == "Equipped" and int(sp.scrap) == 13, "salvage_preview: equipped Legendary IP 150 -> 13 Scrap, refused (Equipped)")
	var sg2 = gdb.roll_grenade("frag", 1, 100)
	inv.add_item(sg2)
	check(inv.backpack.grenade.has(sg2) and prog.salvage_preview(sg2, inv).ok and prog.scrap_item(sg2, inv) == 1 and prog.scrap == 1
		and not inv.backpack.grenade.has(sg2), "spare grenade: salvage_preview ok, scrap_item pays 1 Scrap and removes it")

	# ------------------------------------------------------------ compare(): non-numeric rows (v070 #6)
	var cj = gdb.roll_grenade("cinderjar", 1, 100)
	var fz_row: Array = cj.card_stats().filter(func(r): return r[0] == "Fuse")[0]
	check(fz_row[1] == "impact", "cinderjar's Fuse row reads \"impact\"")
	var cmp_cj: Array = inv.compare(cj) # vs the equipped gravewell (fuse 1.2 s)
	var cmp_fz: Dictionary = cmp_cj.filter(func(r): return r.label == "Fuse")[0] if cmp_cj.any(func(r): return r.label == "Fuse") else {}
	check(cmp_cj.size() == 4 and not cmp_fz.is_empty() and cmp_fz.text == "" and cmp_fz.delta == 0.0 and not cmp_fz.better and not cmp_fz.worse and cmp_fz.numeric == false,
		"compare(grenade): the FUSE \"impact\" row has an empty delta (text \"\", not better, not worse, numeric false)")
	var cmp_dmg: Dictionary = cmp_cj.filter(func(r): return r.label == "Damage")[0]
	check(cmp_dmg.numeric == true and cmp_cj.filter(func(r): return r.numeric).size() == 3, "compare(grenade): the Damage / Radius / Cooldown rows keep their numeric deltas")
	var fr = gdb.roll_grenade("frag", 1, 100)
	var cmp_fr: Array = inv.compare(fr)
	check(cmp_fr.size() == 4 and cmp_fr.all(func(r): return r.numeric) and cmp_fr.filter(func(r): return r.label == "Fuse")[0].text != "",
		"compare(grenade): two timed grenades still get a numeric FUSE delta")
	# an equipped impact grenade as the baseline blanks the row too
	var ibase = INV.new()
	root.add_child(ibase)
	ibase.add_item(cj)
	var cmp_back: Array = ibase.compare(fr)
	check(cmp_back.filter(func(r): return r.label == "Fuse")[0].text == "" and cmp_back.filter(func(r): return r.label == "Damage")[0].numeric,
		"compare(grenade) against an equipped impact grenade: FUSE blank too")
	ibase.free()

	# ------------------------------------------------------------ inventory slot + save
	check(INV.ALL_SLOTS.has("grenade") and INV.SAVE_VERSION == 2 and inv.equipped_grenade() == sg, "Inventory: grenade slot, save v2, equipped_grenade()")
	var sv: Dictionary = inv.to_save_dict()
	check(sv.equipped.get("grenade") is Dictionary and str(sv.equipped.grenade.grenade_id) == "gravewell", "to_save_dict carries the grenade slot")
	var inv2 = INV.new()
	root.add_child(inv2)
	inv2.load_save_dict(sv)
	check(inv2.equipped_grenade() != null and inv2.equipped_grenade().item_id == sg.item_id, "load_save_dict restores the equipped grenade")
	var inv_s = INV.new()
	root.add_child(inv_s)
	inv_s.give_fresh_starter_loadout()
	var v1: Dictionary = inv_s.to_save_dict()
	inv_s.free()
	v1.equipped.erase("grenade")
	v1.backpack.erase("grenade")
	v1["version"] = 1
	var mig: Dictionary = prog.migrate_stash(v1)
	check(mig.equipped.has("grenade") and mig.equipped.grenade == null and mig.backpack.grenade == [] and int(mig.version) == 2, "migrate_stash v1 -> v2: empty grenade slot added")
	prog.stash = mig
	var inv3 = INV.new()
	root.add_child(inv3)
	check(prog.restore_stash(inv3) and inv3.equipped_grenade() != null and inv3.equipped_grenade().fittings.is_empty()
		and inv3.equipped_grenade().grenade_id == str(prog.load_selected_class().grenade_id), "old save: restore fills the slot with the class grenade (%s)" % (inv3.equipped_grenade().grenade_id if inv3.equipped_grenade() else "none"))
	check(inv3.equipped.primary != null and inv3.equipped.chest != null, "old save: weapons / armor untouched")
	inv.free()
	inv2.free()
	inv3.free()

	# ------------------------------------------------------------ attachment shop
	check(A.attachment_rarity("witchlight_dabs") == "common" and A.attachment_rarity("hush_can") == "uncommon" and A.attachment_rarity("mourners_sleeve") == "rare"
		and A.attachment_rarity("mine_lamp") == "legendary" and A.attachment_rarity("echo_drum") == "mythic" and A.attachment_rarity("gravesight") == "legendary",
		"attachment rarity: cost / tier floor / unique step / optic rarity")
	check(A.attachment_prices("hush_can") == {"scrap": 14, "gravemark": 4} and A.attachment_currency() == "scrap" and A.cost_of("hush_can") == 14
		and A.cost_of("hush_can", "gravemark") == 4 and A.attachment_currency("gravemark") == "gravemark" and A.attachment_currency("bogus") == "",
		"hush_can: 14 Scrap or 4 Gravemarks; default currency scrap (cost_of 14; cost_of(id, \"gravemark\") 4; an unknown currency is refused)")
	prog.scrap = 13
	check(not A.purchase_check("hush_can", "scrap").ok and A.purchase_check("hush_can", "scrap").reason == "Need 14 Scrap (you have 13)", "short on Scrap -> \"Need 14 Scrap (you have 13)\"")
	prog.scrap = 20
	var api = A.new()
	check(api.purchase_with("hush_can", "scrap") and A.owned("hush_can") and prog.scrap == 6 and prog.gravemarks == 0, "purchase_with(hush_can, scrap): 14 Scrap spent, owned, Gravemarks untouched")
	check(not api.purchase_with("pocket_hush", "points") and A.last_refusal_reason() != "", "unknown currency refused")
	var la: Array = api.list_attachments("auto_rifle")
	var e: Dictionary = la.filter(func(x): return x.id == "hush_can")[0] if la.any(func(x): return x.id == "hush_can") else {}
	check(e.has_all(["currency", "rarity", "prices", "scrap_cost", "gravemark_cost", "can_afford_scrap", "can_afford_gravemark"]) and int(e.scrap_cost) == 14 and e.owned and e.currency == "scrap",
		"list_attachments entries: currency / rarity / prices / scrap_cost / can_afford_scrap")
	var ph_s: int = A.attachment_price("pocket_hush", "scrap")
	prog.scrap = ph_s
	prog.gravemarks = 3
	check(api.purchase("pocket_hush") and prog.scrap == 0 and prog.gravemarks == 3, "purchase(id) pays Scrap by default (%d), Gravemarks untouched" % ph_s)
	var ph2: String = "witchlight_dabs"
	prog.scrap = 0
	prog.gravemarks = A.cost_of(ph2, "gravemark")
	check(not api.purchase(ph2) and api.purchase_with(ph2, "gravemark") and A.owned(ph2) and prog.gravemarks == 0 and prog.scrap == 0,
		"Gravemark payment still works: purchase_with(id, \"gravemark\") when the default (Scrap) can't pay")
	var mt: Dictionary = A.matches_to_max("medium")
	print("      scrap/match medium %.1f; all attachments %d Scrap = %d matches; one weapon to V %d matches" % [mt.scrap_per_match, mt.attachments_scrap_cost, mt.attachments_in_scrap, mt.one_weapon_max])
	check(mt.attachments_scrap_cost > 600 and mt.one_weapon_max >= 6 and mt.one_weapon_max <= 12, "pacing: every attachment in Scrap > 600, one weapon to V in 6-12 Medium matches")

	# ------------------------------------------------------------ loot
	var saved_dc: float = float(gdb.loot.tables.zombie.drop_chance)
	gdb.loot.tables.zombie.drop_chance = 1.0
	var got = null
	for i in 600:
		for it in gdb.roll_table("zombie", 5):
			if it.get_script() == GI:
				got = it
	gdb.loot.tables.zombie.drop_chance = saved_dc
	check(got != null and got.item_power > 100, "zombie table drops GrenadeItems (IP from the round)")
	var pk = load("res://scenes/pickup.tscn").instantiate()
	pk.item = gdb.roll_grenade("cinderjar", 3)
	root.add_child(pk)
	await physics_frame
	check(pk.is_gear() and str(pk.get_prompt()).contains("Uncommon Grenade") and (not ResourceLoader.exists("res://assets/models/grenades/cinderjar.glb") or pk._visual.scene_file_path.contains("cinderjar")),
		"pickup: gear prompt (%s), grenade model" % pk.get_prompt())
	pk.free()

	# ------------------------------------------------------------ merchant
	prog.merchant = {}
	var m = load("res://scripts/merchant/merchant.gd").new()
	m.clock = func(): return 1.8e9
	var gs: Array = m.grenade_stock()
	var gs2: Array = m.grenade_stock()
	check(gs.size() == 2 and gs.all(func(o): return o.item != null and o.item.get_script() == GI and int(o.price) == m.grenade_price_for(int(o.rarity)) and o.has_all(["offer_id", "grenade_id", "fittings", "can_afford", "currency"]))
		and gs.map(func(o): return o.item_id) == gs2.map(func(o): return o.item_id), "grenade_stock: 2 GrenadeItem offers, priced by rarity, stable between calls")
	var prices: Array = []
	for r in 5:
		prices.append(m.grenade_price_for(r))
	check(prices == [3, 7, 16, 39, 79], "grenade prices C..M = 3/7/16/39/79 Gravemarks (%s)" % [prices])
	var kinv = INV.new()
	root.add_child(kinv)
	kinv.give_fresh_starter_loadout()
	prog.bind_inventory(kinv)
	prog.gravemarks = 200
	var o0: Dictionary = gs[0]
	var res: Dictionary = m.buy_grenade(str(o0.offer_id))
	check(res.ok and res.item.get_script() == GI and kinv.backpack.grenade.has(res.item) and prog.gravemarks == 200 - int(o0.price)
		and m.grenade_stock()[0].sold, "buy_grenade: Gravemarks spent, GrenadeItem in the Kit backpack, offer sold")
	check(not m.buy_grenade(str(o0.offer_id)).ok, "sold offer can't be bought twice")
	var g_old: Array = m.grenade_stock().map(func(o): return o.offer_id)
	m.reroll()
	var g_new: Array = m.grenade_stock().map(func(o): return o.offer_id)
	check(g_new[0] == g_old[0] and g_new[1] != g_old[1], "reroll replaces the unsold grenade offer, keeps the sold one")
	m.free()
	M.free()
	prog.bind_inventory(null)
	kinv.free()

	# ------------------------------------------------------------ live player
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	await wait(3)
	var main = current_scene
	main.set("_break_timer", 9999.0)
	var pl = main.player
	var pin = pl.inventory
	check(pin.equipped_grenade() != null and str(pl.grenade_data.get("item_id", "")) == pin.equipped_grenade().item_id,
		"match start: the player throws the equipped grenade item (%s)" % pl.grenade_data.get("name", "?"))
	var lw = gdb.roll_grenade("leechbell", 4, 160)
	lw.fittings = {"quick_rearm": 0.9}
	pin.add_item(lw)
	var ch0: int = pl.grenade_charges
	var sig: Array = []
	pin.grenade_equipped.connect(func(it): sig.append(it))
	check(pin.equip_grenade(lw) and str(pl.grenade_data.variant) == "leechbell" and str(pl.grenade_data.item_id) == lw.item_id and pl.grenade_charges == ch0 and sig == [lw],
		"equip_grenade: player throws Leechbell now, charges kept, grenade_equipped(item)")
	var k: float = pl.grenade_cooldown / float(lw.throw_data().cooldown)
	check(absf(float(pl.grenade_data.cooldown) - float(gdb.grenade("leechbell").cooldown) * 0.9) < 0.001 and k > 0.0, "Quick Rearm on the cooldown (%.1f s base)" % float(pl.grenade_data.cooldown))
	if FileAccess.get_file_as_string("res://scripts/player.gd").contains("GrenadeItem.resolve"):
		pl.apply_stats()
		check(str(pl.grenade_data.get("item_id", "")) == lw.item_id, "player.gd §25: apply_stats keeps the equipped item (with its Fittings)")
	else:
		pl.apply_stats()
		check(str(pl.grenade_data.get("item_id", "")) == lw.item_id and absf(float(pl.grenade_data.cooldown) - float(gdb.grenade("leechbell").cooldown) * 0.9) < 0.001,
			"(no player.gd §25 hunk) apply_stats keeps the item + Fittings via the §24c meta -> GearDB.grenade(@item_id)")
		GI.apply_to_player(pl)
	check(pin.unequip_grenade() and pin.equipped_grenade() == null and str(pl.grenade_data.variant) == str(gdb.grenade(str(pl.player_class.grenade_id)).variant)
		and not pl.has_meta("grenade_override"), "unequip_grenade: back to the class grenade")
	pin.equip_grenade(lw)
	var TP = load("res://scripts/projectiles/thrown_projectile.gd")
	var legacy = gdb.grenade_pickup("rookery")
	check(legacy.give_grenade(pl) and pin.equipped_grenade().grenade_id == "rookery" and pin.backpack.grenade.has(lw) and str(pl.grenade_data.variant) == "rookery",
		"legacy grenade consumable -> a Rookery GrenadeItem equipped, old one to the backpack")
	pl._grenade_cd = 0.0
	pl.grenade_charges = pl.grenade_charges_max
	pl.throw_grenade()
	await wait(2)
	var found := false
	for n in main.get_children():
		if n.get_script() == TP and n.type_id == &"grenade":
			found = found or (n.variant == &"rookery" and str(n.spec.get("data", {}).get("item_id", "")) == pin.equipped_grenade().item_id)
	check(found, "throw: ThrownProjectile type grenade, variant rookery, spec data = the item's stats")

	P.delete_save_files(prog.save_path)
	print("grenade_items_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
