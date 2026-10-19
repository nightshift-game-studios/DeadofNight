extends MenuBase
## Settings menu (Gooey). Tabs: Video, Audio, Controls, Gameplay. Built on MenuBase (pauses, Esc closes).
## Uses /root/Settings or Settings.get_or_create. Live-applies; Esc cancels an in-progress rebind first.
## When opened from the pause menu, closing returns there without unpausing.

const SettingsScript := preload("res://scripts/autoload/settings.gd")

var main: Node
var settings: Node
var return_to: Node = null ## pause menu to restore on close
var _tabs: HBoxContainer
var _body: VBoxContainer
var _tab: String = "video"
var _tab_btns: Dictionary = {}
var _rebind_action: String = ""
var _rebind_banner: PanelContainer
var _conflict_label: Label
var _scroll: ScrollContainer

signal opened_from_pause
signal closed_to_pause


func _init() -> void:
	super._init()
	layer = 12
	toggle_action = "" ## Esc handled below (rebind cancel first)


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(780, 520)
	settings = SettingsScript.get_or_create(self)
	if main == null:
		main = get_parent()
	if main and main.has_method("_on_menu_closed"):
		closed.connect(_on_closed_for_main)
	_build_chrome()


func _on_closed_for_main() -> void:
	if return_to != null:
		return # pause menu owns the session
	if main and main.has_method("_on_menu_closed"):
		main._on_menu_closed()


func open() -> void:
	return_to = null
	settings = SettingsScript.get_or_create(self)
	super.open()


## Open on top of the pause menu without toggling pause state.
func open_from_pause(pause: Node) -> void:
	return_to = pause
	settings = SettingsScript.get_or_create(self)
	_ui_snd("menu_open")
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	refresh()
	opened_from_pause.emit()


func close() -> void:
	_cancel_rebind()
	_ui_snd("menu_close")
	visible = false
	if return_to != null and is_instance_valid(return_to):
		var p := return_to
		return_to = null
		p.visible = true
		closed_to_pause.emit()
		return
	get_tree().paused = false
	closed.emit()


func _build_chrome() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	content.add_child(head)
	head.add_child(UIStyle.label("SETTINGS", 28, UIStyle.BONE, true))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var reset := _btn("RESET TO DEFAULTS", _on_reset)
	head.add_child(reset)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 6)
	content.add_child(_tabs)
	for id_label in [["video", "VIDEO"], ["audio", "AUDIO"], ["controls", "CONTROLS"], ["gameplay", "GAMEPLAY"]]:
		var b := _tab_btn(id_label[0], id_label[1])
		_tabs.add_child(b)
		_tab_btns[id_label[0]] = b
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	_scroll.add_child(_body)
	_rebind_banner = PanelContainer.new()
	_rebind_banner.visible = false
	_rebind_banner.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(UIStyle.BLOOD, 0.85), UIStyle.BONE, 2, 8))
	content.add_child(_rebind_banner)
	var rb := UIStyle.label("PRESS A KEY OR BUTTON…  ESC CANCELS", 16, UIStyle.BONE, true)
	rb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_rebind_banner.add_child(rb)
	_conflict_label = UIStyle.label("", 12, UIStyle.BAD)
	_conflict_label.visible = false
	content.add_child(_conflict_label)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	content.add_child(foot)
	foot.add_child(UIStyle.key_cap("ESC", 11))
	foot.add_child(UIStyle.label("BACK", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("Q / E", 11))
	foot.add_child(UIStyle.label("TABS", 11, UIStyle.BONE_DIM))
	var fs := Control.new()
	fs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fs)
	foot.add_child(UIStyle.label("Changes apply live  //  saved to user://settings.cfg", 11, UIStyle.BONE_DIM))


func refresh() -> void:
	_select_tab(_tab)


func _select_tab(id: String) -> void:
	_tab = id
	for k in _tab_btns:
		_style_tab(_tab_btns[k], k == id)
	for c in _body.get_children():
		c.queue_free()
	_conflict_label.visible = false
	match id:
		"video": _build_video()
		"audio": _build_audio()
		"controls": _build_controls()
		"gameplay": _build_gameplay()


