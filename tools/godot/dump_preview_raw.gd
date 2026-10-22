extends SceneTree
## Map-select preview, step 1 (Mapz, playtest #4). Headless, read-only: instantiates each map scene (not added to the tree,
## so no _ready runs) and dumps raw top-down data to JSON for tools/build_map_previews.py.
## usage: godot --headless --path . -s res://tools/godot/dump_preview_raw.gd -- <id>=<res://scene.tscn> ... --out=<dir>
func _initialize() -> void:
	var out_dir := "/tmp"
	var jobs := []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="): out_dir = a.substr(6)
		elif "=" in a: jobs.append(a.split("=", true, 1))
	for j in jobs:
		var ps: PackedScene = load(j[1])
		var root: Node = ps.instantiate()
		var d := _dump(root)
		d["id"] = j[0]; d["scene"] = j[1]
		var f := FileAccess.open(out_dir + "/" + j[0] + "_raw.json", FileAccess.WRITE)
		f.store_string(JSON.stringify(d))
		f.close()
		print("DUMP %s colliders=%d markers=%d doors=%d" % [j[0], d.colliders.size(), d.markers.size(), d.doors.size()])
		root.free()
	quit(0)

func _gt(n: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var c := n
	while c != null:
		if c is Node3D: t = (c as Node3D).transform * t
		c = c.get_parent()
	return t

func _rel(root: Node, n: Node) -> String:
	return str(root.get_path_to(n)) if n.is_inside_tree() else _manual_path(root, n)

func _manual_path(root: Node, n: Node) -> String:
	var parts := []
	var c := n
	while c != null and c != root:
		parts.push_front(str(c.name)); c = c.get_parent()
	return "/".join(parts)

func _v(p: Vector3) -> Array: return [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]

func _dump(root: Node) -> Dictionary:
	var cols := []; var markers := []; var doors := []
	var stack := [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children(): stack.append(c)
		var path := _manual_path(root, n)
		if n is CollisionShape3D and not (n as CollisionShape3D).disabled and (n as CollisionShape3D).shape:
			var body := n.get_parent()
			if not body is CollisionObject3D: continue
			if not body is StaticBody3D and not body is AnimatableBody3D: continue
			if ((body as CollisionObject3D).collision_layer & 1) == 0: continue
			var g := _gt(n)
			var sh: Shape3D = (n as CollisionShape3D).shape
			var pts := PackedVector3Array()
			if sh is BoxShape3D:
				var h: Vector3 = (sh as BoxShape3D).size * 0.5
				for sx in [-1, 1]: for sy in [-1, 1]: for sz in [-1, 1]: pts.append(g * Vector3(sx * h.x, sy * h.y, sz * h.z))
			elif sh is ConvexPolygonShape3D:
				for p in (sh as ConvexPolygonShape3D).points: pts.append(g * p)
			elif sh is ConcavePolygonShape3D:
				for p in (sh as ConcavePolygonShape3D).get_faces(): pts.append(g * p)
			elif sh is CylinderShape3D or sh is CapsuleShape3D:
				var r: float = sh.radius; var hh: float = sh.height * 0.5
				for k in 12:
					var an := TAU * k / 12.0
					for sy in [-1, 1]: pts.append(g * Vector3(cos(an) * r, sy * hh, sin(an) * r))
			else:
				continue
			var flat := []
			for p in pts: flat.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)])
			cols.append({"path": path, "type": sh.get_class(), "pts": flat})
		elif n is Node3D:
			var nm := str(n.name)
			var g := _gt(n)
			if n.get_parent() != null and str(n.get_parent().name) == "Doors" and n.get_script() != null:
				var w := 0.0
				for c in n.find_children("*", "CollisionShape3D", true, false):
					var s: Shape3D = (c as CollisionShape3D).shape
					if s is BoxShape3D: w = maxf(w, maxf((s as BoxShape3D).size.x, (s as BoxShape3D).size.z))
				doors.append({"pos": _v(g.origin), "axis": _v(g.basis.x.normalized()), "width": snappedf(w, 0.01), "path": path})
			elif nm in ["PlayerSpawn", "PowerWeaponSpot", "PerkMachineSpot", "MysteryBoxSpot"] and n.get_parent() == root:
				markers.append({"kind": nm, "pos": _v(g.origin)})
			elif nm == "Player" and n.get_parent() == root:
				markers.append({"kind": "PlayerStart", "pos": _v(g.origin)})
			elif nm == "BossArenaHook":
				markers.append({"kind": "BossArenaHook", "pos": _v(n.get_meta("arena_center", g.origin)), "radius": float(n.get_meta("radius", 6.0))})
			elif n.get_parent() != null and str(n.get_parent().name) == "Chests" and n.get_parent().get_parent() == root:
				markers.append({"kind": "Chest", "pos": _v(g.origin)})
	var b = root.get_meta("bounds", null)
	return {"colliders": cols, "markers": markers, "doors": doors, "bounds": [b.position.x, b.position.z, b.size.x, b.size.z] if b is AABB else null}
