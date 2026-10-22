extends MenuBase
## Map picker (Gooey). Lists MapRegistry.list() with name, a short description and a top-down preview (image if the
## map ships one, else a schematic of walls, doors and key features from Mapz's data/map_previews/<id>.json,
## format mapz_preview v1, docs/map_contract.md); marks the current map. No door names / costs (playtest 2026-10-22 #4).
## Loading calls main.restart_with_map(id) (MapRegistry.select + scene reload).
## Opened with M (action "map_next") only before round 1 or at game over. main.gd instances this as map_picker
## and calls open() on M; the menu also accepts M while closed as a belt-and-braces path.
## Keys: up/down or d-pad choose, Enter / A load, M / Esc / B close.

const PREVIEW_PATHS := ["res://maps/%s/preview.png", "res://maps/%s/preview.jpg", "res://assets/ui/maps/%s.png"]
const HARD_NOTE := "Hard: tougher zombies, better rare-currency drops."
const DIFF_ORDER := {"easy": 0, "medium": 1, "hard": 2}


var main: Node ## the match scene (has current_round / _game_over / restart_with_map)
var _ids: Array = []
var _rows: Dictionary = {} ## id -> Button
var _sel: String = ""
var _list: VBoxContainer
var _preview: _Schematic
var _preview_img: TextureRect
var _name: Label
var _cur_tag: PanelContainer
var _desc: Label
var _play_btn: Button
var _gate_label: Label
var restart_calls: Array = [] ## ids passed to restart (tests read this; set dry_run to skip the reload)
var dry_run: bool = false
## Home title screen: always openable, sorts Easy→Hard, difficulty badges, emits map_chosen.
var home_mode: bool = false
var pick_label: String = "" ## home_mode button text, e.g. "PICK %s" (co-op lobby); "" = "DEPLOY ON %s"
var gate_text: String = "" ## home_mode header, "" = "CHOOSE YOUR DROP"
signal map_chosen(map_id: String)
var _diff_note: Label


func _init() -> void:
	super._init()
	toggle_action = "map_next"


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(980, 540)
	_build()
	if main == null:
		main = get_parent()
	if main and main.has_method("_on_menu_closed"):
		closed.connect(main._on_menu_closed)


## M is only live before round 1 and at game over (same gate as main's map cycling).
## Home mode (title Play → map select) always allows open.
func can_open() -> bool:
	if home_mode:
		return true
	if main == null or not is_instance_valid(main):
		return false
	return int(main.get("current_round")) == 0 or bool(main.get("_game_over"))


func open() -> void:
	if not can_open():
		return
	var hud = main.get("hud") if main else null
	if hud:
		hud.hide_message()
		hud.visible = false
	super.open()


# ---------------------------------------------------------------- build

