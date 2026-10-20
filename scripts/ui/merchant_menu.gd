extends MenuBase
## MERCHANT (Gooey): hourly gun shop opened from the home screen. Logic lives in Skillz's Merchant
## (scripts/merchant/merchant.gd, contract /workspace/skillz/MERCHANT_API.md); until it lands, merchant_api.gd's stub.
## Every API call goes through MerchantAPI.call_api / sig so names live in merchant_api.gd only.
##
## Layout: header (title, REFRESH IN mm:ss, REROLL [cost], Gravemark chip) / portrait slot (left) / 4-6 offer
## cards (3-column grid) / footer (keys + refusal toast). Buy and reroll both confirm through the shared dialog look.
##
## Portrait slot (art drop-in): <this menu>/.../MerchantPortrait/PortraitFrame/PortraitSlot (Control, clip on).
##   set_portrait_texture(tex)  -> TextureRect "PortraitTexture" fills the slot (placeholder hidden)
##   set_portrait_node(node)    -> any Control, e.g. a SubViewportContainer with a 3D merchant, fills the slot
## Node names used by tests: OfferCard_<slot> (meta offer_id), OfferBuy, OfferReason, OfferPrice, OfferIP, SoldStamp,
## OwnedTag, RefreshCountdown, RerollBtn, RerollReason, MerchantBalance, RefusalToast, MerchantConfirm(Overlay).

const MAPI := preload("res://scripts/ui/merchant_api.gd")
const ICON_DIR := "res://assets/icons/weapons/"
const TOAST_SECS := 3.5
const HOLD_CONFIRM := 0.55
const CARD_W := 300.0
const KEY_STATS := ["Damage", "Fire Rate", "Accuracy", "Reload Time"] ## shown on the card, compared vs equipped

var api: Object ## Merchant (real) or the stub
var inventory: Node ## equipped weapons for deltas + the API's grant target (real Merchant.inventory or the stub's)
var merchant_name: String = "THE GRAVEDIGGER"
var merchant_line: String = "Steel for marks. No refunds."

var _bal_chip: PanelContainer
var _countdown: Label
var _reroll_btn: Button
var _reroll_reason: Label
var _grid: GridContainer
var _scroll: ScrollContainer
var _away: Control ## empty state: "The Gravecrew merchant is away" (no stock / data not loaded)
var _away_label: Label
var _cd_box: Control
var _portrait_slot: Control
var _placeholder: Control
var _toast: Label
var _toast_t: float = 0.0
var _tick_t: float = 0.0
var _confirm_overlay: Control
var _confirm: PanelContainer
var _confirm_label: Label
var _confirm_cost: Label
var _confirm_yes_btn: Button
var _pending: Dictionary = {} ## {kind: "buy"|"reroll", offer_id, price}
var _hold_t: float = 0.0
var _refusal: Dictionary = {} ## {offer_id, text} last refused buy, inline on that card
var _cards: Array = [] ## [PanelContainer] in slot order
var _buy_btns: Array = [] ## [Button] in slot order
var _stock: Array = [] ## last get_stock()
var last_toast: String = ""
var last_bought: Object = null


func _init() -> void:
	super._init()
	layer = 12
	toggle_action = ""


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(1210, 660)
	if api == null:
		api = MAPI.create()
	_wire_api()
	_build()
	refresh()


# ------------------------------------------------------------------ API wiring

func set_api(a: Object) -> void:
	_unwire_api()
	api = a
	_wire_api()
	if is_inside_tree() and _grid:
		refresh()


func _wire_api() -> void:
	if api == null:
		return
	if inventory:
		MAPI.set_api_inventory(api, inventory)
	MAPI.sig(api, "stock_changed", _on_stock_changed)
	MAPI.sig(api, "purchased", _on_purchased)
	MAPI.sig(api, "refreshed", _on_refreshed)
	MAPI.sig(api, "reroll_cost_changed", _on_reroll_cost)
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_signal("currency_changed") and not prog.currency_changed.is_connected(_on_currency):
		prog.currency_changed.connect(_on_currency)


func _unwire_api() -> void:
	if api == null:
		return
	if inventory and "inventory" in api and api.get("inventory") == inventory:
		MAPI.set_api_inventory(api, null) # the autoload outlives this menu: don't leave it pointing at our kit
	MAPI.unsig(api, "stock_changed", _on_stock_changed)
	MAPI.unsig(api, "purchased", _on_purchased)
	MAPI.unsig(api, "refreshed", _on_refreshed)
	MAPI.unsig(api, "reroll_cost_changed", _on_reroll_cost)


func _exit_tree() -> void:
	if api and inventory and "inventory" in api and api.get("inventory") == inventory:
		MAPI.set_api_inventory(api, null)


func _enter_tree() -> void:
	if api and inventory:
		MAPI.set_api_inventory(api, inventory)


func set_inventory(inv: Node) -> void:
	inventory = inv
	MAPI.set_api_inventory(api, inv)
	if visible:
		refresh()


func _on_stock_changed(_reason: String = "") -> void:
	if visible:
		refresh()


func _on_purchased(_offer_id: String = "", item: Object = null, _price: int = 0) -> void:
	last_bought = item


func _on_refreshed() -> void:
	_refusal = {}
	if visible:
		_show_toast("Fresh stock on the table.", false)


