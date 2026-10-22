extends MenuBase
## K (round 0 or game over): the v2 meta skill tree (data/skill_tree.json, logic in the Progress autoload).
## Layout follows /workspace/gooey-ui/skilltree/LAYOUT.md: full-screen panel; fixed header (class, keystone plate,
## level/XP, skill points, respec); branch rail (jump + pan); clipped, pannable canvas laid out from the data's
## x/y grid with elbow connectors (all-of solid, any-of merged at an "ANY 1" chip), OR chips between choice pairs,
## a keystone guide line and a CLASS LINES dock; per-node tiles with rank pips, cost badge, MAX stamp and type
## markers; a hover/focus tooltip with the per-rank table and the drawback in red; keyboard + pad focus.
## Built once per open(); purchases update tiles and wires in place from Progress.rank_changed / ranks_changed.
## Only the v2 Progress API is used (state / can_afford / rank / next_cost / buy_rank / respec ...).
## §24 (playtest 2026-10-22 #3 #8): two tabs. MAIN TREES = the 5 main trees (open to every class, one keystone each);
## SPECIALIZATION = the class roster (pick your class here), the viewed class's 3x7 tree, its Q pick and class items
## (Characters.spec: specializations / select_specialization / select_q, SKILLTREE_API.md §24). Layout from
## Progress.tree.tabs and the nodes' tab / tab_x / tab_y.

signal skill_unlocked(id: String) ## main.gd re-applies player stats on this ("" after a respec)

const TILE := 44.0
const KEY_TILE := 56.0
const ROW_H := 94.0 ## #14: room for a 2-line capstone name above a keystone
const ORIGIN := Vector2(64, 40) ## canvas px of grid (0, 0)
const MIN_PITCH := 76.0 ## playtest #14: the 15-column tree fits 1280 wide without side panning
const CANVAS_H := 548.0
const C_LOCKED := Color(0.17, 0.18, 0.14)
const C_EXCL := Color(0.30, 0.18, 0.13)

var _built := false
var _nodes: Dictionary = {} ## id -> SkillTile
var _defs: Dictionary = {} ## id -> node dictionary
var _branch: Dictionary = {} ## branch id -> branch dictionary
var _pitch := 110.0
var _clip: Control
var _canvas: Control
var _wires: Wires
var _content_size := Vector2.ZERO
var _pan := Vector2.ZERO
var _drag := false
var _tooltip: PanelContainer
var _tip_id := ""
var _focus_id := ""
var _points_label: Label
var _points_tab: PanelContainer
var _spent_label: Label
var _level_label: Label
var _xp_bar: Control
var _xp_fill: ColorRect
var _xp_next: Label
var _key_label: Label
var _class_label: Label
var _respec_btn: Button
var _respec_armed := 0.0
var _rail: HBoxContainer
var _rail_tabs: Dictionary = {} ## branch id -> Button
var _last_bought := "" ## tests: id of the last node bought through the UI
## Playtest #31: the info box shows only while a skill is hovered. Keyboard / gamepad focus counts as hover
## (nav_input is set by key / pad input and cleared by real mouse motion), the auto-focus on open does not.
var nav_input := false
var _hover_id := ""
## Playtest #14: 109-node tree. General branches (rows 0-7) always show; ONE class dock shows under them
## (class_view, default = your class); its rail tab / Q E switch the dock. Layout comes from Progress.tree.grid.
var class_view := "" ## Specialization tree shown on the SPECIALIZATION tab ("" = yours)
var tab := "main" ## §24: "main" / "spec"
var _row_h := ROW_H
var _tile := TILE ## tile sizes for the current tab (the 3x7 spec trees use slightly smaller tiles to fit 720 high)
var _key_tile := KEY_TILE
var _tab_btns: Dictionary = {} ## "main" / "spec" -> Button
var _spec_left: VBoxContainer ## roster (4 Specializations)
var _spec_right: VBoxContainer ## viewed Specialization: CHOOSE, Q pick, class items
var spec_buttons: Dictionary = {} ## class id -> roster Button
var q_buttons: Dictionary = {} ## ability id -> Button (viewed Specialization)
var select_button: Button
var _spec_reason: Label
const SPEC_ROW_H := 70.0 ## 7 rows fit the canvas without panning at 1280x720
const SPEC_PITCH := 118.0
const SPEC_SIDE_W := 250.0
const SPEC_INFO_W := 400.0
var _ids: Array = [] ## visible node ids, file order
var _toast: Label
var _toast_t := 0.0


func _ready() -> void:
	super._ready()
	Progress.rank_changed.connect(_on_rank_changed)
	Progress.ranks_changed.connect(_on_ranks_changed)


## Skillz's SkillSpec (Characters.spec, SKILLTREE_API.md) when the Characters autoload is live, else null
## (then the tree talks to Progress directly, as before Batch C).
func spec() -> Node:
	var c := get_node_or_null("/root/Characters")
	if c == null or not ("spec" in c) or c.spec == null:
		return null
	if c.has_method("is_bound") and not c.is_bound():
		return null
	return c.spec


func _connect_spec() -> void:
	var sp := spec()
	if sp and sp.has_signal("tree_changed") and not sp.tree_changed.is_connected(_on_ranks_changed):
		sp.tree_changed.connect(_on_ranks_changed)
	if sp and sp.has_signal("specialization_changed") and not sp.specialization_changed.is_connected(_on_spec_changed):
		sp.specialization_changed.connect(_on_spec_changed)
	if sp and sp.has_signal("q_changed") and not sp.q_changed.is_connected(_on_q_changed):
		sp.q_changed.connect(_on_q_changed)


## Your Specialization (= class): spec.current_specialization(), else Progress.selected_class.
func current_spec() -> String:
	var sp := spec()
	return str(sp.current_specialization()) if sp and sp.has_method("current_specialization") else str(Progress.selected_class)


## Specialization rows (spec.specializations()); without Characters a read-only roster from ClassRoster.
func spec_rows() -> Array:
	var sp := spec()
	if sp and sp.has_method("specializations"):
		return sp.specializations()
	var out: Array = []
	for cid in ClassRoster.ids():
		var d: Dictionary = ClassRoster.describe(cid).duplicate(true)
		d["icon"] = "spec_" + cid
		d["selected"] = cid == str(Progress.selected_class)
		d["can_select"] = false
		d["select_code"] = "blocked"
		d["select_reason"] = "Specializations switch on with the character slots update."
		d["class_items"] = ClassItems.owned(cid).size()
		out.append(d)
	return out


func spec_row(cid: String) -> Dictionary:
	for r in spec_rows():
		if str(r.id) == cid:
			return r
	return {}


func _node_tab(d: Dictionary) -> String:
	return str(d.get("tab", "spec" if str(d.get("class", "")) != "" else "main"))


## Branch ids on a tab (Progress.tree.tabs.<tab>.branches), falling back to class-less / class branches.
func tab_branches(t: String) -> Array:
	var b: Array = Progress.tree.get("tabs", {}).get(t, {}).get("branches", [])
	if not b.is_empty():
		return b
	return Progress.branches().filter(func(x): return (str(x.get("class", "")) == "") == (t == "main")).map(func(x): return str(x.id))


## Friendly text for a refused pick (spec.can_pick / pick codes). other_spec names the Specialization to choose.
func refusal_text(id: String, code: String, reason: String) -> String:
	if code == "other_spec":
		var cid := str(Progress.get_skill(id).get("class", ""))
		var nm := str(spec_row(cid).get("name", cid.capitalize()))
		return "Not your Specialization: CHOOSE %s to spend points here." % nm.to_upper()
	return reason


func _class_x0(cls: String) -> float:
	var x0 := 1e9
	for id in Progress.all_node_ids():
		var d := Progress.get_skill(id)
		if str(d.get("class", "")) == cls:
			x0 = minf(x0, float(d.get("x", 0)))
	return 0.0 if x0 > 1e8 else x0


## Visible node defs for the current tab: MAIN = every main-tree node, SPEC = class_view's Specialization tree;
## positions from tab_x / tab_y (§24; spec trees are 3 cols x 7 rows).
func _layout_defs() -> void:
	_defs.clear()
	_ids.clear()
	if class_view == "":
		class_view = current_spec()
	_row_h = ROW_H if tab == "main" else SPEC_ROW_H
	_tile = TILE if tab == "main" else 38.0
	_key_tile = KEY_TILE if tab == "main" else 48.0
	for id in Progress.all_node_ids():
		var d := Progress.get_skill(id)
		if _node_tab(d) != tab:
			continue
		if tab == "spec" and str(d.get("class", "")) != class_view:
			continue
		d = d.duplicate()
		d["x"] = float(d.get("tab_x", d.get("x", 0)))
		d["y"] = float(d.get("tab_y", d.get("y", 0)))
		_defs[id] = d
		_ids.append(id)


## Show a Specialization's tree on the SPECIALIZATION tab (roster card / Q E there). Doesn't choose it.
func view_class(cls: String) -> void:
	if cls == class_view and tab == "spec" and _built:
		return
	class_view = cls
	tab = "spec"
	_focus_id = ""
	_build()
	_refresh_all()


## Switch tab ("main" / "spec"): T / pad SELECT, or the tab buttons.
func set_tab(t: String) -> void:
	if t == tab and _built:
		return
	tab = t
	if t == "spec" and class_view == "":
		class_view = current_spec()
	_focus_id = ""
	hide_tooltip()
	_ui_snd("ui_hover")
	_build()
	_refresh_all()
	_focus_first.call_deferred()


func refresh() -> void:
	if not _built:
		_build()
	if not visible or _hover_id == "":
		hide_tooltip()
	_fit_panel()
	_refresh_all()
	_focus_first.call_deferred()


# ---------------------------------------------------------------- build (once)

func _fit_panel() -> void:
	var vp := get_viewport().get_visible_rect().size if get_viewport() else Vector2(1280, 720)
	panel.custom_minimum_size = vp - Vector2(28, 20)


