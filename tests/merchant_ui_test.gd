extends SceneTree
## Merchant UI test (Gooey):  godot --headless --path . -s res://tests/merchant_ui_test.gd
## Home MERCHANT entry -> merchant_menu on Skillz's real Merchant when scripts/merchant/merchant.gd exists, else the
## merchant_api.gd stub (MAPI.force_stub = true forces the stub): stock render (4-6 cards), rarity borders,
## card content + stat deltas, can't-afford, owned / sold, buy confirm flow + balance, reroll cost rising + confirm,
## countdown format + ticking + hourly refresh, refusal reasons (stale / sold / stash full), portrait slot, nav + ESC home.
## Exit code = number of failures. Own save file; never touches the real one.

const SAVE := "user://progress_merchant_ui_test.cfg"
var _fails := 0
var _passes := 0
var prog
var home
var m
var MAPI
var MenuScr


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func frames(n: int) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	_run.call_deferred()


func press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	await frames(2)
	var up := InputEventAction.new()
	up.action = action
	up.pressed = false
	Input.parse_input_event(up)
	await frames(2)


func reason_of(card: Node) -> String:
	var l := card.find_child("OfferReason", true, false) as Label
	return l.text if l else "<none>"


func buy_btn(card: Node) -> Button:
	return card.find_child("OfferBuy", true, false) as Button


