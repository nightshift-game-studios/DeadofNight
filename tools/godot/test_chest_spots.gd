extends SceneTree
## Chest relocation spot check (Mapz, contract v0.4 / Skillz format). Headless, read-only.
## Usage: godot --headless --path . -s res://tools/godot/test_chest_spots.gd -- res://maps/<m>/<m>.tscn [more.tscn ...]
## Exit 0 = all pass, 1 = any failure. Prints "CHEST_SPOTS_RESULT <map> {...}" and a final "CHEST_SPOTS_SUITE ... PASS|FAIL".
## Checks per map: ChestSpots node; 8-12 children, each an EMPTY Marker3D in the persistent group chest_spot; meta area
## (StringName, or Array of StringName for boundary spots), hidden (bool), initial (bool), weight (int, optional);
## initial spots == the Chests/ markers (position within 0.05 m); >= 6 m apart and >= 6 m from PlayerSpawn; >= 2 spots
## per area tag used by SpawnPoints (>= 1 on maps with 6+ area tags); floor under the 1.2 x 0.8 m footprint (origin on the floor, no void); footprint
## (0.05-1.05 m) and the 1.2 x 1.2 x 1.8 m zone in front (-Z) free of layer-1 collision; the front zone on the navmesh
## and reachable from PlayerSpawn with all doors open; nav carve compatibility: with a 1.2 x 0.8 m carve at EVERY spot
## at once, every spot front and every SpawnPoint still reaches PlayerSpawn.
const FOOT := Vector3(1.2, 1.0, 0.8)
var fails := 0
var sp: PhysicsDirectSpaceState3D
func _initialize() -> void: _main.call_deferred()
func _chk(ok: bool, msg: String, lines: Array) -> void:
	lines.append(("PASS  " if ok else "FAIL  ") + msg)
	if not ok: fails += 1
func _main() -> void:
	var maps := OS.get_cmdline_user_args()
	var total_fail := 0
	for m in maps:
		if not m.ends_with(".tscn"): continue
		fails = 0
		var lines := []
		await _test(m, lines)
		for l in lines: print(l)
		print("CHEST_SPOTS_RESULT %s fails=%d" % [m.get_file().get_basename(), fails])
		total_fail += fails
	print("CHEST_SPOTS_SUITE maps=%d fails=%d -> %s" % [maps.size(), total_fail, "PASS" if total_fail == 0 else "FAIL"])
	quit(0 if total_fail == 0 else 1)
var exclude: Array[RID] = [] ## colliders of real chest instances under Chests/ (the arena) are not geometry
func _collect_rids(n: Node) -> void:
	if n is CollisionObject3D: exclude.append(n.get_rid())
	for c in n.get_children(): _collect_rids(c)
func _box_free(c: Vector3, size: Vector3, bas: Basis) -> bool:
	var q := PhysicsShapeQueryParameters3D.new(); q.exclude = exclude
	var bs := BoxShape3D.new(); bs.size = size; q.shape = bs
	q.transform = Transform3D(bas, c); q.collision_mask = 1
	return sp.intersect_shape(q, 1).is_empty()
func _floor(p: Vector3) -> Dictionary:
	return sp.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 0.6, 0), p - Vector3(0, 0.6, 0), 1))
func _reach(rid: RID, a: Vector3, b: Vector3) -> bool:
	var ca := NavigationServer3D.map_get_closest_point(rid, a); var cb := NavigationServer3D.map_get_closest_point(rid, b)
	if Vector2(cb.x - b.x, cb.z - b.z).length() > 0.6: return false
	var p := NavigationServer3D.map_get_path(rid, ca, cb, true)
	return p.size() > 0 and p[p.size() - 1].distance_to(cb) < 0.6
func _sync(rid: RID) -> void:
	NavigationServer3D.map_force_update(rid)
	for i in 30: await physics_frame
	NavigationServer3D.map_force_update(rid)
	for i in 5: await physics_frame
