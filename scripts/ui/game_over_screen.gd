class_name GameOverScreen
extends CanvasLayer
## Gooey: the death / game-over stats page (playtest #8). Built by hud.gd when RunStatsTracker finishes; added
## next to the HUD (not under it: the HUD forces MOUSE_FILTER_IGNORE on all its descendants).
## Headline tiles: kills, damage dealt, rounds survived, points earned, Gravemarks, XP. Detail rows: accuracy,
## headshots, precision kills, time survived, damage taken / healed, boss / melee kills, grenades, Field Cards,
## doors. BACK TO MENU (main.return_to_home), PLAY AGAIN (Enter, same as main's restart), SKILL TREE (K).
## main.gd still owns K / M / 1 / 2 / Enter in _unhandled_input; the focused PLAY AGAIN button takes Enter.

const RunStatsScr := preload("res://scripts/ui/run_stats.gd")

signal back_to_menu_pressed
signal play_again_pressed
signal skill_tree_pressed

var main: Node
var stats: Dictionary = {}
var dry_run: bool = false ## tests: buttons emit their signals but don't change scene / reload
var tiles: Dictionary = {} ## stat key -> value Label (tests)
var rows: Dictionary = {} ## detail key -> value Label (tests)
var back_button: Button
var again_button: Button
var skills_button: Button
var _root: Control
var _title: Label
var _sub: Label
var _foot: Label
var _tiles_box: GridContainer
var _rows_box: GridContainer

const TILE_KEYS := [["kills", "KILLS"], ["damage_dealt", "DAMAGE DEALT"], ["rounds", "ROUNDS SURVIVED"],
	["points_earned", "POINTS EARNED"], ["gravemarks", "GRAVEMARKS"], ["xp_earned", "XP EARNED"]]
const ROW_KEYS := [["accuracy", "ACCURACY"], ["headshots", "HEADSHOTS"], ["precision_kills", "PRECISION KILLS"],
	["time_s", "TIME SURVIVED"], ["damage_taken", "DAMAGE TAKEN"], ["healed", "HEALED"], ["boss_kills", "BOSS KILLS"],
	["melee_kills", "MELEE KILLS"], ["grenades", "GRENADES THROWN"], ["cards_picked", "FIELD CARDS PICKED"],
	["doors_opened", "DOORS OPENED"], ["best_round", "BEST ROUND"]]


func _init() -> void:
	layer = 8 # above the HUD, below MenuBase menus (10) and the pause menu (11)
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "GameOverScreen"


func _ready() -> void:
	_build()
	if not stats.is_empty():
		show_stats(stats)


func _build() -> void:
	if _root != null:
		return
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.02, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	var card := PanelContainer.new()
	card.name = "StatsCard"
	card.custom_minimum_size = Vector2(860, 0)
	var cst := UIStyle.cut_box(Color(0.07, 0.06, 0.05, 0.97), UIStyle.BLOOD.darkened(0.15), 4, 18)
	cst.set_content_margin_all(22)
	card.add_theme_stylebox_override("panel", cst)
	center.add_child(card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	card.add_child(col)

	_title = UIStyle.label("YOU DIED", 44, UIStyle.BAD, true, 4)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_title)
	_sub = UIStyle.label("", 15, UIStyle.BONE_DIM)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_sub)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	col.add_child(line)

	_tiles_box = GridContainer.new()
	_tiles_box.name = "Tiles"
	_tiles_box.columns = 3
	_tiles_box.add_theme_constant_override("h_separation", 10)
	_tiles_box.add_theme_constant_override("v_separation", 10)
	col.add_child(_tiles_box)
	for kv in TILE_KEYS:
		_tiles_box.add_child(_tile(kv[0], kv[1]))

	_rows_box = GridContainer.new()
	_rows_box.name = "Details"
	_rows_box.columns = 4
	_rows_box.add_theme_constant_override("h_separation", 18)
	_rows_box.add_theme_constant_override("v_separation", 4)
	col.add_child(_rows_box)
	for kv in ROW_KEYS:
		var k := UIStyle.label(kv[1], 13, UIStyle.BONE_DIM)
		k.custom_minimum_size = Vector2(150, 0)
		_rows_box.add_child(k)
		var v := UIStyle.label("-", 15, UIStyle.BONE)
		v.custom_minimum_size = Vector2(230, 0)
		v.name = "Row_" + kv[0]
		_rows_box.add_child(v)
		rows[kv[0]] = v

	_foot = UIStyle.label("", 13, UIStyle.BONE_DIM)
	_foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_foot)

	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	btns.add_theme_constant_override("separation", 14)
	col.add_child(btns)
	skills_button = _btn("SKILL TREE", "K", _on_skills)
	again_button = _btn("PLAY AGAIN", "ENTER", _on_again)
	back_button = _btn("BACK TO MENU", "", _on_back)
	UIStyle.style_primary_button(back_button)
	back_button.add_theme_font_size_override("font_size", 19)
	for b in [skills_button, again_button, back_button]:
		btns.add_child(b)
	skills_button.focus_neighbor_right = again_button.get_path()
	back_button.focus_neighbor_left = again_button.get_path()