func _build() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	content.add_child(head)
	head.add_child(UIStyle.label("SELECT MAP", 30, UIStyle.BONE, true))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_gate_label = UIStyle.label("", 12, UIStyle.BONE_DIM)
	_gate_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_gate_label)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(body)
	_list = VBoxContainer.new()
	_list.custom_minimum_size.x = 300
	_list.add_theme_constant_override("separation", 6)
	body.add_child(_list)
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_theme_constant_override("separation", 6)
	body.add_child(detail)
	var pv := PanelContainer.new()
	var ps := UIStyle.cut_box(Color(0.03, 0.035, 0.03, 0.95), Color(UIStyle.BONE_DIM, 0.5), 2, 12)
	ps.set_content_margin_all(4)
	pv.add_theme_stylebox_override("panel", ps)
	pv.custom_minimum_size = Vector2(0, 300)
	pv.size_flags_vertical = Control.SIZE_EXPAND_FILL # the preview takes the spare height, not text
	detail.add_child(pv)
	_preview = _Schematic.new()
	_preview.clip_contents = true
	pv.add_child(_preview)
	_preview_img = TextureRect.new()
	_preview_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_preview_img.visible = false
	pv.add_child(_preview_img)
	var nh := HBoxContainer.new()
	nh.add_theme_constant_override("separation", 10)
	detail.add_child(nh)
	_name = UIStyle.label("", 24, UIStyle.BONE, true)
	nh.add_child(_name)
	_cur_tag = PanelContainer.new()
	var cs := UIStyle.cut_box(UIStyle.OLIVE, Color(0, 0, 0, 0), 0, 5)
	cs.set_content_margin_all(2)
	cs.content_margin_left = 8
	cs.content_margin_right = 8
	_cur_tag.add_theme_stylebox_override("panel", cs)
	_cur_tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_cur_tag.add_child(UIStyle.label("CURRENT", 11, UIStyle.INK, true))
	nh.add_child(_cur_tag)
	_desc = UIStyle.label("", 13, UIStyle.BONE_DIM)
	_desc.name = "MapDesc"
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.max_lines_visible = 2 # fixed height: a long description can't push the layout
	_desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_desc.custom_minimum_size = Vector2(200, 36)
	_desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail.add_child(_desc)
	_play_btn = Button.new()
	_play_btn.focus_mode = Control.FOCUS_NONE
	_play_btn.custom_minimum_size = Vector2(0, 40)
	_play_btn.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	_play_btn.add_theme_font_size_override("font_size", 16)
	_play_btn.add_theme_color_override("font_color", UIStyle.INK)
	_play_btn.add_theme_color_override("font_hover_color", UIStyle.INK)
	var bs := UIStyle.cut_box(UIStyle.BONE, Color(0, 0, 0, 0), 0, 8)
	_play_btn.add_theme_stylebox_override("normal", bs)
	var bh := UIStyle.cut_box(UIStyle.BONE.lightened(0.2), UIStyle.RUST, 2, 8)
	_play_btn.add_theme_stylebox_override("hover", bh)
	_play_btn.add_theme_stylebox_override("pressed", bh)
	_play_btn.pressed.connect(func(): load_map(_sel))
	_play_btn.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	detail.add_child(_play_btn)
	_diff_note = UIStyle.label(HARD_NOTE, 12, UIStyle.BONE_DIM)
	_diff_note.name = "DiffNote"
	_diff_note.visible = false
	_diff_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_diff_note.custom_minimum_size.x = 200
	detail.add_child(_diff_note)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	content.add_child(foot)
	for pair in [["↑ ↓", "D-PAD", "CHOOSE"], ["ENTER", "A", "LOAD + RESTART"], ["M", "B", "CLOSE"]]:
		foot.add_child(UIStyle.key_cap(pair[0], 11))
		foot.add_child(UIStyle.label("/", 11, UIStyle.BONE_DIM))
		foot.add_child(UIStyle.key_cap(pair[1], 11))
		foot.add_child(UIStyle.label(pair[2] + "    ", 11, UIStyle.BONE_DIM))
	var fs := Control.new()
	fs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fs)
	foot.add_child(UIStyle.label("Loading a map restarts the match // skill points and XP carry over", 11, UIStyle.BONE_DIM))


func refresh() -> void:
	for c in _list.get_children():
		c.queue_free()
	_rows.clear()
	_ids = sorted_map_ids()
	var cur := MapRegistry.current_id()
	_list.add_child(UIStyle.label("MAPS // %d" % _ids.size(), 16, UIStyle.RUST, true))
	for id in _ids:
		var b := _make_row(id, id == cur)
		_list.add_child(b)
		_rows[id] = b
	var keys := _rows.keys()
	for i in keys.size():
		var b: Button = _rows[keys[i]]
		b.focus_neighbor_top = b.get_path_to(_rows[keys[(i - 1 + keys.size()) % keys.size()]])
		b.focus_neighbor_bottom = b.get_path_to(_rows[keys[(i + 1) % keys.size()]])
	if home_mode:
		_gate_label.text = gate_text if gate_text != "" else "CHOOSE YOUR DROP"
		_play_btn.text = "DEPLOY"
	elif main:
		_gate_label.text = "GAME OVER // PICK THE NEXT MAP" if bool(main.get("_game_over")) else "BEFORE ROUND 1"
	else:
		_gate_label.text = ""
	select_row(cur if _rows.has(cur) else (_ids[0] if not _ids.is_empty() else ""))
	if _rows.has(_sel):
		(_rows[_sel] as Button).call_deferred("grab_focus")


