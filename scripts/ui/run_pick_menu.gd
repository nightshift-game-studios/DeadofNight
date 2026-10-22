extends MenuBase
## Field Card chooser (Gooey). main.gd instances this automatically (RUN_PICK_MENU_PATH) instead of the TEMP
## chooser. Talks to the backend only through RunState: shows on offer_ready (also re-emitted after a reroll or
## banish), hides on offer_closed, and resolves with choose / reroll / skip / banish. main.gd owns pausing.
## Keys: 1-4 take, arrows / d-pad move, Enter / A take focused, R / pad Y reroll, S / pad X skip,
## B / pad B toggles banish mode (then 1-4 or click banishes), or click a card's X.

const CARD_W := 262.0
const CARD_H := 372.0
const NUM_COL := "8fd16a"

var _entries: Array = []
var _milestone: bool = false
var _banish_mode: bool = false
var card_buttons: Array = [] ## Button per offer slot (tests)
var _cards_row: HBoxContainer
var _round_label: Label
var _title: Label
var _sub: RichTextLabel
var _points: Label
var _run_list: VBoxContainer
var _run_head: Label
var _reroll_btn: Button
var _skip_btn: Button
var _banish_btn: Button
var _hint: RichTextLabel
var _focus_slot: int = 0
var toast_label: Label ## co-op reroll refusal toast (RunState.reroll_refused -> friendly last_refusal_reason)
var refusal_label: Label ## NET M13 name for the same label (== toast_label)
var _toast_t: float = 0.0
var _seen_pending: bool = false ## last RunState.reroll_pending we drew (host answer pending -> reroll disabled)

## RunState.last_refusal_reason -> player text. Unknown reasons fall back to a generic line.
const REFUSAL_TEXT := {
	"not_enough_points": "Not enough points for that reroll",
	"points": "Not enough points for that reroll",
	"timeout": "Host didn't answer. Reroll not charged",
	"busy": "Host is busy. Try the reroll again",
	"offer_closed": "Offer closed. Reroll not charged",
}
const TOAST_SECS := 2.8


func _init() -> void:
	super._init()
	layer = 11


func _ready() -> void:
	super._ready()
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	panel.get_child(0).visible = false # no grit sheet: cards float on the backdrop
	panel.custom_minimum_size = Vector2(0, 0)
	content.add_theme_constant_override("separation", 6)
	_build()
	RunState.offer_ready.connect(_on_offer_ready)
	RunState.offer_closed.connect(_on_offer_closed)
	RunState.rerolled.connect(func(_c, _f): _ui_snd("ui_equip"))
	RunState.banished.connect(func(_i): _ui_snd("ui_scrap_dismantle"))
	RunState.cards_changed.connect(_refresh_run_list)
	if RunState.has_signal("reroll_refused"): # co-op paid reroll refused / timed out by the host (Netz M13)
		RunState.reroll_refused.connect(_on_reroll_refused)


# ---------------------------------------------------------------- build

func _build() -> void:
	_round_label = UIStyle.label("", 12, UIStyle.BLOOD.lightened(0.25), true)
	_round_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_round_label)
	_title = UIStyle.label("", 34, UIStyle.BONE, true, 2)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_title)
	_sub = _rich(12, CARD_W * 3)
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_sub)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	content.add_child(gap)
	_cards_row = HBoxContainer.new()
	_cards_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_cards_row.add_theme_constant_override("separation", 20)
	_cards_row.custom_minimum_size = Vector2(0, CARD_H + 12)
	content.add_child(_cards_row)
	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 8)
	content.add_child(gap2)
	var acts := HBoxContainer.new()
	acts.alignment = BoxContainer.ALIGNMENT_CENTER
	acts.add_theme_constant_override("separation", 16)
	content.add_child(acts)
	_reroll_btn = _action_btn("R", acts, do_reroll)
	_skip_btn = _action_btn("S", acts, do_skip)
	_banish_btn = _action_btn("B", acts, toggle_banish)
	toast_label = UIStyle.label("", 13, UIStyle.BAD.lightened(0.2), true)
	toast_label.name = "RerollToast"
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.modulate.a = 0.0
	content.add_child(toast_label)
	refusal_label = toast_label
	_hint = _rich(11, 900)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_hint)
	# points (top right) and THIS RUN list (left), outside the centred column
	var pts_box := VBoxContainer.new()
	pts_box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	pts_box.position = Vector2(-200, 20)
	pts_box.size = Vector2(176, 80)
	pts_box.add_theme_constant_override("separation", -4)
	add_child(pts_box)
	var pl := UIStyle.label("POINTS", 10, UIStyle.BONE_DIM, true)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pts_box.add_child(pl)
	_points = UIStyle.label("0", 30, UIStyle.BONE, true, 2)
	_points.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pts_box.add_child(_points)
	var pp := UIStyle.label("GAME PAUSED // BREAK STARTS AFTER PICK", 9, UIStyle.BONE_DIM)
	pp.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pts_box.add_child(pp)
	_run_list = VBoxContainer.new()
	_run_list.position = Vector2(16, 120)
	_run_list.add_theme_constant_override("separation", 3)
	add_child(_run_list)