func _build() -> void:
	_built = true
	clear_content()
	_defs.clear()
	_branch.clear()
	_nodes.clear()
	_rail_tabs.clear()
	_connect_spec()
	_layout_defs()
	for b in Progress.branches():
		_branch[str(b.id)] = b
	_fit_panel()
	content.add_theme_constant_override("separation", 6)
	spec_buttons.clear()
	q_buttons.clear()
	select_button = null
	_build_header()
	_build_tabs()
	if tab == "main":
		_build_rail()
		_build_canvas(content)
	else:
		var body := HBoxContainer.new()
		body.name = "SpecBody"
		body.add_theme_constant_override("separation", 12)
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content.add_child(body)
		_spec_left = VBoxContainer.new()
		_spec_left.name = "SpecRoster"
		_spec_left.custom_minimum_size.x = SPEC_SIDE_W
		_spec_left.add_theme_constant_override("separation", 6)
		body.add_child(_spec_left)
		_build_canvas(body)
		_spec_right = VBoxContainer.new()
		_spec_right.name = "SpecInfo"
		_spec_right.custom_minimum_size.x = SPEC_INFO_W
		_spec_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_spec_right.add_theme_constant_override("separation", 6)
		body.add_child(_spec_right)
		_rebuild_spec_side()
	_build_footer()
	if _tooltip and is_instance_valid(_tooltip):
		_tooltip.free()
	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.z_index = 20
	add_child(_tooltip)


func _build_header() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	content.add_child(head)
	head.add_child(UIStyle.label("SKILL TREE", 32, UIStyle.BONE, true))
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", UIStyle.cut_box(UIStyle.OLIVE_DARK, UIStyle.OLIVE, 2, 6))
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_class_label = UIStyle.label("", 13, UIStyle.BONE)
	chip.add_child(_class_label)
	head.add_child(chip)
	# keystone plate: KEYSTONE tab + n/1 + owned keystone name
	var kp := _plate("KEY\nSTONE", UIStyle.BONE_DIM)
	_key_label = UIStyle.label("", 15, UIStyle.BONE)
	kp.get_child(0).add_child(_key_label)
	head.add_child(kp)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var lvl := VBoxContainer.new()
	lvl.add_theme_constant_override("separation", 1)
	lvl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_level_label = UIStyle.label("", 12, UIStyle.BONE_DIM)
	_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lvl.add_child(_level_label)
	_xp_bar = UIStyle.bar(0.0, UIStyle.RUST, 130, 4)
	_xp_bar.size_flags_horizontal = Control.SIZE_SHRINK_END
	_xp_fill = _xp_bar.get_child(_xp_bar.get_child_count() - 1)
	lvl.add_child(_xp_bar)
	_xp_next = UIStyle.label("", 10, UIStyle.BONE_DIM)
	_xp_next.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lvl.add_child(_xp_next)
	head.add_child(lvl)
	var pp := _plate("SKILL\nPOINTS", UIStyle.RUST.lightened(0.15))
	_points_tab = pp.get_meta("tab")
	_points_label = UIStyle.label("0", 26, UIStyle.BONE, true)
	pp.get_child(0).add_child(_points_label)
	_spent_label = UIStyle.label("", 10, UIStyle.BONE_DIM)
	_spent_label.add_theme_constant_override("line_spacing", -3)
	pp.get_child(0).add_child(_spent_label)
	head.add_child(pp)
	_respec_btn = Button.new()
	_respec_btn.focus_mode = Control.FOCUS_NONE
	_respec_btn.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	_respec_btn.add_theme_font_size_override("font_size", 14)
	_respec_btn.add_theme_color_override("font_color", UIStyle.BONE)
	_respec_btn.add_theme_color_override("font_disabled_color", Color(UIStyle.BONE_DIM, 0.5))
	var rs := UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 7)
	rs.content_margin_left = 12
	rs.content_margin_right = 12
	_respec_btn.add_theme_stylebox_override("normal", rs)
	_respec_btn.add_theme_stylebox_override("disabled", rs)
	var rh := rs.duplicate() as StyleBoxFlat
	rh.border_color = UIStyle.BONE
	rh.bg_color = Color(0.2, 0.12, 0.07, 0.95)
	_respec_btn.add_theme_stylebox_override("hover", rh)
	_respec_btn.add_theme_stylebox_override("pressed", rh)
	_respec_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_respec_btn.pressed.connect(_on_respec_pressed)
	_respec_btn.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	head.add_child(_respec_btn)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)


# ---------------------------------------------------------------- §24 Specialization tab (class + Q + class items)

func _on_spec_changed(_cid: String = "") -> void:
	if _built and visible:
		class_view = current_spec() if tab != "spec" else class_view
		_build()
		_refresh_all()


func _on_q_changed(_cid: String = "", _aid: String = "") -> void:
	if _built and visible and tab == "spec":
		_rebuild_spec_side()


func _spec_icon(key: String, sz: float, fallback: String) -> Control:
	var tex := UIStyle.icon_key_tex(key)
	if tex:
		var tr := TextureRect.new()
		tr.name = "SpecIcon"
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(sz, sz)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return tr
	var g := PanelContainer.new()
	g.name = "SpecGlyph"
	g.add_theme_stylebox_override("panel", UIStyle.cut_box(UIStyle.INK, UIStyle.BONE_DIM, 2, 5))
	g.custom_minimum_size = Vector2(sz, sz)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UIStyle.label(UIStyle.initials(fallback), int(sz * 0.4), UIStyle.BONE, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.add_child(l)
	return g


func _side_btn(cb: Callable, on: bool, primary: bool = false) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.add_theme_color_override("font_disabled_color", Color(UIStyle.BONE_DIM, 0.55))
	var bg := Color(0.30, 0.16, 0.07, 0.95) if primary else (Color(0.16, 0.12, 0.08, 0.95) if on else Color(UIStyle.INK, 0.9))
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(bg, UIStyle.RUST if (on or primary) else Color(UIStyle.BONE_DIM, 0.6), 3 if on else 2, 8))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
	b.add_theme_stylebox_override("pressed", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 3, 8))
	b.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.BONE, 3, 8))
	b.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.12, 0.13, 0.085, 0.95) if on else Color(UIStyle.INK, 0.6),
		UIStyle.OLIVE.lightened(0.3) if on else Color(UIStyle.BONE_DIM, 0.3), 2, 8))
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	return b