func _make_row(id: String, current: bool) -> Button:
	var info: Dictionary = MapRegistry.get_info(id)
	var valid := MapRegistry.is_valid(id)
	var b := Button.new()
	b.custom_minimum_size = Vector2(300, 46)
	b.focus_mode = Control.FOCUS_ALL
	b.disabled = not valid
	var c := UIStyle.OLIVE if current else UIStyle.BONE_DIM
	var n := UIStyle.cut_box(Color(UIStyle.INK, 0.85), Color(c, 0.6), 2, 8)
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("disabled", n)
	var f := UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST.lightened(0.15), 3, 8)
	b.add_theme_stylebox_override("focus", f)
	b.add_theme_stylebox_override("hover", f)
	b.add_theme_stylebox_override("pressed", f)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 12
	v.offset_right = -10
	v.offset_top = 6
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(v)
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(h)
	var nl := UIStyle.label(str(info.get("display_name", id)).to_upper(), 16, UIStyle.BONE if valid else UIStyle.BONE_DIM, true)
	nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(nl)
	h.add_child(difficulty_badge(map_difficulty(id)))
	if current:
		h.add_child(UIStyle.label("CURRENT", 10, UIStyle.OLIVE.lightened(0.35), true))
	if not valid:
		v.add_child(UIStyle.label("MISSING SCENE", 11, UIStyle.BAD))
	b.focus_entered.connect(select_row.bind(id))
	b.mouse_entered.connect(func(): if valid: b.grab_focus())
	b.pressed.connect(load_map.bind(id))
	return b


func select_row(id: String) -> void:
	if id == "":
		return
	if _sel != id and visible and _sel != "":
		_ui_snd("ui_hover")
	_sel = id
	var info: Dictionary = MapRegistry.get_info(id)
	var cur := id == MapRegistry.current_id()
	_name.text = str(info.get("display_name", id)).to_upper()
	_cur_tag.visible = cur
	_desc.text = str(info.get("description", ""))
	var img := _preview_texture(id, info)
	_preview_img.visible = img != null
	_preview_img.texture = img
	_preview.visible = img == null
	_preview.pv = map_preview(id)
	_preview.title = _name.text
	_preview.queue_redraw()
	if home_mode:
		_play_btn.text = (pick_label if pick_label != "" else "DEPLOY ON %s") % _name.text
	else:
		_play_btn.text = ("RESTART ON %s" if cur else "LOAD %s") % _name.text
	_play_btn.disabled = not MapRegistry.is_valid(id)
	if _diff_note:
		_diff_note.visible = map_difficulty(id) == "hard"


## Selects `id` in MapRegistry and restarts the match on it through main.restart_with_map.
## Home mode: select + emit map_chosen (home starts the match / change_scene).
func load_map(id: String) -> bool:
	if id == "" or not MapRegistry.is_valid(id) or not can_open():
		return false
	restart_calls.append(id)
	_ui_snd("ui_equip")
	MapRegistry.select(id)
	map_chosen.emit(id)
	if dry_run:
		return true
	visible = false
	if home_mode:
		# Host (home_menu) listens to map_chosen → start_match / change_scene.
		return true
	return bool(main.restart_with_map(id))


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		if event.is_action_pressed("map_next") and can_open():
			get_viewport().set_input_as_handled() # main's own M handler would cycle + reload instead
			open()
		return
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		load_map(_sel)
	elif (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B) \
			or (event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE):
		get_viewport().set_input_as_handled()
		close()
	else:
		super._unhandled_input(event)


# ---------------------------------------------------------------- map preview image

func _preview_texture(id: String, info: Dictionary) -> Texture2D:
	var paths: Array = []
	if str(info.get("preview", "")) != "":
		paths.append(str(info.preview))
	for p in PREVIEW_PATHS:
		paths.append(p % id)
	for p in paths:
		if ResourceLoader.exists(p):
			return load(p) as Texture2D
	return null


# ---------------------------------------------------------------- difficulty (Pass 5 home / map select)

## maps.json difficulty field; missing/unknown → "medium" (Pass 5 UI default).
static func map_difficulty(id: String) -> String:
	var d := str(MapRegistry.get_info(id).get("difficulty", "")).strip_edges().to_lower()
	if d in ["easy", "medium", "hard"]:
		return d
	return "medium"


static func difficulty_color(diff: String) -> Color:
	match diff:
		"easy":
			return UIStyle.GOOD
		"hard":
			return UIStyle.BLOOD.lightened(0.15)
		_:
			return UIStyle.RUST.lightened(0.35) # amber / medium