func _rich(size: int, w: float) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.custom_minimum_size = Vector2(w, 0)
	r.add_theme_font_override("normal_font", UIStyle.body_bold())
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_color_override("default_color", UIStyle.BONE)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


func _action_btn(key: String, parent: Control, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(214, 40)
	var st := UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 8)
	b.add_theme_stylebox_override("normal", st)
	var hs := st.duplicate() as StyleBoxFlat
	hs.border_color = UIStyle.BONE
	hs.bg_color = Color(0.16, 0.12, 0.08, 0.95)
	b.add_theme_stylebox_override("hover", hs)
	b.add_theme_stylebox_override("pressed", hs)
	var ds := st.duplicate() as StyleBoxFlat
	ds.border_color = Color(UIStyle.BONE_DIM, 0.3)
	ds.bg_color = Color(UIStyle.INK, 0.6)
	b.add_theme_stylebox_override("disabled", ds)
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	parent.add_child(b)
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 12
	h.offset_right = -10
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	h.add_child(UIStyle.key_cap(key, 12))
	var r := _rich(13, 0)
	r.autowrap_mode = TextServer.AUTOWRAP_OFF
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.add_theme_font_override("normal_font", UIStyle.FONT_STENCIL)
	h.add_child(r)
	b.set_meta("text", r)
	return b


# ---------------------------------------------------------------- offer flow

func _on_offer_ready(cards: Array, is_milestone: bool) -> void:
	var was_open := visible
	_entries = cards
	_milestone = is_milestone
	_banish_mode = false
	hide_toast()
	if not was_open:
		_focus_slot = 0
		_ui_snd("loot_drop_legendary" if is_milestone else "menu_open")
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	refresh()


func _on_offer_closed(result: String, _id: String) -> void:
	if not visible:
		return
	_ui_snd("ui_skill_unlock" if result == "chosen" else "points_tick")
	_ui_snd("menu_close")
	visible = false
	_banish_mode = false


func refresh() -> void:
	var n_leg := _entries.filter(func(e): return str(e.get("tier", "")) == "legendary").size()
	_round_label.text = "ROUND %d CLEARED" % RunState.offer_round
	_title.text = "MILESTONE CACHE" if _milestone else "FIELD CARDS"
	var parts := ["FIELD CARDS // PICK 1 OF %d" % _entries.size()]
	if n_leg > 0:
		parts.append("[color=#%s]%d LEGENDARY[/color] + %d NORMAL" % [UIStyle.TIER_LEGENDARY.lightened(0.35).to_html(false), n_leg, _entries.size() - n_leg])
	_sub.text = "[center][color=#%s]%s[/color][/center]" % [UIStyle.BONE_DIM.to_html(false), "  //  ".join(parts)]
	var pts: int = int(RunState.player.points) if RunState.player != null and is_instance_valid(RunState.player) else 0
	_points.text = _thousands(pts)
	_rebuild_cards()
	_refresh_actions()
	_refresh_run_list()


