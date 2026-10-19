extends MenuBase
## Lightweight pause overlay (Gooey). Esc / toggle_mouse opens mid-match (and at round 0 / game over).
## Hosted by hud.gd until main.gd instances it. Offers Resume + Settings; Settings opens settings_menu.
## Consumes Esc so player.gd does not also toggle mouse capture.

const SettingsMenuScript := preload("res://scripts/ui/settings_menu.gd")

var main: Node
var settings_menu: Node
var _status: Label


func _init() -> void:
	super._init()
	layer = 11
	toggle_action = "toggle_mouse"


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(420, 340)
	if main == null:
		main = get_parent()
	_build()
	if main and main.has_method("_on_menu_closed"):
		closed.connect(main._on_menu_closed)


func _build() -> void:
	content.add_child(UIStyle.label("PAUSED", 32, UIStyle.BONE, true))
	_status = UIStyle.label("", 13, UIStyle.BONE_DIM)
	content.add_child(_status)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)
	content.add_child(_menu_btn("RESUME", close))
	content.add_child(_menu_btn("SETTINGS", _open_settings))
	content.add_child(_menu_btn("QUIT TO HOME", _quit_to_home))
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	content.add_child(foot)
	foot.add_child(UIStyle.key_cap("ESC", 11))
	foot.add_child(UIStyle.label("RESUME", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ENTER", 11))
	foot.add_child(UIStyle.label("CONFIRM", 11, UIStyle.BONE_DIM))


func _menu_btn(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	return b


func refresh() -> void:
	var round_n: int = int(main.get("current_round")) if main else 0
	var over: bool = bool(main.get("_game_over")) if main else false
	if over:
		_status.text = "GAME OVER  //  SETTINGS & RESUME"
	elif round_n == 0:
		_status.text = "BEFORE ROUND 1  //  TWEAK BEFORE YOU DROP"
	else:
		_status.text = "ROUND %d  //  GAME PAUSED" % round_n


func can_open() -> bool:
	if main == null or not is_instance_valid(main):
		return false
	# Don't steal Esc from other open menus.
	for n in [main.get("skill_menu"), main.get("map_picker"), main.get("character_screen"), main.get("run_pick_menu")]:
		if n != null and is_instance_valid(n) and bool(n.get("visible")):
			return false
	if settings_menu != null and settings_menu.visible:
		return false
	return true


const HOME_SCENE := "res://scenes/ui/home.tscn"
var dry_run: bool = false ## tests: skip change_scene
var quit_home_calls: int = 0


## Save stash, unpause, return to the title screen. main.return_to_home() if present.
func _quit_to_home() -> void:
	quit_home_calls += 1
	_ui_snd("menu_close")
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("save_stash"):
		prog.save_stash()
	visible = false
	get_tree().paused = false
	if dry_run:
		return
	if main and main.has_method("return_to_home"):
		main.return_to_home()
		return
	get_tree().change_scene_to_file(HOME_SCENE)


func _open_settings() -> void:
	if settings_menu == null:
		return
	visible = false
	settings_menu.open_from_pause(self)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_mouse"):
		if visible:
			get_viewport().set_input_as_handled()
			close()
			return
		if can_open():
			get_viewport().set_input_as_handled()
			open()
			return
	if not visible:
		return
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		close()
	else:
		super._unhandled_input(event)
