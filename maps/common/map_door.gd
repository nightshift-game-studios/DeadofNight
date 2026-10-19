class_name MapDoor
extends StaticBody3D
## Buyable door / barricade for Mapz maps (map contract v0.2).
## While closed it is a layer-1 collider inside NavigationRegion3D, so it blocks the player AND the navmesh bake.
## Interact (E) with enough points -> spend `cost`, drop collision, animate/hide visual, emit `opened`.
## Desi door glbs under Visual/DesiSlot: Frame stays, Panel tweens open (slide or swing). Their "-col"
## StaticBody is stripped in _ready — MapDoor owns gameplay collision and nav blocking.

signal opened(door: MapDoor)

@export var door_id: StringName = &""
@export var cost: int = 750
@export var connects: PackedStringArray = []
@export var opens_areas: PackedStringArray = []
@export var prompt_name: String = "Door"
## Open animation for Desi visuals: "slide" | "swing" | "" (hide Visual, used for rollershutter / greybox).
@export var open_mode: String = ""
@export var open_slide_m: float = 4.0
@export var open_swing_deg: float = -95.0
@export var open_duration: float = 1.2

var is_open: bool = false

## Defaults from Desi NOTES.txt batch 2 (override via exports if needed).
const _DESI_OPEN := {
	&"D1": {"mode": "slide", "slide": 4.0, "swing": 0.0},
	&"D3": {"mode": "swing", "slide": 0.0, "swing": -95.0},
	&"D4": {"mode": "swing", "slide": 0.0, "swing": -95.0},
	&"D6": {"mode": "swing", "slide": 0.0, "swing": -105.0},
}


func _ready() -> void:
	_strip_desi_preview_colliders()
	if open_mode == "" and _DESI_OPEN.has(door_id):
		var d: Dictionary = _DESI_OPEN[door_id]
		open_mode = str(d.mode)
		open_slide_m = float(d.slide)
		open_swing_deg = float(d.swing)
	add_to_group("map_doors")
	var trig := get_node_or_null("Trigger") as Area3D
	if trig:
		trig.body_entered.connect(func(b): if b.has_method("set_nearby_interactable"): b.set_nearby_interactable(self, true))
		trig.body_exited.connect(func(b): if b.has_method("set_nearby_interactable"): b.set_nearby_interactable(self, false))


## Desi glbs ship a closed-state "-col" box. Leaving it would block the doorway after buy + poison the nav bake.
func _strip_desi_preview_colliders() -> void:
	var vis := get_node_or_null("Visual")
	if vis == null:
		return
	# Free CollisionObject3D under Visual (Desi "-col" bodies). MapDoor owns gameplay collision.
	for c in vis.find_children("*", "CollisionObject3D", true, false):
		c.collision_layer = 0
		c.collision_mask = 0
		for sh in c.find_children("*", "CollisionShape3D", true, false):
			(sh as CollisionShape3D).disabled = true
		c.get_parent().remove_child(c)
		c.free()
	# Also free the magenta *-col MeshInstance3D Godot leaves visible when importing -col meshes
	for mi in vis.find_children("*", "MeshInstance3D", true, false):
		var n := String(mi.name)
		var pn := String(mi.get_parent().name) if mi.get_parent() else ""
		var mat: Material = mi.get_active_material(0)
		if mat == null and mi.mesh and mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)
		var magenta := mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_color.is_equal_approx(Color(1, 0, 1))
		var mesh_col := mi.mesh != null and String(mi.mesh.resource_name).contains("-col")
		var mat_col := mat != null and String(mat.resource_name).contains("-col")
		if magenta or n.contains("-col") or pn.contains("-col") or mesh_col or mat_col:
			# colliders under Visual are already stripped above; just drop the magenta mesh
			mi.get_parent().remove_child(mi)
			mi.free()


func can_interact() -> bool:
	return not is_open


func get_prompt() -> String:
	return "Open %s [%d]" % [prompt_name, cost]


func interact(player: Node) -> void:
	if is_open:
		return
	if player and player.has_method("spend_points") and not player.spend_points(cost):
		return
	open(player)


## Opens without charging (debug / tests / scripted events).
func open(player: Node = null) -> void:
	if is_open:
		return
	is_open = true
	_strip_desi_preview_colliders()
	collision_layer = 0
	collision_mask = 0
	for c in get_children():
		if c is CollisionShape3D:
			c.set_deferred("disabled", true)
	var trig := get_node_or_null("Trigger") as Area3D
	if trig:
		trig.set_deferred("monitoring", false)
	if player and player.has_method("set_nearby_interactable"):
		player.set_nearby_interactable(self, false)
	_play_open_visual()
	opened.emit(self)


func _play_open_visual() -> void:
	var vis := get_node_or_null("Visual") as Node3D
	var sign := get_node_or_null("CostSign") as Node3D
	if sign:
		sign.visible = false
	var panel := _find_desi_panel(vis)
	if panel != null and (open_mode == "slide" or open_mode == "swing"):
		var tw := create_tween()
		tw.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
		if open_mode == "slide":
			# Desi rail gate: Panel translates in local +X by ~4 m (along the wall, clears the opening).
			tw.tween_property(panel, "position:x", panel.position.x + open_slide_m, open_duration)
		else:
			# Hinged doors: Panel origin is on the hinge edge; swing about local +Y (outward / NOTES).
			tw.tween_property(panel, "rotation:y", panel.rotation.y + deg_to_rad(open_swing_deg), open_duration)
		return
	# Greybox / rollershutter: hide the whole Visual subtree.
	if vis:
		vis.visible = false


func _find_desi_panel(vis: Node) -> Node3D:
	if vis == null:
		return null
	# Prefer the authored "Panel" under the Desi instance (not a greybox MeshInstance3D named Panel).
	for n in vis.find_children("Panel", "", true, false):
		if n is Node3D and n.get_parent() != vis:
			return n
	return null