func _refresh_actions() -> void:
	var cost := RunState.reroll_cost()
	var rr := "REROLL  "
	if cost == 0:
		rr += "[color=#%s]FREE[/color]  [font_size=10][color=#%s]%d FREE LEFT[/color][/font_size]" % [NUM_COL, UIStyle.BONE_DIM.to_html(false), RunState.free_rerolls]
	else:
		rr += "[color=#%s]%s[/color]" % [UIStyle.BAD.to_html(false) if not RunState.can_reroll() else "e0a060", _thousands(cost)]
	_seen_pending = reroll_pending()
	if _seen_pending:
		rr = "REROLL  [color=#%s]WAITING FOR HOST...[/color]" % UIStyle.BONE_DIM.to_html(false)
	_reroll_btn.get_meta("text").text = rr
	_reroll_btn.disabled = not RunState.can_reroll()
	_skip_btn.get_meta("text").text = "SKIP  [color=#%s]+%s[/color]" % [NUM_COL, _thousands(RunState.skip_reward())]
	var max_per := int(RunState.cfg("max_banish_per_offer", 1))
	var can_b := RunState.banishes_left > 0 and RunState.banished_this_offer < max_per
	_banish_btn.get_meta("text").text = ("BANISH: PICK A CARD" if _banish_mode else "BANISH  %d LEFT" % RunState.banishes_left) + \
		"  [font_size=10][color=#%s]%d PER OFFER[/color][/font_size]" % [UIStyle.BONE_DIM.to_html(false), max_per]
	_banish_btn.disabled = not can_b
	var dim := UIStyle.BONE_DIM.to_html(false)
	if _banish_mode:
		_hint.text = "[center][color=#%s]BANISH MODE[/color] [color=#%s]//  press 1-%d or click a card to remove it from this match  //  B to cancel[/color][/center]" % [UIStyle.BAD.to_html(false), dim, _entries.size()]
	else:
		_hint.text = "[center][color=#%s]1-%d TAKE  //  ARROWS / D-PAD CHOOSE  //  ENTER / A TAKE FOCUSED  //  R / Y REROLL  //  S / X SKIP  //  B BANISH  //  GAME PAUSED[/color][/center]" % [dim, _entries.size()]
	for i in card_buttons.size():
		_style_card(i)


func _refresh_run_list() -> void:
	if _run_list == null:
		return
	for c in _run_list.get_children():
		c.queue_free()
	var owned: Array = RunState.owned_cards()
	if owned.is_empty():
		return
	var head := UIStyle.label("THIS RUN // %d" % owned.size(), 12, UIStyle.BONE, true)
	_run_list.add_child(head)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.8)
	line.custom_minimum_size = Vector2(150, 2)
	_run_list.add_child(line)
	for c in owned:
		_run_list.add_child(UIStyle.field_card_row(c, 150))


# ---------------------------------------------------------------- cards

func _rebuild_cards() -> void:
	for c in _cards_row.get_children():
		_cards_row.remove_child(c)
		c.queue_free()
	card_buttons.clear()
	for i in _entries.size():
		var b := _make_card(i, _entries[i])
		_cards_row.add_child(b)
		card_buttons.append(b)
	for i in card_buttons.size():
		var b: Button = card_buttons[i]
		b.focus_neighbor_left = b.get_path_to(card_buttons[(i - 1 + card_buttons.size()) % card_buttons.size()])
		b.focus_neighbor_right = b.get_path_to(card_buttons[(i + 1) % card_buttons.size()])
	if not card_buttons.is_empty():
		_focus_slot = clampi(_focus_slot, 0, card_buttons.size() - 1)
		(card_buttons[_focus_slot] as Button).call_deferred("grab_focus")