func _test(path: String, L: Array) -> void:
	var ps: PackedScene = load(path)
	_chk(ps != null, "loads " + path, L)
	if ps == null: return
	var map: Node3D = ps.instantiate()
	if map.get_script() and not map.get_script().resource_path.ends_with("map_root.gd"): map.set_script(null)
	root.add_child(map)
	var cs := map.get_node_or_null("ChestSpots")
	_chk(cs != null, "ChestSpots node", L)
	if cs == null:
		map.queue_free(); return
	var spots := cs.get_children()
	_chk(spots.size() >= 8 and spots.size() <= 12, "count %d in 8..12" % spots.size(), L)
	var fmt_bad := []
	for s in spots:
		var ok: bool = s is Marker3D and s.get_child_count() == 0 and s.is_in_group("chest_spot")
		var a = s.get_meta("area", null)
		ok = ok and (a is StringName or (a is Array and a.size() > 0 and a.all(func(x): return x is StringName)))
		ok = ok and s.get_meta("hidden", null) is bool and s.get_meta("initial", null) is bool
		ok = ok and (not s.has_meta("weight") or s.get_meta("weight") is int)
		if not ok: fmt_bad.append(s.name)
	_chk(fmt_bad.is_empty(), "format: empty Marker3D, group chest_spot (persistent), meta area/hidden/initial/weight %s" % (fmt_bad if fmt_bad.size() else ""), L)
	var groups_saved := FileAccess.get_file_as_string(path).count('parent="ChestSpots"') == FileAccess.get_file_as_string(path).count('parent="ChestSpots" ') and FileAccess.get_file_as_string(path).count('groups=["chest_spot"]') >= spots.size()
	_chk(groups_saved, "group chest_spot saved in the .tscn for every spot", L)
	var chests := map.get_node("Chests").get_children() if map.has_node("Chests") else []
	var init := spots.filter(func(s): return s.get_meta("initial", false))
	var unmatched := chests.filter(func(c): return not init.any(func(s): return s.global_position.distance_to(c.global_position) < 0.05))
	_chk(init.size() == chests.size() and unmatched.is_empty(), "initial spots (%d) == Chests/ markers (%d)" % [init.size(), chests.size()], L)
	# PlayerSpawn, or (arena: main.tscn has none) the Player instance's start, which main.gd uses then
	var pspawn: Vector3 = map.get_node("PlayerSpawn").global_position if map.has_node("PlayerSpawn") else (map.get_node("Player").global_position if map.has_node("Player") else Vector3.ZERO)
	if map.has_node("Player"): map.get_node("Player").free() # no live player in the probe
	var mind := INF; var minp := INF
	for i in spots.size():
		minp = minf(minp, spots[i].global_position.distance_to(pspawn))
		for j in range(i + 1, spots.size()): mind = minf(mind, spots[i].global_position.distance_to(spots[j].global_position))
	_chk(mind >= 6.0, "spacing >= 6 m (min %.1f)" % mind, L)
	_chk(minp >= 6.0, ">= 6 m from PlayerSpawn (min %.1f)" % minp, L)
	var per := {}
	for s in spots:
		var a = s.get_meta("area")
		for t in (a if a is Array else [a]): per[t] = int(per.get(t, 0)) + 1
	var area_tags := {}
	if map.has_node("SpawnPoints"):
		for s in map.get_node("SpawnPoints").get_children(): if s.has_meta("area"): area_tags[s.get_meta("area")] = true
	var need := 1 if area_tags.size() >= 6 else 2 # large maps (6+ areas): 8-12 spots cannot give every area 2
	var thin := area_tags.keys().filter(func(t): return int(per.get(t, 0)) < need)
	_chk(thin.is_empty(), ">= %d spots per area %s %s" % [need, per, ("missing " + str(thin)) if thin.size() else ""], L)
	# geometry
	if "rebake_on_door_open" in map: map.set("rebake_on_door_open", false)
	if map.has_node("NavigationRegion3D/Doors"):
		for d in map.get_node("NavigationRegion3D/Doors").get_children(): if d.has_method("open"): d.open()
	for i in 90: await physics_frame
	sp = root.world_3d.direct_space_state
	exclude.clear()
	for c in chests: _collect_rids(c)
	var geo_bad := []
	for s in spots:
		var o: Vector3 = s.global_position
		var bas: Basis = s.global_transform.basis.orthonormalized()
		var why := ""
		for cx in [-0.6, 0.0, 0.6]:
			for cz in [-0.4, 0.4]:
				var f := _floor(o + bas * Vector3(cx, 0, cz))
				if f.is_empty() or absf(f.position.y - o.y) > 0.06: why = "no floor under footprint"
		if not _box_free(o + Vector3(0, 0.55, 0), FOOT, bas): why += " footprint blocked"
		if not _box_free(o + bas * Vector3(0, 0, -1.0) + Vector3(0, 0.95, 0), Vector3(1.2, 1.8, 1.2), bas): why += " front blocked"
		if why != "": geo_bad.append("%s %s" % [s.name, why])
	_chk(geo_bad.is_empty(), "floor + footprint + 1.2 m front clear %s" % (geo_bad if geo_bad.size() else ""), L)
	var nav: NavigationRegion3D = map.get_node("NavigationRegion3D")
	var rid := nav.get_navigation_map()
	nav.bake_navigation_mesh(false); await _sync(rid)
	nav.bake_navigation_mesh(false); await _sync(rid)
	var unreach := spots.filter(func(s): return not _reach(rid, pspawn, s.global_position + s.global_transform.basis * Vector3(0, 0, -1.0)))
	_chk(unreach.is_empty(), "every spot front on nav + reachable from PlayerSpawn (doors open) %s" % (unreach.map(func(s): return s.name) if unreach.size() else ""), L)
	# carve compatibility: chests at all spots at once
	var carves := []
	var carve_root := nav.get_node_or_null("NavCarves")
	if carve_root == null:
		carve_root = Node3D.new(); nav.add_child(carve_root)
	for s in spots:
		var ob := NavigationObstacle3D.new()
		var pts := PackedVector3Array()
		for c in [Vector3(-0.6, 0, -0.4), Vector3(0.6, 0, -0.4), Vector3(0.6, 0, 0.4), Vector3(-0.6, 0, 0.4)]:
			pts.append(s.global_transform.basis.orthonormalized() * c)
		ob.vertices = pts; ob.height = 1.0; ob.affect_navigation_mesh = true; ob.carve_navigation_mesh = true; ob.avoidance_enabled = false
		carve_root.add_child(ob); ob.global_position = s.global_position - Vector3(0, 0.2, 0)
		carves.append(ob)
	for i in 3: await physics_frame
	nav.bake_navigation_mesh(false); await _sync(rid)
	var unreach2 := spots.filter(func(s): return not _reach(rid, pspawn, s.global_position + s.global_transform.basis * Vector3(0, 0, -1.2)))
	var sp_bad := []
	if map.has_node("SpawnPoints"):
		for s in map.get_node("SpawnPoints").get_children():
			if not _reach(rid, s.global_position, pspawn): sp_bad.append(s.name)
	_chk(unreach2.is_empty() and sp_bad.is_empty(), "nav carve compatible (all spots carved): spot fronts %s, spawns %s reach PlayerSpawn" % ["ok" if unreach2.is_empty() else str(unreach2.map(func(s): return s.name)), "ok" if sp_bad.is_empty() else str(sp_bad)], L)
	for c in carves: c.queue_free()
	map.queue_free()
	for i in 3: await physics_frame