func _run() -> void:
	prog = root.get_node("Progress")
	prog.save_path = SAVE
	prog.armory_unequipped_on_load = []
	prog.gravemarks = 1000
	MAPI = load("res://scripts/ui/merchant_api.gd")
	MenuScr = load("res://scripts/ui/merchant_menu.gd")

	# ---------------------------------------------------------------- API factory / names
	var real: bool = ResourceLoader.exists(MAPI.REAL_SCRIPT) and not MAPI.force_stub
	var api0 = MAPI.create()
	if real:
		check(api0 != null and not MAPI.is_stub(api0) and api0.get_script().resource_path == MAPI.REAL_SCRIPT,
			"create() returns the real Merchant (%s exists)" % MAPI.REAL_SCRIPT)
	else:
		check(api0 != null and MAPI.is_stub(api0), "create() falls back to the stub (no %s)" % MAPI.REAL_SCRIPT)
	var was_forced: bool = MAPI.force_stub
	MAPI.force_stub = true
	var forced = MAPI.create()
	check(MAPI.is_stub(forced) and not MAPI.is_real_available(), "force_stub test hook: create() hands out the stub")
	MAPI.force_stub = was_forced
	print("INFO  merchant_ui_test runs against the %s" % ("REAL Merchant" if real else "stub"))
	for a in [api0, forced]:
		var all_m := true
		for k in MAPI.METHODS:
			all_m = all_m and a.has_method(MAPI.METHODS[k])
		var all_s := true
		for k in MAPI.SIGNALS:
			all_s = all_s and a.has_signal(MAPI.SIGNALS[k])
		check(all_m and all_s, "%s implements every METHODS / SIGNALS name (%d / %d)"
			% ["stub" if MAPI.is_stub(a) else "real Merchant", MAPI.METHODS.size(), MAPI.SIGNALS.size()])
	var s0: Array = api0.get_stock()
	var keys_ok := s0.size() > 0
	for k in ["offer_id", "slot", "item", "archetype", "rarity", "item_power", "perks", "price", "sold", "owned", "can_afford", "reason"]:
		keys_ok = keys_ok and s0[0].has(k)
	check(keys_ok, "offers carry the MERCHANT_API.md keys")

	# ---------------------------------------------------------------- home entry
	home = load("res://scripts/ui/home_menu.gd").new()
	home.dry_run = true
	root.add_child(home)
	await frames(10)
	var ids: Array = home._focus_order
	check(ids.has("merchant") and ids.find("merchant") == ids.find("armory") + 1 and ids.find("settings") == ids.find("merchant") + 1,
		"home: MERCHANT sits between ARMORY and SETTINGS (%s)" % [ids])
	var mb: Button = home._btns.get("merchant")
	check(mb != null and mb.text == "MERCHANT" and mb.name == "Btn_merchant", "home: Btn_merchant labelled MERCHANT")
	check(home._btns["armory"].focus_neighbor_bottom == home._btns["armory"].get_path_to(mb), "home: ↓ from ARMORY lands on MERCHANT")
	m = home._merchant
	check(m != null and not m.visible, "merchant menu hosted, closed")
	home._on_btn("merchant")
	await frames(4)
	check(m.visible and paused, "MERCHANT button opens the shop (tree paused like other menus)")
	var kit_inv = home._kit_proxy.inventory
	check(MAPI.is_stub(m.api) != real and m.inventory == kit_inv and m.api.get("inventory") == kit_inv,
		"shop grants into the kit stash Inventory (%s.inventory = home kit)" % ("Merchant" if real else "stub"))
	var inv = m.inventory

	# ---------------------------------------------------------------- stock render
	check(m.card_count() >= 4 and m.card_count() <= 6, "stock renders %d offer cards (4-6)" % m.card_count())
	var border_ok := true
	var content_ok := true
	for i in m.card_count():
		var c: PanelContainer = m._cards[i]
		var o: Dictionary = m._stock[i]
		var sb := c.get_theme_stylebox("panel") as StyleBoxFlat
		border_ok = border_ok and sb != null and sb.border_color.is_equal_approx(UIStyle.rarity_color(int(o.rarity))) and sb.border_width_left >= 3
		for n in ["OfferName", "OfferMaker", "OfferArchetype", "OfferIP", "OfferStats", "OfferPrice", "OfferBuy", "RarityTag"]:
			content_ok = content_ok and c.find_child(n, true, false) != null
		content_ok = content_ok and (c.find_child("OfferPrice", true, false) as Label).text == str(o.price)
		content_ok = content_ok and (c.find_child("IPNumber", true, false) as Label).text == str(o.item_power)
		content_ok = content_ok and c.find_child("GravemarkIcon", true, false) != null
		if str(o.item.flavor) != "":
			content_ok = content_ok and c.find_child("OfferFlavor", true, false) != null
		if o.perks.size() > 0:
			content_ok = content_ok and c.find_child("OfferPerks", true, false) != null
	check(border_ok, "every card border = its rarity colour (Rarity via UIStyle.rarity_color)")
	check(content_ok, "cards show name, maker, archetype, IP, key stats, perks, flavor, Gravemark price, BUY")
	# deltas vs equipped (same slot)
	var i0 := 0 # first offer whose slot has an equipped gun to compare against
	for i in m._stock.size():
		if inv.equipped.get(m._stock[i].item.slot) != null:
			i0 = i
			break
	var c0: PanelContainer = m._cards[i0]
	var w0 = m._stock[i0].item
	var cmp: Array = inv.compare(w0)
	var dmg := c0.find_child("Delta_Damage", true, false)
	check(dmg != null and cmp.size() > 0 and bool(dmg.get_meta("better")) == bool(cmp[0].better) and bool(dmg.get_meta("worse")) == bool(cmp[0].worse),
		"Damage delta matches Inventory.compare vs equipped %s" % (inv.equipped[w0.slot].display_name if inv.equipped[w0.slot] else "<none>"))
	var col_ok := true
	for d in c0.find_children("Delta_*", "", true, false):
		for l in d.get_children():
			if l is Label and l.text != "" and l.text != "=":
				var good: bool = d.get_meta("better")
				col_ok = col_ok and l.get_theme_color("font_color").is_equal_approx(UIStyle.GOOD if good else UIStyle.BAD)
	check(col_ok, "deltas green when better, red when worse")
	# 4 and 6 offer variants
	for n in [4, 6]:
		var st = MAPI.new()
		st.stock_size = n
		st._roll_all()
		var mm = MenuScr.new()
		mm.api = st
		mm.inventory = inv
		root.add_child(mm)
		await frames(2)
		check(mm.card_count() == n, "stub stock_size %d -> %d cards" % [n, mm.card_count()])
		mm.queue_free()
	await frames(2)

	# ---------------------------------------------------------------- nav focus
	await frames(2)
	var f: Control = m.get_viewport().gui_get_focus_owner()
	check(f != null and m._buy_btns.has(f), "opening focuses a BUY button")
	var b0: Button = m._buy_btns[0]
	var b1: Button = m._buy_btns[1]
	check(b0.get_node(b0.focus_neighbor_right) == b1 and b0.get_node(b0.focus_neighbor_top) == m._reroll_btn,
		"BUY → right = next card, ↑ = REROLL")
	if m._buy_btns.size() > 3:
		check(b0.get_node(b0.focus_neighbor_bottom) == m._buy_btns[3], "BUY ↓ = card below (3 columns)")

	# ---------------------------------------------------------------- can't afford
	var exp_i := 0
	for i in m._stock.size():
		if int(m._stock[i].price) > int(m._stock[exp_i].price):
			exp_i = i
	var pricey: Dictionary = m._stock[exp_i]
	prog.gravemarks = int(pricey.price) - 1
	prog.currency_changed.emit(prog.gravemarks)
	await frames(2)
	var pc: PanelContainer = m.card_for(str(pricey.offer_id))
	var want := "Need %d Gravemarks (you have %d)" % [int(pricey.price), int(pricey.price) - 1]
	check(buy_btn(pc).disabled and reason_of(pc) == want, "can't afford: BUY disabled, '%s'" % reason_of(pc))
	check(buy_btn(pc).tooltip_text == want, "can't afford reason also on the button tooltip")
	check((pc.find_child("OfferPrice", true, false) as Label).get_theme_color("font_color").is_equal_approx(UIStyle.BAD), "unaffordable price in red")
	check(not m.ask_buy(str(pricey.offer_id)) and m.last_toast.contains("Not enough Gravemarks"), "forced buy refused with API reason: %s" % m.last_toast)
	check(not m.confirm_visible(), "no confirm on refusal")

	# ---------------------------------------------------------------- buy confirm flow
	prog.gravemarks = 1000
	prog.currency_changed.emit(1000)
	await frames(2)
	var target: Dictionary = m._stock[1 if m._stock.size() > 1 else 0]
	for o in m._stock: # an offer we can afford (the real Merchant's prices come from data/merchant.json)
		if int(o.price) <= 1000 and o != m._stock[exp_i]:
			target = o
			break
	var tid := str(target.offer_id)
	var price := int(target.price)
	var got := []
	m.api.purchased.connect(func(oid, item, p): got.append([oid, item, p]))
	buy_btn(m.card_for(tid)).pressed.emit()
	await frames(2)
	check(m.confirm_visible(), "BUY opens the confirm card")
	var ct: Label = m.find_child("ConfirmTitle", true, false)
	var cc: Label = m.find_child("ConfirmCost", true, false)
	check(ct.text == "Buy %s for %d Gravemarks?" % [target.item.display_name.to_upper(), price], "confirm title: %s" % ct.text)
	check(cc.text == "1000  →  %d" % (1000 - price), "confirm cost line: %s" % cc.text)
	check(m.find_child("MerchantConfirm", true, false) is PanelContainer and m.find_child("ConfirmYes", true, false) != null
		and m.find_child("ConfirmNo", true, false) != null, "confirm built with the shared dialog helpers (card + CONFIRM / CANCEL)")
	check(m.get_viewport().gui_get_focus_owner() == m.find_child("ConfirmYes", true, false), "CONFIRM takes focus")
	await press("ui_cancel")
	check(not m.confirm_visible() and m.visible and prog.gravemarks == 1000, "ESC cancels the confirm only (shop stays, no charge)")
	m.ask_buy(tid)
	m.confirm_yes()
	await frames(2)
	check(prog.gravemarks == 1000 - price, "balance drops by the price (%d → %d)" % [1000, prog.gravemarks])
	check((m._bal_chip.find_child("GravemarkAmount", true, false) as Label).text == str(1000 - price), "header Gravemark chip updates live")
	var item = target.item
	var in_bp: bool = inv.backpack[item.slot].has(item)
	var auto_eq: bool = inv.equipped[item.slot] == item # bought for an empty slot: Inventory auto-equips it (seen)
	check((in_bp and not item.seen) or auto_eq,
		"bought gun is in the stash, unseen (or auto-equipped into an empty slot)%s" % (" [auto-equipped]" if auto_eq else ""))
	check(got.size() == 1 and got[0][0] == tid and got[0][1] == item and got[0][2] == price, "purchased(offer_id, item, price) emitted")
	check(m.last_bought == item and m.last_toast.contains("sent to your stash"), "toast: %s" % m.last_toast)
	var sc: PanelContainer = m.card_for(tid)
	check(sc.find_child("SoldStamp", true, false) != null and buy_btn(sc).disabled and buy_btn(sc).text == "SOLD" and sc.modulate.r < 0.8,
		"sold: dimmed card, SOLD stamp, BUY disabled")
	check(sc.find_child("OwnedTag", true, false) != null, "bought offer now flagged OWNED")
	check(not m.ask_buy(tid) and m.last_toast.contains("Sold out") and reason_of(sc) == "", "re-buy refused: Sold out (toast)")
	check(str(prog.stash.get("equipped", {})).length() > 0, "stash saved after the buy")

	# ---------------------------------------------------------------- owned (not sold): still buyable
	var other: Dictionary = {}
	for o in m._stock:
		if not o.sold and int(o.price) <= prog.gravemarks:
			other = o
			break
	var lookalike = root.get_node("GearDB").roll_weapon(str(other.item.archetype), 1, 1)
	lookalike.display_name = other.item.display_name # same archetype + name, different item_id: NOT owned
	inv.backpack[lookalike.slot].append(lookalike)
	m.refresh()
	await frames(1)
	var oc: PanelContainer = m.card_for(str(other.offer_id))
	check(oc.find_child("OwnedTag", true, false) == null, "same archetype + name but another item_id is not OWNED (item_id match only)")
	inv.backpack[lookalike.slot].erase(lookalike)
	var dupe = root.get_node("GearDB").roll_weapon(str(other.item.archetype), 1, 1)
	dupe.item_id = other.item.item_id
	inv.backpack[dupe.slot].append(dupe)
	m.refresh()
	await frames(1)
	oc = m.card_for(str(other.offer_id))
	check(oc.find_child("OwnedTag", true, false) != null and not buy_btn(oc).disabled and oc.find_child("SoldStamp", true, false) == null,
		"owned (same item_id already in stash): OWNED tag, BUY still enabled")
	inv.backpack[dupe.slot].erase(dupe)

	# ---------------------------------------------------------------- stash full
	var cap_was: int = inv.stash_cap
	inv.stash_cap = inv.carried_count()
	m.refresh()
	await frames(1)
	var sf: Dictionary = {}
	for o in m._stock:
		if not o.sold and inv.equipped.get(o.item.slot) != null:
			sf = o
			break
	var sfc: PanelContainer = m.card_for(str(sf.offer_id))
	var sf_txt := "Stash full (%d/%d)" % [inv.carried_count(), inv.stash_cap]
	check(buy_btn(sfc).disabled and reason_of(sfc) == sf_txt, "stash full: BUY disabled with '%s'" % reason_of(sfc))
	var bal_sf: int = prog.gravemarks
	check(not m.ask_buy(str(sf.offer_id)) and m.last_toast.contains(sf_txt) and prog.gravemarks == bal_sf, "stash full refusal toast, no charge")
	var direct = m.api.buy(str(sf.offer_id))
	check(not direct.ok and direct.reason == sf_txt and m.api.last_refusal_reason() == sf_txt, "api buy() refuses at the stash cap (40 default)")
	inv.stash_cap = cap_was
	check(cap_was == 40, "stash cap is 40")
	m.refresh()

	# ---------------------------------------------------------------- reroll
	prog.gravemarks = 1000
	prog.currency_changed.emit(1000)
	await frames(1)
	var cost0: int = m.api.reroll_cost()
	check(m._reroll_btn.text == "REROLL  %d" % cost0 and not m._reroll_btn.disabled, "REROLL shows its cost (%d)" % cost0)
	var ids_before: Array = m._stock.map(func(o): return str(o.offer_id))
	m._reroll_btn.pressed.emit()
	await frames(1)
	check(m.confirm_visible() and (m.find_child("ConfirmTitle", true, false) as Label).text.contains("Reroll"), "REROLL asks to confirm")
	m.confirm_yes()
	await frames(2)
	var cost1: int = m.api.reroll_cost()
	check(prog.gravemarks == 1000 - cost0, "reroll charged %d" % cost0)
	check(cost1 > cost0 and m._reroll_btn.text == "REROLL  %d" % cost1, "reroll cost rises (%d → %d)" % [cost0, cost1])
	var ids_after: Array = m._stock.map(func(o): return str(o.offer_id))
	var sold_kept := false
	var unsold_new := true
	for i in m._stock.size():
		if m._stock[i].sold:
			sold_kept = ids_after[i] == ids_before[i]
		else:
			unsold_new = unsold_new and ids_after[i] != ids_before[i]
	check(unsold_new and sold_kept, "reroll replaces unsold offers, sold slot stays")
	m.ask_reroll()
	m.confirm_yes()
	await frames(1)
	check(m.api.reroll_cost() > cost1, "rises again (%d)" % m.api.reroll_cost())
	prog.gravemarks = 3
	prog.currency_changed.emit(3)
	await frames(1)
	var rc: int = m.api.reroll_cost()
	check(m._reroll_btn.disabled and m._reroll_reason.text == "Need %d Gravemarks (you have 3)" % rc, "reroll unaffordable: disabled, '%s'" % m._reroll_reason.text)
	check(not m.ask_reroll() and m.last_toast.begins_with("Can't reroll"), "forced reroll refused: %s" % m.last_toast)
	prog.gravemarks = 1000
	prog.currency_changed.emit(1000)

	# ---------------------------------------------------------------- countdown
	check(MenuScr.format_countdown(0) == "REFRESH IN 00:00", "format 0 → 00:00")
	check(MenuScr.format_countdown(125) == "REFRESH IN 02:05", "format 125 → 02:05")
	check(MenuScr.format_countdown(59.2) == "REFRESH IN 01:00", "format 59.2 → 01:00 (ceil)")
	check(MenuScr.format_countdown(3599) == "REFRESH IN 59:59", "format 3599 → 59:59")
	check(MenuScr.format_countdown(3600) == "REFRESH IN 1:00:00", "format 3600 → 1:00:00")
	check(MenuScr.format_countdown(-5) == "REFRESH IN 00:00", "negative clamps to 00:00")
	var api = m.api
	api.now_offset = 0.0
	var ttr: int = api.time_to_refresh()
	if ttr < 30: # keep the hourly rollover away from the tick check
		api.now_offset = float(ttr + 60)
		api.refresh_if_due()
	m.tick()
	var t_a: String = m._countdown.text
	check(t_a == MenuScr.format_countdown(api.time_to_refresh()), "countdown label = time_to_refresh (%s)" % t_a)
	api.now_offset += 7.0
	var end := Time.get_ticks_msec() + 1300
	while Time.get_ticks_msec() < end:
		await process_frame
	var t_b: String = m._countdown.text
	var ttr_b: int = api.time_to_refresh() # a wall-clock second may pass between the tick and here (load): allow +1
	check(t_b != t_a and (t_b == MenuScr.format_countdown(ttr_b) or t_b == MenuScr.format_countdown(ttr_b + 1)),
		"countdown ticks every second (%s → %s)" % [t_a, t_b])
	# hourly refresh: new stock, reroll cost back to base
	var refreshed_n := [0]
	api.refreshed.connect(func(): refreshed_n[0] += 1)
	var ids_r: Array = m._stock.map(func(o): return str(o.offer_id))
	api.now_offset += float(api.time_to_refresh() + 1)
	m.tick()
	await frames(2)
	var ids_r2: Array = m._stock.map(func(o): return str(o.offer_id))
	var all_new := true
	for i in ids_r2.size():
		all_new = all_new and not ids_r.has(ids_r2[i])
	check(refreshed_n[0] == 1 and all_new and m.card_count() >= 4, "hourly refresh: refreshed(), all-new stock")
	check(api.reroll_cost() == api.reroll_base and m._reroll_btn.text == "REROLL  %d" % api.reroll_base, "reroll cost resets on refresh")
	var sold_any := false
	for o in m._stock:
		sold_any = sold_any or o.sold
	check(not sold_any, "fresh stock has nothing sold")
	api.now_offset -= 7200.0
	check(not api.refresh_if_due(), "clock rollback doesn't refresh early")
	api.now_offset += 7200.0

	# ---------------------------------------------------------------- stale offer
	var stale := str(m._stock[0].offer_id)
	m.ask_buy(stale)
	check(m.confirm_visible(), "confirm up for an offer")
	api.now_offset += float(api.time_to_refresh() + 1)
	api.refresh_if_due() # stock rolls while the confirm is open
	m.confirm_yes()
	await frames(1)
	check(m.last_toast.contains("Stock expired") and prog.gravemarks == 1000, "stale offer id: 'Stock expired', no charge (%s)" % m.last_toast)
	check(not m.ask_buy("bogus_id") and m.last_toast.contains("Stock expired"), "unknown id refuses with Stock expired")
	check(m._refusal.get("text", "") == "Stock expired", "refusal remembered for inline display")
	# inline refusal on a live card
	var live: Dictionary = m._stock[0]
	prog.gravemarks = int(live.price) - 1
	m.refuse(str(live.offer_id), "Not enough Gravemarks (need %d)" % int(live.price))
	await frames(1)
	check(reason_of(m.card_for(str(live.offer_id))) == "Not enough Gravemarks (need %d)" % int(live.price), "refusal reason inline on its card")
	check(m._toast.visible and m._toast.text.begins_with("Can't buy"), "refusal toast visible: %s" % m._toast.text)
	prog.gravemarks = 1000
	prog.currency_changed.emit(1000)

	# ---------------------------------------------------------------- away (no data): empty state
	var gone = MAPI.new()
	gone.available = false
	var am = MenuScr.new()
	am.api = gone
	am.inventory = inv
	root.add_child(am)
	am.open()
	await frames(2)
	var away_node: Control = am.find_child("MerchantAway", true, false)
	check(am.card_count() == 0 and away_node != null and away_node.visible and am.away_text() == "The Gravecrew merchant is away"
		and not (am.find_child("OfferScroll", true, false) as Control).visible,
		"no stock: empty state '%s' instead of cards" % am.away_text())
	check(am._reroll_btn.disabled and am._reroll_btn.text == "REROLL" and am._reroll_reason.text == ""
		and not (am.find_child("RefreshBox", true, false) as Control).visible, "away: REROLL disabled, no cost / countdown / red text")
	check(not am.ask_buy("anything") and (am.last_toast.contains("Stock expired") or am.last_toast.contains("away")), "away: buy refused (%s)" % am.last_toast)
	gone.available = true
	am.tick()
	await frames(1)
	check(am.card_count() >= 4 and not away_node.visible, "merchant back (data loaded): empty state clears on the next tick")
	am.close()
	paused = true # the main shop (m) is still open underneath
	am.queue_free()
	await frames(2)
	# ---------------------------------------------------------------- portrait slot
	var slot: Control = m.find_child("PortraitSlot", true, false)
	check(slot != null and slot.get_parent().name == "PortraitFrame" and slot.get_parent().get_parent().name == "MerchantPortrait"
		and slot == m.portrait_slot(), "portrait slot at MerchantPortrait/PortraitFrame/PortraitSlot")
	check(m.find_child("PortraitPlaceholder", true, false).visible and m.find_child("PortraitNamePlate", true, false) != null
		and (m.find_child("MerchantName", true, false) as Label).text == "THE GRAVEDIGGER", "placeholder silhouette + name plate")
	var tr = m.set_portrait_texture(UIStyle.gravemark_tex())
	await frames(1)
	check(tr.get_parent() == slot and not m.find_child("PortraitPlaceholder", true, false).visible and tr.anchor_right == 1.0,
		"set_portrait_texture fills the slot, hides the placeholder")
	var svc := SubViewportContainer.new()
	m.set_portrait_node(svc)
	await frames(1)
	check(svc.get_parent() == slot and svc.name == "PortraitCustom", "set_portrait_node takes a SubViewportContainer")

	# ---------------------------------------------------------------- ESC back home
	m.focus_first()
	await press("ui_cancel")
	await frames(2)
	check(not m.visible and not paused, "ESC closes the shop and unpauses")
	check(home.get_viewport().gui_get_focus_owner() == home._btns["merchant"], "focus back on home MERCHANT")
	home.open_merchant()
	await frames(2)
	check(m.visible, "re-open via open_merchant()")
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	await frames(2)
	var esc_up := esc.duplicate()
	esc_up.pressed = false
	Input.parse_input_event(esc_up)
	await frames(2)
	check(not m.visible, "Escape key also backs out")

	if real: # the real script with no data/merchant.json: whatever it does, the menu never shows a broken shop
		var rm = load(MAPI.REAL_SCRIPT).new()
		rm.data = {}
		var rmenu = MenuScr.new()
		rmenu.api = rm
		root.add_child(rmenu)
		await frames(2)
		var rn: Control = rmenu.find_child("MerchantAway", true, false)
		check(rmenu.card_count() > 0 or (rn.visible and rmenu.away_text() == "The Gravecrew merchant is away"),
			"real Merchant with data {}: cards or the clean empty state (%d cards)" % rmenu.card_count())
		rmenu.queue_free()
		await frames(2)
		if rm is Node:
			rm.free()

	home.queue_free()
	await frames(2)
	load("res://scripts/autoload/progress.gd").delete_save_files(SAVE)
	print("merchant_ui_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
