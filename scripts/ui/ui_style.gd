class_name UIStyle
## Shared look for the HUD and menus: rugged survival palette, OFL fonts,
## chunky chamfered ("cut corner") panels, grit overlay and perk badges.

const FONT_STENCIL := preload("res://assets/fonts/BlackOpsOne-Regular.ttf")
const FONT_BODY := preload("res://assets/fonts/Oswald-Variable.ttf")
const ICON_GRAVEMARK_PATH := "res://assets/icons/gravemark.png"
const ICON_GRAVEMARK: Texture2D = preload("res://assets/icons/gravemark.png")

# Palette: desaturated olive / rust / bone with blood-red accents.
const BONE := Color(0.89, 0.85, 0.74)
const BONE_DIM := Color(0.66, 0.63, 0.55)
const OLIVE := Color(0.45, 0.48, 0.31)
const OLIVE_DARK := Color(0.16, 0.17, 0.12)
const RUST := Color(0.70, 0.38, 0.18)
const BLOOD := Color(0.78, 0.07, 0.05)
const INK := Color(0.045, 0.045, 0.04)
const PANEL := Color(0.07, 0.07, 0.06, 0.86)
const GOOD := Color(0.35, 0.95, 0.35)
const BAD := Color(1.0, 0.3, 0.25)

static var _grit: NoiseTexture2D
static var _body_bold: FontVariation


## Oswald at a heavier weight for labels and numbers.
static func body_bold() -> Font:
	if _body_bold == null:
		_body_bold = FontVariation.new()
		_body_bold.base_font = FONT_BODY
		_body_bold.variation_opentype = {"wght": 600}
	return _body_bold


