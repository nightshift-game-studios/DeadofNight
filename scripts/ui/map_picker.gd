extends MenuBase
## Map picker (Gooey). Lists MapRegistry.list() with name, description, a preview (image if the map ships one,
## else a schematic drawn from the map scene's markers) and a door / area hint; marks the current map.
## Loading calls main.restart_with_map(id) (MapRegistry.select + scene reload).
## Opened with M (action "map_next") only before round 1 or at game over. main.gd instances this as map_picker
## and calls open() on M; the menu also accepts M while closed as a belt-and-braces path.
## Keys: up/down or d-pad choose, Enter / A load, M / Esc / B close.

const PREVIEW_PATHS := ["res://maps/%s/preview.png", "res://maps/%s/preview.jpg", "res://assets/ui/maps/%s.png"]
const HARD_NOTE := "Hard: tougher zombies, better rare-currency drops."
const DIFF_ORDER := {"easy": 0, "medium": 1, "hard": 2}

static var _meta_cache: Dictionary = {}

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
var _hint: VBoxContainer
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
	pv.custom_minimum_size = Vector2(0, 250)
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
	_desc = UIStyle.label("", 14, UIStyle.BONE)
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.custom_minimum_size.x = 600
	detail.add_child(_desc)
	_hint = VBoxContainer.new()
	_hint.add_theme_constant_override("separation", 2)
	detail.add_child(_hint)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	detail.add_child(fill)
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
	_diff_note.custom_minimum_size.x = 600
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
	b.custom_minimum_size = Vector2(300, 58)
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
	var m := map_meta(id)
	var sub := "MISSING SCENE" if not valid else _short_hint(m)
	v.add_child(UIStyle.label(sub, 11, UIStyle.BONE_DIM))
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
	var m := map_meta(id)
	var img := _preview_texture(id, info)
	_preview_img.visible = img != null
	_preview_img.texture = img
	_preview.visible = img == null
	_preview.meta = m
	_preview.walls = map_walls(id)
	_preview.title = _name.text
	_preview.queue_redraw()
	for c in _hint.get_children():
		c.queue_free()
	for line in hint_lines(m):
		var l := UIStyle.label(line[0], 12, line[1])
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 600
		_hint.add_child(l)
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


# ---------------------------------------------------------------- map metadata (read from the scene file, no load)

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


## {doors: [{name, cost, opens, pos}], areas: {area -> [Vector2]}, start, bounds: Rect2, spawn: Vector2, open: bool}

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


## Parsed from the .tscn text (doors = nodes with opens_areas; cost defaults to 750 when omitted), cached.
static func map_meta(id: String) -> Dictionary:
	if _meta_cache.has(id):
		return _meta_cache[id]
	var out := {"doors": [], "areas": {}, "start": "start", "bounds": Rect2(), "spawn": Vector2.ZERO, "open": true, "has_spawn": false}
	var scene_path := str(MapRegistry.get_info(id).get("scene", ""))
	if scene_path != "" and FileAccess.file_exists(scene_path):
		var txt := FileAccess.get_file_as_string(scene_path)
		var re_t := RegEx.create_from_string("transform = Transform3D\\(([^)]*)\\)")
		var re_cost := RegEx.create_from_string("\\ncost = (\\d+)")
		var re_open := RegEx.create_from_string("opens_areas = PackedStringArray\\(([^)]*)\\)")
		var re_name := RegEx.create_from_string("prompt_name = \"([^\"]*)\"")
		var re_area := RegEx.create_from_string("metadata/area = &?\"([^\"]*)\"")
		var re_start := RegEx.create_from_string("\\nstart_area = &?\"([^\"]*)\"")
		var re_bounds := RegEx.create_from_string("metadata/bounds = AABB\\(([^)]*)\\)")
		var ms := re_start.search(txt)
		if ms:
			out.start = ms.get_string(1)
		var mb := re_bounds.search(txt)
		if mb:
			var b := mb.get_string(1).split(",")
			if b.size() == 6:
				out.bounds = Rect2(float(b[0]), float(b[2]), float(b[3]), float(b[5]))
		for block in txt.split("\n[node "):
			var mt := re_t.search(block)
			var pos := Vector2.ZERO
			if mt:
				var n := mt.get_string(1).split(",")
				if n.size() == 12:
					pos = Vector2(float(n[9]), float(n[11]))
			var mo := re_open.search(block)
			var mc := re_cost.search(block)
			if mo:
				var opens := Array(mo.get_string(1).replace("\"", "").replace(" ", "").split(",", false))
				var mn := re_name.search(block)
				var cost := int(mc.get_string(1)) if mc else 750
				out.doors.append({"name": mn.get_string(1) if mn else "Door", "cost": cost, "opens": opens, "pos": pos})
				continue
			var ma := re_area.search(block)
			if ma and mt:
				var a := ma.get_string(1)
				if not out.areas.has(a):
					out.areas[a] = []
				out.areas[a].append(pos)
			if block.begins_with("name=\"PlayerSpawn\"") and mt:
				out.spawn = pos
				out.has_spawn = true
		out.open = out.doors.is_empty()
	_meta_cache[id] = out
	return out


