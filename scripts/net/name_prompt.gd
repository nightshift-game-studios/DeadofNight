class_name NetNamePrompt
extends PanelContainer
## Minimal first-launch player name prompt (Netz). Fallback only: Gooey's scripts/ui/name_prompt.gd is the real one
## (Net.needs_name_prompt / Net.local_name / Net.validate_name / Net.set_local_profile / Net.profile_changed).
## open_if_needed() defers to it: when Gooey's prompt exists in the build, this one never opens.
## Hook (home_menu.gd _ready, one line):  NetNamePrompt.open_if_needed(self)

signal name_confirmed(player_name: String)

var line_edit: LineEdit
var ok_button: Button
var error_label: Label


## Opens the prompt on `parent` if no name has been saved yet; returns it, or null when nothing is needed.
const GOOEY_PROMPT := "res://scripts/ui/name_prompt.gd"
static var gooey_prompt_path := GOOEY_PROMPT ## tests point it elsewhere


static func open_if_needed(parent: Node) -> NetNamePrompt:
	var net := parent.get_node_or_null("/root/Net") if parent and parent.is_inside_tree() else null
	if net == null or not net.needs_name_prompt():
		return null
	if gooey_prompt_path != "" and ResourceLoader.exists(gooey_prompt_path):
		return null # Gooey's home opens its own prompt
	var p := NetNamePrompt.new()
	parent.add_child(p)
	return p


func _ready() -> void:
	set_anchors_preset(Control.PRESET_CENTER)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var title := Label.new()
	title.text = "Choose your name"
	box.add_child(title)
	line_edit = LineEdit.new()
	line_edit.max_length = int(NetConfig.get_value("profile.max_name_length", 16))
	line_edit.placeholder_text = str(NetConfig.get_value("profile.default_name", "Survivor"))
	line_edit.custom_minimum_size = Vector2(260, 0)
	line_edit.text_submitted.connect(func(_t): confirm())
	box.add_child(line_edit)
	error_label = Label.new()
	error_label.visible = false
	box.add_child(error_label)
	ok_button = Button.new()
	ok_button.text = "OK"
	ok_button.pressed.connect(confirm)
	box.add_child(ok_button)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	line_edit.grab_focus.call_deferred()


## Saves the name (empty -> the default name) and closes. Returns false if the text sanitizes to nothing usable.
func confirm() -> bool:
	var net := get_node_or_null("/root/Net")
	if net == null:
		return false
	var raw := line_edit.text if line_edit.text.strip_edges() != "" else line_edit.placeholder_text
	if not net.set_local_profile(raw):
		error_label.text = str(net.validate_name(raw).reason) if net.has_method("validate_name") else "That name can't be used"
		error_label.visible = true
		return false
	name_confirmed.emit(net.local_name())
	queue_free()
	return true
