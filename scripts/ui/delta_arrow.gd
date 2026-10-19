class_name DeltaArrow
extends Control
## Small green up / red down triangle used for stat comparisons.

var up: bool = true


static func make(is_up: bool, s: float = 12.0) -> DeltaArrow:
	var a := DeltaArrow.new()
	a.up = is_up
	a.custom_minimum_size = Vector2(s, s)
	a.size = Vector2(s, s)
	a.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return a


func _draw() -> void:
	var w := size.x
	var h := size.y
	var pts := PackedVector2Array([Vector2(w * 0.5, 0), Vector2(w, h), Vector2(0, h)]) if up \
		else PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w * 0.5, h)])
	draw_colored_polygon(pts, UIStyle.GOOD if up else UIStyle.BAD)
