extends Label3D
## Heartbeat Counter readout (Skillz art pass 2): sits on the optic's ScreenAnchor (WeaponRig._add_heartbeat).
## Counts live nodes in group "enemies" within `radius` m of the player (or of itself), 4x a second; sweeps the
## Needle (local X) with the count and blinks Pulse faster when it's crowded (5+ = the +12% damage threshold).
## 2D HUD readout = Gooey (ARMORY_HANDOFF.md, "Heartbeat Counter").

var radius: float = 10.0
var needle: Node3D
var pulse: Node3D
var count: int = 0
var crowd_threshold: int = 5
var _t: float = 0.0
var _beat: float = 0.0


func _ready() -> void:
	text = "0"
	font_size = 48
	pixel_size = 0.00014 # ~7 mm digits on the 16 x 9.5 mm screen (real metres; inherits the view scale)
	outline_size = 6
	modulate = Color(0.55, 1.0, 0.6)
	outline_modulate = Color(0, 0.08, 0.02)
	no_depth_test = false
	shaded = false
	double_sided = true
	fixed_size = false
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rotation_degrees.y = -90.0 # the Screen faces -X (back toward the shooter); Label3D reads from +Z, so turn it to -X
	position = Vector3(-0.0006, 0, 0) # just proud of the glass
	refresh()


## Recount now (also called 4x a second). Returns the count.
func refresh() -> int:
	var c := 0
	if is_inside_tree():
		var origin := global_position
		var pl := get_tree().get_first_node_in_group("player") as Node3D
		if pl:
			origin = pl.global_position
		for e in get_tree().get_nodes_in_group("enemies"):
			if e is Node3D and is_instance_valid(e) and e.get("_dead") != true \
					and (e as Node3D).global_position.distance_to(origin) <= radius:
				c += 1
	count = c
	text = str(c)
	modulate = Color(1.0, 0.45, 0.35) if c >= crowd_threshold else Color(0.55, 1.0, 0.6)
	return c


func _process(delta: float) -> void:
	_t -= delta
	if _t <= 0.0:
		_t = 0.25
		refresh()
	if needle and is_instance_valid(needle):
		var want := -deg_to_rad(clampf(float(count) / float(maxi(crowd_threshold * 2, 1)), 0.0, 1.0) * 120.0)
		needle.rotation.x = lerpf(needle.rotation.x, want, clampf(8.0 * delta, 0.0, 1.0))
	if pulse and is_instance_valid(pulse):
		_beat += delta * (1.0 + float(count) * 0.35)
		pulse.visible = fmod(_beat, 1.0) < 0.25 or count == 0