func _side_wrap(t: String, fs: int, col: Color, w: float) -> Label:
	var l := UIStyle.label(t, fs, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = w
	return l


## Roster (left) + the viewed Specialization's CHOOSE / Q / class items (right). Rebuilt on any tree / Q change.
func _rebuild_spec_side() -> void:
	if _spec_left == null or not is_instance_valid(_spec_left) or _spec_right == null or not is_instance_valid(_spec_right):
		return
	for host in [_spec_left, _spec_right]:
		for c in host.get_children():
			host.remove_child(c)
			c.queue_free()
	spec_buttons.clear()
	q_buttons.clear()
	var rows := spec_rows()
	var view: Dictionary = {}
	_spec_left.add_child(UIStyle.label("SPECIALIZATIONS", 13, UIStyle.RUST.lightened(0.25), true))
	for r in rows:
		var cid := str(r.id)
		var mine := bool(r.get("selected", false))
		var viewing := cid == class_view
		if viewing:
			view = r
		var b := _side_btn(view_class.bind(cid), viewing)
		b.name = "Spec_" + cid
		b.custom_minimum_size = Vector2(SPEC_SIDE_W, 74)
		b.tooltip_text = str(r.get("role", ""))
		var h := HBoxContainer.new()
		h.set_anchors_preset(Control.PRESET_FULL_RECT)
		h.offset_left = 8
		h.offset_right = -8
		h.add_theme_constant_override("separation", 8)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(h)
		var ic := _spec_icon(str(r.get("icon", "spec_" + cid)), 52, str(r.get("name", cid)))
		ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(ic)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(v)
		var acc := UIStyle.accent(str(r.get("accent", "")), r.get("color", null))
		v.add_child(UIStyle.label(str(r.get("name", cid)).to_upper(), 17, UIStyle.BONE if viewing or mine else UIStyle.BONE_DIM, true))
		var role := UIStyle.label(str(r.get("role", "")).to_upper(), 10, acc)
		role.clip_text = true
		role.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.add_child(role)
		var stt := UIStyle.label("● YOUR SPECIALIZATION" if mine else "%d PTS IN TREE" % int(r.get("points_spent", 0)), 10,
			UIStyle.GOOD if mine else UIStyle.BONE_DIM, true)
		stt.name = "SpecStatus"
		v.add_child(stt)
		_spec_left.add_child(b)
		spec_buttons[cid] = b
	if view.is_empty():
		return
	var cid2 := str(view.id)
	var mine2 := bool(view.get("selected", false))
	var acc2 := UIStyle.accent(str(view.get("accent", "")), view.get("color", null))
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	_spec_right.add_child(top)
	top.add_child(_spec_icon(str(view.get("icon", "spec_" + cid2)), 56, str(view.get("name", cid2))))
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(tv)
	var nm := UIStyle.label(str(view.get("name", cid2)).to_upper(), 26, UIStyle.BONE, true)
	nm.name = "SpecName"
	tv.add_child(nm)
	tv.add_child(UIStyle.label(str(view.get("role", "")).to_upper(), 11, acc2, true))
	var stats := "%d HP  //  WALK %.1f  //  SPRINT %.1f  //  %s GRENADE" % [int(view.get("max_health", 100)), float(view.get("walk_speed", 5.0)),
		float(view.get("sprint_speed", 8.5)), str(view.get("grenade_id", "frag")).replace("_", " ").to_upper()]
	var sl := UIStyle.label(stats, 11, UIStyle.BONE, true)
	sl.name = "ClassStats"
	_spec_right.add_child(sl)
	var bl := _side_wrap(str(view.get("description", "")), 12, UIStyle.BONE_DIM, SPEC_INFO_W - 10)
	bl.name = "SpecBlurb"
	bl.max_lines_visible = 3
	_spec_right.add_child(bl)
	select_button = _side_btn(choose_spec.bind(cid2), mine2, not mine2)
	select_button.name = "SelectSpec"
	select_button.custom_minimum_size = Vector2(0, 40)
	select_button.text = "● YOUR SPECIALIZATION" if mine2 else "CHOOSE %s" % str(view.get("name", cid2)).to_upper()
	select_button.disabled = mine2 or not bool(view.get("can_select", false))
	if not mine2 and str(view.get("select_reason", "")) != "":
		select_button.tooltip_text = str(view.select_reason)
	_spec_right.add_child(select_button)
	if not mine2:
		var note := _side_wrap(str(view.get("select_reason", "")) if not bool(view.get("can_select", false)) else
			"Your class next match. Ranks in your current Specialization are kept and run again when you switch back.", 11,
			UIStyle.BAD.lightened(0.2) if not bool(view.get("can_select", false)) else UIStyle.BONE_DIM, SPEC_INFO_W - 10)
		note.name = "SelectNote"
		_spec_right.add_child(note)
	# Q ability
	_spec_right.add_child(UIStyle.label("Q ABILITY", 13, UIStyle.RUST.lightened(0.25), true))
	var qr := HBoxContainer.new()
	qr.name = "Abilities"
	qr.add_theme_constant_override("separation", 8)
	_spec_right.add_child(qr)
	var q_now: Dictionary = {}
	var blocked := str(view.get("select_code", "")) == "blocked"
	for a in view.get("abilities", []):
		var on := bool(a.get("selected", false)) or str(a.id) == str(view.get("ability", ""))
		if on:
			q_now = a
		var qb := _side_btn(pick_q.bind(str(a.id)), on)
		qb.name = "Ability_" + str(a.id)
		qb.custom_minimum_size = Vector2(0, 44)
		qb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		qb.disabled = blocked and not on
		qb.tooltip_text = str(a.get("summary", ""))
		var qh := HBoxContainer.new()
		qh.set_anchors_preset(Control.PRESET_FULL_RECT)
		qh.offset_left = 6
		qh.offset_right = -6
		qh.add_theme_constant_override("separation", 6)
		qh.mouse_filter = Control.MOUSE_FILTER_IGNORE
		qb.add_child(qh)
		var atex := UIStyle.ability_icon_tex(str(a.get("icon", a.id)).trim_prefix("ability_"))
		if atex == null:
			atex = UIStyle.ability_icon_tex(str(a.get("icon_fallback", "")).trim_prefix("ability_"))
		if atex:
			var tr := TextureRect.new()
			tr.texture = atex
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.custom_minimum_size = Vector2(32, 32)
			tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			qh.add_child(tr)
		var an := UIStyle.label(("● " if on else "") + str(a.get("name", a.id)).to_upper(), 13, UIStyle.BONE if on else UIStyle.BONE_DIM, true)
		an.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		an.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		an.clip_text = true
		an.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		qh.add_child(an)
		qr.add_child(qb)
		q_buttons[str(a.id)] = qb
	if not q_now.is_empty():
		var dur := float(q_now.get("duration", 0))
		var at := "%s  //  %ss COOLDOWN%s  //  %s" % [str(q_now.get("kind", "")).to_upper(), ("%.1f" % float(q_now.get("cooldown", 0))).trim_suffix(".0"),
			("  //  LASTS %ss" % ("%.1f" % dur).trim_suffix(".0")) if dur >= 0.5 else "", str(q_now.get("summary", ""))]
		var al := _side_wrap(at, 11, UIStyle.BONE_DIM, SPEC_INFO_W - 10)
		al.name = "AbilitySummary"
		al.max_lines_visible = 3
		_spec_right.add_child(al)
	# class items (ClassItems.owned_rows), equipped first
	var ci: Array = ClassItems.owned_rows(cid2)
	_spec_right.add_child(UIStyle.label("CLASS ITEMS  //  %d OWNED" % ci.size(), 13, UIStyle.RUST.lightened(0.25), true))
	var box := VBoxContainer.new()
	box.name = "ClassItems"
	box.add_theme_constant_override("separation", 2)
	_spec_right.add_child(box)
	if ci.is_empty():
		var none := _side_wrap("None yet. Class items drop in matches; they work only while this is your Specialization.", 11, UIStyle.BONE_DIM, SPEC_INFO_W - 10)
		none.name = "ClassItemsNone"
		box.add_child(none)
	for r2 in ci.slice(0, 3):
		var h2 := HBoxContainer.new()
		h2.name = "ClassItemRow"
		h2.add_theme_constant_override("separation", 8)
		box.add_child(h2)
		var iname := UIStyle.label(("● " if bool(r2.get("equipped", false)) else "") + str(r2.get("name", "")).to_upper(), 12, UIStyle.rarity_color(int(r2.get("rarity", 0))), true)
		iname.custom_minimum_size.x = 170
		iname.clip_text = true
		iname.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		h2.add_child(iname)
		var ln := str(r2.get("line", ""))
		if bool(r2.get("synergy_owned", false)) and str(r2.get("synergy_line", "")) != "":
			ln += "  +  " + str(r2.synergy_line)
		var il := UIStyle.label(ln, 11, UIStyle.BONE if bool(r2.get("active", false)) else UIStyle.BONE_DIM)
		il.clip_text = true
		il.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		il.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		il.custom_minimum_size.x = 1
		il.tooltip_text = ln
		il.mouse_filter = Control.MOUSE_FILTER_PASS
		h2.add_child(il)
	if ci.size() > 3:
		box.add_child(UIStyle.label("+ %d MORE IN YOUR KIT" % (ci.size() - 3), 10, UIStyle.BONE_DIM))
	_spec_reason = _side_wrap("", 11, UIStyle.BAD.lightened(0.2), SPEC_INFO_W - 10)
	_spec_reason.name = "SpecReason"
	_spec_right.add_child(_spec_reason)


## CHOOSE: make `cid` your Specialization (= class) through spec.select_specialization. Free undo stays open.
func choose_spec(cid: String = "") -> bool:
	if cid == "":
		cid = class_view
	var sp := spec()
	var r: Dictionary = sp.select_specialization(cid) if sp else {"ok": false, "reason": str(spec_row(cid).get("select_reason", ""))}
	if not bool(r.get("ok", false)):
		_spec_say(str(r.get("reason", "")))
		return false
	_ui_snd("ui_equip")
	skill_unlocked.emit("") # main.gd / home re-apply stats + class
	class_view = cid
	_build()
	_refresh_all()
	return true


## Q pick for the viewed Specialization (spec.select_q(ability_id, class_view)).
func pick_q(aid: String) -> bool:
	var sp := spec()
	var r: Dictionary = sp.select_q(aid, class_view) if sp else {"ok": false, "reason": "Specializations switch on with the character slots update."}
	if not bool(r.get("ok", false)):
		_spec_say(str(r.get("reason", "")))
		return false
	_ui_snd("ui_equip")
	skill_unlocked.emit("")
	_rebuild_spec_side()
	return true


func _spec_say(t: String) -> void:
	show_toast(t)
	if _spec_reason and is_instance_valid(_spec_reason):
		_spec_reason.text = t


## §24 tab strip: MAIN TREES / SPECIALIZATION // <YOURS> + what each tab is for.
func _build_tabs() -> void:
	_tab_btns.clear()
	var row := HBoxContainer.new()
	row.name = "TabStrip"
	row.add_theme_constant_override("separation", 8)
	content.add_child(row)
	for t in [["main", "MAIN TREES"], ["spec", "SPECIALIZATION  //  %s" % str(spec_row(current_spec()).get("name", current_spec())).to_upper()]]:
		var on: bool = t[0] == tab
		var b := Button.new()
		b.name = "TreeTab_" + t[0]
		b.text = t[1]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(230, 32)
		b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
		b.add_theme_font_size_override("font_size", 15)
		b.add_theme_color_override("font_color", UIStyle.BONE if on else UIStyle.BONE_DIM)
		b.add_theme_color_override("font_hover_color", UIStyle.BONE)
		var st := UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95) if on else Color(UIStyle.INK, 0.9), UIStyle.RUST if on else Color(UIStyle.BONE_DIM, 0.45), 3 if on else 2, 8)
		for k in ["normal", "hover", "pressed"]:
			b.add_theme_stylebox_override(k, st)
		b.pressed.connect(set_tab.bind(t[0]))
		b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
		# Desi bfa5ca4: tab_specialization icon on the SPECIALIZATION tab
		var tic := UIStyle.icon_key_tex("tab_specialization") if t[0] == "spec" else null
		if tic:
			b.icon = tic
			b.expand_icon = true
			b.add_theme_constant_override("icon_max_width", 22)
			b.add_theme_constant_override("h_separation", 8)
			b.custom_minimum_size.x += 26
		row.add_child(b)
		_tab_btns[t[0]] = b
	row.add_child(UIStyle.key_cap("T", 10))
	row.add_child(UIStyle.label("SWITCH", 11, UIStyle.BONE_DIM))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(sp)
	var hint := UIStyle.label("OPEN TO EVERY CLASS  //  ONE KEYSTONE PER TREE" if tab == "main"
		else "PICK YOUR CLASS + Q HERE  //  ONLY YOUR SPECIALIZATION TAKES POINTS", 11, UIStyle.BONE_DIM, true)
	hint.name = "TabHint"
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(hint)