func _on_reroll_cost(_c: int = 0) -> void:
	_refresh_header()


func _on_currency(_b: int = 0) -> void:
	if visible:
		refresh()
	else:
		_refresh_balance()


func balance() -> int:
	var prog := get_node_or_null("/root/Progress")
	return int(prog.gravemark_balance()) if prog and prog.has_method("gravemark_balance") else 0


func _inv() -> Node:
	if inventory and is_instance_valid(inventory):
		return inventory
	var prog := get_node_or_null("/root/Progress")
	return prog.bound_inventory() if prog and prog.has_method("bound_inventory") else null


# ------------------------------------------------------------------ build

func _build() -> void:
	clear_content()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	content.add_child(head)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -2)
	head.add_child(titles)
	titles.add_child(UIStyle.label("MERCHANT", 28, UIStyle.BONE, true))
	titles.add_child(UIStyle.label("HOURLY STOCK  //  GUNS FOR GRAVEMARKS", 12, UIStyle.RUST.lightened(0.2), true))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var cd_box := PanelContainer.new()
	_cd_box = cd_box
	cd_box.name = "RefreshBox"
	var cds := UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8)
	cds.set_content_margin_all(8)
	cds.content_margin_left = 12
	cds.content_margin_right = 12
	cd_box.add_theme_stylebox_override("panel", cds)
	cd_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_countdown = UIStyle.label("REFRESH IN --:--", 16, UIStyle.BONE, true)
	_countdown.name = "RefreshCountdown"
	cd_box.add_child(_countdown)
	head.add_child(cd_box)
	var rr := VBoxContainer.new()
	rr.add_theme_constant_override("separation", 0)
	rr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(rr)
	_reroll_btn = _btn("REROLL", _ask_reroll)
	_reroll_btn.name = "RerollBtn"
	_reroll_btn.custom_minimum_size = Vector2(170, 40)
	_reroll_btn.icon = UIStyle.gravemark_tex()
	_reroll_btn.expand_icon = false
	_reroll_btn.add_theme_constant_override("icon_max_width", 20)
	_reroll_btn.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rr.add_child(_reroll_btn)
	_reroll_reason = UIStyle.label("", 10, UIStyle.BAD)
	_reroll_reason.name = "RerollReason"
	_reroll_reason.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rr.add_child(_reroll_reason)
	_bal_chip = UIStyle.gravemark_chip(0, 24)
	_bal_chip.name = "MerchantBalance"
	_bal_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_bal_chip)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(body)
	body.add_child(_build_portrait())
	var scroll := ScrollContainer.new()
	scroll.name = "OfferScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(3 * CARD_W + 24, 540)
	body.add_child(scroll)
	_scroll = scroll
	body.add_child(_build_away())
	_grid = GridContainer.new()
	_grid.name = "OfferGrid"
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	content.add_child(foot)
	foot.add_child(UIStyle.key_cap("←↑→↓", 11))
	foot.add_child(UIStyle.label("NAV", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ENTER", 11))
	foot.add_child(UIStyle.label("BUY", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("R", 11))
	foot.add_child(UIStyle.label("REROLL", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ESC", 11))
	foot.add_child(UIStyle.label("BACK", 11, UIStyle.BONE_DIM))
	var fsp := Control.new()
	fsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fsp)
	_toast = UIStyle.label("", 12, UIStyle.BONE, true)
	_toast.name = "RefusalToast"
	_toast.visible = false
	foot.add_child(_toast)
	_build_confirm()


func _build_portrait() -> Control:
	var wrap := VBoxContainer.new()
	wrap.name = "MerchantPortrait"
	wrap.custom_minimum_size.x = 210
	wrap.add_theme_constant_override("separation", 0)
	var frame := PanelContainer.new()
	frame.name = "PortraitFrame"
	var fs := UIStyle.cut_box(Color(0.05, 0.045, 0.04, 0.98), UIStyle.RUST, 3, 16)
	fs.set_content_margin_all(6)
	frame.add_theme_stylebox_override("panel", fs)
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_child(frame)
	_portrait_slot = Control.new()
	_portrait_slot.name = "PortraitSlot"
	_portrait_slot.clip_contents = true
	_portrait_slot.custom_minimum_size = Vector2(196, 400)
	_portrait_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(_portrait_slot)
	var bg := TextureRect.new()
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.35)
	gt.fill_to = Vector2(1.0, 1.0)
	var g := Gradient.new()
	g.set_color(0, Color(0.42, 0.26, 0.12, 0.55))
	g.set_color(1, Color(0, 0, 0, 0.9))
	gt.gradient = g
	bg.texture = gt
	bg.name = "PortraitBackdrop"
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait_slot.add_child(bg)
	_placeholder = Control.new()
	_placeholder.name = "PortraitPlaceholder"
	_placeholder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_placeholder.draw.connect(_draw_silhouette)
	_portrait_slot.add_child(_placeholder)
	UIStyle.add_grit(_portrait_slot, 0.18)
	var plate := PanelContainer.new()
	plate.name = "PortraitNamePlate"
	var ps := UIStyle.cut_box(UIStyle.RUST.darkened(0.15), UIStyle.BONE, 2, 10)
	ps.set_content_margin_all(6)
	plate.add_theme_stylebox_override("panel", ps)
	wrap.add_child(plate)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", -2)
	plate.add_child(pv)
	var nl := UIStyle.label(merchant_name, 16, UIStyle.BONE, true)
	nl.name = "MerchantName"
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pv.add_child(nl)
	var ql := UIStyle.label('"%s"' % merchant_line, 11, UIStyle.INK)
	ql.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ql.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pv.add_child(ql)
	return wrap


## Placeholder: hooded figure silhouette with two ember eyes (drawn, so it scales with the slot).
func _draw_silhouette() -> void:
	var s := _placeholder.size
	var cx := s.x * 0.5
	var col := Color(0.015, 0.012, 0.01, 0.96)
	var hood := PackedVector2Array([
		Vector2(cx, s.y * 0.12), Vector2(cx + s.x * 0.2, s.y * 0.2), Vector2(cx + s.x * 0.24, s.y * 0.38),
		Vector2(cx + s.x * 0.2, s.y * 0.5), Vector2(cx + s.x * 0.44, s.y * 0.66), Vector2(cx + s.x * 0.5, s.y),
		Vector2(cx - s.x * 0.5, s.y), Vector2(cx - s.x * 0.44, s.y * 0.66), Vector2(cx - s.x * 0.2, s.y * 0.5),
		Vector2(cx - s.x * 0.24, s.y * 0.38), Vector2(cx - s.x * 0.2, s.y * 0.2)])
	_placeholder.draw_colored_polygon(hood, col)
	var face := PackedVector2Array([Vector2(cx - s.x * 0.12, s.y * 0.3), Vector2(cx + s.x * 0.12, s.y * 0.3),
		Vector2(cx + s.x * 0.1, s.y * 0.44), Vector2(cx, s.y * 0.48), Vector2(cx - s.x * 0.1, s.y * 0.44)])
	_placeholder.draw_colored_polygon(face, Color(0, 0, 0, 1))
	var ember := Color(1.0, 0.45, 0.12, 0.95)
	_placeholder.draw_circle(Vector2(cx - s.x * 0.05, s.y * 0.37), maxf(2.0, s.x * 0.014), ember)
	_placeholder.draw_circle(Vector2(cx + s.x * 0.05, s.y * 0.37), maxf(2.0, s.x * 0.014), ember)
	# lantern glow, lower left
	_placeholder.draw_circle(Vector2(cx - s.x * 0.3, s.y * 0.8), s.x * 0.08, Color(1.0, 0.55, 0.2, 0.18))
	_placeholder.draw_circle(Vector2(cx - s.x * 0.3, s.y * 0.8), s.x * 0.035, Color(1.0, 0.7, 0.3, 0.7))


func set_portrait_texture(tex: Texture2D) -> TextureRect:
	var tr := TextureRect.new()
	tr.name = "PortraitTexture"
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	set_portrait_node(tr)
	return tr


func set_portrait_node(node: Control) -> void:
	for c in _portrait_slot.get_children():
		if c.name in ["PortraitTexture", "PortraitCustom"]:
			c.queue_free()
	if node.name == "" or not (node.name in ["PortraitTexture"]):
		node.name = "PortraitCustom" if node.name != "PortraitTexture" else node.name
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_portrait_slot.add_child(node)
	_portrait_slot.move_child(node, 1) # above the backdrop, below the grit
	_placeholder.visible = false


func portrait_slot() -> Control:
	return _portrait_slot


func _build_confirm() -> void:
	var dlg := UIStyle.dialog_overlay("MerchantConfirmOverlay")
	_confirm_overlay = dlg.overlay
	_confirm_overlay.visible = false
	add_child(_confirm_overlay)
	_confirm = UIStyle.dialog_card(Vector2(460, 200), "MerchantConfirm")
	(dlg.center as CenterContainer).add_child(_confirm)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 12)
	cv.alignment = BoxContainer.ALIGNMENT_CENTER
	_confirm.add_child(cv)
	_confirm_label = UIStyle.label("Buy?", 17, UIStyle.BONE, true)
	_confirm_label.name = "ConfirmTitle"
	_confirm_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_label.custom_minimum_size.x = 400
	cv.add_child(_confirm_label)
	var row := HBoxContainer.new()
	row.name = "ConfirmCostRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	cv.add_child(row)
	row.add_child(UIStyle.gravemark_icon(20))
	_confirm_cost = UIStyle.label("0  →  0", 15, UIStyle.RUST.lightened(0.25), true)
	_confirm_cost.name = "ConfirmCost"
	row.add_child(_confirm_cost)
	var ch := HBoxContainer.new()
	ch.name = "ConfirmButtons"
	ch.alignment = BoxContainer.ALIGNMENT_CENTER
	ch.add_theme_constant_override("separation", 14)
	cv.add_child(ch)
	_confirm_yes_btn = _btn("CONFIRM", confirm_yes)
	_confirm_yes_btn.name = "ConfirmYes"
	_confirm_yes_btn.custom_minimum_size = Vector2(140, 44)
	UIStyle.style_primary_button(_confirm_yes_btn)
	ch.add_child(_confirm_yes_btn)
	var no := _btn("CANCEL", confirm_no)
	no.name = "ConfirmNo"
	no.custom_minimum_size = Vector2(120, 44)
	ch.add_child(no)
	_confirm_yes_btn.focus_neighbor_right = _confirm_yes_btn.get_path_to(no)
	no.focus_neighbor_left = no.get_path_to(_confirm_yes_btn)
	var hint := UIStyle.label("hold ENTER 0.55s to confirm  ·  ESC cancel", 11, UIStyle.BONE_DIM)
	hint.name = "ConfirmHint"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(hint)


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.add_theme_color_override("font_focus_color", UIStyle.BONE)
	b.add_theme_color_override("font_disabled_color", Color(0.55, 0.52, 0.45))
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
	b.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0, 0, 0, 0), UIStyle.BONE, 3, 8))
	b.add_theme_stylebox_override("pressed", UIStyle.cut_box(UIStyle.OLIVE_DARK, UIStyle.RUST, 2, 8))
	b.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.08, 0.08, 0.07, 0.9), Color(0.36, 0.33, 0.28), 2, 8))
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	b.focus_entered.connect(_ui_snd.bind("ui_hover"))
	return b