static func label(text: String, size: int, color: Color = BONE, stencil: bool = false, outline: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", FONT_STENCIL if stencil else body_bold())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if outline > 0:
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("outline_size", outline)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Chunky panel with chamfered top-left / bottom-right corners and a thick border.
static func cut_box(bg: Color, border: Color = Color(0, 0, 0, 0), border_w: int = 0, cut: int = 12,
		all_corners: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w)
	s.corner_detail = 1 # 1 = straight bevel, i.e. a cut corner
	s.corner_radius_top_left = cut
	s.corner_radius_bottom_right = cut
	s.corner_radius_top_right = cut if all_corners else 2
	s.corner_radius_bottom_left = cut if all_corners else 2
	s.set_content_margin_all(8)
	s.anti_aliasing = true
	return s


## Tileable grit texture used to scuff panels.
static func grit() -> NoiseTexture2D:
	if _grit == null:
		var n := FastNoiseLite.new()
		n.noise_type = FastNoiseLite.TYPE_CELLULAR
		n.frequency = 0.09
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = 3
		_grit = NoiseTexture2D.new()
		_grit.width = 256
		_grit.height = 256
		_grit.seamless = true
		_grit.noise = n
		var g := Gradient.new()
		g.set_color(0, Color(0, 0, 0, 0.0))
		g.add_point(0.55, Color(0, 0, 0, 0.0))
		g.set_color(1, Color(0, 0, 0, 1.0))
		_grit.color_ramp = g
	return _grit


## Adds a scuffed grit overlay that fills `parent`.
static func add_grit(parent: Control, alpha: float = 0.35) -> TextureRect:
	var t := TextureRect.new()
	t.texture = grit()
	t.stretch_mode = TextureRect.STRETCH_TILE
	t.set_anchors_preset(Control.PRESET_FULL_RECT)
	t.modulate = Color(1, 1, 1, alpha)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(t)
	return t


static func rarity_color(r: int) -> Color:
	return Rarity.color(r)


## Simple bar (background + fill) as a Control. `frac` 0..1.
static func bar(frac: float, color: Color, w: float = 150.0, h: float = 8.0, ghost: float = -1.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bgr := ColorRect.new()
	bgr.color = Color(1, 1, 1, 0.1)
	bgr.size = Vector2(w, h)
	c.add_child(bgr)
	if ghost >= 0.0: # equipped item's value, drawn behind for comparison
		var gr := ColorRect.new()
		gr.color = Color(1, 1, 1, 0.28)
		gr.size = Vector2(w * clampf(ghost, 0, 1), h)
		c.add_child(gr)
	var f := ColorRect.new()
	f.color = color
	f.size = Vector2(w * clampf(frac, 0.0, 1.0), h)
	c.add_child(f)
	return c


## Item Power plate: a stamped tag with a solid "IP" tab and the number (not a diamond).
## `tint` colours the number (e.g. GOOD / BAD vs equipped); `size` is the number's font size.
static func ip_plate(ip: int, size: int = 13, tint: Color = BONE, tab_text: String = "IP") -> PanelContainer:
	var p := PanelContainer.new()
	var st := cut_box(Color(INK, 0.92), Color(BONE_DIM, 0.75), 1, maxi(4, size / 3))
	st.corner_radius_top_left = 2
	st.corner_radius_bottom_right = 2
	st.corner_radius_top_right = maxi(4, size / 3)
	st.set_content_margin_all(0)
	p.add_theme_stylebox_override("panel", st)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 0)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	var tab := PanelContainer.new()
	var ts := StyleBoxFlat.new()
	ts.bg_color = BONE_DIM
	ts.content_margin_left = maxf(2.0, size * 0.25)
	ts.content_margin_right = maxf(2.0, size * 0.25)
	ts.content_margin_top = 0
	ts.content_margin_bottom = 0
	tab.add_theme_stylebox_override("panel", ts)
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tl := label(tab_text, maxi(8, int(size * 0.72)), INK)
	tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tl.size_flags_vertical = Control.SIZE_FILL
	tab.add_child(tl)
	h.add_child(tab)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", maxi(3, size / 3))
	m.add_theme_constant_override("margin_right", maxi(4, size / 2))
	m.add_theme_constant_override("margin_top", -2)
	m.add_theme_constant_override("margin_bottom", -2)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var num := label(str(ip), size, tint)
	num.name = "IPNumber"
	m.add_child(num)
	h.add_child(m)
	return p


## Colour for an Item Power number compared with what's equipped (BONE if equal / no compare).
static func ip_tint(delta: int) -> Color:
	return GOOD if delta > 0 else (BAD if delta < 0 else BONE)


## Roll-quality bar: "ROLL [====|----] 72%  OF IP 118 RANGE". `q` = 0..1.
static func roll_bar(q: float, ip: int, w: float = 150.0) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(label("ROLL", 12, BONE_DIM))
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, 10)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var back := Panel.new()
	back.add_theme_stylebox_override("panel", cut_box(Color(1, 1, 1, 0.08), Color(BONE, 0.2), 1, 4))
	back.size = Vector2(w, 10)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(back)
	var f := ColorRect.new()
	f.color = OLIVE.lerp(Color(0.62, 0.66, 0.36), clampf(q, 0, 1))
	f.position = Vector2(2, 2)
	f.size = Vector2((w - 4) * clampf(q, 0.0, 1.0), 6)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(f)
	var tick := ColorRect.new()
	tick.color = BONE
	tick.position = Vector2(clampf(2 + (w - 4) * q - 1, 0, w - 3), -2)
	tick.size = Vector2(3, 14)
	tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(tick)
	h.add_child(c)
	h.add_child(label("%d%%" % roundi(clampf(q, 0, 1) * 100.0), 16, BONE, true))
	var tail := label("OF IP %d RANGE" % ip, 11, BONE_DIM)
	tail.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(tail)
	return h


## Skill-tree / Field Card branch accents: muted versions of Skillz's accent keys (STYLE.md palette).
## Unknown keys fall back to the data's RGB, pulled 35% toward bone-grey so it never goes neon.
const ACCENTS := {
	"marksman_orange": Color("c2703f"), "sapper_yellow": Color("b8892e"), "ledger_olive": Color("8a9354"),
	"survivor_red": Color("b5473a"), "freerunner_teal": Color("5e9c94"), "soldier_steel": Color("8c9eb2"),
	"scout_green": Color("6f9a7c"), # shifted from leaf green toward teal-olive (not delta-up / uncommon green)
}
const BRANCH_ACCENT_KEYS := {"marksman": "marksman_orange", "sapper": "sapper_yellow", "ledger": "ledger_olive",
	"survivor": "survivor_red", "freerunner": "freerunner_teal", "soldier": "soldier_steel", "scout": "scout_green"}
const STEEL := Color(0.62, 0.70, 0.76) ## overshield / plating


static func accent(key: String, fallback = null) -> Color:
	if ACCENTS.has(key):
		return ACCENTS[key]
	if typeof(fallback) == TYPE_ARRAY and fallback.size() >= 3:
		return Color(fallback[0], fallback[1], fallback[2]).lerp(BONE_DIM, 0.35)
	return BONE_DIM