func _tile(key: String, caption: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "Tile_" + key
	p.custom_minimum_size = Vector2(266, 84)
	p.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(UIStyle.INK, 0.92), UIStyle.BONE_DIM.darkened(0.3), 2, 10))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	p.add_child(v)
	var cap := UIStyle.label(caption, 12, UIStyle.BONE_DIM)
	v.add_child(cap)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	v.add_child(h)
	if key == "gravemarks":
		h.add_child(UIStyle.gravemark_icon(30))
	var val := UIStyle.label("0", 34, UIStyle.BONE, true)
	val.name = "Value"
	h.add_child(val)
	tiles[key] = val
	return p


func _btn(text: String, key: String, cb: Callable) -> Button:
	var b := Button.new()
	b.name = text.replace(" ", "")
	b.text = text + ("   [%s]" % key if key != "" else "")
	b.custom_minimum_size = Vector2(230, 48)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 17)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
	b.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.BONE, 3, 8))
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.pressed.connect(cb)
	return b


static func fmt_int(n: int) -> String:
	var t := str(absi(n))
	var out := ""
	while t.length() > 3:
		out = "," + t.substr(t.length() - 3) + out
		t = t.substr(0, t.length() - 3)
	return ("-" if n < 0 else "") + t + out


## Display text for one stat key (shared by tiles and rows; tests read it).
static func value_text(key: String, st: Dictionary) -> String:
	match key:
		"accuracy":
			var a := float(st.get("accuracy", -1.0))
			if a < 0.0:
				return "-"
			return "%d%%  (%d / %d)" % [roundi(a * 100.0), int(st.get("shots_fired", 0)) - int(st.get("shots_missed", 0)),
				int(st.get("shots_fired", 0))]
		"time_s":
			return RunStatsScr.format_time(float(st.get("time_s", 0.0)))
		"damage_dealt":
			return fmt_int(roundi(float(st.get("damage_dealt", 0.0))))
		"gravemarks", "xp_earned":
			return "+" + fmt_int(int(st.get(key, 0)))
		"headshots":
			var hits := int(st.get("hits", 0))
			var hs := int(st.get("headshots", 0))
			return fmt_int(hs) if hits <= 0 else "%s  (%d%% of hits)" % [fmt_int(hs), roundi(100.0 * hs / float(hits))]
	return fmt_int(int(st.get(key, 0)))


func show_stats(st: Dictionary) -> void:
	stats = st
	if _root == null:
		return
	for kv in TILE_KEYS:
		tiles[kv[0]].text = value_text(kv[0], st)
	for kv in ROW_KEYS:
		rows[kv[0]].text = value_text(kv[0], st)
	var rounds := int(st.get("rounds", 0))
	_title.text = "YOU DIED"
	var map_name := ""
	if main and main.get("map_id") != null:
		map_name = str(MapRegistry.get_info(str(main.get("map_id"))).get("display_name", main.get("map_id"))).to_upper()
	_sub.text = "GRAVECREW  //  %sROUND %d  //  LEVEL %d" % [(map_name + "  //  ") if map_name != "" else "", rounds,
		int(st.get("level", 0))]
	refresh_footer()
	visible = true
	if again_button.is_inside_tree():
		again_button.grab_focus.call_deferred()


## Class-for-next-game line + skill points (main's 1 / 2 keys and the skill tree change these).
func refresh_footer() -> void:
	if _foot == null:
		return
	var prog := get_node_or_null("/root/Progress") if is_inside_tree() else null
	var parts: Array = []
	if prog:
		if prog.has_method("load_selected_class"):
			var c = prog.load_selected_class()
			if c:
				parts.append("Class for next game: %s  (1 = Soldier, 2 = Scout)" % str(c.get("display_name")))
		if prog.has_method("skill_points_available"):
			parts.append("%d skill point%s to spend" % [prog.skill_points_available(),
				"" if prog.skill_points_available() == 1 else "s"])
	_foot.text = "   |   ".join(parts)


func _on_back() -> void:
	back_to_menu_pressed.emit()
	if dry_run:
		return
	visible = false
	if main and main.has_method("return_to_home"):
		main.return_to_home()
	else:
		get_tree().paused = false
		get_tree().change_scene_to_file("res://scenes/ui/home.tscn")


func _on_again() -> void:
	play_again_pressed.emit()
	if dry_run:
		return
	var net := get_node_or_null("/root/Net")
	if net and net.is_networked(): # same as main.gd's Enter: the leader takes everyone back to the lobby
		net.return_to_lobby()
	else:
		get_tree().paused = false
		get_tree().reload_current_scene()


func _on_skills() -> void:
	skill_tree_pressed.emit()
	if dry_run:
		return
	var sm = main.get("skill_menu") if main else null
	if sm and is_instance_valid(sm):
		var hud = main.get("hud")
		if hud:
			hud.hide_message()
		sm.open()