# ------------------------------------------------------------------ refresh

func open() -> void:
	_wire_api()
	MAPI.call_api(api, "refresh_if_due")
	super.open()
	_tick_t = 0.0
	call_deferred("focus_first")


func close() -> void:
	show_confirm(false)
	super.close()


func refresh() -> void:
	if _grid == null:
		return
	_refresh_balance()
	_rebuild_cards() # first: the header reads the fresh stock (away state)
	_refresh_header()


func _refresh_balance() -> void:
	UIStyle.set_gravemark_chip_amount(_bal_chip, balance())


func _refresh_header() -> void:
	if _countdown == null:
		return
	if is_away():
		_cd_box.visible = false
		_reroll_btn.text = "REROLL"
		_reroll_btn.disabled = true
		_reroll_reason.text = ""
		_reroll_btn.tooltip_text = MAPI.R_UNAVAILABLE
		return
	_cd_box.visible = true
	update_countdown()
	var cost := int(MAPI.call_api(api, "reroll_cost") if api else 0)
	_reroll_btn.text = "REROLL  %d" % cost
	var chk := MAPI.as_check(MAPI.call_api(api, "reroll_check"))
	_reroll_btn.disabled = not chk.ok
	var why := ""
	if not chk.ok:
		why = need_text(cost, balance()) if cost > balance() else chk.reason
	_reroll_reason.text = why
	_reroll_btn.tooltip_text = why


