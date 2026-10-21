extends MenuBase
## Gooey, playtest #21 + #9: CHARACTERS screen (home header chip).
##   left : character slots (separate saves, Characters.MAX_CHARACTERS) + "+ NEW CHARACTER"
##   right: the picked character: PLAY AS / RENAME / DELETE (two-step, Characters.request_delete token),
##          and for the character you're playing its LOADOUT: class (4) + Q ability (#9).
##          A free slot shows the create form (name + class).
## Talks to Skillz's Characters autoload (CHARACTER_API.md). Until that autoload is live (MAIN_HOOKS §23a) the screen
## shows the current save as the only character and says why slots are off. Class items show on item cards (Kit).

const NEW_ID := -1
const CONFIRM_S := 8.0

signal character_switched(id: int)

var selected_id: int = 0 ## 0 = the active one, NEW_ID = create form
var slot_buttons: Dictionary = {} ## character id (int) / "new" -> Button
var class_buttons: Dictionary = {} ## class id -> Button
var ability_buttons: Dictionary = {} ## ability id -> Button
var play_button: Button
var delete_button: Button
var rename_button: Button
var rename_edit: LineEdit
var create_button: Button
var name_edit: LineEdit
var reason_label: Label
var create_class: String = "soldier"
var _delete_token: String = ""
var _delete_t: float = 0.0
var _left: VBoxContainer
var _right: VBoxContainer


func _init() -> void:
	super._init()
	layer = 12


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(1180, 640)
	var c := chars()
	if c:
		c.characters_changed.connect(_on_changed)


func _on_changed() -> void:
	if visible:
		refresh()


## Characters autoload when it's live (bound to the save), else null.
func chars() -> Node:
	var c := get_node_or_null("/root/Characters")
	if c and c.has_method("is_bound") and c.is_bound():
		return c
	return null


func is_live() -> bool:
	return chars() != null


func entries() -> Array:
	var c := chars()
	if c:
		return c.list()
	var st := get_node_or_null("/root/Settings")
	var nm := str(st.get("player_name")) if st and str(st.get("player_name")) != "" else "Survivor"
	var cls := str(Progress.selected_class)
	return [{"id": 1, "name": nm, "class": cls, "class_name": cls.capitalize(), "level": Progress.get_level(), "active": true,
		"last_played": 0, "ability": ""}]


func active_id() -> int:
	var c := chars()
	return int(c.active_id()) if c else 1


func max_slots() -> int:
	var c := chars()
	return int(c.MAX_CHARACTERS) if c else 1


func entry(id: int) -> Dictionary:
	for e in entries():
		if int(e.id) == id:
			return e
	return {}


func blocked() -> String:
	var c := chars()
	return str(c.blocked_reason()) if c else "Character slots switch on with the classes update."


# ---------------------------------------------------------------- build

func refresh() -> void:
	for old in content.get_children():
		old.visible = false # queue_free lands next frame; hide now so focus / layout / tests only see the new page
	clear_content()
	slot_buttons.clear()
	class_buttons.clear()
	ability_buttons.clear()
	play_button = null
	delete_button = null
	create_button = null
	name_edit = null
	if selected_id == 0 or (selected_id != NEW_ID and entry(selected_id).is_empty()):
		selected_id = active_id()
	var head := HBoxContainer.new()
	content.add_child(head)
	head.add_child(UIStyle.label("CHARACTERS", 30, UIStyle.BONE, true, 2))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var slots := UIStyle.label("%d / %d SLOTS" % [entries().size(), max_slots()], 12, UIStyle.BONE_DIM, true)
	slots.name = "SlotCount"
	head.add_child(slots)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.75)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(body)
	_left = VBoxContainer.new()
	_left.name = "Slots"
	_left.custom_minimum_size.x = 320
	_left.add_theme_constant_override("separation", 8)
	body.add_child(_left)
	var vr := ColorRect.new()
	vr.color = Color(UIStyle.BONE_DIM, 0.18)
	vr.custom_minimum_size.x = 2
	body.add_child(vr)
	_right = VBoxContainer.new()
	_right.name = "Detail"
	_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right.add_theme_constant_override("separation", 8)
	body.add_child(_right)
	for e in entries():
		_slot_card(e)
	if is_live() and entries().size() < max_slots():
		var nb := _btn("+  NEW CHARACTER", select_slot.bind(NEW_ID))
		nb.name = "NewSlot"
		nb.custom_minimum_size.y = 50
		_left.add_child(nb)
		slot_buttons["new"] = nb
	if not is_live():
		var off := _wrap(blocked(), 12, UIStyle.BONE_DIM)
		off.name = "SlotsOff"
		_left.add_child(off)
	if selected_id == NEW_ID:
		_build_create()
	else:
		_build_detail(entry(selected_id))
	reason_label = _wrap("", 12, UIStyle.BAD.lightened(0.2))
	reason_label.name = "Reason"
	_right.add_child(reason_label)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	content.add_child(foot)
	for k in [["↑↓", "MOVE"], ["ENTER", "SELECT"], ["ESC", "BACK"]]:
		foot.add_child(UIStyle.key_cap(k[0], 11))
		foot.add_child(UIStyle.label(k[1], 11, UIStyle.BONE_DIM))
	var fsp := Control.new()
	fsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fsp)
	foot.add_child(UIStyle.label("Per character: level, skills, class, stash  //  shared: Gravemarks, Armory, Merchant", 11, UIStyle.BONE_DIM))
	_focus_selected.call_deferred()