## Stamped plate: solid tab on the left, contents HBox (child 0) on the right.
func _plate(tab_text: String, tab_col: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var st := UIStyle.cut_box(Color(UIStyle.INK, 0.9), tab_col, 2, 9)
	st.set_content_margin_all(0)
	st.content_margin_right = 10
	p.add_theme_stylebox_override("panel", st)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	p.add_child(h)
	var tab := PanelContainer.new()
	var ts := StyleBoxFlat.new()
	ts.bg_color = tab_col
	ts.content_margin_left = 6
	ts.content_margin_right = 6
	tab.add_theme_stylebox_override("panel", ts)
	var tl := UIStyle.label(tab_text, 10, UIStyle.INK)
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tl.add_theme_constant_override("line_spacing", -4)
	tab.add_child(tl)
	h.add_child(tab)
	var pad := Control.new()
	pad.custom_minimum_size.x = 2
	p.set_meta("tab", tab)
	h.move_child(tab, 0)
	var tail := Control.new()
	tail.custom_minimum_size.x = 4
	h.add_child(tail)
	h.move_child(tail, h.get_child_count() - 1)
	return p


func _build_rail() -> void:
	_rail = HBoxContainer.new()
	_rail.add_theme_constant_override("separation", 6)
	content.add_child(_rail)
	for id in tab_branches("main"):
		var t := Button.new()
		t.focus_mode = Control.FOCUS_NONE
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.custom_minimum_size = Vector2(40, 26)
		t.clip_text = true # playtest #29: many branches shrink the tabs (ellipsis) instead of overlapping
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		t.alignment = HORIZONTAL_ALIGNMENT_LEFT
		t.add_theme_font_override("font", UIStyle.FONT_STENCIL)
		t.add_theme_font_size_override("font_size", 12)
		t.add_theme_color_override("font_color", UIStyle.BONE_DIM)
		t.add_theme_color_override("font_hover_color", UIStyle.BONE)
		t.pressed.connect(_jump_to_branch.bind(id))
		t.mouse_entered.connect(_ui_snd.bind("ui_hover"))
		t.name = "Tab_" + id
		var ric := UIStyle.icon_key_tex(str(_branch.get(id, {}).get("icon", "tree_" + str(id))))
		if ric: # Desi bfa5ca4 tree_<branch> icons
			t.icon = ric
			t.expand_icon = true
			t.add_theme_constant_override("icon_max_width", 18)
			t.add_theme_constant_override("h_separation", 5)
		_rail.add_child(t)
		_rail_tabs[id] = t


func _accent(branch_id: String) -> Color:
	var b: Dictionary = _branch.get(branch_id, {})
	return UIStyle.accent(str(b.get("accent", "")), b.get("color", null))


func _build_canvas(host: Control) -> void:
	_clip = Control.new()
	_clip.name = "TreeCanvas"
	_clip.clip_contents = true
	_clip.custom_minimum_size = Vector2(ORIGIN.x * 2.0 + 2.0 * SPEC_PITCH + 16.0 if tab == "spec" else 0.0, CANVAS_H)
	_clip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_clip.mouse_filter = Control.MOUSE_FILTER_PASS
	_clip.gui_input.connect(_on_canvas_input)
	host.add_child(_clip)
	var grid_bg := ColorRect.new() # faint backdrop so the canvas reads as a field
	grid_bg.color = Color(0.0, 0.0, 0.0, 0.18)
	grid_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	grid_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(grid_bg)
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.add_child(_canvas)
	_toast = UIStyle.label("", 13, UIStyle.BAD.lightened(0.25), true, 3)
	_toast.name = "PickToast"
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.anchor_left = 0.0
	_toast.anchor_right = 1.0
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_toast.offset_top = -48
	_toast.offset_bottom = -8
	_toast.modulate.a = 0.0
	_toast.z_index = 5
	_clip.add_child.call_deferred(_toast)
	var g: Dictionary = Progress.tree.get("grid", {})
	var max_x := 0.0
	var max_y := 0.0
	for id in _defs:
		max_x = maxf(max_x, float(_defs[id].get("x", 0)))
		max_y = maxf(max_y, float(_defs[id].get("y", 0)))
	var tg: Dictionary = Progress.tree.get("tabs", {}).get(tab, g)
	max_x = maxf(max_x, float(tg.get("cols", 1)) - 1.0)
	var clip_w := panel.custom_minimum_size.x - 40.0
	_pitch = SPEC_PITCH if tab == "spec" else maxf((clip_w - ORIGIN.x * 2.0) / maxf(max_x, 1.0), MIN_PITCH)
	_content_size = Vector2(ORIGIN.x * 2.0 + max_x * _pitch, ORIGIN.y + max_y * _row_h + (64.0 if tab == "main" else 76.0))
	_canvas.size = _content_size
	_wires = Wires.new()
	_wires.menu = self
	_wires.size = _content_size
	_wires.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_wires)
	# branch headers, centred over each non-class branch's span
	for b in Progress.branches():
		var ids := _defs.keys().filter(func(i): return str(_defs[i].branch) == str(b.id))
		if ids.is_empty():
			continue
		var xs: Array = ids.map(func(i): return float(_defs[i].x))
		var cx: float = ORIGIN.x + (float(xs.min()) + float(xs.max())) * 0.5 * _pitch
		var name_s := str(b.name).to_upper() + (" TRUNK" if str(b.id) == "ledger" else "")
		var span_w: float = (float(xs.max()) - float(xs.min())) * _pitch + _pitch - 10.0 # playtest #29: fit the span
		var hfs := fit_font_size(UIStyle.FONT_STENCIL, name_s, span_w, 14, 9)
		var hl := UIStyle.label(name_s, hfs, _accent(str(b.id)), true)
		hl.name = "BranchHeader_" + str(b.id)
		hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hl.clip_text = true
		hl.size = Vector2(span_w, 18)
		hl.position = Vector2(cx - span_w * 0.5, 0)
		_canvas.add_child(hl)
		var bic := UIStyle.icon_key_tex(str(b.get("icon", "tree_" + str(b.id))))
		var tw: float = UIStyle.FONT_STENCIL.get_string_size(name_s, HORIZONTAL_ALIGNMENT_LEFT, -1, hfs).x
		if bic and tw + 44.0 <= span_w: # Desi bfa5ca4 tree icon left of the header when it fits the span
			var bi := TextureRect.new()
			bi.name = "BranchIcon_" + str(b.id)
			bi.texture = bic
			bi.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			bi.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			bi.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			bi.size = Vector2(18, 18)
			bi.position = Vector2(cx - tw * 0.5 - 22.0, 0)
			bi.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_canvas.add_child(bi)
		var ul := ColorRect.new()
		ul.color = Color(_accent(str(b.id)), 0.75)
		ul.size = Vector2(40, 2)
		ul.position = Vector2(cx - 20, 18)
		ul.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(ul)
	# nodes
	for id in _ids:
		var t := SkillTile.new()
		t.menu = self
		t.id = id
		t.def = _defs[id]
		t.accent = _accent(str(_defs[id].branch))
		var s := _key_tile if str(_defs[id].get("type", "")) == "keystone" else _tile
		t.size = Vector2(s, s)
		t.set_meta("skill_id", id)
		t.position = _grid_pos(id) - Vector2(s, s) * 0.5
		t.pressed.connect(_on_tile_pressed.bind(id))
		t.focus_entered.connect(_on_tile_focus.bind(id))
		t.mouse_entered.connect(_on_tile_hover.bind(id, true))
		t.mouse_exited.connect(_on_tile_hover.bind(id, false))
		_canvas.add_child(t)
		_nodes[id] = t


func _build_footer() -> void:
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	content.add_child(foot)
	for ks in [["ARROWS", "D-PAD", "MOVE"], ["Q  E", "LB  RB", "BRANCH" if tab == "main" else "SPEC"], ["LMB", "A", "BUY RANK"],
			["RMB DRAG", "R-STICK", "PAN"], ["U", "X", "UNDO"], ["R", "Y", "RESPEC"], ["K", "B", "CLOSE"]]:
		if ks[2] == "UNDO" and self.spec() == null:
			continue
		foot.add_child(UIStyle.key_cap(ks[0], 10))
		foot.add_child(UIStyle.label("/", 10, UIStyle.BONE_DIM))
		foot.add_child(UIStyle.key_cap(ks[1], 10))
		var l := UIStyle.label(ks[2], 11, UIStyle.BONE_DIM)
		l.custom_minimum_size.x = 0
		foot.add_child(l)
		var gap := Control.new()
		gap.custom_minimum_size.x = 8
		foot.add_child(gap)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp)
	foot.add_child(UIStyle.label("Applies at match start  //  respec: home, round 0, game over", 11, UIStyle.BONE_DIM))


## Largest font size in [lo, hi] that fits `text` in `w` px (single line).
static func fit_font_size(f: Font, text: String, w: float, hi: int, lo: int) -> int:
	var fs := hi
	while fs > lo and f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > w:
		fs -= 1
	return fs


## Name plate width under a tile: never wider than the column pitch, so neighbours' names can't touch.
func name_width() -> float:
	return minf(110.0 if tab == "spec" else 96.0, _pitch - 10.0)


func _grid_pos(id: String) -> Vector2:
	var d: Dictionary = _defs[id]
	return ORIGIN + Vector2(float(d.get("x", 0)) * _pitch, float(d.get("y", 0)) * _row_h + (20.0 if tab == "main" else 12.0))


# ---------------------------------------------------------------- state (in place)

## UI state for a node: Progress.state() plus "unaffordable" for available nodes we can't pay for.
func ui_state(id: String) -> String:
	var s: String = Progress.state(id)
	var cls := str(Progress.get_skill(id).get("class", ""))
	if cls != "" and cls != current_spec() and s == "available":
		return "other_spec" # §24: only your Specialization takes points
	if s == "available" and not Progress.can_afford(id):
		return "unaffordable"
	return s