## Accent for a branch id ("core" / unknown -> bone-dim).
static func branch_accent(branch_id: String) -> Color:
	return accent(str(BRANCH_ACCENT_KEYS.get(branch_id, "")))


static func roman(n: int) -> String:
	return ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][clampi(n, 0, 10)]


## Two-letter stencil glyph for things without icon art yet ("Powder Stock" -> "PS").
static func initials(name: String) -> String:
	var words := name.replace("'", "").replace("-", " ").split(" ", false)
	if words.size() >= 2:
		return (words[0].left(1) + words[1].left(1)).to_upper()
	return name.left(2).to_upper()


## Key-cap chip ("R", "LMB", "1"): bone outline, Oswald.
static func key_cap(text: String, size: int = 12) -> PanelContainer:
	var p := PanelContainer.new()
	var st := cut_box(Color(INK, 0.8), BONE, 1, 3)
	st.set_content_margin_all(1)
	st.content_margin_left = 5
	st.content_margin_right = 5
	p.add_theme_stylebox_override("panel", st)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(label(text, size, BONE))
	return p


# ---------------------------------------------------------------- Field Cards (run picks)
const TIER_LEGENDARY := Color(0.56, 0.36, 0.74)
const TIER_NORMAL := Color(0.42, 0.60, 0.30)


static func tier_color(tier: String) -> Color:
	return TIER_LEGENDARY if tier == "legendary" else TIER_NORMAL


## Rank text for a card: "III" / "★" for single-rank legendaries.
static func card_rank_text(c: Dictionary) -> String:
	if int(c.get("ranks", 1)) <= 1:
		return "★" if str(c.get("tier", "")) == "legendary" else "I"
	return roman(int(c.get("rank", 1)))


## One owned Field Card as a compact row: branch tick, name, rank (and the description when `desc_w` > 0).
## Used by the run pick menu's THIS RUN list, the HUD strip tooltip and the character screen.
static func field_card_row(c: Dictionary, w: float = 150.0, desc_w: float = 0.0, inline_desc: bool = false) -> PanelContainer:
	var p := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(INK, 0.72)
	st.border_color = branch_accent(str(c.get("branch", "")))
	if str(c.get("tier", "")) == "legendary":
		st.border_color = TIER_LEGENDARY.lightened(0.15)
	st.border_width_left = 3
	st.content_margin_left = 8
	st.content_margin_right = 6
	st.content_margin_top = 2
	st.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", st)
	p.custom_minimum_size.x = w
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	p.add_child(v)
	var h := HBoxContainer.new()
	v.add_child(h)
	var n := label(str(c.get("name", c.get("id", "?"))), 12, BONE)
	n.clip_text = true
	h.add_child(n)
	if inline_desc: # one line: name, clipped description, rank
		n.custom_minimum_size.x = 104
		var dl := label(card_blurb(c), 11, BONE_DIM)
		dl.clip_text = true
		dl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		dl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(dl)
	else:
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var leg := str(c.get("tier", "")) == "legendary"
	h.add_child(label(card_rank_text(c), 12, TIER_LEGENDARY.lightened(0.35) if leg else BONE_DIM))
	if desc_w > 0.0:
		var d := label(card_blurb(c, 120), 11, BONE_DIM)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size.x = desc_w
		v.add_child(d)
	return p