## "REFRESH IN mm:ss" (h:mm:ss past an hour).
static func format_countdown(seconds: float) -> String:
	var s := maxi(int(ceil(seconds)), 0)
	if s >= 3600:
		return "REFRESH IN %d:%02d:%02d" % [s / 3600, (s % 3600) / 60, s % 60]
	return "REFRESH IN %02d:%02d" % [s / 60, s % 60]


static func need_text(price: int, have: int = -1) -> String:
	if have < 0:
		return "Need %d Gravemarks" % price
	return "Need %d Gravemarks (you have %d)" % [price, have]


func update_countdown() -> void:
	var t = MAPI.call_api(api, "time_to_refresh")
	_countdown.text = format_countdown(float(t) if t != null else 0.0)


func _rebuild_cards() -> void:
	var focused_slot := -1
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	for i in _buy_btns.size():
		if _buy_btns[i] == f:
			focused_slot = i
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	_cards.clear()
	_buy_btns.clear()
	var st = MAPI.call_api(api, "get_stock")
	_stock = st if st is Array else []
	for o in _stock:
		var card := _offer_card(o)
		_grid.add_child(card)
		_cards.append(card)
		_buy_btns.append(card.find_child("OfferBuy", true, false))
	_wire_nav()
	_show_away(is_away())
	if focused_slot >= 0 and visible:
		focus_slot(mini(focused_slot, _buy_btns.size() - 1))


## Empty state: the API has no stock (the real Merchant returns [] with no data / Progress / GearDB) or says it is away.
func is_away() -> bool:
	if api == null:
		return true
	if _stock.is_empty():
		return true
	var chk := MAPI.as_check(MAPI.call_api(api, "reroll_check"))
	return not chk.ok and str(chk.reason) == MAPI.R_UNAVAILABLE


func away_text() -> String:
	return _away_label.text if _away_label and _away.visible else ""


func _build_away() -> Control:
	var c := CenterContainer.new()
	c.name = "MerchantAway"
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.custom_minimum_size = Vector2(3 * CARD_W + 24, 540)
	c.visible = false
	_away = c
	var card := PanelContainer.new()
	card.name = "AwayCard"
	var sb := UIStyle.cut_box(Color(UIStyle.INK, 0.92), UIStyle.BONE_DIM, 2, 10)
	sb.set_content_margin_all(28)
	card.add_theme_stylebox_override("panel", sb)
	c.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	card.add_child(v)
	var icon := TextureRect.new()
	icon.name = "AwayIcon"
	icon.texture = UIStyle.gravemark_tex()
	icon.custom_minimum_size = Vector2(48, 48)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.modulate = Color(1, 1, 1, 0.5)
	v.add_child(icon)
	_away_label = UIStyle.label(MAPI.R_UNAVAILABLE, 22, UIStyle.BONE, true)
	_away_label.name = "AwayTitle"
	_away_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_away_label)
	var sub := UIStyle.label("No stock on the table right now. Check back later.", 13, UIStyle.BONE_DIM)
	sub.name = "AwaySub"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	return c