func _refresh_all() -> void:
	if not _built:
		return
	var pts := Progress.skill_points_available()
	_points_label.text = str(pts)
	_points_label.add_theme_color_override("font_color", UIStyle.BONE if pts > 0 else UIStyle.BONE_DIM)
	_spent_label.text = "SPENT %d\nOF %d" % [Progress.skill_points_spent, Progress.tree_total_cost()]
	var per := maxi(int(Progress.tree.get("xp_per_skill_point", 250)), 1)
	_level_label.text = "LEVEL %d  //  %d XP" % [Progress.get_level(), Progress.xp]
	_xp_fill.size.x = 130.0 * float(Progress.xp % per) / float(per)
	_xp_next.text = "%d XP TO NEXT POINT" % (per - Progress.xp % per)
	_class_label.text = "SPEC  //  " + str(spec_row(current_spec()).get("name", current_spec())).to_upper()
	var k_total := 0
	var k_owned := 0
	for id in _defs: # §24: one keystone per tree (main tab: 5; spec tab: the viewed tree's)
		if str(_defs[id].get("type", "")) == "keystone":
			k_total += 1
			k_owned += 1 if Progress.rank(id) > 0 else 0
	_key_label.text = "%d/%d" % [k_owned, k_total]
	_key_label.add_theme_color_override("font_color", UIStyle.BONE if k_owned > 0 else UIStyle.RUST.lightened(0.2))
	_refresh_respec()
	for id in _nodes:
		_nodes[id].queue_redraw()
	_wires.queue_redraw()
	for bid in _rail_tabs:
		var spent := 0
		var total := 0
		for id in Progress.all_node_ids():
			var nd := Progress.get_skill(id)
			if str(nd.branch) != bid:
				continue
			var costs: Array = nd.get("cost", [1])
			for i in costs.size():
				total += int(costs[i])
				if i < Progress.rank(id):
					spent += int(costs[i])
		var t: Button = _rail_tabs[bid]
		var cls := str(_branch[bid].get("class", ""))
		t.text = "  %s   %d/%d" % [str(_branch[bid].name).to_upper(), spent, total]
		var on: bool = _focus_id != "" and str(_defs.get(_focus_id, {}).get("branch", "")) == bid
		var st := UIStyle.cut_box(Color(0.13, 0.135, 0.1, 0.95) if on else Color(0.07, 0.075, 0.06, 0.9),
			Color(UIStyle.BONE, 0.8) if on else Color(UIStyle.BONE_DIM, 0.25), 1, 6)
		st.border_width_left = 5
		st.border_color = st.border_color if not on else UIStyle.BONE
		st.set_content_margin_all(2)
		var stripe := st.duplicate() as StyleBoxFlat
		stripe.border_color = _accent(bid)
		stripe.border_width_left = 5
		stripe.border_width_top = 1 if not on else 2
		stripe.border_width_right = 1 if not on else 2
		stripe.border_width_bottom = 1 if not on else 2
		t.add_theme_stylebox_override("normal", stripe)
		t.add_theme_stylebox_override("hover", stripe)
		t.add_theme_stylebox_override("pressed", stripe)
		t.add_theme_color_override("font_color", UIStyle.BONE if on else UIStyle.BONE_DIM)
		t.modulate.a = 1.0 if cls == "" or cls == Progress.selected_class else 0.7
	if tab == "spec":
		_rebuild_spec_side()
	if _tooltip.visible and _tip_id != "":
		_show_tooltip(_tip_id)


func _refresh_respec() -> void:
	var rs := respec_state()
	_respec_btn.disabled = not bool(rs.allowed)
	if _respec_armed > 0.0:
		_respec_btn.text = "CONFIRM RESPEC?  REFUNDS %d" % Progress.skill_points_spent
	else:
		_respec_btn.text = str(rs.label)


func _on_rank_changed(_id: String, _rank: int) -> void:
	if _built and visible:
		_refresh_all()


func _on_ranks_changed() -> void:
	if _built and visible:
		_refresh_all()


func _process(delta: float) -> void:
	if not visible:
		return
	if _respec_armed > 0.0:
		_respec_armed -= delta
		if _respec_armed <= 0.0:
			_refresh_respec()
	if _toast_t > 0.0 and _toast:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t / 0.4, 0.0, 1.0)
	var stick := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if stick.length() > 0.2:
		_set_pan(_pan + stick * 600.0 * delta)


# ---------------------------------------------------------------- interaction

## Buy the next rank of `id` through Progress (also used by the tests).
func buy(id: String) -> bool:
	var sp := spec()
	if sp:
		var r: Dictionary = sp.pick(id)
		if not bool(r.get("ok", false)):
			show_toast(refusal_text(id, str(r.get("code", "")), str(r.get("reason", ""))))
			return false
		_last_bought = id
		_ui_snd("ui_skill_unlock")
		skill_unlocked.emit(id)
		return true
	if ui_state(id) == "other_spec":
		show_toast(refusal_text(id, "other_spec", ""))
		return false
	if Progress.buy_rank(id):
		_last_bought = id
		_ui_snd("ui_skill_unlock")
		skill_unlocked.emit(id)
		return true
	return false


func _on_tile_pressed(id: String) -> void:
	buy(id)


## Free undo of one rank picked this visit (SkillSpec session: home menu / tree page). Needs Characters.
func refund(id: String) -> bool:
	var sp := spec()
	if sp == null or id == "":
		return false
	var chk: Dictionary = sp.can_refund(id)
	if not bool(chk.get("ok", false)):
		show_toast(str(chk.get("reason", "")))
		return false
	var r = sp.refund(id)
	var ok: bool = r if r is bool else (bool(r.get("ok", false)) if r is Dictionary else false)
	if ok:
		_ui_snd("ui_scrap_dismantle")
		skill_unlocked.emit("")
	_refresh_all()
	return ok


func show_toast(text: String, secs: float = 2.6) -> void:
	if _toast == null or text == "":
		return
	_toast.text = text.to_upper()
	_toast.modulate.a = 1.0
	_toast_t = secs


func toast_text() -> String:
	return _toast.text if _toast and _toast.modulate.a > 0.01 else ""


## {allowed, label, reason}: what the respec button can do now (SkillSpec.respec_cost when live).
func respec_state() -> Dictionary:
	var spent := int(Progress.skill_points_spent)
	var sp := spec()
	if sp == null:
		var ok0 := Progress.can_respec() and spent > 0
		return {"allowed": ok0, "label": "[R] RESPEC  //  FREE" if Progress.can_respec() else "[R] RESPEC  //  ROUND 0 ONLY", "reason": ""}
	var rc: Dictionary = sp.respec_cost()
	var allowed := bool(rc.get("allowed", false))
	var price := ""
	if not allowed:
		price = "HOME / ROUND 0 ONLY"
	elif bool(rc.get("free", false)) or not bool(rc.get("currency_available", false)):
		price = "FREE"
	else:
		price = "%d %s" % [int(rc.get("amount", 0)), str(rc.get("currency", "scrap")).to_upper()]
		if not bool(rc.get("can_afford", true)):
			allowed = false
	return {"allowed": allowed and spent > 0, "label": "[R] RESPEC  //  " + price, "reason": str(rc.get("reason", ""))}


func _on_respec_pressed() -> void:
	if not bool(respec_state().allowed):
		show_toast(str(respec_state().reason))
		return
	if _respec_armed <= 0.0:
		_respec_armed = 3.0
		_refresh_respec()
		return
	_respec_armed = 0.0
	var sp := spec()
	if sp:
		var r: Dictionary = sp.respec()
		if bool(r.get("ok", false)):
			_ui_snd("ui_scrap_dismantle")
			skill_unlocked.emit("")
		else:
			show_toast(str(r.get("reason", "")))
	elif Progress.respec():
		_ui_snd("ui_scrap_dismantle")
		skill_unlocked.emit("")
	_refresh_all()


func _on_tile_focus(id: String) -> void:
	var prev := _focus_id
	_focus_id = id
	if prev != "" and _nodes.has(prev):
		_nodes[prev].queue_redraw()
	_nodes[id].queue_redraw()
	_ensure_visible(id)
	if nav_input or _hover_id == id:
		_show_tooltip(id)
	elif _hover_id == "":
		hide_tooltip()
	if prev == "" or str(_defs[prev].branch) != str(_defs[id].branch):
		_refresh_all()


func _on_tile_hover(id: String, inside: bool) -> void:
	_nodes[id].hover = inside
	_nodes[id].queue_redraw()
	if inside:
		_hover_id = id
		_ui_snd("ui_hover")
		_show_tooltip(id)
	else:
		if _hover_id == id:
			_hover_id = ""
		if _tip_id == id:
			if nav_input and _focus_id != "" and _nodes[_focus_id].has_focus():
				_show_tooltip(_focus_id)
			else:
				hide_tooltip()


func hide_tooltip() -> void:
	if _tooltip:
		_tooltip.visible = false
	_tip_id = ""


func tooltip_visible() -> bool:
	return _tooltip != null and _tooltip.visible


## Key / pad input turns nav mode on (focus shows the info box); real mouse motion turns it off and hides the
## box unless the pointer is over a skill. Observed in _input, never consumed.
func _input(event: InputEvent) -> void:
	if not visible or not _built:
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).relative.length() > 0.5:
		if nav_input:
			nav_input = false
			if _hover_id == "":
				hide_tooltip()
	elif (event is InputEventKey and event.pressed) or (event is InputEventJoypadButton and event.pressed) \
			or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5):
		if not nav_input:
			nav_input = true
			var f := get_viewport().gui_get_focus_owner()
			if f != null and f.has_meta("skill_id") and _nodes.has(str(f.get_meta("skill_id"))):
				_show_tooltip(str(f.get_meta("skill_id"))) # an arrow press then moves focus -> _on_tile_focus


func _focus_first() -> void:
	if not visible or _nodes.is_empty():
		return
	var pick := _focus_id
	if pick == "" or not _nodes.has(pick):
		pick = ""
		for id in _ids:
			if ui_state(id) in ["available", "owned"] and Progress.can_afford(id):
				pick = id
				break
	if pick == "":
		pick = _ids[0]
	_nodes[pick].grab_focus()


func _jump_to_branch(bid: String) -> void:
	_ui_snd("ui_hover")
	if bid in tab_branches("spec"):
		view_class(bid)
	elif tab != "main":
		set_tab("main")
	var ids := _ids.filter(func(i): return str(_defs[i].branch) == bid)
	if ids.is_empty():
		return
	var pick: String = ids[0]
	for i in ids:
		if ui_state(i) in ["available", "owned"]:
			pick = i
			break
	_nodes[pick].grab_focus()


