extends Control
## DeadofNight HOME / title screen (Pass 5, Gooey).
## Full-screen rugged menu (same palette as the loadout). Until G4M3N sets
## run/main_scene to scenes/ui/home.tscn, tests and shots instance this directly.
##
## Buttons: Play → map select → MapRegistry.select + change_scene to main.tscn
##          Kit → character_screen on a KitProxy (persistent stash)
##          Armory → placeholder ArmoryAPI shell (COMING SOON)
##          Settings → settings_menu
##          Quit → Progress.save_stash() then quit
## Header: rare-currency chip (hidden until a real currency_balance API exists).

const CharacterScreenScript := preload("res://scripts/ui/character_screen.gd")
const MapPickerScript := preload("res://scripts/ui/map_picker.gd")
const SettingsMenuScript := preload("res://scripts/ui/settings_menu.gd")
const ArmoryMenuScript := preload("res://scripts/ui/armory_menu.gd")
const KitProxyScript := preload("res://scripts/ui/kit_proxy.gd")
const ArmoryScr := preload("res://scripts/armory/armory.gd")
const MAIN_SCENE := "res://scenes/main.tscn"
const HARD_NOTE := "Hard: tougher zombies, better rare-currency drops."

signal play_requested(map_id: String) ## emitted before scene change (tests stub change_scene)
signal quit_requested ## emitted before quit (tests stub quit)

var dry_run: bool = false ## tests: don't change_scene / quit
var last_play_map: String = ""
var quit_calls: int = 0
var save_stash_calls: int = 0

var _btns: Dictionary = {} ## id -> Button
var _currency_chip: PanelContainer
var _currency_label: Label
var _map_picker: MenuBase
var _settings: MenuBase
var _armory: MenuBase
var _kit_screen: MenuBase
var _kit_proxy: Node
var _armory_api: RefCounted ## Armory instance for live Gravemark balance
var _focus_order: Array = [] ## button ids for keyboard wrap


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	call_deferred("_focus_first")


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = UIStyle.INK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var vg := TextureRect.new()
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.4)
	gt.fill_to = Vector2(1.15, 1.15)
	var g := Gradient.new()
	g.set_color(0, Color(0.32, 0.22, 0.12, 0.28))
	g.set_color(1, Color(0, 0, 0, 0.75))
	gt.gradient = g
	vg.texture = gt
	vg.stretch_mode = TextureRect.STRETCH_SCALE
	vg.set_anchors_preset(Control.PRESET_FULL_RECT)
	vg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vg)
	UIStyle.add_grit(self, 0.1)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + s, 64)
	margin.add_theme_constant_override("margin_top", 48)
	margin.add_theme_constant_override("margin_bottom", 40)
	add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 18)
	margin.add_child(col)

	# Header: title + rare-currency slot (hidden until API exists)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	col.add_child(head)
	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override("separation", -4)
	head.add_child(title_box)
	title_box.add_child(UIStyle.label("DEADOFNIGHT", 52, UIStyle.BONE, true, 4))
	title_box.add_child(UIStyle.label("SURVIVE THE WAVE", 14, UIStyle.RUST.lightened(0.2), true))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_currency_chip = UIStyle.gravemark_chip(0, 26)
	_currency_chip.name = "CurrencyChip"
	_currency_chip.visible = true
	_currency_label = _currency_chip.find_child("GravemarkAmount", true, false) as Label
	head.add_child(_currency_chip)

	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.75)
	line.custom_minimum_size = Vector2(0, 4)
	col.add_child(line)

	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 10)
	menu.custom_minimum_size.x = 420
	col.add_child(menu)
	for id_lab in [
		["play", "PLAY"],
		["kit", "KIT / INVENTORY"],
		["armory", "ARMORY"],
		["settings", "SETTINGS"],
		["quit", "QUIT"],
	]:
		var b := _menu_btn(id_lab[1])
		b.name = "Btn_" + id_lab[0]
		b.pressed.connect(_on_btn.bind(id_lab[0]))
		menu.add_child(b)
		_btns[id_lab[0]] = b
		_focus_order.append(id_lab[0])

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	col.add_child(foot)
	foot.add_child(UIStyle.key_cap("↑↓", 11))
	foot.add_child(UIStyle.label("MOVE", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ENTER", 11))
	foot.add_child(UIStyle.label("SELECT", 11, UIStyle.BONE_DIM))
	var fsp := Control.new()
	fsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fsp)
	foot.add_child(UIStyle.label("TAB  LOADOUT IN-MATCH", 11, UIStyle.BONE_DIM))

	# Child overlays (built once, opened on demand)
	_kit_proxy = KitProxyScript.new()
	_kit_proxy.name = "KitProxy"
	add_child(_kit_proxy)

	_kit_screen = CharacterScreenScript.new()
	_kit_screen.name = "KitScreen"
	_kit_screen.toggle_action = "inventory"
	_kit_screen.player = _kit_proxy
	_kit_screen.closed.connect(_on_kit_closed)
	add_child(_kit_screen)

	_map_picker = MapPickerScript.new()
	_map_picker.name = "HomeMapPicker"
	_map_picker.home_mode = true
	_map_picker.dry_run = dry_run
	_map_picker.main = self # can_open in home_mode ignores match gates
	if _map_picker.has_signal("map_chosen"):
		_map_picker.map_chosen.connect(_on_map_chosen)
	add_child(_map_picker)

	_settings = SettingsMenuScript.new()
	_settings.name = "HomeSettings"
	add_child(_settings)

	_armory = ArmoryMenuScript.new()
	_armory.name = "HomeArmory"
	add_child(_armory)

	_armory_api = ArmoryScr.new()
	if _armory_api.has_signal("currency_changed"):
		_armory_api.currency_changed.connect(_on_currency_changed)
	_on_currency_changed(int(_armory_api.currency_balance()))
	# Also listen on Progress directly (match drops while home is not shown still refresh on return)
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_signal("currency_changed") and not prog.currency_changed.is_connected(_on_currency_changed):
		prog.currency_changed.connect(_on_currency_changed)

	_wire_focus_neighbors()


func _menu_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 52)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.add_theme_color_override("font_hover_color", UIStyle.BONE)
	b.add_theme_color_override("font_focus_color", UIStyle.INK)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.92), UIStyle.BONE_DIM, 2, 10))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.96), UIStyle.RUST, 3, 10))
	b.add_theme_stylebox_override("focus", UIStyle.cut_box(UIStyle.BONE, UIStyle.RUST, 3, 10))
	b.add_theme_stylebox_override("pressed", UIStyle.cut_box(UIStyle.OLIVE_DARK, UIStyle.RUST, 3, 10))
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	return b