static func difficulty_badge(diff: String) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "DiffBadge"
	p.set_meta("difficulty", diff)
	var c := difficulty_color(diff)
	var st := UIStyle.cut_box(c.darkened(0.35), c, 2, 5)
	st.set_content_margin_all(2)
	st.content_margin_left = 6
	st.content_margin_right = 6
	p.add_theme_stylebox_override("panel", st)
	p.add_child(UIStyle.label(diff.to_upper(), 10, UIStyle.INK if diff != "hard" else UIStyle.BONE, true))
	return p


## Easy → Hard, stable by display name within a tier.
static func sorted_map_ids() -> Array:
	var rows: Array = []
	for m in MapRegistry.list():
		var id := str(m.get("id", ""))
		if id == "":
			continue
		rows.append({"id": id, "diff": map_difficulty(id), "name": str(m.get("display_name", id))})
	rows.sort_custom(func(a, b):
		var oa: int = int(DIFF_ORDER.get(a.diff, 1))
		var ob: int = int(DIFF_ORDER.get(b.diff, 1))
		if oa != ob:
			return oa < ob
		return str(a.name) < str(b.name))
	return rows.map(func(r): return str(r.id))


const PREVIEW_DIR := "res://data/map_previews/%s.json"
const PREVIEW_FORMAT := "mapz_preview v1"
const FEATURE_TYPES := ["start", "boss_arena", "perk", "mystery_box", "power_weapon", "chest"]

static var _preview_cache: Dictionary = {}


## Mapz preview data for `id`, normalised: {ok, bounds: Rect2, walls: [PackedVector2Array], doors: [[a, b]],
## features: [{type, pos: Vector2, radius}]}. ok = false (empty arrays) when the file is missing or not v1.
static func map_preview(id: String) -> Dictionary:
	if _preview_cache.has(id):
		return _preview_cache[id]
	var out := {"ok": false, "bounds": Rect2(), "walls": [], "doors": [], "features": []}
	var path := PREVIEW_DIR % id
	if id != "" and FileAccess.file_exists(path):
		var d = JSON.parse_string(FileAccess.get_file_as_string(path))
		if d is Dictionary and str(d.get("format", "")) == PREVIEW_FORMAT:
			var b: Array = d.get("bounds", [])
			if b.size() == 4:
				out.bounds = Rect2(float(b[0]), float(b[1]), float(b[2]), float(b[3]))
			for w in d.get("walls", []):
				var poly := PackedVector2Array()
				for p in w:
					poly.append(Vector2(float(p[0]), float(p[1])))
				if poly.size() >= 3:
					out.walls.append(poly)
			for dr in d.get("doors", []):
				if dr is Dictionary and dr.has("a") and dr.has("b"):
					out.doors.append([Vector2(float(dr.a[0]), float(dr.a[1])), Vector2(float(dr.b[0]), float(dr.b[1]))])
			for f in d.get("features", []):
				if f is Dictionary and str(f.get("type", "")) in FEATURE_TYPES and f.get("pos", []).size() == 2:
					out.features.append({"type": str(f.type), "pos": Vector2(float(f.pos[0]), float(f.pos[1])), "radius": float(f.get("radius", 0.0))})
			out.ok = true
	_preview_cache[id] = out
	return out


# ---------------------------------------------------------------- schematic preview