func _wrap(t: String, fs: int, col: Color) -> Label:
	var l := UIStyle.label(t, fs, col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 200
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _btn(text: String, cb: Callable, w: float = 0.0, primary: bool = false) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(w, 40)
	b.focus_mode = Control.FOCUS_ALL
	b.clip_text = true
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", 15)
	var bg := Color(0.30, 0.16, 0.07, 0.95) if primary else Color(UIStyle.INK, 0.9)
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(bg, UIStyle.RUST if primary else UIStyle.BONE_DIM, 2, 8))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 2, 8))
	b.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.BONE, 3, 8))
	b.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(UIStyle.INK, 0.6), Color(UIStyle.BONE_DIM, 0.3), 2, 8))
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.add_theme_color_override("font_disabled_color", Color(UIStyle.BONE_DIM, 0.45))
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	return b


func _slot_card(e: Dictionary) -> void:
	var id := int(e.id)
	var b := _btn("", select_slot.bind(id))
	b.name = "Slot_%d" % id
	b.custom_minimum_size = Vector2(0, 72)
	if id == selected_id:
		b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.95), UIStyle.RUST, 3, 8))
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 12
	box.offset_top = 7
	box.offset_right = -10
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(box)
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(top)
	var nm := UIStyle.label(str(e.name).to_upper(), 18, UIStyle.BONE, true)
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(nm)
	if bool(e.get("active", false)):
		top.add_child(UIStyle.label("PLAYING", 11, UIStyle.GOOD, true))
	box.add_child(UIStyle.label("LV %d  //  %s  //  Q %s" % [int(e.get("level", 1)), str(e.get("class_name", e.get("class", ""))).to_upper(),
		str(e.get("ability_name", e.get("ability", ""))).to_upper()], 12, UIStyle.BONE_DIM, true))
	var meta := UIStyle.label("BEST ROUND %d  //  %d GAMES" % [int(e.get("best_round", 0)), int(e.get("games_played", 0))], 11, Color(UIStyle.BONE_DIM, 0.8))
	meta.name = "SlotMeta"
	box.add_child(meta)
	_left.add_child(b)
	slot_buttons[id] = b


func _section(title: String) -> void:
	var l := UIStyle.label(title, 13, UIStyle.RUST.lightened(0.25), true)
	_right.add_child(l)