## Q / E: next main tree (MAIN tab) or next Specialization (SPEC tab).
func _branch_step(dir: int) -> void:
	if tab == "spec":
		var order: Array = tab_branches("spec")
		view_class(order[posmod(order.find(class_view) + dir, order.size())])
		_focus_first.call_deferred()
		return
	var order2: Array = tab_branches("main")
	var cur := order2.find(str(_defs.get(_focus_id, {}).get("branch", order2[0])))
	_jump_to_branch(order2[posmod(cur + dir, order2.size())])


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_Q:
				_branch_step(-1)
			KEY_E:
				_branch_step(1)
			KEY_R:
				_on_respec_pressed()
			KEY_T:
				set_tab("spec" if tab == "main" else "main")
			KEY_U, KEY_BACKSPACE:
				refund(_focus_id)
			_:
				super._unhandled_input(event)
				return
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_LEFT_SHOULDER:
				_branch_step(-1)
			JOY_BUTTON_RIGHT_SHOULDER:
				_branch_step(1)
			JOY_BUTTON_Y:
				_on_respec_pressed()
			JOY_BUTTON_BACK:
				set_tab("spec" if tab == "main" else "main")
			JOY_BUTTON_X:
				refund(_focus_id)
			JOY_BUTTON_B:
				close()
			_:
				return
		get_viewport().set_input_as_handled()
		return
	super._unhandled_input(event)


func _on_canvas_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_drag = event.pressed
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_pan(_pan + Vector2(0, 48))
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_pan(_pan - Vector2(0, 48))
	elif event is InputEventMouseMotion and _drag:
		_set_pan(_pan - event.relative)


func _set_pan(p: Vector2) -> void:
	var view := _clip.size
	var maxp := (_content_size - view).max(Vector2.ZERO)
	_pan = p.clamp(Vector2.ZERO, maxp)
	_canvas.position = -_pan
	if _tooltip.visible and _tip_id != "":
		_place_tooltip(_tip_id)


func _ensure_visible(id: String) -> void:
	var r := Rect2(_nodes[id].position - Vector2(40, 30), _nodes[id].size + Vector2(80, 90))
	var view := Rect2(_pan, _clip.size)
	var p := _pan
	if r.position.x < view.position.x:
		p.x = r.position.x
	elif r.end.x > view.end.x:
		p.x = r.end.x - view.size.x
	if r.position.y < view.position.y:
		p.y = r.position.y
	elif r.end.y > view.end.y:
		p.y = r.end.y - view.size.y
	_set_pan(p)


# ---------------------------------------------------------------- tooltip

func _show_tooltip(id: String) -> void:
	_tip_id = id
	for c in _tooltip.get_children():
		c.queue_free()
	var d: Dictionary = _defs[id]
	var r := Progress.rank(id)
	var ranks := int(d.get("ranks", 1))
	var st := ui_state(id)
	var acc := _accent(str(d.branch))
	var border := UIStyle.RUST.lightened(0.15)
	match st:
		"maxed", "owned":
			border = UIStyle.OLIVE.lightened(0.3)
		"excluded":
			border = C_EXCL.lightened(0.2)
		"locked":
			border = Color(UIStyle.BONE_DIM, 0.5)
	var box := UIStyle.cut_box(Color(0.055, 0.058, 0.045, 0.98), border, 2, 12)
	box.set_content_margin_all(0)
	box.border_width_left = 6
	_tooltip.add_theme_stylebox_override("panel", box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.custom_minimum_size.x = 290
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 10)
	m.add_child(v)
	_tooltip.add_child(m)
	# header
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	v.add_child(h)
	var nv := VBoxContainer.new()
	nv.add_theme_constant_override("separation", -2)
	nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nv.add_child(UIStyle.label(str(d.name).to_upper(), 17, UIStyle.BONE, true))
	var meta := "%s  //  %s  //  TIER %d" % [str(_branch.get(str(d.branch), {}).get("name", d.branch)).to_upper(),
		str(d.get("type", "passive")).to_upper(), int(d.get("y", 0))]
	nv.add_child(UIStyle.label(meta, 10, acc))
	h.add_child(nv)
	var rk := ""
	if ranks > 1:
		rk = "%d/%d" % [r, ranks]
	elif r > 0:
		rk = "OWNED"
	else:
		rk = "%d PT" % Progress.next_cost(id)
	var rl := UIStyle.label(rk, 20, UIStyle.OLIVE.lightened(0.35) if r > 0 else UIStyle.RUST.lightened(0.2), true)
	rl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(rl)
	v.add_child(_tip_rule())
	# body: current rank (or rank 1 preview)
	var show_r := maxi(r, 1)
	var desc := UIStyle.label(Progress.format_description(d, show_r), 13, UIStyle.BONE)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size.x = 290
	v.add_child(desc)
	if str(d.get("drawback", "")) != "":
		var dr := UIStyle.label(Progress.format_drawback(d, show_r), 13, UIStyle.BAD)
		dr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		dr.custom_minimum_size.x = 290
		dr.name = "Drawback"
		v.add_child(dr)
	if r == 0 and ranks > 1:
		v.add_child(UIStyle.label("SHOWN AT RANK I", 9, UIStyle.BONE_DIM))
	# per-rank table
	if ranks > 1:
		var grid := GridContainer.new()
		grid.columns = 3
		grid.name = "RankTable"
		grid.add_theme_constant_override("h_separation", 8)
		grid.add_theme_constant_override("v_separation", 1)
		var costs: Array = d.get("cost", [])
		for i in range(1, ranks + 1):
			var cur := i == r
			var nxt := i == r + 1
			var col := UIStyle.OLIVE.lightened(0.35) if cur else (UIStyle.RUST.lightened(0.25) if nxt else Color(UIStyle.BONE_DIM, 0.8))
			grid.add_child(UIStyle.label(UIStyle.roman(i) + (" >" if nxt else ""), 12, col, true))
			var txt := UIStyle.label(Progress.format_description(d, i), 11, UIStyle.BONE if (cur or nxt) else UIStyle.BONE_DIM)
			txt.custom_minimum_size.x = 200
			txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			grid.add_child(txt)
			var ctext := "OWNED" if i <= r else "%d PT" % int(costs[i - 1] if i - 1 < costs.size() else 1)
			grid.add_child(UIStyle.label(ctext, 11, col))
		v.add_child(_tip_rule())
		v.add_child(grid)
	# notes
	v.add_child(_tip_rule())
	var req_rank: Dictionary = d.get("requires_rank", {})
	for req in d.get("requires", []):
		var need := int(req_rank.get(req, 1))
		var ok := Progress.rank(req) >= need
		var rn := str(_defs.get(req, {}).get("name", req)).to_upper() + ((" " + UIStyle.roman(need)) if need > 1 else "")
		v.add_child(UIStyle.label("REQUIRES %s  %s" % [rn, "// DONE" if ok else "// MISSING"], 10,
			UIStyle.OLIVE.lightened(0.35) if ok else UIStyle.BLOOD.lightened(0.4)))
	var any_of: Array = d.get("requires_any", [])
	if not any_of.is_empty():
		var any_ok := any_of.any(func(q): return Progress.rank(q) >= int(req_rank.get(q, 1)))
		var names := PackedStringArray(any_of.map(func(q): return str(_defs.get(q, {}).get("name", q)).to_upper()))
		v.add_child(UIStyle.label("REQUIRES ANY OF %s  %s" % [" / ".join(names), "// DONE" if any_ok else "// MISSING"], 10,
			UIStyle.OLIVE.lightened(0.35) if any_ok else UIStyle.BLOOD.lightened(0.4)))
	var grp := str(d.get("choice_group", ""))
	if grp != "":
		var others := _defs.keys().filter(func(o): return o != id and str(_defs[o].get("choice_group", "")) == grp)
		var names2 := PackedStringArray(others.map(func(o): return str(_defs[o].name).to_upper()))
		if grp == "keystone":
			var kb := UIStyle.label("KEYSTONE: ONE PER TREE", 10, UIStyle.BLOOD.lightened(0.45))
			v.add_child(kb)
		var ex := Progress.excluded_by(id)
		if ex != "" and r == 0:
			v.add_child(UIStyle.label("EXCLUDED: YOU OWN %s" % str(_defs[ex].name).to_upper(), 10, UIStyle.BAD))
		else:
			v.add_child(UIStyle.label("PICK 1 OF %d  //  EXCLUDES %s" % [others.size() + 1, ", ".join(names2)], 10, UIStyle.BONE_DIM))
	var cls := str(d.get("class", ""))
	if cls != "":
		var cnm := str(spec_row(cls).get("name", cls.capitalize())).to_upper()
		if cls == current_spec():
			v.add_child(UIStyle.label("%s SPECIALIZATION  //  YOURS" % cnm, 10, _accent(str(d.branch))))
		else:
			var os := UIStyle.label(refusal_text(id, "other_spec", "") if r == 0 else "%s SPECIALIZATION  //  KEPT, RUNS AGAIN WHEN YOU CHOOSE %s" % [cnm, cnm], 10, _accent(str(d.branch)).lightened(0.2))
			os.name = "OtherSpec"
			os.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			os.custom_minimum_size.x = 280
			v.add_child(os)
	_tip_spec_lines(v, id)
	# footer
	v.add_child(_tip_rule())
	var f := HBoxContainer.new()
	f.add_theme_constant_override("separation", 6)
	v.add_child(f)
	var act := ""
	var act_col := UIStyle.BONE
	match st:
		"maxed":
			act = "MAXED"
			act_col = UIStyle.OLIVE.lightened(0.35)
		"excluded":
			act = "RESPEC TO SWAP"
			act_col = UIStyle.BONE_DIM
		"locked":
			act = "LOCKED"
			act_col = UIStyle.BONE_DIM
		"other_spec":
			act = "CHOOSE %s TO SPEND HERE" % str(spec_row(str(d.get("class", ""))).get("name", "")).to_upper()
			act_col = UIStyle.BONE_DIM
		_:
			if Progress.can_afford(id):
				f.add_child(UIStyle.key_cap("LMB", 10))
				act = ("BUY RANK %s  //  %d PT" % [UIStyle.roman(r + 1), Progress.next_cost(id)]) if ranks > 1 else "BUY  //  %d PT" % Progress.next_cost(id)
			else:
				act = "NEED %d MORE POINT%s" % [Progress.next_cost(id) - Progress.skill_points_available(),
					"" if Progress.next_cost(id) - Progress.skill_points_available() == 1 else "S"]
				act_col = UIStyle.BAD
	f.add_child(UIStyle.label(act, 11, act_col))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f.add_child(sp)
	f.add_child(UIStyle.label("%d PTS LEFT" % Progress.skill_points_available(), 11, UIStyle.BONE_DIM))
	_tooltip.visible = true
	_tooltip.reset_size()
	_place_tooltip(id)
	_place_tooltip.call_deferred(id)


