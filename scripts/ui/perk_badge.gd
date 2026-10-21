class_name PerkBadge
extends Control
## Hexagonal perk icon drawn in code: coloured hex + 2-letter glyph (from data/perks.json).

var color: Color = Color(0.8, 0.6, 0.2)
var glyph: String = "?"
var icon: Texture2D = null ## Desi perk_<id>.png; drawn inside the hex instead of the glyph when set


static func make(perk: Dictionary, size: float = 30.0) -> PerkBadge:
	var b := PerkBadge.new()
	var c = perk.get("icon_color", [0.8, 0.6, 0.2])
	b.color = Color(c[0], c[1], c[2])
	b.glyph = perk.get("glyph", str(perk.get("name", "?")).substr(0, 2).to_upper())
	b.icon = UIStyle.perk_icon_tex(str(perk.get("id", "")))
	b.custom_minimum_size = Vector2(size, size)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return b


func _draw() -> void:
	var r := minf(size.x, size.y) * 0.5
	var c := size * 0.5
	var pts := PackedVector2Array()
	for i in 6:
		var a := TAU * i / 6.0 + PI / 6.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	draw_colored_polygon(pts, color.darkened(0.45))
	var inner := PackedVector2Array()
	for p in pts:
		inner.append(c + (p - c) * 0.78)
	draw_colored_polygon(inner, color if icon == null else Color(0.06, 0.055, 0.05))
	pts.append(pts[0])
	draw_polyline(pts, Color(0, 0, 0, 0.8), 2.0)
	if icon != null:
		var isz := r * 1.5
		draw_texture_rect(icon, Rect2(c - Vector2(isz, isz) * 0.5, Vector2(isz, isz)), false)
		return
	var f: Font = UIStyle.FONT_STENCIL
	var fs := int(r * 0.85)
	var ts := f.get_string_size(glyph, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	draw_string(f, c + Vector2(-ts.x * 0.5, ts.y * 0.32), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.05, 0.04, 0.03))