func _build_detail(e: Dictionary) -> void:
	if e.is_empty():
		return
	var id := int(e.id)
	var active := bool(e.get("active", false))
	var nm := UIStyle.label(str(e.name).to_upper(), 28, UIStyle.BONE, true, 2)
	nm.name = "DetailName"
	nm.clip_text = true
	_right.add_child(nm)
	_right.add_child(UIStyle.label("LEVEL %d  //  %s  //  BEST ROUND %d  //  %d GAMES%s" % [int(e.get("level", 1)), str(e.get("class_name", "")).to_upper(),
		int(e.get("best_round", 0)), int(e.get("games_played", 0)), "  //  PLAYING NOW" if active else ""], 13, UIStyle.BONE_DIM, true))
	var acts := HBoxContainer.new()
	acts.add_theme_constant_override("separation", 10)
	_right.add_child(acts)
	var why := blocked()
	play_button = _btn("PLAYING" if active else "PLAY AS %s" % str(e.name).to_upper(), switch_to.bind(id), 250, not active)
	play_button.name = "PlayAs"
	play_button.disabled = active or why != ""
	acts.add_child(play_button)
	var confirming := _delete_t > 0.0 and _delete_token != ""
	delete_button = _btn("CONFIRM DELETE (CAN'T UNDO)" if confirming else "DELETE", delete_selected, 250 if confirming else 130)
	delete_button.name = "Delete"
	delete_button.disabled = why != "" or entries().size() <= 1
	if confirming:
		delete_button.add_theme_color_override("font_color", UIStyle.BAD)
	acts.add_child(delete_button)
	if is_live():
		var rn := HBoxContainer.new()
		rn.add_theme_constant_override("separation", 10)
		_right.add_child(rn)
		rename_edit = LineEdit.new()
		rename_edit.name = "RenameEdit"
		rename_edit.max_length = int(chars().NAME_MAX)
		rename_edit.text = str(e.name)
		rename_edit.custom_minimum_size = Vector2(280, 38)
		rename_edit.text_submitted.connect(func(_t): rename_selected())
		rn.add_child(rename_edit)
		rename_button = _btn("RENAME", rename_selected, 130)
		rename_button.name = "Rename"
		rn.add_child(rename_button)
	if active:
		_build_loadout()
	else:
		_right.add_child(_wrap("Switch to this character to change its class and Q ability.", 12, UIStyle.BONE_DIM))


## #9: class + Q ability for the character you're playing (Characters.loadout()).
func _build_loadout() -> void:
	var c := chars()
	if c == null:
		_section("CLASS")
		_right.add_child(_wrap("Class: %s. (Pick it on the game-over screen until the classes update is switched on.)" % str(Progress.selected_class).capitalize(), 12, UIStyle.BONE_DIM))
		return
	var lo: Dictionary = c.loadout()
	var locked := str(lo.get("blocked", ""))
	_section("CLASS  //  NEXT MATCH SPAWNS AS")
	var row := HBoxContainer.new()
	row.name = "Classes"
	row.add_theme_constant_override("separation", 8)
	_right.add_child(row)
	var cur: Dictionary = {}
	for k in lo.get("classes", []):
		var on := bool(k.get("selected", false))
		if on:
			cur = k
		var b := _btn(("● " if on else "") + str(k.get("name", k.id)).to_upper(), set_class.bind(str(k.id)), 0, on)
		b.name = "Class_" + str(k.id)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = locked != "" and not on
		b.tooltip_text = str(k.get("role", ""))
		row.add_child(b)
		class_buttons[str(k.id)] = b
	if not cur.is_empty():
		var stats := "%s  //  %d HP  //  WALK %.1f  //  SPRINT %.1f  //  %s GRENADE" % [str(cur.get("role", "")).to_upper(),
			int(cur.get("max_health", 100)), float(cur.get("walk_speed", 5.0)), float(cur.get("sprint_speed", 8.5)),
			str(cur.get("grenade_id", "frag")).replace("_", " ").to_upper()]
		var sl := UIStyle.label(stats, 12, UIStyle.BONE, true)
		sl.name = "ClassStats"
		_right.add_child(sl)
		var dl := _wrap(str(cur.get("description", "")), 12, UIStyle.BONE_DIM)
		dl.name = "ClassBlurb"
		_right.add_child(dl)
		_section("Q ABILITY")
		var ar := HBoxContainer.new()
		ar.name = "Abilities"
		ar.add_theme_constant_override("separation", 8)
		_right.add_child(ar)
		var pick := str(lo.get("ability", ""))
		var pick_row: Dictionary = {}
		for a in cur.get("abilities", []):
			var on2 := str(a.id) == pick
			if on2:
				pick_row = a
			var ab := _btn(("● " if on2 else "") + str(a.get("name", a.id)).to_upper(), set_ability.bind(str(cur.id), str(a.id)), 0, on2)
			ab.name = "Ability_" + str(a.id)
			ab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			ab.disabled = locked != "" and not on2
			ar.add_child(ab)
			ability_buttons[str(a.id)] = ab
		if not pick_row.is_empty():
			var at := "%s  //  %ss COOLDOWN%s  //  %s" % [str(pick_row.get("kind", "")).to_upper(), ("%.1f" % float(pick_row.get("cooldown", 0))).trim_suffix(".0"),
				("  //  LASTS %ss" % ("%.1f" % float(pick_row.get("duration", 0))).trim_suffix(".0")) if float(pick_row.get("duration", 0)) >= 0.5 else "", str(pick_row.get("summary", ""))]
			var al := _wrap(at, 12, UIStyle.BONE_DIM)
			al.name = "AbilitySummary"
			_right.add_child(al)
		_build_class_items(str(cur.id))
	if locked != "":
		_right.add_child(_wrap(locked, 12, UIStyle.BAD.lightened(0.2)))


