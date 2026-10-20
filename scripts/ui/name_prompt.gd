class_name GravecrewNamePrompt
extends CanvasLayer
## Player-name prompt (Gooey): the real UI behind Netz's NetNamePrompt placeholder (same entry point + signal).
## First launch on home, before CO-OP / HOST / JOIN when no name is set, and from Settings.
##   GravecrewNamePrompt.open_if_needed(parent)  == NetNamePrompt.open_if_needed(parent): null when no name is needed
## Name store: ONE store, Settings.player_name. Netz (cb5e52a) reads / writes it whenever Settings has the field and
## follows Settings.changed; Net.needs_name_prompt / local_name / set_local_profile front it (LobbyAPI.sync_names only
## covers an older Net that kept user://net_profile.cfg). Rules: one validator, Net.validate_name (NetNames) when
## installed, else Settings.validate_player_name (byte-identical: 2-16 chars, letters, numbers, space, _ - .; invalid
## names are refused, not stripped). Netz's NetNamePrompt.open_if_needed returns null while this script exists.
## Emits submitted(name) + name_confirmed(name).
## Nodes: NamePromptOverlay / NamePromptCard / NameEdit, NameError, NameOK, NameCancel.

signal submitted(player_name: String)
signal name_confirmed(player_name: String) ## NetNamePrompt's signal name
signal cancelled

const LAPI := preload("res://scripts/ui/lobby_api.gd")


## Opens the prompt on `parent` when no name is saved yet (Net.needs_name_prompt, else no Settings name).
## Returns it, or null when nothing is needed. Drop-in for NetNamePrompt.open_if_needed(parent).
static func open_if_needed(parent: Node) -> Node:
	if parent == null or not parent.is_inside_tree():
		return null
	var st := parent.get_node_or_null("/root/Settings")
	if st == null or not LAPI.needs_name(st, LAPI.existing(parent)):
		return null
	var p: CanvasLayer = load("res://scripts/ui/name_prompt.gd").new()
	p.allow_cancel = false
	parent.add_child(p)
	return p

const SettingsScript := preload("res://scripts/autoload/settings.gd")

var title_text: String = "WHAT DO THEY CALL YOU?"
var sub_text: String = "Your name shows in co-op lobbies and on the party HUD. Change it any time in Settings."
var allow_cancel: bool = false ## first launch: must pick a name

var edit: LineEdit
var error_label: Label
var ok_btn: Button
var cancel_btn: Button
var _overlay: Control


func _init() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "NamePrompt"


func _ready() -> void:
	var dlg := UIStyle.dialog_overlay("NamePromptOverlay", 0.8)
	_overlay = dlg.overlay
	add_child(_overlay)
	var card := UIStyle.dialog_card(Vector2(520, 230), "NamePromptCard")
	(dlg.center as CenterContainer).add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	card.add_child(v)
	var t := UIStyle.label(title_text, 22, UIStyle.BONE, true)
	t.name = "NameTitle"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := UIStyle.label(sub_text, 12, UIStyle.BONE_DIM)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.custom_minimum_size.x = 470
	v.add_child(sub)
	edit = LineEdit.new()
	edit.name = "NameEdit"
	edit.max_length = SettingsScript.NAME_MAX + 4
	edit.placeholder_text = "Survivor name"
	edit.custom_minimum_size = Vector2(0, 46)
	edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	edit.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	edit.add_theme_font_size_override("font_size", 22)
	edit.add_theme_color_override("font_color", UIStyle.BONE)
	edit.add_theme_color_override("font_placeholder_color", Color(UIStyle.BONE_DIM, 0.5))
	edit.add_theme_color_override("caret_color", UIStyle.RUST.lightened(0.3))
	edit.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.95), UIStyle.BONE_DIM, 2, 10))
	edit.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0, 0, 0, 0), UIStyle.RUST, 3, 10))
	edit.text_changed.connect(_on_text_changed)
	edit.text_submitted.connect(func(_t): submit())
	v.add_child(edit)
	error_label = UIStyle.label("%d-%d characters: %s" % [SettingsScript.NAME_MIN, SettingsScript.NAME_MAX, SettingsScript.NAME_ALLOWED], 12, UIStyle.BONE_DIM)
	error_label.name = "NameError"
	error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(error_label)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	ok_btn = _btn("SAVE NAME")
	ok_btn.name = "NameOK"
	UIStyle.style_primary_button(ok_btn)
	ok_btn.pressed.connect(submit)
	row.add_child(ok_btn)
	cancel_btn = _btn("CANCEL")
	cancel_btn.name = "NameCancel"
	cancel_btn.pressed.connect(cancel)
	cancel_btn.visible = allow_cancel
	row.add_child(cancel_btn)
	edit.focus_neighbor_bottom = edit.get_path_to(ok_btn)
	ok_btn.focus_neighbor_top = ok_btn.get_path_to(edit)
	ok_btn.focus_neighbor_right = ok_btn.get_path_to(cancel_btn if allow_cancel else ok_btn)
	cancel_btn.focus_neighbor_left = cancel_btn.get_path_to(ok_btn)
	var s := _settings()
	var net := LAPI.existing(self)
	if net and not LAPI.is_stub(net) and net.has_method("needs_name_prompt") and not net.needs_name_prompt():
		edit.text = str(net.local_name())
	elif s and str(s.get("player_name")) != "":
		edit.text = str(s.player_name)
	_on_text_changed(edit.text)
	edit.call_deferred("grab_focus")