func _show_away(on: bool) -> void:
	if _away == null:
		_away = find_child("MerchantAway", true, false)
	if _away:
		_away.visible = on
	if _scroll:
		_scroll.visible = not on


func card_count() -> int:
	return _cards.size()


func card_for(offer_id: String) -> PanelContainer:
	for c in _cards:
		if str(c.get_meta("offer_id", "")) == offer_id:
			return c
	return null


func offer(offer_id: String) -> Dictionary:
	for o in _stock:
		if str(o.get(MAPI.K_OFFER_ID, "")) == offer_id:
			return o
	return {}


func _offer_card(o: Dictionary) -> PanelContainer:
	var w = o.get(MAPI.K_ITEM)
	var rarity := int(o.get(MAPI.K_RARITY, w.rarity if w else 0))
	var rc: Color = UIStyle.rarity_color(rarity)
	var oid := str(o.get(MAPI.K_OFFER_ID, ""))
	var sold := bool(o.get(MAPI.K_SOLD, false))
	var owned := bool(o.get(MAPI.K_OWNED, false))
	var price := int(o.get(MAPI.K_PRICE, 0))
	var bal := balance()
	var card := PanelContainer.new()
	card.name = "OfferCard_%d" % int(o.get(MAPI.K_SLOT, _cards.size()))
	card.set_meta("offer_id", oid)
	card.set_meta("rarity", rarity)
	card.custom_minimum_size = Vector2(CARD_W, 262)
	var cs := UIStyle.cut_box(Color(0.06, 0.06, 0.05, 0.97), rc, 4, 18)
	cs.set_content_margin_all(0)
	card.add_theme_stylebox_override("panel", cs)
	card.set_meta("border_color", rc)
	var layers := Control.new()
	layers.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(layers)
	var bgt := TextureRect.new() # rarity wash, top-left
	var gt := GradientTexture2D.new()
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0.9, 0.7)
	var gr := Gradient.new()
	gr.set_color(0, Color(rc.darkened(0.5), 0.55))
	gr.set_color(1, Color(0, 0, 0, 0))
	gt.gradient = gr
	bgt.texture = gt
	bgt.stretch_mode = TextureRect.STRETCH_SCALE
	bgt.set_anchors_preset(Control.PRESET_FULL_RECT)
	bgt.offset_left = 4
	bgt.offset_top = 4
	bgt.offset_right = -4
	bgt.offset_bottom = -4
	bgt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layers.add_child(bgt)
	UIStyle.add_grit(layers, 0.22)
	var icon_path := ICON_DIR + str(o.get(MAPI.K_ARCHETYPE, w.archetype if w else "")) + ".png"
	if ResourceLoader.exists(icon_path):
		var tr := TextureRect.new()
		tr.texture = load(icon_path)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.position = Vector2(CARD_W - 150, 50)
		tr.size = Vector2(140, 60)
		tr.modulate = Color(1, 1, 1, 0.22)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layers.add_child(tr)

	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 12)
	m.add_theme_constant_override("margin_top", 10)
	m.add_theme_constant_override("margin_bottom", 10)
	card.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	m.add_child(v)

	# Row 1: rarity tag + type | OWNED | IP
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	v.add_child(top)
	var tagbox := VBoxContainer.new()
	tagbox.add_theme_constant_override("separation", 2)
	top.add_child(tagbox)
	var tag := PanelContainer.new()
	tag.name = "RarityTag"
	var ts := UIStyle.cut_box(rc, Color(0, 0, 0, 0), 0, 6)
	ts.set_content_margin_all(2)
	ts.content_margin_left = 8
	ts.content_margin_right = 8
	tag.add_theme_stylebox_override("panel", ts)
	tag.add_child(UIStyle.label(Rarity.name_of(rarity).to_upper(), 11, UIStyle.INK, true))
	tag.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tagbox.add_child(tag)
	var type_txt: String = (w.type_name() if w else str(o.get(MAPI.K_ARCHETYPE, ""))).to_upper()
	var tl := UIStyle.label(type_txt, 12, UIStyle.BONE_DIM, true)
	tl.name = "OfferArchetype"
	tagbox.add_child(tl)
	if owned:
		var ot := PanelContainer.new()
		ot.name = "OwnedTag"
		var os := UIStyle.cut_box(Color(UIStyle.OLIVE_DARK, 0.95), UIStyle.OLIVE.lightened(0.3), 2, 5)
		os.set_content_margin_all(2)
		os.content_margin_left = 6
		os.content_margin_right = 6
		ot.add_theme_stylebox_override("panel", os)
		ot.add_child(UIStyle.label("OWNED", 10, UIStyle.OLIVE.lightened(0.5), true))
		ot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		top.add_child(ot)
	var tsp := Control.new()
	tsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(tsp)
	top.add_child(_ip_box(o, w))

	# Name + maker
	var nm := UIStyle.label((w.display_name if w else str(o.get("name", "?"))).to_upper(), 19, rc.lightened(0.1), true, 3)
	nm.name = "OfferName"
	nm.clip_text = true
	nm.custom_minimum_size.x = CARD_W - 24
	v.add_child(nm)
	if w:
		var mk := UIStyle.label(str(w.manufacturer).to_upper(), 12, w.manufacturer_color)
		mk.name = "OfferMaker"
		v.add_child(mk)

	# Key stats with deltas vs the equipped weapon of that slot
	if w:
		var grid := GridContainer.new()
		grid.name = "OfferStats"
		grid.columns = 6
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 0)
		v.add_child(grid)
		var rows: Array = w.card_stats()
		var inv := _inv()
		var cmp: Array = inv.compare(w) if inv and inv.has_method("compare") else []
		var shown := 0
		for i in rows.size():
			if not (str(rows[i][0]) in KEY_STATS):
				continue
			var lab := UIStyle.label(_short_stat(str(rows[i][0])), 11, UIStyle.BONE_DIM)
			lab.custom_minimum_size.x = 34
			grid.add_child(lab)
			var num := UIStyle.label(str(rows[i][1]), 14, UIStyle.BONE, true)
			num.custom_minimum_size.x = 54
			grid.add_child(num)
			var dw := _delta(cmp[i] if i < cmp.size() else {})
			dw.name = "Delta_%s" % str(rows[i][0]).replace(" ", "")
			grid.add_child(dw)
			shown += 1
	# Perks
	var perks: Array = o.get(MAPI.K_PERKS, Array(w.perks) if w else [])
	if perks.size() > 0:
		var names: PackedStringArray = []
		var gdb := get_node_or_null("/root/GearDB")
		for pid in perks:
			var p: Dictionary = gdb.perk(pid) if gdb and gdb.has_method("perk") else {}
			names.append(str(p.get("name", pid)).to_upper())
		var pl := UIStyle.label("◆ " + "   ◆ ".join(names), 11, UIStyle.OLIVE.lightened(0.45), true)
		pl.name = "OfferPerks"
		pl.clip_text = true
		pl.custom_minimum_size.x = CARD_W - 24
		v.add_child(pl)
	var flv := str(w.flavor) if w else str(o.get("flavor", ""))
	if flv != "":
		var fl := UIStyle.label('"%s"' % flv, 11, UIStyle.RUST.lightened(0.25))
		fl.name = "OfferFlavor"
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.max_lines_visible = 2
		fl.custom_minimum_size.x = CARD_W - 24
		v.add_child(fl)
	var vsp := Control.new()
	vsp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(vsp)

	# Price + BUY
	var bot := HBoxContainer.new()
	bot.add_theme_constant_override("separation", 6)
	v.add_child(bot)
	bot.add_child(UIStyle.gravemark_icon(22))
	var pr := UIStyle.label(str(price), 20, UIStyle.BONE if price <= bal else UIStyle.BAD, true)
	pr.name = "OfferPrice"
	bot.add_child(pr)
	var bsp := Control.new()
	bsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bot.add_child(bsp)
	var buy := _btn("SOLD" if sold else "BUY", _on_buy_pressed.bind(oid))
	buy.name = "OfferBuy"
	buy.custom_minimum_size = Vector2(110, 36)
	if not sold:
		UIStyle.style_primary_button(buy)
		buy.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.08, 0.08, 0.07, 0.9), Color(0.36, 0.33, 0.28), 2, 8))
		buy.add_theme_stylebox_override("focus", UIStyle.cut_box(UIStyle.BONE, UIStyle.RUST, 3, 10))
		buy.add_theme_color_override("font_focus_color", UIStyle.INK)
	bot.add_child(buy)
	var why := disable_reason(o)
	buy.disabled = why != ""
	if buy.disabled: # focus on a disabled BUY: outline only, so it never reads as buyable
		buy.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0, 0, 0, 0), UIStyle.BONE_DIM, 2, 8))
	buy.tooltip_text = why
	var inline := why
	if not _refusal.is_empty() and str(_refusal.get("offer_id", "")) == oid and str(_refusal.text) != "":
		inline = str(_refusal.text)
	var rl := UIStyle.label(inline, 11, UIStyle.BAD)
	rl.name = "OfferReason"
	rl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rl.custom_minimum_size = Vector2(CARD_W - 24, 14)
	rl.clip_text = true
	v.add_child(rl)
	if sold:
		rl.text = ""
		_sold_stamp(card)
	return card