## SkillSpec extras (Characters live): stat before -> after for the next rank, why an owned node isn't running,
## and the free-undo hint for picks made this visit.
func _tip_spec_lines(v: VBoxContainer, id: String) -> void:
	var sp := spec()
	if sp == null:
		return
	var pv: Dictionary = sp.preview(id)
	var lines: Array = pv.get("lines", [])
	if not lines.is_empty():
		v.add_child(_tip_rule())
		for ln in lines:
			var unit := str(ln.get("unit", ""))
			var row := HBoxContainer.new()
			row.name = "PreviewLine"
			row.add_theme_constant_override("separation", 6)
			var lab := UIStyle.label(str(ln.get("label", ln.get("stat", ""))), 11, UIStyle.BONE_DIM)
			lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lab)
			row.add_child(UIStyle.label("%s%s  →  %s%s" % [_num(ln.get("before", 0)), unit, _num(ln.get("after", 0)), unit], 11, UIStyle.GOOD))
			v.add_child(row)
	var why := str(sp.inactive_reason(id))
	if why != "" and Progress.rank(id) > 0:
		var w := UIStyle.label(why.to_upper(), 10, UIStyle.BAD.lightened(0.15))
		w.name = "InactiveReason"
		w.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		w.custom_minimum_size.x = 260
		v.add_child(w)
	elif why != "":
		var w2 := UIStyle.label(why, 10, UIStyle.BONE_DIM)
		w2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		w2.custom_minimum_size.x = 260
		v.add_child(w2)
	if bool(sp.can_refund(id).get("ok", false)):
		var u := UIStyle.label("U / X  UNDO THIS PICK (FREE THIS VISIT)", 10, UIStyle.OLIVE.lightened(0.4))
		u.name = "UndoHint"
		v.add_child(u)


static func _num(x) -> String:
	var f := float(x)
	return str(int(f)) if is_equal_approx(f, roundf(f)) else ("%.2f" % f).rstrip("0").rstrip(".")


func _tip_rule() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(UIStyle.BONE_DIM, 0.18)
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _place_tooltip(id: String) -> void:
	if not _nodes.has(id):
		return
	var t: Control = _nodes[id]
	var rect := t.get_global_rect()
	var vp := get_viewport().get_visible_rect().size
	var sz := _tooltip.get_combined_minimum_size()
	var pos := Vector2(rect.end.x + 16, rect.position.y - 14)
	if pos.x + sz.x > vp.x - 8:
		pos.x = rect.position.x - sz.x - 16
	pos.y = clampf(pos.y, 8, vp.y - sz.y - 8)
	_tooltip.position = pos


# ---------------------------------------------------------------- drawing helpers

static func chamfer(r: Rect2, c: float, all: bool = false) -> PackedVector2Array:
	var a := r.position
	var b := r.end
	if all:
		return PackedVector2Array([Vector2(a.x + c, a.y), Vector2(b.x - c, a.y), Vector2(b.x, a.y + c), Vector2(b.x, b.y - c),
			Vector2(b.x - c, b.y), Vector2(a.x + c, b.y), Vector2(a.x, b.y - c), Vector2(a.x, a.y + c)])
	return PackedVector2Array([Vector2(a.x + c, a.y), Vector2(b.x, a.y), Vector2(b.x, b.y - c), Vector2(b.x - c, b.y),
		Vector2(a.x, b.y), Vector2(a.x, a.y + c)])


