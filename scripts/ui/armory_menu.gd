extends MenuBase
## Armory (Pass 5+): Gravemark currency, per-type Rework I–V, attachments by slot.
## Talks to Skillz Armory (scripts/armory/armory.gd). Keyboard / controller nav.
## Buy: short confirm panel (Enter confirms, Esc cancels). Hold Enter 0.55s also buys.

const ArmoryScr := preload("res://scripts/armory/armory.gd")
const ICON_GM := "res://assets/icons/gravemark.png"
const ArmoryNoticeScr := preload("res://scripts/ui/armory_notice.gd")

var api: RefCounted
var _weapon_id: String = "sidearm"
var _left: VBoxContainer ## weapon list
var _right: VBoxContainer ## upgrades + attachments
var _bal_chip: PanelContainer
var _title_sub: Label
var _confirm_overlay: Control ## full-rect dim + centered card (NOT a panel child — PanelContainer stretches kids)
var _confirm: PanelContainer ## compact ~460x200 card
var _confirm_label: Label
var _confirm_cost_row: HBoxContainer
var _confirm_cost: Label
var _pending_id: String = ""
var _pending_kind: String = "" ## "buy" | "equip" | "unequip"
var _hold_t: float = 0.0
var _holding: bool = false
var _weapon_btns: Dictionary = {} ## id -> Button
var _focusables: Array = [] ## Controls for nav dump
var _refusal: Dictionary = {} ## {id, kind, text}: last refused buy / equip, shown inline on that row (§2b)
var _toast: Label ## short refusal toast in the footer, near the actions
var _toast_t: float = 0.0
const TOAST_SECS := 3.5
const RIGHT_GUTTER := 14 ## px between the right-panel cards and the scrollbar


## Wrapping body text for the right panel: shrinks with the column instead of forcing it wider (playtest #10).
static func wrap_label(text: String, size: int, color: Color, stencil: bool = false) -> Label:
	var l := UIStyle.label(text, size, color, stencil)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size.x = 40
	return l


func _init() -> void:
	super._init()
	layer = 12


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(1040, 620)
	if api == null:
		api = ArmoryScr.new()
	_wire_api()
	_build()
	refresh()


func _wire_api() -> void:
	if api == null:
		return
	if api.has_signal("currency_changed") and not api.currency_changed.is_connected(_on_currency):
		api.currency_changed.connect(_on_currency)
	if api.has_signal("armory_changed") and not api.armory_changed.is_connected(_on_armory):
		api.armory_changed.connect(_on_armory)


func _on_currency(_b: int = 0) -> void:
	_refresh_balance()


func _on_armory(_kind: String = "", _id: String = "") -> void:
	if visible:
		refresh()


