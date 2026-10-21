extends SceneTree
## Void-gap / floor-coverage test (Mapz). Headless, read-only: loads a map, never saves it.
##
## Usage (from the project root):
##   godot --headless --path . -s res://tools/godot/test_void_gaps.gd -- res://maps/lockout_substation/lockout_substation.tscn [more.tscn ...]
##         [--step=0.25] [--margin=1.0] [--depth=3.0] [--json=user://void_gaps.json] [--no-visual] [--verbose]
##         [--skip=Chests,Pickups]   (node paths relative to the map root whose bodies + meshes are ignored; default none)
## With no map arguments it tests res://maps/rustwell_foundry/rustwell_foundry.tscn and res://maps/lockout_substation/lockout_substation.tscn.
## Exit code: 0 = no holes on any map, 1 = at least one hole (or a map failed to load). Last line: "VOID_SUITE ... PASS|FAIL".
##
## Checks, on a grid (default every 0.25 m) over the play area of each map:
##   VOID          downward physics rays (layer 1) from above the whole map: the play area must have collision under it, and
##                 the lowest hit may not be more than --depth below the lowest walkable level (ray falls into the void).
##   NAV_NO_FLOOR  every navmesh sample (all doors open): a collider must sit within 1.0 m under it
##                 (ray from 0.5 m above the nav surface; the navmesh floats ~0.26 m over floors).
##   VISUAL_HOLE   where there is a walkable collision floor (under a nav sample, or bare single-surface ground), a visible
##                 mesh must cover it from 0.3 m above to 0.75 m below (stepped stair art under a smooth ramp collider is ok). Mesh raycast: every visible MeshInstance3D / MultiMesh instance is
##                 mirrored as a trimesh on a private physics layer (20), so this tests what the player SEES.
##   SEAM          extra samples 0.03 m outside every collider / visible-mesh footprint edge (spacing step/2), so slits
##                 narrower than the grid between slabs, wedges and ridges are caught (physics void + visual void).
## Causes: "visual floor without collider" (a mesh covers it, no collision does), "open hole (collision + visual)",
## "no visual" (collision only), "collision gap, visual covered", "visual gap, collision covered".
## Play area = navmesh footprint (all doors open) dilated by --margin (default 1.0 m), so wall feet, cover and the nav
## erosion band along edges are tested too.
## Intended pits: any Node3D with meta `intended_pit = true` is excluded. Footprint = meta `pit_size` (Vector3, centred on
## the node) if set, else the global XZ AABB of its meshes / collision shapes. Bodies under Clip/ are ignored (invisible
## boundary clips are not floors). A non-map root script (e.g. scenes/main.tscn's main.gd) is stripped before the scene
## enters the tree, so the arena is tested as geometry only.

const VIS_LAYER := 1 << 19
var step := 0.25
var margin := 1.0
var depth := 3.0
var do_visual := true
var verbose := false
var json_path := ""
var skip_paths: PackedStringArray = []
var space: PhysicsDirectSpaceState3D
var clip_rids: Array[RID] = []
const NO_RIDS: Array[RID] = []

func _initialize() -> void:
	_main.call_deferred()

func _main() -> void:
	var maps: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--step="): step = float(a.get_slice("=", 1))
		elif a.begins_with("--margin="): margin = float(a.get_slice("=", 1))
		elif a.begins_with("--depth="): depth = float(a.get_slice("=", 1))
		elif a.begins_with("--json="): json_path = a.get_slice("=", 1)
		elif a == "--no-visual": do_visual = false
		elif a.begins_with("--skip="): skip_paths = a.get_slice("=", 1).split(",", false)
		elif a == "--verbose": verbose = true
		elif a.ends_with(".tscn"): maps.append(a)
	if maps.is_empty():
		maps = ["res://maps/rustwell_foundry/rustwell_foundry.tscn", "res://maps/lockout_substation/lockout_substation.tscn"]
	var total := 0
	var all := {}
	for m in maps:
		var r: Dictionary = await _test_map(m)
		all[m] = r
		total += int(r.get("holes", 1))
	if json_path != "":
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f: f.store_string(JSON.stringify(all, "  "))
	print("VOID_SUITE maps=%d holes=%d -> %s" % [maps.size(), total, "PASS" if total == 0 else "FAIL"])
	quit(0 if total == 0 else 1)

# ------------------------------------------------------------------ rays
func _ray(from: Vector3, to: Vector3, mask: int, excl: Array[RID]) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, excl)
	q.hit_back_faces = false
	return space.intersect_ray(q)