func _build_video() -> void:
	_body.add_child(_section("DISPLAY"))
	_body.add_child(_toggle_row("Fullscreen", settings.fullscreen, func(v): settings.set_fullscreen(v)))
	_body.add_child(_toggle_row("VSync", settings.vsync, func(v): settings.set_vsync(v)))
	_body.add_child(_section("CAMERA"))
	_body.add_child(_slider_row("Field of View", settings.fov, 60.0, 110.0, 1.0, "%d°",
		func(v): settings.set_fov(v), true))
	## Motion blur master switch (no effect ships yet; kept here next to FOV for when a camera blur lands).
	_body.add_child(_toggle_row("Motion Blur", settings.motion_blur, func(v): settings.set_motion_blur(v)))


func _build_audio() -> void:
	_body.add_child(_section("MIXER"))
	for b in SettingsScript.AUDIO_BUSES:
		var key: String = "vol_" + b
		var cur: float = float(settings.get(key))
		_body.add_child(_slider_row(b, cur * 100.0, 0.0, 100.0, 1.0, "%d%%",
			func(v, bus=b): settings.set_bus_volume(bus, v / 100.0), true))


func _build_gameplay() -> void:
	_body.add_child(_section("LOOK"))
	var sens_ui: float = settings.mouse_sensitivity / 0.0025 # 1.0 = default
	_body.add_child(_slider_row("Mouse Sensitivity", sens_ui, 0.2, 4.0, 0.05, "%.2f×",
		func(v): settings.set_mouse_sensitivity(v * 0.0025), false))
	_body.add_child(_toggle_row("Invert Y", settings.invert_y, func(v): settings.set_invert_y(v)))
	_body.add_child(_section("AIM"))
	_body.add_child(_choice_row("ADS Mode", ["hold", "toggle"], ["Hold", "Toggle"], settings.ads_mode,
		func(v): settings.set_ads_mode(v)))
	var note := UIStyle.label("Hold: aim while RMB is down.  Toggle: RMB flips aim on/off.  Skillz ADS reads this.", 12, UIStyle.BONE_DIM)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size.x = 700
	_body.add_child(note)


func _build_controls() -> void:
	_body.add_child(_section("BINDINGS"))
	var hint := UIStyle.label("Click a binding, then press a key / mouse button / pad button. Esc cancels. Conflicts swap.", 12, UIStyle.BONE_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 700
	_body.add_child(hint)
	for a in SettingsScript.BINDABLE:
		if a == "ads" and not InputMap.has_action("ads"):
			continue
		_body.add_child(_bind_row(a))


# ---------------------------------------------------------------- widgets

func _section(t: String) -> Label:
	return UIStyle.label(t, 14, UIStyle.RUST, true)


func _toggle_row(label: String, on: bool, cb: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UIStyle.label(label, 15, UIStyle.BONE)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var b := Button.new()
	b.custom_minimum_size = Vector2(110, 32)
	b.focus_mode = Control.FOCUS_ALL
	_paint_toggle(b, on)
	b.pressed.connect(func():
		on = not on
		_paint_toggle(b, on)
		cb.call(on)
		_ui_snd("ui_equip"))
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	row.add_child(b)
	return row


func _paint_toggle(b: Button, on: bool) -> void:
	b.text = "ON" if on else "OFF"
	var col := UIStyle.OLIVE if on else UIStyle.BONE_DIM
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), col, 2, 6))
	b.add_theme_color_override("font_color", UIStyle.BONE if on else UIStyle.BONE_DIM)
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 14)


func _slider_row(label: String, value: float, mn: float, mx: float, step: float, fmt: String, cb: Callable, as_int: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var l := UIStyle.label(label, 15, UIStyle.BONE)
	l.custom_minimum_size.x = 160
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.value = value
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.custom_minimum_size.y = 28
	row.add_child(sl)
	var val := UIStyle.label(fmt % (int(round(value)) if as_int else value), 14, UIStyle.BONE, true)
	val.custom_minimum_size.x = 64
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val)
	sl.value_changed.connect(func(v):
		val.text = fmt % (int(round(v)) if as_int else v)
		cb.call(v))
	return row