func _build() -> void:
	clear_content()
	_weapon_btns.clear()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	content.add_child(head)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -2)
	head.add_child(titles)
	titles.add_child(UIStyle.label("ARMORY", 28, UIStyle.BONE, true))
	_title_sub = UIStyle.label("REWORK + ATTACHMENTS", 12, UIStyle.RUST.lightened(0.2), true)
	titles.add_child(_title_sub)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_bal_chip = UIStyle.gravemark_chip(0, 24)
	head.add_child(_bal_chip)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(body)

	var left_wrap := VBoxContainer.new()
	left_wrap.custom_minimum_size.x = 220
	left_wrap.add_theme_constant_override("separation", 6)
	body.add_child(left_wrap)
	left_wrap.add_child(UIStyle.label("WEAPONS", 14, UIStyle.RUST, true))
	var scroll_l := ScrollContainer.new()
	scroll_l.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll_l.custom_minimum_size = Vector2(220, 420)
	left_wrap.add_child(scroll_l)
	scroll_l.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var gutter_l := MarginContainer.new()
	gutter_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter_l.add_theme_constant_override("margin_right", RIGHT_GUTTER)
	scroll_l.add_child(gutter_l)
	_left = VBoxContainer.new()
	_left.add_theme_constant_override("separation", 4)
	_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter_l.add_child(_left)

	# Playtest #10: the right panel never scrolls sideways (long summaries / drawbacks used to widen it past the
	# viewport, so text ran under the scrollbar and over the cost / BUY column). Every text line wraps instead, and
	# a gutter keeps the cards clear of the vertical scrollbar.
	var right_scroll := ScrollContainer.new()
	right_scroll.name = "RightScroll"
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(right_scroll)
	var gutter := MarginContainer.new()
	gutter.name = "RightGutter"
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_theme_constant_override("margin_right", RIGHT_GUTTER)
	right_scroll.add_child(gutter)
	_right = VBoxContainer.new()
	_right.add_theme_constant_override("separation", 8)
	_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_child(_right)

	# Confirm overlay on CanvasLayer root (self), NOT inside panel — PanelContainer
	# stretches every direct child to fill, which blew the old card across the armory.
	var dlg := UIStyle.dialog_overlay("BuyConfirmOverlay")
	_confirm_overlay = dlg.overlay
	_confirm_overlay.visible = false
	add_child(_confirm_overlay)
	_confirm = UIStyle.dialog_card(Vector2(460, 200), "BuyConfirm")
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
	_confirm_cost_row = HBoxContainer.new()
	_confirm_cost_row.name = "ConfirmCostRow"
	_confirm_cost_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_confirm_cost_row.add_theme_constant_override("separation", 8)
	cv.add_child(_confirm_cost_row)
	_confirm_cost = UIStyle.label("0  →  0", 15, UIStyle.RUST.lightened(0.25), true)
	_confirm_cost.name = "ConfirmCost"
	_confirm_cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_cost_row.add_child(_confirm_cost)
	var ch := HBoxContainer.new()
	ch.name = "ConfirmButtons"
	ch.alignment = BoxContainer.ALIGNMENT_CENTER
	ch.add_theme_constant_override("separation", 14)
	cv.add_child(ch)
	var yes := _btn("CONFIRM", _confirm_yes)
	yes.name = "ConfirmYes"
	yes.custom_minimum_size = Vector2(140, 44)
	UIStyle.style_primary_button(yes)
	var no := _btn("CANCEL", _confirm_no)
	no.name = "ConfirmNo"
	no.custom_minimum_size = Vector2(120, 44)
	ch.add_child(yes)
	ch.add_child(no)
	var hint := UIStyle.label("hold ENTER 0.55s to confirm  ·  ESC cancel", 11, UIStyle.BONE_DIM)
	hint.name = "ConfirmHint"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cv.add_child(hint)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	content.add_child(foot)
	foot.add_child(UIStyle.key_cap("↑↓", 11))
	foot.add_child(UIStyle.label("NAV", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ENTER", 11))
	foot.add_child(UIStyle.label("BUY / EQUIP", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ESC", 11))
	foot.add_child(UIStyle.label("BACK", 11, UIStyle.BONE_DIM))
	var fsp := Control.new()
	fsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fsp)
	_toast = UIStyle.label("", 12, UIStyle.BONE, true)
	_toast.name = "RefusalToast"
	_toast.visible = false
	_toast.add_theme_color_override("font_color", UIStyle.BLOOD.lightened(0.35))
	foot.add_child(_toast)


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
	b.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.08, 0.08, 0.07, 0.9), Color(0.44, 0.41, 0.34), 2, 8))
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	return b


func _refresh_balance() -> void:
	var n := int(api.currency_balance()) if api else 0
	UIStyle.set_gravemark_chip_amount(_bal_chip, n)


func open() -> void:
	_wire_api()
	super.open()
	refresh()
	# Fallback for the one-time unequipped-on-load notice when the home menu wasn't shown first.
	ArmoryNoticeScr.show_if_pending(self)


func refresh() -> void:
	_refresh_balance()
	_rebuild_weapons()
	_rebuild_detail()