func _hits(x: float, z: float, y0: float, y1: float, mask: int, maxn := 10) -> Array:
	## all surfaces along a downward ray (y0 > y1), top first
	var out := []
	var y := y0
	for i in maxn:
		var h := _ray(Vector3(x, y, z), Vector3(x, y1, z), mask, clip_rids if mask == 1 else NO_RIDS)
		if h.is_empty(): break
		out.append(h)
		y = h.position.y - 0.02
		if y <= y1: break
	return out

# ------------------------------------------------------------------ map
func _test_map(path: String) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var ps: PackedScene = load(path)
	if ps == null:
		print("VOID_FAIL load %s" % path)
		return {"holes": 1, "error": "load"}
	var map: Node3D = ps.instantiate()
	var scr: Script = map.get_script()
	if scr and not scr.resource_path.ends_with("map_root.gd"):
		map.set_script(null)
	root.add_child(map)
	for i in 3: await physics_frame
	var nav: NavigationRegion3D = map.get_node_or_null("NavigationRegion3D")
	if nav == null:
		var regs := map.find_children("*", "NavigationRegion3D", true, false)
		nav = regs[0] if regs.size() else null
	if nav == null:
		print("VOID_FAIL %s: no NavigationRegion3D" % path)
		map.queue_free(); return {"holes": 1, "error": "nav"}
	if "rebake_on_door_open" in map: map.set("rebake_on_door_open", false)
	var doors := map.get_node_or_null("NavigationRegion3D/Doors")
	if doors:
		for d in doors.get_children():
			if d.has_method("open"): d.open()
	for i in 90: await physics_frame
	nav.bake_navigation_mesh(false)
	for i in 5: await physics_frame
	var kill_y: float = -25.0
	if "kill_y" in map: kill_y = float(map.get("kill_y"))
	elif map.has_meta("kill_y"): kill_y = float(map.get_meta("kill_y"))
	space = root.world_3d.direct_space_state
	clip_rids.clear()
	var clip := map.get_node_or_null("Clip")
	if clip:
		for b in clip.find_children("*", "CollisionObject3D", true, false): clip_rids.append(b.get_rid())
	var skip_nodes: Array[Node] = []
	for sp in skip_paths:
		var sn := map.get_node_or_null(NodePath(sp))
		if sn == null: continue
		skip_nodes.append(sn)
		if sn is CollisionObject3D: clip_rids.append(sn.get_rid())
		for b in sn.find_children("*", "CollisionObject3D", true, false): clip_rids.append(b.get_rid())

	# ---- nav samples per cell
	var nm := nav.navigation_mesh
	var xf := nav.global_transform
	var wv := PackedVector3Array()
	for v in nm.get_vertices(): wv.append(xf * v)
	var lo := Vector2(INF, INF); var hi := Vector2(-INF, -INF); var nav_min_y := INF; var nav_max_y := -INF
	for v in wv:
		lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.z)); hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.z))
		nav_min_y = minf(nav_min_y, v.y); nav_max_y = maxf(nav_max_y, v.y)
	if wv.is_empty():
		print("VOID_FAIL %s: navmesh empty" % path)
		map.queue_free(); return {"holes": 1, "error": "navmesh empty"}
	lo -= Vector2(margin + step, margin + step); hi += Vector2(margin + step, margin + step)
	var ox := floorf(lo.x / step) * step; var oz := floorf(lo.y / step) * step
	var W := int(ceil((hi.x - ox) / step)); var H := int(ceil((hi.y - oz) / step))
	var navc := {}   # cell idx -> PackedFloat32Array of nav y
	var navmask := PackedByteArray(); navmask.resize(W * H)
	for pi in nm.get_polygon_count():
		var poly := nm.get_polygon(pi)
		var pts: Array[Vector3] = []
		for vi in poly: pts.append(wv[vi])
		var a := Vector2(INF, INF); var b := Vector2(-INF, -INF)
		for p in pts: a = Vector2(minf(a.x, p.x), minf(a.y, p.z)); b = Vector2(maxf(b.x, p.x), maxf(b.y, p.z))
		for ix in range(maxi(0, int(floor((a.x - ox) / step))), mini(W, int(ceil((b.x - ox) / step)) + 1)):
			for iz in range(maxi(0, int(floor((a.y - oz) / step))), mini(H, int(ceil((b.y - oz) / step)) + 1)):
				var cx := ox + (ix + 0.5) * step; var cz := oz + (iz + 0.5) * step
				var y = _poly_y(pts, cx, cz)
				if y == null: continue
				var k := iz * W + ix
				var arr: PackedFloat32Array = navc.get(k, PackedFloat32Array())
				var dup := false
				for e in arr:
					if absf(e - y) < 0.3: dup = true
				if not dup:
					arr.append(y); navc[k] = arr
				navmask[k] = 1
	# ---- play area = nav footprint dilated by margin (separable square dilation)
	var r := int(ceil(margin / step))
	var tmp := PackedByteArray(); tmp.resize(W * H)
	for iz in H:
		var run := -1000000
		for ix in W:
			if navmask[iz * W + ix]: run = ix
			if ix - run <= r: tmp[iz * W + ix] = 1
		run = 1000000
		for ix in range(W - 1, -1, -1):
			if navmask[iz * W + ix]: run = ix
			if run - ix <= r: tmp[iz * W + ix] = 1
	var play := PackedByteArray(); play.resize(W * H)
	for ix in W:
		var run := -1000000
		for iz in H:
			if tmp[iz * W + ix]: run = iz
			if iz - run <= r: play[iz * W + ix] = 1
		run = 1000000
		for iz in range(H - 1, -1, -1):
			if tmp[iz * W + ix]: run = iz
			if run - iz <= r: play[iz * W + ix] = 1
	# ---- intended pits
	var pits: Array[AABB] = []
	var cand: Array = map.find_children("*", "Node3D", true, false)
	cand.append(map)
	for n in cand:
		if not (n.has_meta("intended_pit") and bool(n.get_meta("intended_pit"))): continue
		if n.has_meta("pit_size"):
			var s: Vector3 = n.get_meta("pit_size"); pits.append(AABB(n.global_position - s / 2, s))
		else:
			var bb := AABB(); var first := true
			var subs: Array = n.find_children("*", "", true, false)
			subs.append(n)
			for c in subs:
				var cb = _node_aabb(c)
				if cb == null: continue
				bb = cb if first else bb.merge(cb); first = false
			if not first: pits.append(bb)
	# ---- visual mirror
	var vis_root := Node3D.new(); vis_root.name = "VoidTestVisual"
	root.add_child(vis_root)
	var nvis := 0
	if do_visual:
		for mi in map.find_children("*", "GeometryInstance3D", true, false):
			if not mi.is_visible_in_tree(): continue
			if skip_nodes.any(func(sn): return sn.is_ancestor_of(mi)): continue
			if mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY: continue
			if mi is MeshInstance3D and mi.mesh:
				nvis += _mirror(vis_root, mi.mesh, mi.global_transform)
			elif mi is MultiMeshInstance3D and mi.multimesh and mi.multimesh.mesh:
				var mm: MultiMesh = mi.multimesh
				var cnt := mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count
				for i in cnt: nvis += _mirror(vis_root, mm.mesh, mi.global_transform * mm.get_instance_transform(i))
		for i in 3: await physics_frame
		space = root.world_3d.direct_space_state
	var top_y := nav_max_y + 12.0
	var floor_min := nav_min_y - 0.6
	var void_y := floor_min - depth
	var low_y := minf(kill_y - 2.0, void_y - 1.0)
	var flags := {"VOID": [], "NAV_NO_FLOOR": [], "VISUAL_HOLE": [], "SEAM": []}   # kind -> [x, y, z, cause, cell]
	var nplay := 0
	var excluded := 0
	for iz in H:
		for ix in W:
			var k := iz * W + ix
			if not play[k]: continue
			var cx := ox + (ix + 0.5) * step; var cz := oz + (iz + 0.5) * step
			if _in_pit(pits, cx, cz):
				excluded += 1; continue
			nplay += 1
			var ph := _hits(cx, cz, top_y, low_y, 1)
			var lowest_y: float = ph[ph.size() - 1].position.y if ph.size() else -INF
			if ph.is_empty() or lowest_y < void_y:
				flags.VOID.append([cx, floor_min, cz, _vcause(cx, cz, top_y, void_y), Vector2i(ix, iz)])
			elif do_visual and ph.size() == 1 and ph[0].normal.y > 0.6:
				var fy: float = ph[0].position.y
				if not _vis_near(cx, fy, cz):
					flags.VISUAL_HOLE.append([cx, fy, cz, "no visual (ground)", Vector2i(ix, iz)])
			if navc.has(k):
				for ny in navc[k]:
					var h := _ray(Vector3(cx, ny + 0.5, cz), Vector3(cx, ny - depth, cz), 1, clip_rids)
					if h.is_empty() or h.position.y < ny - 1.0:
						var dtxt := ("drop %.1f m" % (ny - h.position.y)) if not h.is_empty() else "drop to void"
						flags.NAV_NO_FLOOR.append([cx, ny, cz, "%s, %s" % [_vcause(cx, cz, ny + 0.5, ny - 1.0), dtxt], Vector2i(ix, iz)])
					elif do_visual:
						var fy: float = h.position.y
						if not _vis_near(cx, fy, cz):
							flags.VISUAL_HOLE.append([cx, fy, cz, "no visual (nav floor)", Vector2i(ix, iz)])
	# ---- seam pass: just outside every collider / visible-mesh footprint edge
	var rects: Array[AABB] = []
	for cs in map.find_children("*", "CollisionShape3D", true, false):
		var p := cs.get_parent()
		if p is CollisionObject3D and (p.collision_layer & 1) and not clip_rids.has(p.get_rid()):
			var bb = _node_aabb(cs)
			if bb != null: rects.append(bb)
	for c in vis_root.get_children():
		var bb = _node_aabb(c.get_child(0))
		if bb != null: rects.append(bb)
	var seen := {}
	var nseam := 0
	for bb in rects:
		if bb.size.x > 400 or bb.size.z > 400: continue
		var x0 := bb.position.x - 0.03; var x1 := bb.end.x + 0.03; var z0 := bb.position.z - 0.03; var z1 := bb.end.z + 0.03
		var pts: Array[Vector2] = []
		var n := int(ceil((x1 - x0) / (step * 0.5)))
		for i in n + 1:
			var x := x0 + (x1 - x0) * i / maxi(n, 1); pts.append(Vector2(x, z0)); pts.append(Vector2(x, z1))
		n = int(ceil((z1 - z0) / (step * 0.5)))
		for i in n + 1:
			var z := z0 + (z1 - z0) * i / maxi(n, 1); pts.append(Vector2(x0, z)); pts.append(Vector2(x1, z))
		for p in pts:
			var key := Vector2i(roundi(p.x * 50), roundi(p.y * 50))
			if seen.has(key): continue
			seen[key] = true
			var ix := int(floor((p.x - ox) / step)); var iz := int(floor((p.y - oz) / step))
			if ix < 0 or iz < 0 or ix >= W or iz >= H or not play[iz * W + ix]: continue
			if _in_pit(pits, p.x, p.y): continue
			nseam += 1
			var ph := _hits(p.x, p.y, top_y, low_y, 1)
			var phys_void: bool = ph.is_empty() or float(ph[ph.size() - 1].position.y) < void_y
			var vis_void := false
			if do_visual:
				var vh := _hits(p.x, p.y, top_y, low_y, VIS_LAYER)
				vis_void = vh.is_empty() or float(vh[vh.size() - 1].position.y) < void_y
			if phys_void or vis_void:
				var cause := "open hole (collision + visual)" if (phys_void and vis_void) else ("collision gap, visual covered" if phys_void else "visual gap, collision covered")
				flags.SEAM.append([p.x, floor_min, p.y, cause, Vector2i(ix, iz)])
	# ---- cluster + report
	var holes := []
	for kind in flags:
		for cl in _cluster(flags[kind]):
			cl["kind"] = kind
			holes.append(cl)
	var mname := path.get_file().get_basename()
	for h in holes:
		print("VOID_HOLE %s %s n=%d centre=(%.2f, %.2f, %.2f) x[%.2f..%.2f] z[%.2f..%.2f] cause=%s" % [mname, h.kind, h.n, h.c.x, h.c.y, h.c.z, h.x0, h.x1, h.z0, h.z1, h.cause])
	if verbose:
		for kind in flags:
			for f in flags[kind]: print("VOID_PT %s %s (%.2f, %.2f, %.2f) %s" % [mname, kind, f[0], f[1], f[2], f[3]])
	var lst := []
	for h in holes:
		lst.append({"kind": h.kind, "n": h.n, "centre": [snappedf(h.c.x, 0.01), snappedf(h.c.y, 0.01), snappedf(h.c.z, 0.01)],
			"x": [snappedf(h.x0, 0.01), snappedf(h.x1, 0.01)], "z": [snappedf(h.z0, 0.01), snappedf(h.z1, 0.01)], "cause": h.cause})
	var res := {"map": path, "holes": holes.size(), "play_cells": nplay, "excluded_pit_cells": excluded, "seam_points": nseam,
		"nav_cells": navc.size(), "visual_meshes": nvis, "step": step, "void_y": void_y, "pits": pits.size(),
		"counts": {"VOID": flags.VOID.size(), "NAV_NO_FLOOR": flags.NAV_NO_FLOOR.size(), "VISUAL_HOLE": flags.VISUAL_HOLE.size(), "SEAM": flags.SEAM.size()},
		"ms": Time.get_ticks_msec() - t0, "list": lst}
	print("VOID_RESULT %s %s" % [mname, JSON.stringify(res)])
	vis_root.queue_free(); map.queue_free()
	for i in 3: await physics_frame
	return res