## Rugged unseen-loot "!" plate (angled cut, blood red). Sit it on a tile/slot corner.
static func unseen_badge(size: int = 16) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "UnseenBadge"
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := cut_box(BLOOD.darkened(0.15), BONE.lightened(0.1), 2, maxi(4, size / 3))
	st.set_content_margin_all(1)
	st.content_margin_left = 4
	st.content_margin_right = 4
	p.add_theme_stylebox_override("panel", st)
	p.custom_minimum_size = Vector2(size + 2, size)
	var l := label("!", size - 2, BONE, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	p.rotation_degrees = -8.0
	return p


## One-liner for Field Card rows: prefer entry.summary (no numbers), else truncated description.
static func card_blurb(c: Dictionary, max_chars: int = 60) -> String:
	var s := str(c.get("summary", "")).strip_edges()
	if s == "":
		s = str(c.get("description", "")).strip_edges()
	if s.length() > max_chars:
		return s.substr(0, max_chars - 1) + "…"
	return s


## Compact Gravemark balance chip (icon + amount). Falls back to a drawn "G" glyph if the icon is missing.
static func gravemark_tex() -> Texture2D:
	if ICON_GRAVEMARK != null:
		return ICON_GRAVEMARK
	if ResourceLoader.exists(ICON_GRAVEMARK_PATH):
		var t = load(ICON_GRAVEMARK_PATH)
		if t is Texture2D:
			return t
	return null


static func gravemark_icon(icon_size: int = 22) -> Control:
	var tex := gravemark_tex()
	if tex:
		var tr := TextureRect.new()
		tr.name = "GravemarkIcon"
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(icon_size, icon_size)
		tr.size = Vector2(icon_size, icon_size)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return tr
	var g := PanelContainer.new()
	g.name = "GravemarkGlyph"
	g.add_theme_stylebox_override("panel", cut_box(RUST.darkened(0.2), BONE, 2, 4))
	g.custom_minimum_size = Vector2(icon_size, icon_size)
	var gl := label("G", maxi(10, icon_size - 8), BONE, true)
	gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.add_child(gl)
	return g


static func gravemark_chip(amount: int, icon_size: int = 22) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "GravemarkChip"
	var st := cut_box(Color(INK, 0.9), RUST, 2, 8)
	st.set_content_margin_all(6)
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	p.add_child(h)
	h.add_child(gravemark_icon(icon_size))
	var amt := label(str(amount), maxi(14, icon_size - 2), BONE, true)
	amt.name = "GravemarkAmount"
	h.add_child(amt)
	return p


static func set_gravemark_chip_amount(chip: PanelContainer, amount: int) -> void:
	if chip == null:
		return
	var amt := chip.find_child("GravemarkAmount", true, false) as Label
	if amt:
		amt.text = str(amount)


# ------------------------------------------------------------------ Item Power breakdown (Armory §1a)

## "290 rolled + 22 Rework" from Armory.item_power_breakdown(); the Rework part is dropped when the bonus is 0.
static func ip_breakdown_text(bd: Dictionary) -> String:
	var base := int(bd.get("base_rolled", bd.get("total", 0)))
	var bonus := int(bd.get("rework_bonus", 0))
	if bonus <= 0:
		return "%d rolled" % base
	return "%d rolled + %d Rework" % [base, bonus]


## Big "312 IP" total over a small breakdown line. Nodes: IPTotal (Label), IPBreakdown (Label).
static func ip_breakdown_block(bd: Dictionary, big: int = 28, small: int = 11,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "IPBreakdownBlock"
	v.add_theme_constant_override("separation", -4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	top.alignment = BoxContainer.ALIGNMENT_CENTER if align == HORIZONTAL_ALIGNMENT_CENTER else \
		(BoxContainer.ALIGNMENT_END if align == HORIZONTAL_ALIGNMENT_RIGHT else BoxContainer.ALIGNMENT_BEGIN)
	v.add_child(top)
	var n := label(str(int(bd.get("total", 0))), big, BONE, true, 0)
	n.name = "IPTotal"
	top.add_child(n)
	var ip := label("IP", maxi(10, big / 2), BONE_DIM, true)
	ip.size_flags_vertical = Control.SIZE_SHRINK_END
	top.add_child(ip)
	var bl := label(ip_breakdown_text(bd), small, OLIVE.lightened(0.4) if int(bd.get("rework_bonus", 0)) > 0 else BONE_DIM)
	bl.name = "IPBreakdown"
	bl.horizontal_alignment = align
	v.add_child(bl)
	return v


# ------------------------------------------------------------------ attachment icons

## res://assets/icons/att_<id>.png when it exists, else null.
static func attachment_tex(att_id: String) -> Texture2D:
	var path := "res://assets/icons/att_%s.png" % att_id
	if att_id != "" and ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			return t
	return null


## Attachment icon: the real att_<id>.png (TextureRect "AttIcon") or a chamfered letter glyph ("AttGlyph":
## first letter of the slot, or of the id) when there is no art yet.
static func attachment_icon(att_id: String, icon_size: int = 36, slot: String = "") -> Control:
	var tex := attachment_tex(att_id)
	if tex:
		var tr := TextureRect.new()
		tr.name = "AttIcon"
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(icon_size, icon_size)
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return tr
	var g := PanelContainer.new()
	g.name = "AttGlyph"
	g.add_theme_stylebox_override("panel", cut_box(OLIVE_DARK, BONE_DIM, 2, 6))
	g.custom_minimum_size = Vector2(icon_size, icon_size)
	g.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var src := slot if slot != "" else att_id
	var gl := label(src.substr(0, 1).to_upper() if src != "" else "?", maxi(10, icon_size / 2), BONE_DIM, true)
	gl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.add_child(gl)
	return g