func _rebuild_weapons() -> void:
	if _left == null:
		return
	for c in _left.get_children():
		c.queue_free()
	_weapon_btns.clear()
	var weapons: Array = api.list_weapons() if api else []
	if weapons.is_empty():
		_left.add_child(UIStyle.label("no weapons", 13, UIStyle.BONE_DIM))
		return
	if _weapon_id == "" or not weapons.any(func(w): return str(w.id) == _weapon_id):
		_weapon_id = str(weapons[0].id)
	for w in weapons:
		var id := str(w.id)
		var b := Button.new()
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(190, 48)
		var on: bool = id == _weapon_id
		b.add_theme_stylebox_override("normal", UIStyle.cut_box(
			UIStyle.OLIVE_DARK if on else Color(UIStyle.INK, 0.9),
			UIStyle.RUST if on else UIStyle.BONE_DIM, 2, 8))
		b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
		b.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 3, 8))
		var v := VBoxContainer.new()
		v.name = "Labels"
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_theme_constant_override("separation", 0)
		v.alignment = BoxContainer.ALIGNMENT_CENTER
		b.add_child(v)
		# Buttons don't lay out children: pin the labels inside the border (they sat on the top-left edge)
		v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		v.offset_left = 10
		v.offset_right = -8
		v.offset_top = 3
		v.offset_bottom = -3
		v.add_child(UIStyle.label(str(w.get("name", id)).to_upper(), 14, UIStyle.BONE, true))
		var tier := int(w.get("tier", 0))
		var tier_s := "BASE" if tier <= 0 else "REWORK %s" % UIStyle.roman(tier)
		v.add_child(UIStyle.label(tier_s, 11, UIStyle.OLIVE.lightened(0.35)))
		b.pressed.connect(_select_weapon.bind(id))
		b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
		_left.add_child(b)
		_weapon_btns[id] = b
	_wire_weapon_neighbors()


func _wire_weapon_neighbors() -> void:
	var keys: Array = _weapon_btns.keys()
	for i in keys.size():
		var b: Button = _weapon_btns[keys[i]]
		var up: Button = _weapon_btns[keys[(i - 1 + keys.size()) % keys.size()]]
		var dn: Button = _weapon_btns[keys[(i + 1) % keys.size()]]
		b.focus_neighbor_top = b.get_path_to(up)
		b.focus_neighbor_bottom = b.get_path_to(dn)


func _select_weapon(id: String) -> void:
	_weapon_id = id
	_refusal = {}
	_ui_snd("ui_hover")
	refresh()


func _weapon_type_name() -> String:
	for w in api.list_weapons():
		if str(w.id) == _weapon_id:
			return str(w.get("name", _weapon_id))
	return _weapon_id.replace("_", " ").capitalize()


func _rebuild_detail() -> void:
	if _right == null:
		return
	for c in _right.get_children():
		c.queue_free()
	var type_name := _weapon_type_name()
	var hdr := HBoxContainer.new()
	hdr.name = "WeaponHeader"
	hdr.add_theme_constant_override("separation", 10)
	_right.add_child(hdr)
	var ht := wrap_label("%s UPGRADES — applies to all %ss" % [type_name.to_upper(), type_name], 15, UIStyle.RUST, true)
	ht.name = "WeaponTitle"
	ht.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hdr.add_child(ht)
	hdr.add_child(_weapon_ip_plate())
	var ups: Array = api.list_upgrades(_weapon_id)
	if ups.is_empty():
		_right.add_child(UIStyle.label("no upgrade track", 12, UIStyle.BONE_DIM))
	else:
		_right.add_child(_upgrade_track(ups[0]))
	_right.add_child(UIStyle.label("ATTACHMENTS", 15, UIStyle.RUST, true))
	var slots: Array = api.list_slots(_weapon_id)
	for sl in slots:
		_right.add_child(_slot_section(str(sl.id), str(sl.name), str(sl.get("equipped", ""))))


## Item Power for the selected type: best owned (or baseline) total + "rolled + Rework" line (Armory §1a).
func _weapon_ip_plate() -> Control:
	var bd: Dictionary = api.item_power_breakdown(_weapon_id) if api and api.has_method("item_power_breakdown") else {}
	var p := PanelContainer.new()
	p.name = "WeaponIP"
	p.set_meta("breakdown", bd)
	var st := UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8)
	st.set_content_margin_all(5)
	st.content_margin_left = 10
	st.content_margin_right = 10
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	p.add_child(h)
	var src := str(bd.get("source", "baseline"))
	var tag := UIStyle.label("BEST\nOWNED" if src == "best_owned" else ("THIS\nITEM" if src == "item" else "BASE\nLINE"), 9, UIStyle.BONE_DIM, true)
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(tag)
	var blk := UIStyle.ip_breakdown_block(bd, 22, 10, HORIZONTAL_ALIGNMENT_RIGHT)
	blk.add_theme_constant_override("separation", 0) # playtest #10: the -4 stack let the total and breakdown lines touch
	h.add_child(blk)
	return p


