class_name TallyCounter
extends Control
## Classic zombies-mode round counter: hand-painted tally marks for rounds 1-10,
## a big painted numeral after that. Strokes get a little seeded jitter so they look brushed.

var value: int = 0:
	set(v):
		value = v
		queue_redraw()
var color: Color = UIStyle.BLOOD


func _draw() -> void:
	if value <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	var h := size.y
	if value <= 10:
		var x := 6.0
		for i in value:
			var in_group := i % 5
			if in_group == 4: # diagonal strike through the previous four
				var gx := x - 4 * h * 0.22 - h * 0.1
				_stroke(Vector2(gx - h * 0.08, h * 0.78), Vector2(x - h * 0.08, h * 0.2), h * 0.11, rng)
				x += h * 0.38
			else:
				_stroke(Vector2(x, h * 0.08 + rng.randf_range(0, 4)), Vector2(x + rng.randf_range(-3, 3), h * 0.92), h * 0.12, rng)
				x += h * 0.22
	else:
		var f: Font = UIStyle.FONT_STENCIL
		var t := str(value)
		var fs := int(h * 1.05)
		draw_string(f, Vector2(5, h * 0.92 + 3), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.6))
		draw_string(f, Vector2(2, h * 0.92), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)


func _stroke(a: Vector2, b: Vector2, w: float, rng: RandomNumberGenerator) -> void:
	draw_line(a + Vector2(3, 3), b + Vector2(3, 3), Color(0, 0, 0, 0.55), w)
	draw_line(a, b, color, w)
	# dry-brush streaks + a drip
	draw_line(a.lerp(b, 0.1), a.lerp(b, rng.randf_range(0.5, 0.9)), color.lightened(0.15), w * 0.3)
	if rng.randf() < 0.6:
		var d := b + Vector2(rng.randf_range(-2, 2), 0)
		draw_line(d, d + Vector2(0, rng.randf_range(5, 12)), color.darkened(0.2), w * 0.35)