func _vis_near(x: float, fy: float, z: float) -> bool:
	## a visible surface from 0.3 m above to 0.75 m below the collision floor (stepped stair visuals under a smooth
	## ramp collider sit up to ~0.45 m low; that is not a see-through hole). Jittered retries so a ray grazing a
	## triangle edge of a merged mesh is not reported as a hole.
	for o in [Vector2.ZERO, Vector2(0.013, 0.007), Vector2(-0.011, -0.009)]:
		if not _ray(Vector3(x + o.x, fy + 0.3, z + o.y), Vector3(x + o.x, fy - 0.75, z + o.y), VIS_LAYER, NO_RIDS).is_empty():
			return true
	return false

func _vcause(x: float, z: float, y0: float, ylim: float) -> String:
	if not do_visual: return "collision missing"
	var vh := _hits(x, z, y0, ylim - 0.01, VIS_LAYER, 6)
	return "visual floor without collider" if vh.size() else "open hole (collision + visual)"

func _mirror(parent: Node3D, mesh: Mesh, t: Transform3D) -> int:
	var shp := mesh.create_trimesh_shape()
	if shp == null: return 0
	var b := StaticBody3D.new()
	b.collision_layer = VIS_LAYER; b.collision_mask = 0
	var cs := CollisionShape3D.new(); cs.shape = shp
	b.add_child(cs)
	parent.add_child(b)
	b.global_transform = t
	return 1