func _choice_row(label: String, values: Array, labels: Array, current: String, cb: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var l := UIStyle.label(label, 15, UIStyle.BONE)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	var btns: Array = []
	for i in values.size():
		var b := Button.new()
		b.text = str(labels[i]).to_upper()
		b.custom_minimum_size = Vector2(100, 32)
		b.focus_mode = Control.FOCUS_ALL
		b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
		b.add_theme_font_size_override("font_size", 13)
		var active: bool = str(values[i]) == current
		b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.OLIVE if active else UIStyle.BONE_DIM, 2, 6))
		b.add_theme_color_override("font_color", UIStyle.BONE)
		var idx := i
		b.pressed.connect(func():
			cb.call(str(values[idx]))
			_ui_snd("ui_equip")
			_select_tab(_tab))
		b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
		row.add_child(b)
		btns.append(b)
	return row


func _bind_row(action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.set_meta("action", action)
	var name := str(SettingsScript.BIND_LABELS.get(action, action))
	var l := UIStyle.label(name, 14, UIStyle.BONE)
	l.custom_minimum_size.x = 160
	row.add_child(l)
	var labels: PackedStringArray = settings.binding_labels(action)
	var shown := ", ".join(labels) if labels.size() > 0 else "(none)"
	var b := Button.new()
	b.text = shown
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 30)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.85), UIStyle.BONE_DIM, 1, 5))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 5))
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.pressed.connect(func(): _begin_rebind(action, b))
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	row.add_child(b)
	var rst := Button.new()
	rst.text = "RESET"
	rst.focus_mode = Control.FOCUS_NONE
	rst.custom_minimum_size = Vector2(72, 30)
	rst.add_theme_font_size_override("font_size", 11)
	rst.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.8), UIStyle.BONE_DIM, 1, 4))
	rst.pressed.connect(func():
		settings.reset_binding(action)
		_ui_snd("ui_scrap_dismantle")
		_select_tab("controls"))
	row.add_child(rst)
	return row


func _begin_rebind(action: String, btn: Button) -> void:
	_rebind_action = action
	_rebind_banner.visible = true
	_conflict_label.visible = false
	btn.text = "…"
	_ui_snd("ui_hover")


func _cancel_rebind() -> void:
	if _rebind_action == "":
		return
	_rebind_action = ""
	_rebind_banner.visible = false
	if _tab == "controls":
		_select_tab("controls")


func _finish_rebind(event: InputEvent) -> void:
	var action := _rebind_action
	_rebind_action = ""
	_rebind_banner.visible = false
	var r: Dictionary = settings.rebind(action, event, true)
	if r.ok:
		_ui_snd("ui_equip")
		if str(r.conflict) != "":
			_conflict_label.text = "Swapped with %s" % SettingsScript.BIND_LABELS.get(r.conflict, r.conflict)
			_conflict_label.visible = true
	else:
		_ui_snd("ui_scrap_dismantle")
	_select_tab("controls")


func _on_reset() -> void:
	settings.reset_to_defaults()
	_ui_snd("ui_scrap_dismantle")
	refresh()


func _tab_btn(id: String, label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(120, 34)
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(func():
		_ui_snd("ui_hover")
		_select_tab(id))
	_style_tab(b, false)
	return b


func _style_tab(b: Button, on: bool) -> void:
	var edge := UIStyle.RUST if on else UIStyle.BONE_DIM
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), edge, 2 if on else 1, 6))
	b.add_theme_color_override("font_color", UIStyle.BONE if on else UIStyle.BONE_DIM)


func _btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 6))
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	return b


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if _rebind_action != "":
		if event.is_action_pressed("toggle_mouse") or (event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE):
			get_viewport().set_input_as_handled()
			_cancel_rebind()
			return
		if event is InputEventKey and event.pressed and not event.echo:
			get_viewport().set_input_as_handled()
			_finish_rebind(event)
			return
		if event is InputEventMouseButton and event.pressed:
			get_viewport().set_input_as_handled()
			_finish_rebind(event)
			return
		if event is InputEventJoypadButton and event.pressed:
			get_viewport().set_input_as_handled()
			_finish_rebind(event)
			return
		return
	if event.is_action_pressed("toggle_mouse") or (event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE):
		get_viewport().set_input_as_handled()
		close()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_Q:
			_cycle_tab(-1)
			get_viewport().set_input_as_handled()
		elif event.physical_keycode == KEY_E:
			_cycle_tab(1)
			get_viewport().set_input_as_handled()


func _cycle_tab(dir: int) -> void:
	var ids := ["video", "audio", "controls", "gameplay"]
	var i := ids.find(_tab)
	_select_tab(ids[(i + dir + ids.size()) % ids.size()])
	_ui_snd("ui_hover")