func _btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(150, 42)
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
	b.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.08, 0.08, 0.07, 0.9), Color(0.36, 0.33, 0.28), 2, 8))
	b.mouse_entered.connect(_snd.bind("ui_hover"))
	return b


func _settings() -> Node:
	return get_node_or_null("/root/Settings")


func _snd(k: String) -> void:
	var a := get_node_or_null("/root/Sfx")
	if a:
		a.play(k)


func _on_text_changed(t: String) -> void:
	if t.strip_edges() == "":
		error_label.text = "%d-%d characters: %s" % [SettingsScript.NAME_MIN, SettingsScript.NAME_MAX, SettingsScript.NAME_ALLOWED]
		error_label.add_theme_color_override("font_color", UIStyle.BONE_DIM)
		ok_btn.disabled = true
		return
	var v := LAPI.check_name(LAPI.existing(self), t)
	ok_btn.disabled = not v.ok
	error_label.text = "Looks good." if v.ok else str(v.reason)
	error_label.add_theme_color_override("font_color", UIStyle.OLIVE.lightened(0.45) if v.ok else UIStyle.BAD)


## Validate + save. Returns the saved name, or "" when refused (reason in NameError).
func submit() -> String:
	var s := _settings()
	var net := LAPI.existing(self)
	var raw := edit.text
	var v: Dictionary = LAPI.check_name(net, raw)
	if bool(v.ok) and net and net.has_method("set_local_profile"):
		var prog := get_node_or_null("/root/Progress")
		if not bool(net.set_local_profile(str(v.name), str(prog.selected_class) if prog and "selected_class" in prog else "")):
			v = {"ok": false, "name": raw, "reason": "That name can't be used."}
	if bool(v.ok) and s:
		v = s.set_player_name(str(v.name))
	if not bool(v.ok):
		error_label.text = str(v.reason)
		error_label.add_theme_color_override("font_color", UIStyle.BAD)
		var a := get_node_or_null("/root/Sfx")
		if a:
			a.play("ui_error" if a.has_method("has") and a.has("ui_error") else "ui_hover")
		return ""
	_snd("ui_equip")
	submitted.emit(str(v.name))
	name_confirmed.emit(str(v.name))
	queue_free()
	return str(v.name)


## NetNamePrompt-compatible: saves the name; false when it can't be used.
func confirm() -> bool:
	return submit() != ""


func cancel() -> void:
	if not allow_cancel:
		return
	cancelled.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if allow_cancel and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_mouse")):
		get_viewport().set_input_as_handled()
		cancel()
