class_name CooldownIcon
extends Control
## Compact cut-corner cooldown badge: glyph + key letter, fills from the bottom while
## recharging and lights its border when ready.

var glyph: String = "G"
var icon: Texture2D = null ## Desi icon (e.g. UIStyle.ability_icon_tex); drawn instead of the glyph when set
var key: String = "G"
var color: Color = UIStyle.RUST
var fraction: float = 1.0 ## 0 = just used, 1 = ready
var seconds_left: float = 0.0
var charges: int = 1 ## charge pips are drawn when max_charges > 1
var max_charges: int = 1
var _flash: float = 0.0


static func make(glyph_text: String, key_text: String, c: Color, s: float = 46.0) -> CooldownIcon:
	var i := CooldownIcon.new()
	i.glyph = glyph_text
	i.key = key_text
	i.color = c
	i.custom_minimum_size = Vector2(s, s)
	i.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return i


func set_state(left: float, total: float) -> void:
	var was_ready := fraction >= 1.0
	seconds_left = left
	fraction = 1.0 if total <= 0.0 else clampf(1.0 - left / total, 0.0, 1.0)
	if fraction >= 1.0 and not was_ready:
		_flash = 1.0
	queue_redraw()


## Charges from player.grenade_charges_changed / ability_charges_changed. With spare charges the badge
## stays lit while the next charge refills.
func set_charges(c: int, m: int) -> void:
	if c > charges and c >= m:
		_flash = 1.0
	charges = c
	max_charges = maxi(m, 1)
	queue_redraw()


func _is_ready() -> bool:
	return fraction >= 1.0 or (max_charges > 1 and charges > 0)


func _process(delta: float) -> void:
	if _flash > 0.0:
		_flash = maxf(_flash - delta * 2.5, 0.0)
		queue_redraw()


func _shape(inset: float) -> PackedVector2Array:
	var w := size.x - inset
	var h := size.y - inset
	var c := size.x * 0.22
	var o := inset
	return PackedVector2Array([Vector2(o + c, o), Vector2(w, o), Vector2(w, h - c), Vector2(w - c, h), Vector2(o, h), Vector2(o, o + c)])


func _draw() -> void:
	var ready := _is_ready()
	draw_colored_polygon(_shape(0), Color(0.05, 0.05, 0.04, 0.78))
	# recharge fill (clip the polygon by height)
	if fraction > 0.0:
		var top := size.y * (1.0 - fraction)
		var pts := Geometry2D.intersect_polygons(_shape(3), PackedVector2Array([
			Vector2(0, top), Vector2(size.x, top), Vector2(size.x, size.y), Vector2(0, size.y)]))
		for p in pts:
			draw_colored_polygon(p, Color(color, 0.85 if ready else 0.4))
	var edge := _shape(1)
	edge.append(edge[0])
	draw_polyline(edge, color.lightened(0.3 + _flash * 0.5) if ready else Color(UIStyle.BONE_DIM, 0.6), 2.0 + _flash * 2.0)
	var f: Font = UIStyle.FONT_STENCIL
	var fs := int(size.y * 0.42)
	var gs := f.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var gc := UIStyle.INK if ready else UIStyle.BONE
	if icon:
		var isz := size * 0.64
		draw_texture_rect(icon, Rect2((size - isz) * 0.5 - Vector2(0, size.y * 0.04), isz), false, Color(gc, 1.0))
	else:
		draw_string(f, Vector2((size.x - gs.x) * 0.5, size.y * 0.5 + fs * 0.36), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, gc)
	var kf: Font = UIStyle.body_bold()
	draw_string(kf, Vector2(4, size.y - 4), key, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size.y * 0.24), Color(gc, 0.8))
	if max_charges > 1: # charge pips, bottom-right
		var pw := 6.0
		var gap := 2.0
		var x0 := size.x - 5.0 - max_charges * pw - (max_charges - 1) * gap - size.x * 0.12
		for i in max_charges:
			var r := Rect2(x0 + i * (pw + gap), size.y - 8.0, pw, 4.0)
			draw_rect(r.grow(1.0), Color(0, 0, 0, 0.7))
			draw_rect(r, UIStyle.BONE if i < charges else Color(UIStyle.BONE_DIM, 0.25))
	if fraction < 1.0:
		var t := "%d" % ceili(seconds_left)
		var ts := kf.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size.y * 0.26))
		draw_string(kf, Vector2(size.x - ts.x - 4, 13), t, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size.y * 0.26), UIStyle.BONE)
