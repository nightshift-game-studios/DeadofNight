class_name DesiLodProp
extends Node3D
## Hero + LOD visual pair. Hero keeps "-col" (layer 1). LOD drops collider; swap at lod_distance.
@export var lod_distance: float = 25.0
@export var lod_end: float = 70.0

func _ready() -> void:
	var hero := get_node_or_null("Hero")
	var lod := get_node_or_null("Lod")
	if hero:
		for m in hero.find_children("*", "GeometryInstance3D", true, false):
			m.visibility_range_begin = 0.0
			m.visibility_range_end = lod_distance
			m.visibility_range_end_margin = 5.0
			m.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	if lod:
		for c in lod.find_children("*", "CollisionObject3D", true, false):
			c.collision_layer = 0
			c.collision_mask = 0
			var p := c.get_parent()
			if p: p.remove_child(c)
			c.free()
		for m in lod.find_children("*", "GeometryInstance3D", true, false):
			m.visibility_range_begin = lod_distance
			m.visibility_range_begin_margin = 5.0
			m.visibility_range_end = lod_end
			m.visibility_range_end_margin = 8.0
			m.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