func _make_card(i: int, e: Dictionary) -> Button:
	var tier := str(e.get("tier", "normal"))
	var tc := UIStyle.tier_color(tier)
	var b := Button.new()
	b.custom_minimum_size = Vector2(CARD_W, CARD_H)
	b.size_flags_vertical = Control.SIZE_SHRINK_END
	b.focus_mode = Control.FOCUS_ALL
	b.set_meta("tier_col", tc)
	b.pressed.connect(_on_card_pressed.bind(i))
	b.mouse_entered.connect(func(): b.grab_focus())
	b.focus_entered.connect(_on_card_focus.bind(i))
	b.focus_exited.connect(_style_card.bind(i))
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	b.add_child(root)
	# tier band
	var band := PanelContainer.new()
	var bs := StyleBoxFlat.new()
	bs.bg_color = tc
	bs.content_margin_left = 12
	bs.content_margin_right = 12
	bs.content_margin_top = 4
	bs.content_margin_bottom = 4
	band.add_theme_stylebox_override("panel", bs)
	root.add_child(band)
	var bh := HBoxContainer.new()
	band.add_child(bh)
	var tl := UIStyle.label(tier.to_upper(), 13, UIStyle.INK, true)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(tl)
	var ranks := int(e.get("ranks", 1))
	var rn := int(e.get("rank_now", 0))
	var right := "UNIQUE" if ranks <= 1 else ("RANK %d → %d" % [rn, int(e.get("rank_next", 1))] if rn > 0 else "%d RANKS" % ranks)
	if bool(e.get("is_cache", false)):
		right = "POINTS"
	bh.add_child(UIStyle.label(right, 10, UIStyle.INK, true))
	var stripe := _Hazard.new()
	stripe.custom_minimum_size = Vector2(0, 5)
	stripe.color = tc.darkened(0.45)
	root.add_child(stripe)
	# branch chip + banish X
	var top := HBoxContainer.new()
	var tm := MarginContainer.new()
	tm.add_theme_constant_override("margin_left", 12)
	tm.add_theme_constant_override("margin_right", 10)
	tm.add_child(top)
	root.add_child(tm)
	var br := str(e.get("branch", "core"))
	var chip := PanelContainer.new()
	var cs := StyleBoxFlat.new()
	cs.bg_color = UIStyle.branch_accent(br) if br != "core" else Color(UIStyle.BONE_DIM, 0.55)
	cs.content_margin_left = 5
	cs.content_margin_right = 5
	chip.add_theme_stylebox_override("panel", cs)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var cls := str(e.get("class", ""))
	chip.add_child(UIStyle.label((cls if cls != "" else br).to_upper() + (" ONLY" if cls != "" else ""), 9, UIStyle.INK, true))
	top.add_child(chip)
	# playtest #13 card type chip (Instant / Echo / Growing / Fleeting / Hoard / Wager / Counter / Reactive / Active)
	var ctype := UIStyle.card_type_of(e)
	if ctype.label != "" and not bool(e.get("is_cache", false)):
		top.add_child(Control.new())
		top.get_child(top.get_child_count() - 1).custom_minimum_size.x = 4
		top.add_child(UIStyle.card_type_chip(e, 9))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(sp)
	if not bool(e.get("is_cache", false)):
		var x := Button.new()
		x.text = "✕"
		x.focus_mode = Control.FOCUS_NONE
		x.tooltip_text = "Banish (removes this card for the rest of the match)"
		x.custom_minimum_size = Vector2(24, 22)
		x.add_theme_font_size_override("font_size", 12)
		x.add_theme_color_override("font_color", UIStyle.BONE_DIM)
		x.add_theme_color_override("font_hover_color", UIStyle.BAD)
		var xs := UIStyle.cut_box(Color(UIStyle.INK, 0.9), Color(UIStyle.BONE_DIM, 0.6), 1, 2)
		xs.set_content_margin_all(0)
		x.add_theme_stylebox_override("normal", xs)
		x.add_theme_stylebox_override("hover", xs)
		x.add_theme_stylebox_override("pressed", xs)
		x.add_theme_stylebox_override("disabled", xs)
		x.disabled = not RunState.can_banish(str(e.id))
		x.pressed.connect(banish_at.bind(i))
		top.add_child(x)
		b.set_meta("x_btn", x)
	# icon
	var ic_c := CenterContainer.new()
	root.add_child(ic_c)
	var icon := PanelContainer.new()
	var ics := StyleBoxFlat.new()
	ics.bg_color = UIStyle.INK
	ics.border_color = tc.lightened(0.1)
	ics.set_border_width_all(3)
	icon.add_theme_stylebox_override("panel", ics)
	icon.custom_minimum_size = Vector2(72, 72)
	var card_tex: Texture2D = null if bool(e.get("is_cache", false)) else UIStyle.card_icon_tex(str(e.get("icon", e.get("id", ""))))
	if card_tex != null: # Desi card_<icon>.png; initials as fallback
		var tr := TextureRect.new()
		tr.texture = card_tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(64, 64)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.add_child(tr)
	else:
		var gl := UIStyle.label("$" if bool(e.get("is_cache", false)) else UIStyle.initials(str(e.get("name", "?"))), 28, UIStyle.BONE, true)
		gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		gl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		icon.add_child(gl)
	ic_c.add_child(icon)
	# name + rank line
	var nm := UIStyle.label(str(e.get("name", "?")).to_upper(), 19, UIStyle.BONE, true)
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	nm.custom_minimum_size.x = CARD_W - 20
	root.add_child(nm)
	var rl := _rich(10, CARD_W - 20)
	var dim := UIStyle.BONE_DIM.to_html(false)
	if bool(e.get("is_cache", false)):
		rl.text = "[center][color=#%s]TAKE THE POINTS INSTEAD OF A CARD[/color][/center]" % dim
	elif rn == 0:
		rl.text = "[center][bgcolor=#%s][color=#e3d9bd] NEW [/color][/bgcolor]   [color=#%s]%s[/color][/center]" % [UIStyle.BLOOD.to_html(false), dim, "1 RANK" if ranks <= 1 else "RANK I OF %s" % UIStyle.roman(ranks)]
	else:
		rl.text = "[center][color=#%s]OWNED  //  RANK %s → [color=#%s]%s[/color][/color][/center]" % [dim, UIStyle.roman(rn), NUM_COL, UIStyle.roman(int(e.get("rank_next", rn)))]
	root.add_child(rl)
	# the type's one-line rule ("Strong, but expires after a few rounds.")
	if ctype.hint != "" and not bool(e.get("is_cache", false)):
		var th0 := UIStyle.label(str(ctype.hint), 11, UIStyle.card_type_color(ctype.type).lightened(0.25))
		th0.name = "TypeHint"
		th0.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		th0.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		th0.custom_minimum_size.x = CARD_W - 28
		root.add_child(th0)
	# description + drawback
	var dm := MarginContainer.new()
	dm.add_theme_constant_override("margin_left", 14)
	dm.add_theme_constant_override("margin_right", 14)
	dm.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(dm)
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 4)
	dm.add_child(dv)
	var desc := _rich(13, CARD_W - 28)
	desc.text = "[center]%s[/center]" % _hl(str(e.get("description", "")))
	dv.add_child(desc)
	if str(e.get("drawback", "")) != "":
		var dr := _rich(12, CARD_W - 28)
		dr.text = "[center][color=#%s]%s[/color][/center]" % [UIStyle.BAD.to_html(false), str(e.drawback)]
		dv.add_child(dr)
	# per-rank chips for multi-rank cards
	if ranks > 1 and not bool(e.get("is_cache", false)):
		var def: Dictionary = RunState.card_def(str(e.id))
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 4)
		for r in range(1, ranks + 1):
			row.add_child(_rank_chip(def, r, rn, tc))
		root.add_child(row)
	# synergy + take
	var syn: Array = e.get("synergy", [])
	var sy := UIStyle.label(("SYNERGY // " + "  //  ".join(syn)).to_upper() if not syn.is_empty() else " ", 9, UIStyle.BONE_DIM)
	sy.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sy.clip_text = true
	sy.custom_minimum_size.x = CARD_W - 20
	root.add_child(sy)
	var tm2 := MarginContainer.new()
	tm2.add_theme_constant_override("margin_left", 14)
	tm2.add_theme_constant_override("margin_right", 14)
	tm2.add_theme_constant_override("margin_bottom", 12)
	root.add_child(tm2)
	var take := PanelContainer.new()
	take.custom_minimum_size = Vector2(0, 30)
	tm2.add_child(take)
	var th := HBoxContainer.new()
	th.alignment = BoxContainer.ALIGNMENT_CENTER
	th.add_theme_constant_override("separation", 8)
	take.add_child(th)
	th.add_child(UIStyle.key_cap(str(i + 1), 12))
	var tlab := UIStyle.label("TAKE", 13, UIStyle.BONE, true)
	th.add_child(tlab)
	b.set_meta("take", take)
	b.set_meta("take_label", tlab)
	_ignore_mouse(root)
	return b