## #9: the class items this character owns for the picked class (ClassItems.owned_rows), equipped first.
func _build_class_items(cid: String) -> void:
	var rows: Array = ClassItems.owned_rows(cid)
	_section("%s CLASS ITEMS  //  %d OWNED" % [cid.to_upper(), rows.size()])
	var box := VBoxContainer.new()
	box.name = "ClassItems"
	box.add_theme_constant_override("separation", 2)
	_right.add_child(box)
	if rows.is_empty():
		var none := _wrap("None yet. Class items drop in matches; they work only while you play this class.", 12, UIStyle.BONE_DIM)
		none.name = "ClassItemsNone"
		box.add_child(none)
		return
	for r in rows.slice(0, 3):
		var h := HBoxContainer.new()
		h.name = "ClassItemRow"
		h.add_theme_constant_override("separation", 8)
		box.add_child(h)
		var nm := UIStyle.label(("● " if bool(r.get("equipped", false)) else "") + str(r.get("name", "")).to_upper(), 13, UIStyle.rarity_color(int(r.get("rarity", 0))), true)
		nm.custom_minimum_size.x = 210
		nm.clip_text = true
		h.add_child(nm)
		var ln := str(r.get("line", ""))
		if bool(r.get("synergy_owned", false)) and str(r.get("synergy_line", "")) != "":
			ln += "  +  " + str(r.synergy_line)
		var l := _wrap(ln, 11, UIStyle.BONE if bool(r.get("active", false)) else UIStyle.BONE_DIM)
		h.add_child(l)
	if rows.size() > 3:
		box.add_child(UIStyle.label("+ %d MORE IN YOUR KIT" % (rows.size() - 3), 11, UIStyle.BONE_DIM))


func _build_create() -> void:
	_right.add_child(UIStyle.label("NEW CHARACTER", 28, UIStyle.BONE, true, 2))
	_right.add_child(_wrap("A fresh save: level 1, its own skills, class and stash. Gravemarks, Armory and Merchant are shared.", 13, UIStyle.BONE_DIM))
	_section("NAME")
	name_edit = LineEdit.new()
	name_edit.name = "NameEdit"
	var c := chars()
	name_edit.max_length = int(c.NAME_MAX) if c else 20
	name_edit.placeholder_text = "Survivor name"
	name_edit.custom_minimum_size = Vector2(360, 40)
	name_edit.add_theme_font_size_override("font_size", 18)
	name_edit.text_changed.connect(func(_t): _refresh_create())
	name_edit.text_submitted.connect(func(_t): create_now())
	_right.add_child(name_edit)
	_section("CLASS")
	var row := HBoxContainer.new()
	row.name = "Classes"
	row.add_theme_constant_override("separation", 8)
	_right.add_child(row)
	for cid in ClassRoster.ids():
		var d := ClassRoster.describe(cid)
		var on := cid == create_class
		var b := _btn(("● " if on else "") + str(d.get("name", cid)).to_upper(), pick_create_class.bind(cid), 0, on)
		b.name = "Class_" + cid
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
		class_buttons[cid] = b
	var dsc := ClassRoster.describe(create_class)
	_right.add_child(_wrap("%s: %s" % [str(dsc.get("role", "")).to_upper(), str(dsc.get("description", ""))], 12, UIStyle.BONE_DIM))
	create_button = _btn("CREATE + PLAY AS", create_now, 260, true)
	create_button.name = "Create"
	_right.add_child(create_button)
	_refresh_create.call_deferred()