## Why BUY is disabled ("" = enabled). Can't afford -> "Need N Gravemarks (you have M)"; else the API's reason.
func disable_reason(o: Dictionary) -> String:
	if bool(o.get(MAPI.K_SOLD, false)):
		return "Sold out"
	var price := int(o.get(MAPI.K_PRICE, 0))
	var bal := balance()
	var afford := bool(o.get(MAPI.K_CAN_AFFORD, bal >= price)) and bal >= price
	if not afford:
		return need_text(price, bal)
	var r := str(o.get(MAPI.K_REASON, ""))
	return r


func _sold_stamp(card: PanelContainer) -> void:
	card.modulate = Color(0.55, 0.55, 0.55, 0.85)
	var holder := Control.new()
	holder.name = "SoldStampHolder"
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(holder)
	var stamp := PanelContainer.new()
	stamp.name = "SoldStamp"
	var ss := UIStyle.cut_box(Color(0.1, 0.0, 0.0, 0.55), UIStyle.BLOOD.lightened(0.25), 4, 6)
	ss.set_content_margin_all(4)
	ss.content_margin_left = 18
	ss.content_margin_right = 18
	stamp.add_theme_stylebox_override("panel", ss)
	var l := UIStyle.label("SOLD", 40, UIStyle.BLOOD.lightened(0.35), true, 3)
	stamp.add_child(l)
	stamp.rotation_degrees = -14.0
	stamp.position = Vector2(CARD_W * 0.5 - 75, 92)
	stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(stamp)