## Top-down wall / floor footprints for the schematic (playtest #26: the preview drew only markers, never walls).
## Parsed from the map scene's text (no instancing, nothing loaded): every CollisionShape3D with a BoxShape3D under a
## StaticBody3D, with the parent chain's transforms composed. Clip / NavCarves / Doors / Decor / Props are skipped
## (invisible clip caps, nav obstacles, doors drawn separately, dressing). The arena (scene "") reads main.tscn's
## NavigationRegion3D only. Returns [{poly: PackedVector2Array (x, z), kind: "floor" | "wall", top: float, h: float}].
static var _walls_cache: Dictionary = {}
const WALL_SKIP_ROOTS := ["Clip", "Decor", "Props", "Dressing", "Merged", "NightKit", "Lights", "Occluders"]

static func map_walls(id: String) -> Array:
	if _walls_cache.has(id):
		return _walls_cache[id]
	var scene_path := str(MapRegistry.get_info(id).get("scene", ""))
	var only_prefix := ""
	if scene_path == "":
		scene_path = "res://scenes/main.tscn"
		only_prefix = "NavigationRegion3D"
	var out: Array = []
	if FileAccess.file_exists(scene_path):
		out = walls_from_text(FileAccess.get_file_as_string(scene_path), only_prefix)
	_walls_cache[id] = out
	return out


static func _parse_tf(n: PackedStringArray) -> Transform3D:
	return Transform3D(Vector3(float(n[0]), float(n[1]), float(n[2])), Vector3(float(n[3]), float(n[4]), float(n[5])),
		Vector3(float(n[6]), float(n[7]), float(n[8])), Vector3(float(n[9]), float(n[10]), float(n[11])))


static func walls_from_text(txt: String, only_prefix: String = "") -> Array:
	var boxes := {} # sub_resource id -> Vector3 size
	var re_sub := RegEx.create_from_string("\\[sub_resource type=\"BoxShape3D\" id=\"([^\"]+)\"\\]\\s*\\nsize = Vector3\\(([^)]*)\\)")
	for m in re_sub.search_all(txt):
		var v := m.get_string(2).split(",")
		if v.size() == 3:
			boxes[m.get_string(1)] = Vector3(float(v[0]), float(v[1]), float(v[2]))
	var re_head := RegEx.create_from_string("^name=\"([^\"]*)\"(?: type=\"([^\"]*)\")?(?: parent=\"([^\"]*)\")?")
	var re_t := RegEx.create_from_string("\ntransform = Transform3D\\(([^)]*)\\)")
	var re_shape := RegEx.create_from_string("\nshape = SubResource\\(\"([^\"]+)\"\\)")
	var local := {} # path -> Transform3D
	var types := {} # path -> type
	var shapes: Array = [] # [path, parent, box id]
	var blocks := txt.split("\n[node ")
	for bi in range(1, blocks.size()):
		var block: String = blocks[bi]
		var mh := re_head.search(block)
		if mh == null:
			continue
		var nm := mh.get_string(1)
		var parent := mh.get_string(3)
		var has_parent := block.contains(" parent=\"")
		var path := "." if not has_parent else (nm if parent == "." else parent + "/" + nm)
		var tf := Transform3D.IDENTITY
		var head_end := block.find("\n[")
		var body := block if head_end < 0 else block.substr(0, head_end)
		var mt := re_t.search(body)
		if mt:
			var n := mt.get_string(1).split(",")
			if n.size() == 12:
				tf = _parse_tf(n)
		local[path] = tf
		types[path] = mh.get_string(2)
		if mh.get_string(2) == "CollisionShape3D":
			var ms := re_shape.search(body)
			if ms and boxes.has(ms.get_string(1)):
				shapes.append([path, parent, ms.get_string(1)])
	var out: Array = []
	for sh in shapes:
		var path: String = sh[0]
		var parent: String = sh[1]
		var root_name := path.split("/")[0]
		if root_name in WALL_SKIP_ROOTS or path.contains("/NavCarves/") or path.contains("/Doors/"):
			continue
		if only_prefix != "" and not path.begins_with(only_prefix + "/"):
			continue
		if str(types.get(parent, "")) != "StaticBody3D":
			continue
		# compose parent chain (skip shapes whose ancestors are not in this file, e.g. inside instanced scenes)
		var g: Transform3D = local[path]
		var cur := parent
		var ok := true
		while cur != "." and cur != "":
			if not local.has(cur):
				ok = false
				break
			g = local[cur] * g
			var cut := cur.rfind("/")
			cur = "." if cut < 0 else cur.substr(0, cut)
		if not ok:
			continue
		var half: Vector3 = boxes[sh[2]] * 0.5
		var poly := PackedVector2Array()
		var ys: Array = []
		for c in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(1, 0, 1), Vector3(-1, 0, 1)]:
			var w: Vector3 = g * (c * half)
			poly.append(Vector2(w.x, w.z))
		for sy in [-1.0, 1.0]:
			ys.append((g * Vector3(0, sy * half.y, 0)).y)
		var axis_h := (g.basis * Vector3(0, half.y * 2.0, 0)).length()
		var top: float = maxf(ys[0], ys[1])
		var kind := "floor" if axis_h <= 1.2 else "wall" # slabs / decks vs walls, blocks, tanks
		out.append({"poly": poly, "kind": kind, "top": top, "h": axis_h})
	return out


