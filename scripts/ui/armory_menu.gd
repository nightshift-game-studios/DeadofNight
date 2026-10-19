extends MenuBase
## Armory shell (Pass 5). Placeholder data via ArmoryAPI — clearly marked COMING SOON.
## Tabs: Upgrades / Attachments. Real Skillz API drops in behind ArmoryAPI later.

const ArmoryAPIScript := preload("res://scripts/ui/armory_api.gd")

var api: RefCounted
var _tabs: HBoxContainer
var _body: VBoxContainer
var _bal: Label
var _tab: String = "upgrades"
var _tab_btns: Dictionary = {}


func _init() -> void:
	super._init()
	layer = 12


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(720, 480)
	if api == null:
		api = ArmoryAPIScript.new()
	if api.has_signal("currency_changed") and not api.currency_changed.is_connected(_on_bal):
		api.currency_changed.connect(_on_bal)
	_build()


func _build() -> void:
	clear_content()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	content.add_child(head)
	head.add_child(UIStyle.label("ARMORY", 28, UIStyle.BONE, true))
	var soon := PanelContainer.new()
	soon.add_theme_stylebox_override("panel", UIStyle.cut_box(UIStyle.BLOOD.darkened(0.2), UIStyle.BONE, 2, 6))
	soon.add_child(UIStyle.label("COMING SOON", 12, UIStyle.BONE, true))
	head.add_child(soon)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_bal = UIStyle.label("", 14, UIStyle.RUST.lightened(0.25), true)
	head.add_child(_bal)
	content.add_child(UIStyle.label("Placeholder catalogue — purchases won't carry into a live match yet.", 12, UIStyle.BONE_DIM))
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 6)
	content.add_child(_tabs)
	for id_lab in [["upgrades", "UPGRADES"], ["attachments", "ATTACHMENTS"]]:
		var b := Button.new()
		b.text = id_lab[1]
		b.focus_mode = Control.FOCUS_ALL
		b.add_theme_font_override("font", UIStyle.body_bold())
		b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(_select_tab.bind(id_lab[0]))
		b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
		_tabs.add_child(b)
		_tab_btns[id_lab[0]] = b
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_body)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	content.add_child(foot)
	foot.add_child(UIStyle.key_cap("ESC", 11))
	foot.add_child(UIStyle.label("BACK", 11, UIStyle.BONE_DIM))
	_select_tab("upgrades")


func _on_bal(_n: int = 0) -> void:
	_refresh_bal()


func _refresh_bal() -> void:
	if _bal == null or api == null:
		return
	_bal.text = "%s  %d" % [str(api.currency_name).to_upper(), int(api.currency_balance())]


func _select_tab(id: String) -> void:
	_tab = id
	for k in _tab_btns:
		var b: Button = _tab_btns[k]
		var on: bool = k == id
		b.add_theme_stylebox_override("normal", UIStyle.cut_box(
			UIStyle.OLIVE_DARK if on else Color(UIStyle.INK, 0.9),
			UIStyle.RUST if on else UIStyle.BONE_DIM, 2, 6))
		b.add_theme_color_override("font_color", UIStyle.BONE)
	refresh()


func refresh() -> void:
	_refresh_bal()
	if _body == null:
		return
	for c in _body.get_children():
		c.queue_free()
	if _tab == "attachments":
		_fill_attachments()
	else:
		_fill_upgrades()


func _fill_upgrades() -> void:
	for e in api.list_upgrades():
		_body.add_child(_row(e, true))


func _fill_attachments() -> void:
	for wid in ["sidearm", "smg"]:
		_body.add_child(UIStyle.label(wid.to_upper(), 13, UIStyle.RUST, true))
		for e in api.list_attachments(wid):
			var row := _row(e, false)
			row.set_meta("weapon_id", wid)
			_body.add_child(row)


func _row(e: Dictionary, is_upgrade: bool) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(UIStyle.INK, 0.85), UIStyle.BONE_DIM, 2, 8))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	p.add_child(h)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	v.add_child(UIStyle.label(str(e.get("name", e.get("id", "?"))).to_upper(), 14, UIStyle.BONE, true))
	var sum := str(e.get("summary", ""))
	v.add_child(UIStyle.label(sum, 12, UIStyle.BONE_DIM))
	var meta := ""
	if is_upgrade:
		meta = "LV %d/%d" % [int(e.get("current_level", 0)), int(e.get("max_level", 1))]
	else:
		meta = "OWNED" if bool(e.get("owned", false)) else str(e.get("slot", "")).to_upper()
	h.add_child(UIStyle.label(meta, 12, UIStyle.OLIVE.lightened(0.3), true))
	var cost := int(e.get("cost", 0))
	var buy := Button.new()
	buy.text = "%d" % cost
	buy.focus_mode = Control.FOCUS_ALL
	buy.disabled = not api.can_afford(str(e.get("id", "")))
	buy.add_theme_font_override("font", UIStyle.body_bold())
	buy.add_theme_stylebox_override("normal", UIStyle.cut_box(UIStyle.PANEL, UIStyle.RUST, 2, 6))
	buy.pressed.connect(func():
		if api.purchase(str(e.id)):
			_ui_snd("ui_equip")
			refresh()
		else:
			_ui_snd("ui_hover"))
	buy.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	h.add_child(buy)
	return p