class _Schematic extends Control:
	const FEATURE_LOOK := { ## type -> [colour, legend label]
		"start": [Color(0.89, 0.85, 0.74), "START"],
		"boss_arena": [Color(0.78, 0.22, 0.18), "BOSS"],
		"perk": [Color(0.37, 0.61, 0.58), "PERK"],
		"mystery_box": [Color(0.72, 0.54, 0.18), "BOX"],
		"power_weapon": [Color(0.56, 0.36, 0.74), "POWER WPN"],
		"chest": [Color(0.55, 0.62, 0.70), "CHEST"],
	}
	var pv: Dictionary = {} ## map_preview(id)
	var title: String = ""
	var wall_count: int = 0 ## walls drawn last frame (tests)
	var door_count: int = 0
	var feature_count: int = 0
	var legend_types: Array = [] ## feature types in the legend last frame (tests)

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.05, 0.06, 0.05))
		var grid := Color(0.37, 0.61, 0.58, 0.07)
		var x := 0.0
		while x < size.x:
			draw_line(Vector2(x, 0), Vector2(x, size.y), grid, 1.0)
			x += 20.0
		var y := 0.0
		while y < size.y:
			draw_line(Vector2(0, y), Vector2(size.x, y), grid, 1.0)
			y += 20.0
		wall_count = 0
		door_count = 0
		feature_count = 0
		legend_types = []
		var f: Font = UIStyle.body_bold()
		var st: Font = UIStyle.FONT_STENCIL
		var b: Rect2 = pv.get("bounds", Rect2())
		if not bool(pv.get("ok", false)) or b.size.x <= 0.0 or b.size.y <= 0.0:
			var t := "NO PREVIEW"
			var ts := st.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 30)
			draw_string(st, (size - ts) * 0.5 + Vector2(0, 20), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color(UIStyle.BONE_DIM, 0.35))
			return
		var legend_h := 22.0
		var pad := 14.0
		var area := Vector2(size.x - pad * 2, size.y - pad * 2 - legend_h)
		var sc := minf(area.x / b.size.x, area.y / b.size.y)
		var off := Vector2(pad, pad) + (area - b.size * sc) * 0.5
		var to := func(p: Vector2) -> Vector2: return off + (p - b.position) * sc
		draw_rect(Rect2(off, b.size * sc), Color(0.37, 0.61, 0.58, 0.05))
		for w in pv.walls:
			var q := PackedVector2Array()
			for p in w:
				q.append(to.call(p))
			draw_colored_polygon(q, Color(UIStyle.BONE, 0.62))
			wall_count += 1
		for d in pv.doors:
			var a: Vector2 = to.call(d[0])
			var c: Vector2 = to.call(d[1])
			draw_line(a, c, Color(UIStyle.INK, 0.9), 6.0)
			draw_line(a, c, UIStyle.RUST.lightened(0.1), 3.5)
			door_count += 1
		var seen := {}
		for ft in pv.features:
			var p: Vector2 = to.call(ft.pos)
			var col: Color = FEATURE_LOOK.get(ft.type, [UIStyle.BONE])[0]
			seen[ft.type] = true
			feature_count += 1
			match str(ft.type):
				"start":
					draw_colored_polygon(PackedVector2Array([p + Vector2(0, -8), p + Vector2(7, 6), p + Vector2(-7, 6)]), col)
				"boss_arena":
					var rr := maxf(float(ft.radius) * sc, 8.0)
					draw_circle(p, rr, Color(col, 0.14))
					draw_arc(p, rr, 0.0, TAU, 40, Color(col, 0.8), 2.0)
					draw_circle(p, 3.0, col)
				"mystery_box":
					draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)), col)
					draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)), UIStyle.INK, false, 1.0)
				"power_weapon":
					draw_colored_polygon(PackedVector2Array([p + Vector2(0, -6), p + Vector2(6, 0), p + Vector2(0, 6), p + Vector2(-6, 0)]), col)
				_:
					draw_circle(p, 4.5, Color(UIStyle.INK, 0.9))
					draw_circle(p, 3.5, col)
		# legend: walls, doors, then the feature types this map has (only what fits)
		var lx := 10.0
		var ly := size.y - 9.0
		var items: Array = [["WALL", Color(UIStyle.BONE, 0.62), "wall"]]
		if not pv.doors.is_empty():
			items.append(["DOOR", UIStyle.RUST.lightened(0.1), "door"])
		for t2 in FEATURE_TYPES_ORDER:
			if seen.has(t2):
				items.append([FEATURE_LOOK[t2][1], FEATURE_LOOK[t2][0], t2])
		for it in items:
			var lw := f.get_string_size(str(it[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			if lx + 14 + lw > size.x - 8:
				break
			draw_rect(Rect2(lx, ly - 8, 9, 9), it[1])
			draw_string(f, Vector2(lx + 13, ly), str(it[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(UIStyle.BONE_DIM, 0.85))
			if not (str(it[2]) in ["wall", "door"]):
				legend_types.append(str(it[2]))
			lx += 13 + lw + 14

	const FEATURE_TYPES_ORDER := ["start", "boss_arena", "perk", "mystery_box", "power_weapon", "chest"]