static func walls_bounds(walls: Array) -> Rect2:
	var b := Rect2()
	var first := true
	for w in walls:
		for p in w.poly:
			if first:
				b = Rect2(p, Vector2.ZERO)
				first = false
			else:
				b = b.expand(p)
	return b


static func area_name(a: String) -> String:
	return "Start area" if a == "start" else a.replace("_", " ").capitalize()


static func _short_hint(m: Dictionary) -> String:
	if m.doors.is_empty():
		return "OPEN LAYOUT // NO DOORS"
	var costs: Array = m.doors.map(func(d): return int(d.cost))
	var areas := {}
	for d in m.doors:
		for a in d.opens:
			areas[a] = true
	var n: int = m.doors.size()
	var door_word := "1 DOOR" if n == 1 else "%d DOORS" % n
	var lo: int = int(costs.min())
	var hi: int = int(costs.max())
	var cost_s := str(lo) if lo == hi else "%d-%d" % [lo, hi]
	var an: int = areas.size()
	var area_word := "1 AREA TO OPEN" if an == 1 else "%d AREAS TO OPEN" % an
	return "%s (%s) // %s" % [door_word, cost_s, area_word]


## Door / area hint lines: [[text, colour]].
static func hint_lines(m: Dictionary) -> Array:
	if m.doors.is_empty():
		return [["NO DOORS // the whole map is open from the first round.", UIStyle.BONE_DIM]]
	var out := [["START IN: %s   //   %s" % [area_name(str(m.start)).to_upper(), _short_hint(m)], UIStyle.RUST.lightened(0.25)]]
	var by_area := {}
	for d in m.doors:
		for a in d.opens:
			if not by_area.has(a):
				by_area[a] = []
			by_area[a].append("%s %d" % [str(d.name), int(d.cost)])
	var parts := []
	for a in by_area:
		parts.append("%s (%s)" % [area_name(a), ", ".join(by_area[a])])
	out.append(["DOORS: " + "  //  ".join(parts), UIStyle.BONE_DIM])
	out.append(["Spawns open with their area: zombies only come from areas you've bought into.", UIStyle.BONE_DIM])
	return out


# ---------------------------------------------------------------- schematic preview

