class_name MenuBase
extends CanvasLayer
## Shared helpers for simple code-built menus that pause the game while open.

signal closed

var toggle_action: String = "" ## pressing this action again closes the menu

var panel: PanelContainer
var content: VBoxContainer


func _init() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false


func _ready() -> void:
	var dim := ColorRect.new()
	dim.color = Color(UIStyle.INK, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var vg := TextureRect.new() # warm centre, dark edges (same backdrop as the loadout screen)
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.45)
	gt.fill_to = Vector2(1.1, 1.1)
	var g := Gradient.new()
	g.set_color(0, Color(0.30, 0.24, 0.14, 0.22))
	g.set_color(1, Color(0, 0, 0, 0.7))
	gt.gradient = g
	vg.texture = gt
	vg.stretch_mode = TextureRect.STRETCH_SCALE
	vg.set_anchors_preset(Control.PRESET_FULL_RECT)
	vg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vg)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(720, 420)
	var ps := UIStyle.cut_box(Color(0.06, 0.06, 0.05, 0.96), UIStyle.RUST, 3, 22)
	ps.set_content_margin_all(0)
	panel.add_theme_stylebox_override("panel", ps)
	center.add_child(panel)
	var grit_holder := Control.new()
	grit_holder.clip_contents = true
	grit_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(grit_holder)
	UIStyle.add_grit(grit_holder, 0.12)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)
	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)


func open() -> void:
	_ui_snd("menu_open")
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	refresh()


func close() -> void:
	_ui_snd("menu_close")
	visible = false
	get_tree().paused = false
	closed.emit()


func refresh() -> void:
	pass


## UI sound through the Sfx autoload (menu open/close, hover, equip, scrap, skill unlock).
func _ui_snd(key: String) -> void:
	var a := get_node_or_null("/root/Sfx")
	if a:
		a.play(key)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if (toggle_action != "" and event.is_action_pressed(toggle_action)) or event.is_action_pressed("toggle_mouse"):
		get_viewport().set_input_as_handled()
		close()


func clear_content() -> void:
	for c in content.get_children():
		c.queue_free()


func add_title(text: String, size: int = 30) -> Label:
	var l := UIStyle.label(text.to_upper(), size, UIStyle.BONE, true)
	content.add_child(l)
	return l


func add_text(parent: Control, text: String, size: int = 16, color: Color = UIStyle.BONE) -> Label:
	var l := UIStyle.label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l