func _short_stat(n: String) -> String:
	match n:
		"Damage":
			return "DMG"
		"Fire Rate":
			return "RPS"
		"Accuracy":
			return "ACC"
		"Reload Time":
			return "RLD"
	return n.substr(0, 3).to_upper()


func _delta(row: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 2)
	h.custom_minimum_size.x = 46
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.set_meta("better", bool(row.get("better", false)))
	h.set_meta("worse", bool(row.get("worse", false)))
	if row.is_empty() or not (row.better or row.worse):
		h.add_child(UIStyle.label("=" if not row.is_empty() else "", 11, UIStyle.BONE_DIM))
		return h
	h.add_child(DeltaArrow.make(row.better, 9.0))
	h.add_child(UIStyle.label(str(row.text), 12, UIStyle.GOOD if row.better else UIStyle.BAD, true))
	return h


func _ip_box(o: Dictionary, w) -> Control:
	var box := PanelContainer.new()
	box.name = "OfferIP"
	var st := UIStyle.cut_box(Color(UIStyle.INK, 0.92), UIStyle.BONE, 2, 8, true)
	st.set_content_margin_all(2)
	st.content_margin_left = 8
	st.content_margin_right = 8
	box.add_theme_stylebox_override("panel", st)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -6)
	box.add_child(v)
	var ip := int(o.get(MAPI.K_ITEM_POWER, w.item_power if w else 0))
	var n := UIStyle.label(str(ip), 30, UIStyle.BONE, true)
	n.name = "IPNumber"
	n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(n)
	var inv := _inv()
	var cur = inv.equipped.get(w.slot) if inv and w else null
	var sub := "ITEM POWER"
	var col := UIStyle.BONE_DIM
	if cur:
		var d := ip - int(cur.item_power)
		sub = "IP  %+d" % d if d != 0 else "IP  ="
		col = UIStyle.ip_tint(d)
	var sl := UIStyle.label(sub, 10, col, true)
	sl.name = "IPDelta"
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sl)
	return box


# ------------------------------------------------------------------ nav

func _wire_nav() -> void:
	var n := _buy_btns.size()
	var cols := _grid.columns
	for i in n:
		var b: Button = _buy_btns[i]
		if b == null:
			continue
		b.focus_neighbor_left = b.get_path_to(_buy_btns[(i - 1 + n) % n])
		b.focus_neighbor_right = b.get_path_to(_buy_btns[(i + 1) % n])
		b.focus_neighbor_top = b.get_path_to(_buy_btns[i - cols] if i - cols >= 0 else _reroll_btn)
		b.focus_neighbor_bottom = b.get_path_to(_buy_btns[i + cols] if i + cols < n else _buy_btns[i])
	if n > 0:
		_reroll_btn.focus_neighbor_bottom = _reroll_btn.get_path_to(_buy_btns[0])
		_reroll_btn.focus_neighbor_top = _reroll_btn.get_path_to(_reroll_btn)


func focus_first() -> void:
	if not visible:
		return
	for i in _buy_btns.size():
		if _buy_btns[i] and not _buy_btns[i].disabled:
			focus_slot(i)
			return
	if _buy_btns.size() > 0:
		focus_slot(0)
	else:
		_reroll_btn.grab_focus()


func focus_slot(i: int) -> void:
	if i >= 0 and i < _buy_btns.size() and _buy_btns[i]:
		(_buy_btns[i] as Button).grab_focus()


# ------------------------------------------------------------------ buy / reroll

func _on_buy_pressed(offer_id: String) -> void:
	ask_buy(offer_id)


## BUY: buy_check first (refusal -> inline + toast), else the confirm card.
func ask_buy(offer_id: String) -> bool:
	var chk := MAPI.as_check(MAPI.call_api(api, "buy_check", [offer_id]))
	if not chk.ok:
		refuse(offer_id, chk.reason)
		return false
	var o := offer(offer_id)
	var w = o.get(MAPI.K_ITEM)
	var price := int(o.get(MAPI.K_PRICE, 0))
	var bal := balance()
	_pending = {"kind": "buy", "offer_id": offer_id, "price": price}
	_confirm_label.text = "Buy %s for %d Gravemarks?" % [(w.display_name if w else "this gun").to_upper(), price]
	_confirm_cost.text = "%d  →  %d" % [bal, maxi(bal - price, 0)]
	show_confirm(true)
	_ui_snd("ui_hover")
	return true


func _ask_reroll() -> void:
	ask_reroll()


