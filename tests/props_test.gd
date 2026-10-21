extends SceneTree
## Art4 props pass (Skillz, 2026-10-19): Desi's loot_chest.glb in chest.tscn / chest.gd (Idle_Closed / Open / Close),
## health_pack / ammo_box / heavy_ammo pickup GLBs (scale 1.0, TintBand-only tint, old mesh fallback),
## grenade.glb on the thrown grenade (Band tint per type, Arm clip, Light position, sphere fallback),
## and every asset path the art4 wiring references exists (with its .import).
##   godot --headless --path . -s res://tests/props_test.gd   (exit code = failures)
## Uses its own save file, never the real one.

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


const CHEST_GLB := "res://assets/models/props/loot_chest.glb"
const GUNS := ["assault_rifle", "scout_rifle", "sniper", "shotgun", "smg", "pistol", "lmg", "rocket_launcher"]
const PICKUPS := ["health_pack", "ammo_box", "heavy_ammo"]


func _meshes(n: Node) -> Array:
	var out: Array = n.find_children("*", "MeshInstance3D", true, false)
	if n is MeshInstance3D:
		out.push_front(n)
	return out


func _bounds(root: Node3D) -> AABB:
	var bb := AABB()
	var first := true
	var inv := root.global_transform.affine_inverse()
	for mi in _meshes(root):
		var b: AABB = (inv * (mi as MeshInstance3D).global_transform) * (mi as MeshInstance3D).get_aabb()
		bb = b if first else bb.merge(b)
		first = false
	return bb