func _rank_chip(def: Dictionary, r: int, rn: int, tc: Color) -> PanelContainer:
	var p := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(UIStyle.INK, 0.8)
	var nxt := r == rn + 1
	s.border_color = tc.lightened(0.3) if nxt else (Color(UIStyle.BONE_DIM, 0.8) if r <= rn else Color(UIStyle.BONE_DIM, 0.3))
	s.set_border_width_all(1)
	s.content_margin_left = 6
	s.content_margin_right = 6
	p.add_theme_stylebox_override("panel", s)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -3)
	p.add_child(v)
	var tag := UIStyle.roman(r) + (" // NOW" if r == rn else (" // NEXT" if nxt else ""))
	var a := UIStyle.label(tag, 8, UIStyle.BONE_DIM)
	a.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(a)
	var vals: Dictionary = def.get("values", {})
	var txt := ""
	if not vals.is_empty():
		var k: String = vals.keys()[0]
		var rv = Progress.rank_value(vals[k], r)
		txt = str(int(rv)) if (typeof(rv) == TYPE_FLOAT and is_equal_approx(rv, roundf(rv))) else str(rv)
		if str(def.get("description", "")).find("{%s}%%" % k) >= 0:
			txt += "%"
		if not txt.begins_with("-"):
			txt = "+" + txt
	var bl := UIStyle.label(txt, 11, UIStyle.GOOD if nxt else UIStyle.BONE)
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(bl)
	return p