func _upgrade_track(u: Dictionary) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "UpgradeTrack"
	p.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(UIStyle.INK, 0.88), UIStyle.OLIVE, 2, 10))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	v.add_child(head)
	var un := wrap_label(str(u.get("name", "Rework")).to_upper(), 16, UIStyle.BONE, true)
	un.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(un)
	var lvl := int(u.get("current_level", u.get("level", 0)))
	var now := UIStyle.label("NOW  %s" % (UIStyle.roman(lvl) if lvl > 0 else "—"), 13, UIStyle.OLIVE.lightened(0.4), true)
	now.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(now)
	var maxed: bool = bool(u.get("maxed", false))
	var buy := _btn("MAXED" if maxed else "BUY %s  %d" % [str(u.get("next_tier_name", "")), int(u.get("cost", 0))],
		func(): _ask_buy(str(u.id), "upgrade"))
	buy.disabled = maxed or not bool(u.get("can_afford", false))
	if buy.disabled and not maxed:
		buy.tooltip_text = _disable_reason(str(u.id), true)
	head.add_child(buy)
	v.add_child(wrap_label(str(u.get("summary", "")), 12, UIStyle.BONE_DIM))
	var row := HBoxContainer.new()
	row.name = "TierRow"
	row.add_theme_constant_override("separation", 4)
	v.add_child(row)
	for t in u.get("tiers", []):
		var ti := int(t.get("tier", 0))
		var cell := PanelContainer.new()
		var cur: bool = ti == lvl
		var done: bool = ti <= lvl
		var col := UIStyle.RUST if cur else (UIStyle.OLIVE if done else UIStyle.BONE_DIM)
		cell.add_theme_stylebox_override("panel", UIStyle.cut_box(
			Color(col, 0.35 if cur else 0.15), col, 2 if cur else 1, 6))
		cell.custom_minimum_size = Vector2(72, 0)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL # 5 cells share the row width; their text wraps
		cell.size_flags_stretch_ratio = 1.0
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 1)
		cell.add_child(cv)
		cv.add_child(UIStyle.label(str(t.get("name", UIStyle.roman(ti))), 13, UIStyle.BONE if done or cur else UIStyle.BONE_DIM, true))
		cv.add_child(wrap_label("%d GM  ·  +%d IP" % [int(t.get("cost", 0)), int(t.get("item_power", 0))], 10, UIStyle.BONE_DIM))
		var sum := str(t.get("summary", ""))
		if sum != "":
			cv.add_child(wrap_label(sum, 10, UIStyle.BONE_DIM))
		row.add_child(cell)
	return p


func _slot_section(slot_id: String, slot_name: String, equipped_id: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	box.name = "Slot_" + slot_id
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)
	var sn := UIStyle.label(slot_name.to_upper(), 13, UIStyle.OLIVE.lightened(0.3), true)
	sn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(sn)
	if equipped_id != "":
		var eqd := UIStyle.label("EQUIPPED", 10, UIStyle.GOOD, true)
		eqd.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(eqd)
		var uq := _btn("UNEQUIP", func(): _do_unequip(slot_id))
		head.add_child(uq)
	var atts: Array = api.list_attachments(_weapon_id, slot_id)
	if atts.is_empty():
		box.add_child(wrap_label("none for this weapon", 11, UIStyle.BONE_DIM))
	for a in atts:
		box.add_child(_att_row(a))
	return box