func _node_aabb(n: Node):
	if n is VisualInstance3D:
		return n.global_transform * (n.get_aabb() as AABB)
	if n is CollisionShape3D and n.shape:
		var dm = n.shape.get_debug_mesh()
		if dm: return n.global_transform * (dm.get_aabb() as AABB)
	return null

func _in_pit(pits: Array[AABB], x: float, z: float) -> bool:
	for p in pits:
		if x >= p.position.x and x <= p.end.x and z >= p.position.z and z <= p.end.z: return true
	return false

func _poly_y(pts: Array[Vector3], x: float, z: float):
	## y on a convex nav polygon at (x, z), or null if outside
	var n := pts.size()
	var sgn := 0
	for i in n:
		var a := pts[i]; var b := pts[(i + 1) % n]
		var c := (b.x - a.x) * (z - a.z) - (b.z - a.z) * (x - a.x)
		if absf(c) < 1e-9: continue
		var s := 1 if c > 0 else -1
		if sgn == 0: sgn = s
		elif s != sgn: return null
	for i in range(1, n - 1):
		var a := pts[0]; var b := pts[i]; var c := pts[i + 1]
		var d := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(d) < 1e-9: continue
		var l1 := ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (z - c.z)) / d
		var l2 := ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (z - c.z)) / d
		var l3 := 1.0 - l1 - l2
		if l1 >= -1e-4 and l2 >= -1e-4 and l3 >= -1e-4: return l1 * a.y + l2 * b.y + l3 * c.y
	return pts[0].y