func _style_card(i: int) -> void:
	if i >= card_buttons.size():
		return
	var b: Button = card_buttons[i]
	var tc: Color = b.get_meta("tier_col")
	var focus := b.has_focus()
	var leg := str(_entries[i].get("tier", "")) == "legendary"
	var bg := Color(0.13, 0.08, 0.17, 0.97) if leg else Color(0.07, 0.09, 0.06, 0.97)
	var edge := tc.lightened(0.2) if focus else tc
	if _banish_mode and RunState.can_banish(str(_entries[i].id)):
		edge = UIStyle.BAD
	var st := UIStyle.cut_box(bg, edge, 4 if focus else 3, 10)
	st.set_content_margin_all(0)
	st.shadow_color = Color(tc, 0.35) if focus else Color(0, 0, 0, 0.5)
	st.shadow_size = 14 if focus else 6
	for k in ["normal", "hover", "pressed", "focus", "disabled"]:
		b.add_theme_stylebox_override(k, st)
	var take: PanelContainer = b.get_meta("take")
	var ts := UIStyle.cut_box(UIStyle.BONE if focus else Color(UIStyle.INK, 0.6), UIStyle.BONE_DIM, 0 if focus else 1, 3)
	ts.set_content_margin_all(2)
	if _banish_mode:
		ts.bg_color = Color(UIStyle.BLOOD, 0.85) if focus else Color(UIStyle.INK, 0.6)
	take.add_theme_stylebox_override("panel", ts)
	var tl: Label = b.get_meta("take_label")
	tl.text = "BANISH" if _banish_mode else "TAKE"
	tl.add_theme_color_override("font_color", UIStyle.INK if focus and not _banish_mode else UIStyle.BONE)
	if b.has_meta("x_btn"):
		(b.get_meta("x_btn") as Button).disabled = not RunState.can_banish(str(_entries[i].id))


func _on_card_focus(i: int) -> void:
	if _focus_slot != i and visible:
		_ui_snd("ui_hover")
	_focus_slot = i
	for k in card_buttons.size():
		_style_card(k)


func _on_card_pressed(i: int) -> void:
	if _banish_mode:
		banish_at(i)
	else:
		take(i)


# ---------------------------------------------------------------- actions (public: tests drive these too)