func _att_row(a: Dictionary) -> PanelContainer:
	var p := PanelContainer.new()
	p.set_meta("att_id", str(a.id))
	var st := str(a.get("state", "available"))
	var border := UIStyle.GOOD if st == "equipped" else (UIStyle.OLIVE if st == "owned" else (UIStyle.BLOOD.darkened(0.2) if st == "locked" else UIStyle.BONE_DIM))
	p.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(UIStyle.INK, 0.85), border, 2, 8))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	p.add_child(h)
	h.add_child(UIStyle.attachment_icon(str(a.id), 40, str(a.get("slot", ""))))
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 1)
	h.add_child(v)
	var nh := HFlowContainer.new() # long names + T / UNIQUE tags wrap instead of pushing the cost column
	nh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nh.add_theme_constant_override("separation", 6)
	v.add_child(nh)
	nh.add_child(UIStyle.label(str(a.get("name", a.id)).to_upper(), 13, UIStyle.BONE, true))
	nh.add_child(UIStyle.label("T%d" % int(a.get("tier", 1)), 10, UIStyle.RUST.lightened(0.3), true))
	if bool(a.get("unique", false)):
		nh.add_child(UIStyle.label("UNIQUE", 9, UIStyle.BLOOD.lightened(0.3), true))
	v.add_child(wrap_label(str(a.get("summary", "")), 11, UIStyle.BONE_DIM))
	var drawback := str(a.get("drawback", ""))
	if drawback != "":
		v.add_child(wrap_label(drawback, 11, UIStyle.BLOOD.lightened(0.25)))
	var reqs: Array = a.get("requirements", [])
	var preqs: Array = a.get("purchase_requirements", [])
	var conflict: Dictionary = a.get("conflict", {}) if a.get("conflict", {}) is Dictionary else {}
	var why_conf := ""
	if not conflict.is_empty() and api.has_method("exclusion_reason"):
		why_conf = str(api.exclusion_reason(str(a.id), _weapon_id))
	var tier_reqs: Array = reqs.filter(func(r): return str(r) != why_conf)
	if not tier_reqs.is_empty():
		v.add_child(wrap_label("Need: " + ", ".join(tier_reqs), 10, UIStyle.RUST.lightened(0.2)))
	elif not bool(a.get("owned", false)) and not preqs.is_empty():
		v.add_child(wrap_label("Buy needs: " + ", ".join(preqs), 10, UIStyle.RUST.lightened(0.2)))
	var refused_here: bool = str(_refusal.get("id", "")) == str(a.id) and why_conf in str(_refusal.get("text", ""))
	if why_conf != "" and not refused_here: # the refusal line below repeats it
		var cl := UIStyle.label(why_conf, 10, UIStyle.BLOOD.lightened(0.35))
		cl.name = "ConflictReason"
		cl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		cl.custom_minimum_size.x = 40
		cl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(cl)
	if str(_refusal.get("id", "")) == str(a.id):
		var rl := UIStyle.label("✕ " + str(_refusal.text), 11, UIStyle.BLOOD.lightened(0.35), true)
		rl.name = "RefusalReason"
		rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rl.custom_minimum_size.x = 40
		rl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(rl)
	var actions := VBoxContainer.new()
	actions.name = "Actions"
	actions.custom_minimum_size.x = 64
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 4)
	h.add_child(actions)
	actions.add_child(UIStyle.label("%d" % int(a.get("cost", 0)), 14, UIStyle.RUST.lightened(0.25), true))
	var owned: bool = bool(a.get("owned", false))
	var equipped: bool = bool(a.get("equipped", false))
	if not owned:
		var buy := _btn("BUY", func(): _ask_buy(str(a.id), "attachment"))
		buy.disabled = not bool(a.get("can_afford", false))
		if buy.disabled:
			buy.tooltip_text = _disable_reason(str(a.id), false)
		actions.add_child(buy)
	elif equipped:
		actions.add_child(UIStyle.label("ON", 12, UIStyle.GOOD, true))
	else:
		var eq := _btn("EQUIP", func(): _do_equip(str(a.id), str(a.get("slot", ""))))
		eq.disabled = not a.get("requirements", []).is_empty()
		if eq.disabled:
			eq.tooltip_text = refusal_reason(str(a.id), "equip")
		actions.add_child(eq)
	return p


func _disable_reason(id: String, is_upgrade: bool) -> String:
	return refusal_reason(id, "buy")


## Why a buy ("buy") or equip ("equip") would be refused, from Armory's own rule set (art pass 3):
## Armory.purchase_check(id) / equip_check(weapon_id, slot, id) -> {ok, reason}. "" when it would go through.
func refusal_reason(id: String, kind: String) -> String:
	if api == null:
		return "Armory unavailable"
	var chk: Dictionary = ArmoryScr.equip_check(_weapon_id, "", id) if kind == "equip" else ArmoryScr.purchase_check(id)
	if bool(chk.get("ok", false)):
		return ""
	var r := str(chk.get("reason", ""))
	return r if r != "" else ("Can't equip this right now" if kind == "equip" else "Can't buy this right now")


## After a failed purchase()/equip(): Armory.last_refusal_reason(), falling back to the check.
func _last_refusal(id: String, kind: String) -> String:
	var r := str(ArmoryScr.last_refusal_reason())
	return r if r != "" else refusal_reason(id, kind)