func _refresh_create() -> void:
	if create_button == null or not is_instance_valid(create_button) or name_edit == null:
		return
	var c := chars()
	var why := blocked()
	if why == "" and c:
		why = str(c.validate_name(name_edit.text))
	create_button.disabled = why != ""
	if reason_label and is_instance_valid(reason_label):
		reason_label.text = "" if name_edit.text.strip_edges() == "" else why


func _focus_selected() -> void:
	if not visible:
		return
	if selected_id == NEW_ID:
		if name_edit and is_instance_valid(name_edit):
			name_edit.grab_focus()
		return
	if slot_buttons.has(selected_id):
		(slot_buttons[selected_id] as Button).grab_focus()


func _say(r) -> bool:
	var ok: bool = r is Dictionary and bool(r.get("ok", false))
	if not ok and reason_label and is_instance_valid(reason_label):
		reason_label.text = str(r.get("reason", "")) if r is Dictionary else ""
	return ok


# ---------------------------------------------------------------- actions (public: tests drive these)

func select_slot(id: int) -> void:
	_ui_snd("ui_hover")
	_delete_token = ""
	_delete_t = 0.0
	selected_id = id
	refresh()


func switch_to(id: int) -> bool:
	var c := chars()
	if c == null:
		return false
	var r: Dictionary = c.select(id)
	if bool(r.ok):
		_ui_snd("ui_equip")
		c.enter_home() # new character: reopen the home respec window / undo session for it
		character_switched.emit(id)
	refresh()
	return _say(r)


func delete_selected() -> bool:
	var c := chars()
	if c == null or selected_id == NEW_ID:
		return false
	if _delete_token == "" or _delete_t <= 0.0:
		var q: Dictionary = c.request_delete(selected_id)
		if not bool(q.ok):
			return _say(q)
		_delete_token = str(q.token)
		_delete_t = CONFIRM_S
		refresh()
		return false
	var r: Dictionary = c.delete(selected_id, _delete_token)
	_delete_token = ""
	_delete_t = 0.0
	if bool(r.ok):
		_ui_snd("ui_scrap_dismantle")
		selected_id = 0
	refresh()
	return _say(r)


func rename_selected() -> bool:
	var c := chars()
	if c == null or rename_edit == null:
		return false
	var r: Dictionary = c.rename(selected_id, rename_edit.text)
	refresh()
	return _say(r)


func pick_create_class(cid: String) -> void:
	create_class = cid
	var keep := name_edit.text if name_edit else ""
	refresh()
	name_edit.text = keep
	name_edit.caret_column = keep.length()
	_refresh_create()


func create_now() -> bool:
	var c := chars()
	if c == null or name_edit == null:
		return false
	var r: Dictionary = c.create(name_edit.text, create_class, true)
	if not bool(r.ok):
		return _say(r)
	selected_id = int(r.id)
	c.enter_home()
	_ui_snd("ui_equip")
	character_switched.emit(selected_id)
	refresh()
	return true


func set_class(cid: String) -> bool:
	var c := chars()
	if c == null:
		return false
	var r: Dictionary = c.set_class(cid)
	if bool(r.ok):
		_ui_snd("ui_equip")
		c.enter_home() # set_class ends the undo session; home keeps one open
	refresh()
	return _say(r)


func set_ability(cid: String, aid: String) -> bool:
	var c := chars()
	if c == null:
		return false
	var r: Dictionary = c.set_ability(cid, aid)
	if bool(r.ok):
		_ui_snd("ui_equip")
	refresh()
	return _say(r)


func _process(delta: float) -> void:
	if _delete_t > 0.0:
		_delete_t -= delta
		if _delete_t <= 0.0:
			_delete_token = ""
			if visible:
				refresh()


## Header chip text for the home screen: "NAME  //  LV n  //  CLASS".
func chip_text() -> String:
	var e := entry(active_id())
	if e.is_empty():
		return "CHARACTER"
	return "%s  //  LV %d  //  %s" % [str(e.name).to_upper(), int(e.get("level", 1)), str(e.get("class_name", "")).to_upper()]
