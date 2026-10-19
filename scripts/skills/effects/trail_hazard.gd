extends SkillEffect
## Sliding drops fire patches (one per `spacing` s) lasting `dur`; zombies within `radius` of a
## patch take dps (ticked every 0.5 s, source "hazard").

var patches: Array = [] ## [{pos, until, node}]
var _last_drop: float = -INF
var _acc: float = 0.0


func has_tick() -> bool:
	return true


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	if now() - _last_drop < float(p("spacing", 0.25)):
		return
	_last_drop = now()
	var pos: Vector3 = player.global_position
	patches.append({"pos": pos, "until": now() + float(p("dur", 2.0)), "node": _spawn_patch(pos)})


func tick(delta: float) -> void:
	for pt in patches.duplicate():
		if now() >= float(pt.until):
			if is_instance_valid(pt.node):
				pt.node.queue_free()
			patches.erase(pt)
	if patches.is_empty():
		_acc = 0.0
		return
	_acc += delta
	if _acc < 0.5:
		return
	_acc -= 0.5
	var burned := {}
	for pt in patches:
		for e in runner.enemies_near(pt.pos + Vector3(0, 0.9, 0), float(p("radius", 1.2)) + 0.9):
			burned[e.get_instance_id()] = e
	for id in burned:
		runner.deal(burned[id], float(p("dps", 20.0)) * 0.5, "hazard", {"depth": 0}, {"element": "blaze"})


func _spawn_patch(pos: Vector3) -> Node3D:
	var scene: Node = player.get_tree().current_scene
	if scene == null:
		return null
	var m := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = float(p("radius", 1.2)) * 0.6
	cm.bottom_radius = cm.top_radius
	cm.height = 0.04
	m.mesh = cm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.45, 0.1, 0.55)
	m.material_override = mat
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(m)
	m.global_position = pos + Vector3(0, 0.03, 0)
	return m


func detach() -> void:
	for pt in patches:
		if is_instance_valid(pt.node):
			pt.node.queue_free()
	patches.clear()
