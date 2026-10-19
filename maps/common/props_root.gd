extends Node3D
## Mapz: put on a "Props" node. Every child is a prop scene instance (glTF). Sets a visibility range on all its meshes
## (per-child metadata vis_end, default 45 m) so small dressing drops out early. Props carry no collision.

@export var default_vis_end: float = 45.0


func _ready() -> void:
	for p in get_children():
		var vis: float = p.get_meta("vis_end", default_vis_end)
		var shadows: bool = p.get_meta("cast_shadow", true)
		for g in p.find_children("*", "GeometryInstance3D", true, false):
			g.visibility_range_end = vis
			g.visibility_range_end_margin = 4.0
			g.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			if not shadows:
				g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
