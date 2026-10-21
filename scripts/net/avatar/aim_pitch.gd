class_name NetAimPitch
extends SkeletonModifier3D
## Remote aim pitch on Desi's spine (NETZ_NOTES: "not baked; rotate spine_03 by camera pitch after the tree").
## Runs after the AnimationTree each frame: the replicated head pitch (rad, + = looking up) is split over the
## data/net.json avatar.aim_pitch.bones weights (spine_02 / spine_03 / neck_01) and applied as a rotation about the
## avatar's own right axis, so the rifle, arms and head follow where that player looks. Only while alive (no lean in
## Downed / Revive / Death); smoothed, clamped to max_deg.

var body: Node3D ## the NetAvatarBody (its -Z = where the player faces)
var target := 0.0 ## rad
var current := 0.0
var enabled_life := true
var _bones: Array = [] ## [[bone idx, weight], ...] from the root of the chain up
var _cfg_done := false


func _cfg() -> void:
	_cfg_done = true
	var sk := get_skeleton()
	var c: Dictionary = NetConfig.get_value("avatar.aim_pitch", {})
	var w: Dictionary = c.get("bones", {"spine_02": 0.3, "spine_03": 0.45, "neck_01": 0.25})
	_bones.clear()
	if sk == null:
		return
	for n in w:
		var i := sk.find_bone(str(n))
		if i >= 0:
			_bones.append([i, float(w[n])])
	_bones.sort_custom(func(a, b): return a[0] < b[0]) # parents before children (glTF bone order)


func max_rad() -> float:
	return deg_to_rad(float(NetConfig.get_value("avatar.aim_pitch.max_deg", 70.0)))


func _process_modification_with_delta(delta: float) -> void:
	if not _cfg_done:
		_cfg()
	var goal := clampf(target, -max_rad(), max_rad()) if enabled_life else 0.0
	var k := clampf(delta * float(NetConfig.get_value("avatar.aim_pitch.smooth", 14.0)), 0.0, 1.0)
	current = lerpf(current, goal, k)
	var sk := get_skeleton()
	if sk == null or body == null or absf(current) < 0.0005 or _bones.is_empty():
		return
	var fwd := -body.global_transform.basis.z.normalized()
	var right := fwd.cross(Vector3.UP)
	if right.length() < 0.01:
		return
	var axis := (sk.global_transform.basis.orthonormalized().inverse() * right.normalized()).normalized() # skeleton space
	for e in _bones:
		var bi: int = e[0]
		var gp := sk.get_bone_global_pose(bi)
		var rot := Basis(axis, current * float(e[1])) * gp.basis
		var par := sk.get_bone_parent(bi)
		var pb := sk.get_bone_global_pose(par).basis if par >= 0 else Basis()
		sk.set_bone_pose_rotation(bi, (pb.orthonormalized().inverse() * rot.orthonormalized()).get_rotation_quaternion())