## One skill node: a focusable Button that draws its own tile, pips, cost badge, name and markers.
class SkillTile extends Button:
	var menu
	var id: String
	var def: Dictionary
	var accent: Color
	var hover := false

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		flat = true
		text = ""
		for s in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
			add_theme_stylebox_override(s, StyleBoxEmpty.new())
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _draw() -> void:
		var st: String = menu.ui_state(id)
		var r: int = Progress.rank(id)
		var ranks := int(def.get("ranks", 1))
		var typ := str(def.get("type", "passive"))
		var active := Progress.class_active(id)
		var a := 1.0 if active else 0.55
		var fill := Color(0.055, 0.058, 0.045)
		var edge: Color = menu.C_LOCKED
		var glyph_c := Color(0.32, 0.33, 0.27)
		var name_c := Color(UIStyle.BONE_DIM, 0.6)
		var bw := 2.0
		match st:
			"available":
				fill = Color(0.12, 0.075, 0.045)
				edge = UIStyle.RUST.lightened(0.2)
				glyph_c = UIStyle.BONE
				name_c = UIStyle.BONE
				bw = 3.0
			"unaffordable", "other_spec":
				fill = Color(0.07, 0.07, 0.06)
				edge = Color(UIStyle.BONE_DIM, 0.5)
				glyph_c = UIStyle.BONE_DIM
				name_c = UIStyle.BONE_DIM
			"owned":
				fill = Color(0.12, 0.13, 0.085)
				edge = UIStyle.OLIVE.lightened(0.35)
				glyph_c = UIStyle.BONE
				name_c = UIStyle.BONE
				bw = 3.0
			"maxed":
				fill = Color(0.16, 0.17, 0.10)
				edge = Color("c9d27a")
				glyph_c = Color(0.93, 0.9, 0.8)
				name_c = UIStyle.BONE
				bw = 4.0
			"excluded":
				fill = Color(0.07, 0.05, 0.04)
				edge = menu.C_EXCL
				glyph_c = Color(0.32, 0.24, 0.2)
				name_c = Color(0.42, 0.37, 0.31)
		edge.a *= a
		var rect := Rect2(Vector2.ZERO, size)
		var cut := size.x * (0.24 if typ == "keystone" else 0.26)
		var poly: PackedVector2Array
		if typ == "keystone":
			poly = menu.chamfer(rect, cut, true)
		elif typ == "capstone":
			poly = PackedVector2Array([Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, size.y * 0.78), Vector2(size.x * 0.5, size.y), Vector2(0, size.y * 0.78)])
		else:
			poly = menu.chamfer(rect, cut)
		if typ == "keystone": # dashed outer frame
			var outer: PackedVector2Array = menu.chamfer(rect.grow(5), cut + 3, true)
			outer.append(outer[0])
			for i in outer.size() - 1:
				_dash(outer[i], outer[i + 1], Color(edge, 0.6 * a), 1.5, 5.0, 4.0)
		draw_colored_polygon(poly, Color(fill, 0.96 * a))
		if st == "excluded": # hatching + slash
			for k in range(-int(size.y / 8.0) - 1, int(size.x / 8.0) + 2):
				var x0 := k * 8.0
				var p0 := Vector2(x0, size.y)
				var p1 := Vector2(x0 + size.y, 0)
				var seg := Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([p0, p1]), poly)
				for sgm in seg:
					draw_polyline(sgm, Color(0.16, 0.10, 0.07, a), 3.0)
			draw_line(Vector2(-4, size.y + 4), Vector2(size.x + 4, -4), Color(0.55, 0.23, 0.15, a), 3.0)
		var closed := poly.duplicate()
		closed.append(poly[0])
		draw_polyline(closed, edge, bw)
		# accent tick on the top edge, right of the chamfer
		draw_rect(Rect2(cut + 2, -1, 10, 3), Color(accent, a))
		# glyph
		var f: Font = UIStyle.FONT_STENCIL
		var fs := 18 if typ == "keystone" else 15
		var icon_tex := UIStyle.skill_icon_tex(str(def.get("icon", id)))
		if icon_tex != null: # icon art, tinted by state (glyph_c), initials as fallback
			var isz := size.x * (0.86 if typ == "keystone" else 0.82)
			var ic := Rect2((size.x - isz) * 0.5, (size.y - isz) * 0.5 - (3 if typ == "capstone" else 0), isz, isz)
			var tint := Color(1, 1, 1, a)
			match st:
				"locked": tint = Color(0.42, 0.42, 0.38, 0.75 * a)
				"unaffordable", "other_spec": tint = Color(0.72, 0.70, 0.64, a)
				"excluded": tint = Color(0.45, 0.33, 0.28, 0.7 * a)
			draw_texture_rect(icon_tex, ic, false, tint)
		else:
			var g := UIStyle.initials(str(def.name))
			var gs := f.get_string_size(g, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
			draw_string(f, Vector2((size.x - gs.x) * 0.5, size.y * 0.5 + fs * 0.36 - (3 if typ == "capstone" else 0)), g,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(glyph_c, a))
		var bf: Font = UIStyle.body_bold()
		# type markers
		if typ == "active":
			draw_rect(Rect2(-5, size.y - 10, 13, 13), Color(0.04, 0.04, 0.035, a))
			draw_rect(Rect2(-5, size.y - 10, 13, 13), Color(edge, a), false, 1.5)
			draw_string(bf, Vector2(-2, size.y + 1), "A", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(glyph_c, a))
		elif typ == "capstone": # stacked cards glyph
			for k in 2:
				var cr := Rect2(size.x - 6 + k * 4, size.y - 16 - k * 3, 9, 12)
				draw_rect(cr, Color(0.04, 0.04, 0.035, a))
				draw_rect(cr, Color(edge, a), false, 1.5)
		# cost badge (next rank) while buyable
		if st in ["available", "unaffordable", "owned", "other_spec"]:
			var c := str(Progress.next_cost(id))
			var cw := maxf(bf.get_string_size(c, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x + 6, 13)
			var br := Rect2(size.x - cw + 6, -7, cw, 13)
			var cc := UIStyle.RUST.lightened(0.25) if Progress.can_afford(id) else UIStyle.BAD
			draw_rect(br, Color(0.04, 0.04, 0.035, a))
			draw_rect(br, Color(cc, a), false, 1.5)
			draw_string(bf, Vector2(br.position.x + 3, br.end.y - 2.5), c, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(cc, a))
		var y := size.y + 4
		if typ == "keystone":
			y = size.y + 8 # below the dashed outer frame (grow 5), not across it
			var kt := "KEYSTONE"
			var kw := bf.get_string_size(kt, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x + 8
			draw_rect(Rect2((size.x - kw) * 0.5, y, kw, 10), Color(edge, 0.9 * a))
			draw_string(bf, Vector2((size.x - kw) * 0.5 + 4, y + 8), kt, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.05, 0.05, 0.04))
			y += 13
		if ranks > 1: # skewed rank pips
			var pw := 9.0
			var total := ranks * pw + (ranks - 1) * 3.0
			var x := (size.x - total) * 0.5
			for i in ranks:
				var px := x + i * (pw + 3.0)
				var pip := PackedVector2Array([Vector2(px + 2, y), Vector2(px + pw + 2, y), Vector2(px + pw, y + 5), Vector2(px, y + 5)])
				draw_colored_polygon(pip, Color(UIStyle.OLIVE.lightened(0.4), a) if i < r else Color(0.2, 0.2, 0.16, a))
			y += 8
		if st == "maxed":
			var mt := "MAX"
			var mw := bf.get_string_size(mt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x + 6
			draw_rect(Rect2((size.x - mw) * 0.5, -10, mw, 10), Color(UIStyle.OLIVE.lightened(0.35), a))
			draw_string(bf, Vector2((size.x - mw) * 0.5 + 3, -2), mt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.05, 0.05, 0.04))
		# name on a dark plate (connectors pass behind it)
		var nm := str(def.name).to_upper()
		var nw: float = menu.name_width()
		var nsz := bf.get_multiline_string_size(nm, HORIZONTAL_ALIGNMENT_CENTER, nw, 10, 2)
		var nx := (size.x - nw) * 0.5
		draw_rect(Rect2((size.x - nsz.x) * 0.5 - 2, y, nsz.x + 4, nsz.y + 1), Color(0.045, 0.047, 0.037, 0.95))
		draw_multiline_string(bf, Vector2(nx, y + 9), nm, HORIZONTAL_ALIGNMENT_CENTER, nw, 10, 2, Color(name_c, a))
		y += nsz.y + 1
		if st == "excluded":
			var ex: String = Progress.excluded_by(id)
			var tk := "TAKEN: " + str(Progress.get_skill(ex).get("name", ex)).to_upper()
			var tw := bf.get_string_size(tk, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
			draw_string(bf, Vector2((size.x - tw) * 0.5, y + 8), tk, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.62, 0.35, 0.25))
		# Playtest #29: no per-tile "<CLASS> ONLY" tape any more. Above the tile it collided with the cost badge / MAX
		# stamp, and lower down it read as part of the row above. The CLASS LINES dock already labels each class row
		# (YOUR CLASS / INACTIVE), inactive tiles are dimmed, and the info box says "<CLASS> ONLY".
		# focus / hover brackets
		if has_focus() or hover:
			var g2 := rect.grow(7)
			var L := 9.0
			var bc := Color(UIStyle.BONE, 0.95 if has_focus() else 0.6)
			for cnr in [[g2.position, Vector2(1, 0), Vector2(0, 1)], [Vector2(g2.end.x, g2.position.y), Vector2(-1, 0), Vector2(0, 1)],
					[Vector2(g2.position.x, g2.end.y), Vector2(1, 0), Vector2(0, -1)], [g2.end, Vector2(-1, 0), Vector2(0, -1)]]:
				draw_line(cnr[0], cnr[0] + cnr[1] * L, bc, 2.5)
				draw_line(cnr[0], cnr[0] + cnr[2] * L, bc, 2.5)

	func _dash(p0: Vector2, p1: Vector2, c: Color, w: float, on: float, off: float) -> void:
		var d := p0.distance_to(p1)
		var dir := (p1 - p0) / maxf(d, 0.001)
		var t := 0.0
		while t < d:
			draw_line(p0 + dir * t, p0 + dir * minf(t + on, d), c, w)
			t += on + off

	## Local y where the name plate starts (below the KEYSTONE tag and rank pips), same steps as _draw.
	func name_top() -> float:
		var y := size.y + 4
		if str(def.get("type", "")) == "keystone":
			y = size.y + 8 + 13
		if int(def.get("ranks", 1)) > 1:
			y += 8
		return y

	## Canvas-space rect of the name plate (playtest #29 layout checks).
	func name_rect() -> Rect2:
		var bf: Font = UIStyle.body_bold()
		var nm := str(def.name).to_upper()
		var nsz := bf.get_multiline_string_size(nm, HORIZONTAL_ALIGNMENT_CENTER, menu.name_width(), 10, 2)
		return Rect2(position + Vector2((size.x - nsz.x) * 0.5 - 2, name_top()), Vector2(nsz.x + 4, nsz.y + 1))

	## Canvas-space rect of the tile including the keystone's dashed frame and the cost badge above.
	func body_rect() -> Rect2:
		var r := Rect2(position, size)
		return r.grow(5) if str(def.get("type", "")) == "keystone" else r.grow_individual(0, 7, 6, 0)


## Connectors, OR / ANY chips and the keystone guide line (one draw pass for the whole canvas).
class Wires extends Control:
	var menu
	var keystone_label_rect := Rect2() ## canvas rect of the vertical KEYSTONE label (tests)

	func _draw() -> void:
		var defs: Dictionary = menu._defs
		var bf: Font = UIStyle.body_bold()
		# keystone guide line (skips the class dock in the middle)
		var ky := -1.0
		for id in defs:
			if str(defs[id].get("type", "")) == "keystone" and str(defs[id].get("class", "")) == "":
				ky = maxf(ky, menu._grid_pos(id).y)
		if ky > 0 and menu.tab == "main":
			var y: float = ky - menu._row_h * 0.55
			# playtest #29: the label runs vertically in the left margin beside the keystone row.
			# §24: keystones no longer exclude each other; each main tree has its own.
			var ktxt := "KEYSTONES · ONE PER TREE"
			var tw: float = bf.get_string_size(ktxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			draw_set_transform(Vector2(13, ky + tw * 0.5), -PI * 0.5)
			draw_string(bf, Vector2.ZERO, ktxt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.8, 0.35, 0.28, 0.9))
			draw_set_transform(Vector2.ZERO)
			keystone_label_rect = Rect2(Vector2(13 - 9, ky - tw * 0.5), Vector2(11, tw))
			_dash(Vector2(menu.ORIGIN.x - menu._key_tile * 0.5 - 10, y), Vector2(size.x - 12, y), Color(0.7, 0.25, 0.2, 0.45), 1.0, 6, 4)
		var chips := []
		for id in defs:
			var d: Dictionary = defs[id]
			for req in d.get("requires", []):
				_edge(req, id, false)
			var any_of: Array = d.get("requires_any", [])
			for req in any_of:
				_edge(req, id, true)
			if not any_of.is_empty():
				chips.append(["ANY 1", menu._grid_pos(id) + Vector2(0, -_half(id) - 12)])
		# OR chips between members of the same (non-keystone) choice group on the same row
		var groups := {}
		for id in defs:
			var g := str(defs[id].get("choice_group", ""))
			if g != "" and g != "keystone":
				if not groups.has(g):
					groups[g] = []
				groups[g].append(id)
		for g in groups:
			var ids: Array = groups[g]
			for i in range(1, ids.size()):
				chips.append(["OR", (menu._grid_pos(ids[i - 1]) + menu._grid_pos(ids[i])) * 0.5])
		for c in chips:
			var t: String = c[0]
			var sz := bf.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9)
			var r := Rect2(c[1] - Vector2(sz.x * 0.5 + 4, 7), Vector2(sz.x + 8, 13))
			draw_rect(r, Color(0.045, 0.047, 0.037))
			draw_rect(r, Color(UIStyle.BONE_DIM, 0.45), false, 1.0)
			draw_string(bf, Vector2(r.position.x + 4, r.end.y - 3), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, UIStyle.BONE_DIM)

	func _half(id: String) -> float:
		return (menu._key_tile if str(menu._defs[id].get("type", "")) == "keystone" else menu._tile) * 0.5

	func _edge(from_id: String, to_id: String, any: bool) -> void:
		if not menu._defs.has(from_id):
			return
		var a: Vector2 = menu._grid_pos(from_id)
		var b: Vector2 = menu._grid_pos(to_id)
		var need := int(menu._defs[to_id].get("requires_rank", {}).get(from_id, 1))
		var lit := Progress.rank(from_id) >= need
		var to_st: String = menu.ui_state(to_id)
		var to_owned := Progress.rank(to_id) > 0
		var col := Color(0.2, 0.21, 0.165)
		var w := 3.0
		if lit and to_owned:
			col = UIStyle.OLIVE.lightened(0.3)
			w = 4.0
		elif lit and to_st in ["available", "unaffordable"]:
			col = UIStyle.RUST.lightened(0.15)
		elif to_st == "excluded":
			col = Color(0.26, 0.16, 0.12)
		var pts: PackedVector2Array
		if absf(a.y - b.y) < 2.0:
			pts = PackedVector2Array([a + Vector2(_half(from_id), 0), b - Vector2(_half(to_id), 0)])
		else:
			var mid := b.y - _half(to_id) - 12.0
			pts = PackedVector2Array([a + Vector2(0, _half(from_id)), Vector2(a.x, mid), Vector2(b.x, mid), b - Vector2(0, _half(to_id))])
		for i in pts.size() - 1:
			if lit:
				draw_line(pts[i], pts[i + 1], col, w)
			else:
				_dash(pts[i], pts[i + 1], col, w, 3.0 if any else 7.0, 5.0)

	func _dash(p0: Vector2, p1: Vector2, c: Color, w: float, on: float, off: float) -> void:
		var d := p0.distance_to(p1)
		var dir := (p1 - p0) / maxf(d, 0.001)
		var t := 0.0
		while t < d:
			draw_line(p0 + dir * t, p0 + dir * minf(t + on, d), c, w)
			t += on + off