func _run() -> void:
	var prog: Node = root.get_node("Progress")
	var test_dir := OS.get_user_data_dir().path_join("props_test")
	DirAccess.make_dir_recursive_absolute(test_dir)
	prog.save_path = test_dir.path_join("progress_props_test.cfg")
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	prog.gravemarks = 0
	prog.bind_inventory(null)
	var world := Node3D.new()
	world.name = "PropsWorld"
	root.add_child(world)
	current_scene = world
	await process_frame
	_asset_paths()
	await _chest(world)
	_pickups(world)
	await _grenade(world)
	world.queue_free()
	await process_frame
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	print("props_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)


# ================================================================== asset paths
func _asset_paths() -> void:
	var paths: Array = [CHEST_GLB, "res://scenes/chest.tscn", "res://scenes/pickup.tscn"]
	for g in GUNS:
		paths.append("res://assets/models/weapons/weapon_%s.glb" % g)
	for id in PICKUPS:
		var it = load("res://resources/items/%s.tres" % id)
		paths.append(it.model_path)
		paths.append(it.fallback_model_path)
	paths.append(load("res://scripts/combat/grenade.gd").MODEL_PATH)
	var cs := FileAccess.get_file_as_string("res://scenes/chest.tscn")
	for line in cs.split("\n"):
		if line.begins_with("[ext_resource"):
			paths.append(line.get_slice('path="', 1).get_slice('"', 0))
	var missing: Array = []
	for p in paths:
		if p == "" or not ResourceLoader.exists(p):
			missing.append(p)
		elif (p as String).get_extension() in ["glb", "gltf"] and not FileAccess.file_exists(p + ".import"):
			missing.append(p + ".import")
	check(missing.is_empty(), "every art4 asset path exists and is imported (%d paths) %s" % [paths.size(), missing])
	check(not cs.contains("wooden_crate_02"), "chest.tscn no longer references the old wooden_crate_02 model")


# ================================================================== chest
func _chest(world: Node3D) -> void:
	var scn := load("res://scenes/chest.tscn") as PackedScene
	var c = scn.instantiate()
	var model: Node3D = c.get_node("Model")
	check(model.scene_file_path == CHEST_GLB and model.transform.is_equal_approx(Transform3D.IDENTITY),
		"chest.tscn Model = loot_chest.glb with an identity transform")
	var names: Array = []
	for n in ["Base", "Lid", "LootSpawn", "InteractPoint"]:
		if model.find_child(n, true, false) == null:
			names.append(n)
	check(names.is_empty(), "loot_chest.glb has Base / Lid / LootSpawn / InteractPoint %s" % [names])
	world.add_child(c)
	await process_frame
	var ap: AnimationPlayer = c.anim
	check(ap != null and ap.has_animation("Open") and ap.has_animation("Close") and ap.has_animation("Idle_Closed")
		and absf(ap.get_animation("Open").length - 0.6) < 0.02 and absf(ap.get_animation("Close").length - 0.4) < 0.02,
		"chest AnimationPlayer has Open 0.6 s / Close 0.4 s / Idle_Closed")
	check(c.last_clip == "Idle_Closed" and ap.current_animation == "Idle_Closed", "_ready plays Idle_Closed")
	var lid: Node3D = model.find_child("Lid", true, false)
	var shut_rot: float = lid.rotation.x
	# collision still fits the new mesh (Desi: fits BoxShape3D 2.3 x 0.93 x 1.06 @ y 0.47)
	var bb := _bounds(model)
	var box: BoxShape3D = (c.get_node("CollisionShape3D") as CollisionShape3D).shape
	var by: float = (c.get_node("CollisionShape3D") as Node3D).position.y
	check(absf(bb.size.y - box.size.y) < 0.05 and absf(bb.size.z - box.size.z) < 0.05 and absf(bb.size.x - box.size.x) < 0.1
		and absf(bb.get_center().y - by) < 0.05, "chest collision box %s @ y %.2f fits the loot_chest bounds %s" % [box.size, by, bb.size])
	var ls: Node3D = model.find_child("LootSpawn", true, false)
	check((c.get_node("Glow") as Node3D).position.is_equal_approx(ls.position + Vector3(0, 0.6, 0)), "Glow sits at LootSpawn + (0, 0.6, 0)")
	# interact -> Open
	c.interact(null)
	check(c.is_open and c.last_clip == "Open" and ap.current_animation == "Open", "interact() plays Open")
	ap.advance(0.7)
	var open_rot: float = lid.rotation.x
	check(rad_to_deg(open_rot) < -90.0, "after Open the Lid is swung open (%.0f deg)" % rad_to_deg(open_rot))
	check(not c.can_interact() and not (c.get_node("Glow") as Node3D).visible, "an open chest can't be re-opened and its glow is off")
	await process_frame
	c.model.scale = Vector3.ONE
	c.rearm(2)
	check(not c.is_open and c.last_clip == "Close" and ap.current_animation == "Close" and c.round_number == 2, "rearm() of an open chest plays Close")
	ap.advance(0.5)
	check(absf(lid.rotation.x - shut_rot) < 0.01, "after Close the Lid is shut again (%.1f deg)" % rad_to_deg(lid.rotation.x))
	c.last_clip = ""
	c.rearm(3)
	check(c.last_clip == "" and c.can_interact(), "rearm() of a closed chest doesn't replay Close (no lid pop)")
	c.queue_free()
	# fallback: a model with no AnimationPlayer (old mesh / stripped build) still opens and re-arms
	var c2 = scn.instantiate()
	var old: Node = c2.get_node("Model")
	c2.remove_child(old)
	old.free()
	var plain := Node3D.new()
	plain.name = "Model"
	c2.add_child(plain)
	world.add_child(c2)
	await process_frame
	check(c2.anim == null and c2.play_clip("Open") == false, "chest without an AnimationPlayer: play_clip() is a no-op")
	c2.interact(null)
	c2.rearm(2)
	check(not c2.is_open and c2.can_interact(), "...and interact()/rearm() still work")
	c2.queue_free()
	await process_frame


# ================================================================== pickups
func _pickup(world: Node3D, item) -> Node:
	var p = (load("res://scenes/pickup.tscn") as PackedScene).instantiate()
	p.item = item
	world.add_child(p)
	return p


func _pickups(world: Node3D) -> void:
	for id in PICKUPS:
		var it = load("res://resources/items/%s.tres" % id)
		check(it.model_path == "res://assets/models/pickups/%s.glb" % id and is_equal_approx(it.model_scale, 1.0)
			and it.fallback_model_path.begins_with("res://assets/models/props/"),
			"%s.tres: model_path pickups/%s.glb, model_scale 1.0, fallback %s x%.1f" % [id, id, it.fallback_model_path.get_file(), it.fallback_model_scale])
		var p = _pickup(world, it)
		var vis: Node3D = p._visual
		check(vis != null and vis.scene_file_path == it.model_path and vis.scale.is_equal_approx(Vector3.ONE) and is_equal_approx((p.label as Node3D).position.y, 0.8),
			"%s pickup shows %s at scale 1.0 (label at 0.8)" % [id, it.model_path.get_file()])
		var tinted: Array = []
		for mi in _meshes(vis):
			if (mi as MeshInstance3D).material_override:
				tinted.append(str(mi.name))
		if id == "heavy_ammo":
			var tb := vis.find_child("TintBand", true, false) as MeshInstance3D
			var m := tb.material_override as StandardMaterial3D if tb else null
			check(tinted == ["TintBand"] and m != null and m.albedo_color.is_equal_approx(it.color),
				"heavy_ammo: only TintBand is tinted (item colour), the box keeps its textures %s" % [tinted])
		else:
			check(tinted.is_empty(), "%s: no tint, Desi's textures show %s" % [id, tinted])
		p.free()
		# old mesh fallback when the GLB is missing
		var miss = it.duplicate()
		miss.model_path = "res://assets/models/pickups/__missing__.glb"
		var pf = _pickup(world, miss)
		check(pf._visual != null and pf._visual.scene_file_path == it.fallback_model_path
			and pf._visual.scale.is_equal_approx(Vector3.ONE * it.fallback_model_scale),
			"%s: missing GLB falls back to %s x%.1f" % [id, it.fallback_model_path.get_file(), it.fallback_model_scale])
		if id == "heavy_ammo":
			var all := true
			for mi in _meshes(pf._visual):
				all = all and (mi as MeshInstance3D).material_override != null
			check(all, "heavy_ammo fallback (no TintBand): whole old mesh tinted as before")
		pf.free()


# ================================================================== grenade
func _grenade(world: Node3D) -> void:
	var G = load("res://scripts/combat/grenade.gd")
	var gdb: Node = root.get_node("GearDB")
	var thrower := Node3D.new()
	world.add_child(thrower)
	var want := {"frag": Color.html("#FF8C33"), "pulse": Color.html("#7FB8FF")} # playtest #25: hex effect tints
	for gid in ["frag", "pulse"]:
		var data: Dictionary = gdb.grenade(gid)
		var g = G.throw_from(thrower, data, Vector3(0, 50, 0), Vector3.FORWARD, Vector3.ZERO)
		var vis: Node3D = g.visual
		check(vis != null and vis.scene_file_path == G.VARIANT_DIR + "frag.glb", "%s: thrown grenade shows Desi's bone-trim grenades/frag.glb" % gid)
		var band := vis.find_child("Band", true, false) as MeshInstance3D
		var bm := band.material_override as StandardMaterial3D if band else null
		check(bm != null and bm == g.band_material and bm.albedo_color.is_equal_approx(want[gid]) and bm.emission.is_equal_approx(want[gid])
			and bm.emission_enabled, "%s: Band recoloured %s (emissive)" % [gid, want[gid]])
		var others := 0
		for mi in _meshes(vis):
			if mi != band and (mi as MeshInstance3D).material_override:
				others += 1
		check(others == 0, "%s: only the Band is overridden (Body/Spoon/Pin keep Desi's textures)" % gid)
		var ap := vis.find_child("AnimationPlayer", true, false) as AnimationPlayer
		check(ap != null and ap.current_animation == "Arm", "%s: Arm clip plays on throw" % gid)
		var lnode := vis.find_child("Light", true, false) as Node3D
		check(lnode != null and g._light.position.is_equal_approx(lnode.position), "%s: fuse light at the GLB's Light node %s" % [gid, lnode.position if lnode else null])
		var shapes: Array = g.find_children("*", "CollisionShape3D", false, false)
		check(shapes.size() == 1 and is_equal_approx(((shapes[0] as CollisionShape3D).shape as SphereShape3D).radius, 0.09), "%s: collision stays SphereShape3D r 0.09" % gid)
		var lo := INF
		var hi := -INF
		for i in 12:
			g._t += 0.01
			g._fuse = 99.0
			g._physics_process(0.0)
			lo = minf(lo, bm.emission_energy_multiplier)
			hi = maxf(hi, bm.emission_energy_multiplier)
		check(lo >= 1.0 and hi <= 4.0 and hi - lo > 1.0, "%s: Band emission pulses with the fuse (%.2f..%.2f)" % [gid, lo, hi])
		g.free()
	# fallback: no GLB -> the old dark sphere, still type-tinted
	G.model_path = "res://assets/models/pickups/__missing__.glb"
	var gf = G.throw_from(thrower, gdb.grenade("pulse"), Vector3(0, 50, 0), Vector3.FORWARD, Vector3.ZERO)
	var mi := gf.visual as MeshInstance3D
	check(mi != null and mi.mesh is SphereMesh and (mi.material_override as StandardMaterial3D).emission.is_equal_approx(want.pulse) and gf.band_material == null,
		"missing grenade.glb falls back to the tinted sphere")
	gf._t = 0.05
	gf._fuse = 99.0
	gf._physics_process(0.0)
	check(true, "fallback grenade ticks without a Band")
	gf.free()
	G.model_path = G.MODEL_PATH
	thrower.free()
	await process_frame