func ask_reroll() -> bool:
	var cost := int(MAPI.call_api(api, "reroll_cost"))
	var chk := MAPI.as_check(MAPI.call_api(api, "reroll_check"))
	if not chk.ok:
		_ui_error()
		_show_toast("Can't reroll: %s" % (need_text(cost, balance()) if cost > balance() else chk.reason), true)
		return false
	var bal := balance()
	_pending = {"kind": "reroll", "price": cost}
	_confirm_label.text = "Reroll the unsold stock for %d Gravemarks?" % cost
	_confirm_cost.text = "%d  →  %d" % [bal, maxi(bal - cost, 0)]
	show_confirm(true)
	_ui_snd("ui_hover")
	return true


func show_confirm(on: bool) -> void:
	if _confirm_overlay:
		_confirm_overlay.visible = on
	_hold_t = 0.0
	if on and _confirm_yes_btn and is_inside_tree():
		_confirm_yes_btn.grab_focus()
	if not on:
		_pending = {}


func confirm_visible() -> bool:
	return _confirm_overlay != null and _confirm_overlay.visible


func confirm_yes() -> void:
	if _pending.is_empty():
		show_confirm(false)
		return
	var p := _pending.duplicate()
	show_confirm(false)
	if str(p.kind) == "buy":
		_do_buy(str(p.offer_id))
	else:
		_do_reroll()


func confirm_no() -> void:
	var p := _pending.duplicate()
	show_confirm(false)
	if str(p.get("kind", "")) == "buy":
		var i := _cards.find(card_for(str(p.offer_id)))
		focus_slot(i)
	elif _reroll_btn:
		_reroll_btn.grab_focus()


func _do_buy(offer_id: String) -> void:
	var o := offer(offer_id)
	var r = MAPI.call_api(api, "buy", [offer_id])
	var chk := MAPI.as_check(r)
	if not chk.ok:
		var why: String = chk.reason
		if why == "":
			why = str(MAPI.call_api(api, "last_refusal_reason"))
		refuse(offer_id, why)
		return
	var item = r.get("item") if r is Dictionary else null
	if item:
		last_bought = item
	_refusal = {}
	_ui_snd("ui_equip")
	var w = item if item else o.get(MAPI.K_ITEM)
	_show_toast("%s sent to your stash." % (w.display_name.to_upper() if w else "Gun"), false)
	refresh()
	focus_slot(_cards.find(card_for(offer_id)))


func _do_reroll() -> void:
	var chk := MAPI.as_check(MAPI.call_api(api, "reroll"))
	if not chk.ok:
		var why: String = chk.reason if chk.reason != "" else str(MAPI.call_api(api, "last_refusal_reason"))
		_ui_error()
		_show_toast("Can't reroll: %s" % why, true)
		refresh()
		return
	_refusal = {}
	_ui_snd("ui_scrap_dismantle")
	_show_toast("New stock on the table.", false)
	refresh()
	if _reroll_btn.disabled:
		focus_first()
	else:
		_reroll_btn.grab_focus()


## Refused buy: reason inline on the card + footer toast + error cue (Armory pattern).
func refuse(offer_id: String, text: String) -> void:
	if text == "":
		text = "Can't buy that right now"
	_refusal = {"offer_id": offer_id, "text": text}
	_ui_error()
	refresh()
	var o := offer(offer_id)
	var w = o.get(MAPI.K_ITEM)
	_show_toast("Can't buy %s: %s" % [(w.display_name.to_upper() if w else "that"), text], true)


func _show_toast(text: String, bad: bool) -> void:
	last_toast = text
	if _toast == null:
		return
	_toast.text = text
	_toast.add_theme_color_override("font_color", UIStyle.BLOOD.lightened(0.35) if bad else UIStyle.OLIVE.lightened(0.5))
	_toast.visible = true
	_toast_t = TOAST_SECS


func _ui_error() -> void:
	var a := get_node_or_null("/root/Sfx")
	if a == null:
		return
	a.play("ui_error" if a.has_method("has") and a.has("ui_error") else "ui_hover")


# ------------------------------------------------------------------ tick + input

func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0 and _toast:
			_toast.visible = false
	if not visible:
		return
	_tick_t += delta
	if _tick_t >= 1.0:
		_tick_t = fmod(_tick_t, 1.0)
		tick()
	if confirm_visible() and Input.is_action_pressed("ui_accept"):
		_hold_t += delta
		if _hold_t >= HOLD_CONFIRM:
			confirm_yes()
	else:
		_hold_t = 0.0


## Once a second: countdown text, plus refresh_if_due (stock rebuilds through stock_changed).
func tick() -> void:
	if MAPI.call_api(api, "refresh_if_due") == true and visible:
		refresh()
	elif visible and _away and _away.visible: # the merchant came back (data loaded): leave the empty state
		var st = MAPI.call_api(api, "get_stock")
		if st is Array and not st.is_empty():
			refresh()
	update_countdown()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if confirm_visible():
		if event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_mouse"):
			get_viewport().set_input_as_handled()
			confirm_no()
		return # buttons in the card handle ui_accept / focus
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_mouse"):
		get_viewport().set_input_as_handled()
		close()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		get_viewport().set_input_as_handled()
		ask_reroll()
		return
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_Y:
		get_viewport().set_input_as_handled()
		ask_reroll()
		return