func _wire_focus_neighbors() -> void:
	var n := _focus_order.size()
	for i in n:
		var b: Button = _btns[_focus_order[i]]
		var up: Button = _btns[_focus_order[(i - 1 + n) % n]]
		var dn: Button = _btns[_focus_order[(i + 1) % n]]
		b.focus_neighbor_top = b.get_path_to(up)
		b.focus_neighbor_bottom = b.get_path_to(dn)


func _focus_first() -> void:
	if _btns.has("play"):
		(_btns["play"] as Button).grab_focus()


func _ui_snd(key: String) -> void:
	var a := get_node_or_null("/root/Sfx")
	if a:
		a.play(key)


func _on_btn(id: String) -> void:
	_ui_snd("ui_equip")
	match id:
		"play":
			_open_map_select()
		"kit":
			_open_kit()
		"armory":
			_armory.open()
		"settings":
			_settings.open()
		"quit":
			request_quit()


func _open_map_select() -> void:
	_map_picker.dry_run = dry_run
	_map_picker.home_mode = true
	_map_picker.open()


func _on_map_chosen(map_id: String) -> void:
	start_match(map_id)


## Select map and enter the match scene (class comes from Progress.selected_class).
func start_match(map_id: String) -> bool:
	if map_id == "" or not MapRegistry.is_valid(map_id):
		return false
	MapRegistry.select(map_id)
	last_play_map = map_id
	play_requested.emit(map_id)
	_ui_snd("ui_equip")
	if dry_run:
		return true
	get_tree().change_scene_to_file(MAIN_SCENE)
	return true


func _open_kit() -> void:
	if _kit_proxy.has_method("ensure"):
		_kit_proxy.ensure()
	_kit_screen.player = _kit_proxy
	_kit_screen.open()


func _on_kit_closed() -> void:
	if _kit_proxy and _kit_proxy.has_method("save"):
		if _kit_proxy.save():
			save_stash_calls += 1


func request_quit() -> void:
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("save_stash"):
		# Bind kit inventory if open so Quit persists kit edits too.
		if _kit_proxy and _kit_proxy.get("inventory"):
			prog.bind_inventory(_kit_proxy.inventory)
		if prog.save_stash():
			save_stash_calls += 1
		elif prog.has_method("save_data"):
			prog.save_data() # still flush progress even with no bound inv
	quit_calls += 1
	quit_requested.emit()
	if dry_run:
		return
	get_tree().quit()


## Home hosts map_picker: pretend "before round 1" so can_open works when home_mode is off.
var current_round: int = 0
var _game_over: bool = false


func restart_with_map(id: String) -> bool:
	## Map picker in home_mode may still call this; route to start_match.
	return start_match(id)


func _on_currency_changed(n: int = -1) -> void:
	var bal := n
	if bal < 0:
		var prog := get_node_or_null("/root/Progress")
		bal = int(prog.gravemark_balance()) if prog and prog.has_method("gravemark_balance") else 0
	UIStyle.set_gravemark_chip_amount(_currency_chip, bal)
	if _currency_chip:
		_currency_chip.visible = true


## Public: force-refresh the header Gravemark chip.
func set_currency_balance(n: int, visible_chip: bool = true) -> void:
	UIStyle.set_gravemark_chip_amount(_currency_chip, n)
	if _currency_chip:
		_currency_chip.visible = visible_chip