class _Schematic extends Control:
	const COLS := [Color(0.45, 0.48, 0.31), Color(0.37, 0.61, 0.58), Color(0.72, 0.54, 0.18), Color(0.70, 0.28, 0.23),
		Color(0.55, 0.62, 0.70), Color(0.56, 0.36, 0.74)]
	var meta: Dictionary = {}
	var title: String = ""
	var walls: Array = [] ## map_walls(id): wall / floor footprints (x, z)
	var wall_count: int = 0 ## walls drawn last frame (tests)

	static func _bounds_of(ws: Array) -> Rect2:
		var bb := Rect2()
		var first := true
		for w in ws:
			for p in w.poly:
				if first:
					bb = Rect2(p, Vector2.ZERO)
					first = false
				else:
					bb = bb.expand(p)
		return bb

	static func _xf(poly: PackedVector2Array, to: Callable) -> PackedVector2Array:
		var o := PackedVector2Array()
		for p in poly:
			o.append(to.call(p))
		return o

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
		var f: Font = UIStyle.body_bold()
		var st: Font = UIStyle.FONT_STENCIL
		if meta.is_empty():
			return
		var b: Rect2 = meta.bounds
		if b.size == Vector2.ZERO and not walls.is_empty():
			b = _bounds_of(walls).grow(2.0)
		var pts: Array = []
		for a in meta.areas:
			pts += meta.areas[a]
		for d in meta.doors:
			pts.append(d.pos)
		if b.size == Vector2.ZERO and not pts.is_empty():
			b = Rect2(pts[0], Vector2.ZERO)
			for p in pts:
				b = b.expand(p)
			b = b.grow(6.0)
		if b.size == Vector2.ZERO: # open map without markers: stencil plate
			var t := "OPEN ARENA"
			var ts := st.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 34)
			draw_string(st, (size - ts) * 0.5 + Vector2(0, 24), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 34, Color(UIStyle.BONE_DIM, 0.35))
			draw_string(f, Vector2(12, size.y - 12), "NO PREVIEW // NO DOORS", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(UIStyle.BONE_DIM, 0.6))
			return
		var pad := 18.0
		var sc := minf((size.x - pad * 2) / b.size.x, (size.y - pad * 2) / b.size.y)
		var off := (size - b.size * sc) * 0.5
		var to := func(p: Vector2) -> Vector2: return off + (p - b.position) * sc
		# map edge: the perimeter is invisible clip walls in the scene (skipped), so the bounds frame stands in for it
		draw_rect(Rect2(off, b.size * sc), Color(UIStyle.BONE, 0.55) if not walls.is_empty() else Color(UIStyle.BONE_DIM, 0.35),
			false, 3.0 if not walls.is_empty() else 1.5)
		# floors / decks first (faint), then walls and solid blocks on top (bone) so the layout reads
		for w in walls:
			if w.kind == "floor" and float(w.top) <= 6.5: # roofs (high slabs) would hide the rooms
				draw_colored_polygon(_xf(w.poly, to), Color(0.37, 0.61, 0.58, 0.10 if float(w.top) < 0.6 else 0.22))
		for w in walls:
			if w.kind == "wall":
				var q := _xf(w.poly, to)
				draw_colored_polygon(q, Color(UIStyle.BONE, 0.62 if float(w.h) >= 2.5 else 0.38))
				q.append(q[0])
				draw_polyline(q, Color(UIStyle.INK, 0.8), 1.0)
		wall_count = walls.filter(func(w): return w.kind == "wall").size()
		var i := 0
		var names: Array = meta.areas.keys()
		for a in names:
			var col: Color = COLS[i % COLS.size()]
			var cen := Vector2.ZERO
			for p in meta.areas[a]:
				var q: Vector2 = to.call(p)
				cen += q
				draw_circle(q, 9.0, Color(col, 0.22))
				draw_rect(Rect2(q - Vector2(3, 3), Vector2(6, 6)), col)
			cen /= float(meta.areas[a].size())
			var lab := "START AREA" if a == str(meta.start) else str(a).replace("_", " ").to_upper()
			var ls := f.get_string_size(lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
			draw_string(f, cen + Vector2(-ls.x * 0.5, -12), lab, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col.lightened(0.35))
			i += 1
		for d in meta.doors:
			var q: Vector2 = to.call(d.pos)
			draw_rect(Rect2(q - Vector2(8, 3), Vector2(16, 6)), UIStyle.RUST)
			draw_rect(Rect2(q - Vector2(8, 3), Vector2(16, 6)), UIStyle.INK, false, 1.0)
			draw_string(f, q + Vector2(10, 4), str(d.cost), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UIStyle.RUST.lightened(0.3))
		if meta.has_spawn:
			var sp: Vector2 = to.call(meta.spawn)
			draw_colored_polygon(PackedVector2Array([sp + Vector2(0, -7), sp + Vector2(6, 5), sp + Vector2(-6, 5)]), UIStyle.BONE)
		draw_string(f, Vector2(10, size.y - 10), "SCHEMATIC // █ WALLS   ■ SPAWNS + CHESTS BY AREA   ▬ DOORS (COST)   ▲ YOU", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(UIStyle.BONE_DIM, 0.75))