func _cluster(pts: Array) -> Array:
	var by := {}
	for i in pts.size():
		var c: Vector2i = pts[i][4]
		if not by.has(c): by[c] = []
		by[c].append(i)
	var done := {}
	var out := []
	for c in by:
		if done.has(c): continue
		var stack := [c]; done[c] = true
		var idx := []
		while stack.size():
			var cur: Vector2i = stack.pop_back()
			idx.append_array(by[cur])
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var nb: Vector2i = cur + Vector2i(dx, dz)
					if by.has(nb) and not done.has(nb):
						done[nb] = true; stack.append(nb)
		var s := Vector3.ZERO; var x0 := INF; var x1 := -INF; var z0 := INF; var z1 := -INF
		var causes := {}
		for i in idx:
			var p = pts[i]
			s += Vector3(p[0], p[1], p[2]); x0 = minf(x0, p[0]); x1 = maxf(x1, p[0]); z0 = minf(z0, p[2]); z1 = maxf(z1, p[2])
			causes[p[3]] = int(causes.get(p[3], 0)) + 1
		var top := ""; var best := -1
		for k in causes:
			if causes[k] > best:
				best = causes[k]; top = k
		out.append({"n": idx.size(), "c": s / idx.size(), "x0": x0, "x1": x1, "z0": z0, "z1": z1, "cause": top})
	return out