## Show a refused buy / equip: inline on its row + footer toast + error cue.
func _refuse(id: String, kind: String, text: String = "") -> void:
	if text == "":
		text = refusal_reason(id, kind)
	_refusal = {"id": id, "kind": kind, "text": text}
	_ui_error()
	refresh()
	if _toast:
		var nm := id
		if not id.begins_with("upg_"):
			nm = str(ArmoryScr.attachment(id).get("name", id))
		else:
			nm = "%s Rework" % ArmoryScr.weapon_type(id.substr(4))
		_toast.text = "%s %s: %s" % ["Can't equip" if kind == "equip" else "Can't buy", nm, text]
		_toast.visible = true
		_toast_t = TOAST_SECS


## Error cue: "ui_error" if a sound with that key ever ships, else the soft ui_hover click.
func _ui_error() -> void:
	var a := get_node_or_null("/root/Sfx")
	if a == null:
		return
	a.play("ui_error" if a.has_method("has") and a.has("ui_error") else "ui_hover")


func _ask_buy(id: String, kind: String) -> void:
	_pending_id = id
	_pending_kind = "buy"
	var cost := int(api.cost(id)) if api else 0
	var bal := int(api.currency_balance()) if api else 0
	var label := id
	if kind == "upgrade":
		for u in api.list_upgrades(_weapon_id):
			if str(u.id) == id:
				var nm := str(u.get("name", id))
				var tier := str(u.get("next_tier_name", ""))
				label = ("%s %s" % [nm, tier]).strip_edges() if tier != "" else nm
				break
	else:
		for a in api.list_attachments(_weapon_id):
			if str(a.id) == id:
				label = str(a.get("name", id))
				break
	_confirm_label.text = "Spend %d Gravemarks on %s?" % [cost, label]
	# Cost / balance line with Gravemark icon: 100 → 97
	for c in _confirm_cost_row.get_children():
		_confirm_cost_row.remove_child(c)
		c.queue_free()
	_confirm_cost_row.add_child(UIStyle.gravemark_icon(20))
	_confirm_cost = UIStyle.label("%d  →  %d" % [bal, maxi(bal - cost, 0)], 15, UIStyle.RUST.lightened(0.25), true)
	_confirm_cost.name = "ConfirmCost"
	_confirm_cost.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_cost_row.add_child(_confirm_cost)
	_show_confirm(true)
	_ui_snd("ui_hover")
	_hold_t = 0.0
	_holding = false


func _show_confirm(on: bool) -> void:
	if _confirm_overlay:
		_confirm_overlay.visible = on
	if _confirm:
		_confirm.visible = on
	if not on:
		_holding = false
		_hold_t = 0.0

func _confirm_yes() -> void:
	_execute_pending()


func _confirm_no() -> void:
	_pending_id = ""
	_show_confirm(false)


func _execute_pending() -> void:
	if _pending_id == "" or api == null:
		_show_confirm(false)
		return
	var ok := false
	var pid := _pending_id
	var why := ""
	if _pending_kind == "buy":
		ok = bool(api.purchase(pid))
		if not ok:
			why = _last_refusal(pid, "buy")
	_show_confirm(false)
	_pending_id = ""
	if ok:
		_refusal = {}
		_ui_snd("ui_equip")
		refresh()
	else:
		_refuse(pid, "buy", why)


func _do_equip(id: String, slot: String) -> void:
	if api == null:
		return
	if api.equip_attachment(_weapon_id, slot, id):
		_refusal = {}
		_ui_snd("ui_equip")
		refresh()
	else:
		_refuse(id, "equip", _last_refusal(id, "equip"))


func _do_unequip(slot: String) -> void:
	if api and api.unequip(_weapon_id, slot):
		_ui_snd("ui_scrap_dismantle")
		refresh()


func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0 and _toast:
			_toast.visible = false
	if not visible or not _confirm.visible:
		_holding = false
		_hold_t = 0.0
		return
	if Input.is_action_pressed("ui_accept"):
		_holding = true
		_hold_t += delta
		if _hold_t >= 0.55:
			_execute_pending()
	else:
		if _holding and _hold_t > 0.0 and _hold_t < 0.55:
			pass # tap handled by confirm button / ui_accept press
		_holding = false
		_hold_t = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _confirm.visible:
		if event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_mouse"):
			get_viewport().set_input_as_handled()
			_confirm_no()
			return
		if event.is_action_pressed("ui_accept"):
			get_viewport().set_input_as_handled()
			_confirm_yes()
			return
	super._unhandled_input(event)