func take(i: int) -> bool:
	if i < 0 or i >= _entries.size():
		return false
	return RunState.choose(str(_entries[i].id))


func do_reroll() -> bool:
	var ok := bool(RunState.reroll())
	if not ok and visible:
		_refresh_actions() # a co-op request went out (pending) or it was refused locally: redraw the button now
	return ok


## RunState.reroll_pending (co-op host answer outstanding); false before Netz's M13 RunState.
static func reroll_pending() -> bool:
	return bool(RunState.get("reroll_pending")) if "reroll_pending" in RunState else false


static func refusal_text(reason: String) -> String:
	if REFUSAL_TEXT.has(reason):
		return REFUSAL_TEXT[reason]
	return "Reroll refused. Not charged" if reason == "" else "Reroll refused (%s). Not charged" % reason.replace("_", " ")


func _on_reroll_refused(reason: String = "") -> void:
	var why := reason
	if why == "" and "last_refusal_reason" in RunState:
		why = str(RunState.last_refusal_reason)
	if not visible:
		return
	_refresh_actions()
	show_toast(refusal_text(why))
	_ui_snd("menu_close")


func show_toast(text: String, secs: float = TOAST_SECS) -> void:
	toast_label.text = text.to_upper()
	toast_label.modulate.a = 1.0
	_toast_t = secs


func hide_toast() -> void:
	_toast_t = 0.0
	if toast_label:
		toast_label.modulate.a = 0.0


func toast_visible() -> bool:
	return toast_label != null and toast_label.modulate.a > 0.01


func _process(delta: float) -> void:
	if not visible:
		return
	if reroll_pending() != _seen_pending: # host request sent / answered: enable or disable the paid reroll
		_refresh_actions()
	if _toast_t > 0.0:
		_toast_t -= delta
		toast_label.modulate.a = clampf(_toast_t / 0.5, 0.0, 1.0)


func do_skip() -> int:
	return RunState.skip()


func toggle_banish() -> void:
	var can_b := RunState.banishes_left > 0 and RunState.banished_this_offer < int(RunState.cfg("max_banish_per_offer", 1))
	_banish_mode = not _banish_mode and can_b
	_ui_snd("ui_hover")
	_refresh_actions()


func banish_at(i: int) -> bool:
	_banish_mode = false
	if i < 0 or i >= _entries.size() or not RunState.can_banish(str(_entries[i].id)):
		_refresh_actions()
		return false
	_focus_slot = i
	return RunState.banish(str(_entries[i].id)) # offer_ready re-emits -> refresh


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	var handled := true
	if event is InputEventKey and event.pressed and not event.echo:
		var k: int = event.physical_keycode
		if k >= KEY_1 and k <= KEY_4:
			_on_card_pressed(k - KEY_1)
		elif k == KEY_R:
			do_reroll()
		elif k == KEY_S:
			do_skip()
		elif k == KEY_B:
			toggle_banish()
		elif k == KEY_ESCAPE and _banish_mode:
			toggle_banish()
		else:
			handled = event.is_action("toggle_mouse") or (toggle_action != "" and event.is_action(toggle_action))
	elif event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_Y: do_reroll()
			JOY_BUTTON_X: do_skip()
			JOY_BUTTON_B: toggle_banish()
			_: handled = false
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled() # never falls through to MenuBase: the offer must be resolved


# ---------------------------------------------------------------- helpers

static func _hl(t: String) -> String:
	var re := RegEx.new()
	re.compile("([+\\-x×]?\\d+(?:\\.\\d+)?(?:%| m| s|s)?)")
	return re.sub(t, "[color=#%s]$1[/color]" % NUM_COL, true)


static func _thousands(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


func _ignore_mouse(n: Node) -> void:
	for c in n.get_children():
		if c is Control and not (c is Button):
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ignore_mouse(c)


class _Hazard extends Control:
	var color := Color(0.3, 0.2, 0.3)

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.6))
		var x := -size.y
		while x < size.x:
			draw_colored_polygon(PackedVector2Array([Vector2(x, size.y), Vector2(x + size.y, 0), Vector2(x + size.y + 5, 0), Vector2(x + 5, size.y)]), color)
			x += 11.0
