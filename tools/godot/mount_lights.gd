extends SceneTree
## Mapz: mount every light of a map on a physical fixture (playtest #16) and fill dark areas with fixture-mounted lights.
## Headless; edits and saves the scene unless --dry is given.
##
##   godot --headless --path . -s res://tools/godot/mount_lights.gd -- res://maps/<id>/<id>.tscn [--plan=res://tools/godot/light_plans/<id>.json]
##         [--edit=res://maps/common/night/arena_night/lights.tscn --strip=NightLights/] [--dry] [--thresh=0.04] [--max-add=40]
##
## Phase A (map in the tree, physics queries): for each light decide a fixture from Desi's six GLBs (assets/models/props/light_*.glb):
##   ceiling gap < 1 m -> flush ceiling lamp; ceiling above (<= 8 m) -> hanging lamp on a chain/rod that reaches the ceiling;
##   light below 2.2 m -> tripod floor work lamp standing on the floor; wall within 6 m -> sconce / caged work light / lantern flush on the wall;
##   else a pole from the floor with a caged work light on it. The light moves to the fixture's LightPoint.
##   Floating legacy lamp props (Poly Haven hanging/security/fluorescent) are removed (replaced by the Desi fixtures).
##   Then the walkable area (navmesh) is sampled; where the estimated light is below --thresh, fixture-mounted lights are added.
## Plan json (all optional): delete[] light paths to drop, snap[] light paths to pull onto the nearest surface (spark flashes, furnace mouths),
##   keep[] node paths already fixtured (tagged light_fixture, light left alone), poles[] pole assemblies (Pole mesh + Head + Light) to rebuild with a caged lamp,
##   shadow_keep[] light paths that may keep shadows (all others off, max 4).
## Phase B: the same edits applied to a fresh, not-in-tree instance of the scene and saved.
## Not geometry/nav: only lights, fixtures (visual only, no colliders) and Props lamp instances are touched.

const Lib := preload("res://tools/godot/light_lib.gd")
const DIR := "res://assets/models/props/"
const FX := {
	"sconce": {"f": "light_wall_sconce.glb", "lp": Vector3(0, 0.012, 0.10), "E": 1.6, "R": 6.0, "col": Color(1, 0.80, 0.52)},
	"ceiling": {"f": "light_ceiling_lamp.glb", "lp": Vector3(0, -0.10, 0), "E": 2.2, "R": 8.0, "col": Color(1, 0.88, 0.68)},
	"caged": {"f": "light_caged_work_light.glb", "lp": Vector3(0, -0.115, 0.15), "E": 2.2, "R": 7.0, "col": Color(1, 0.93, 0.78)},
	"hanging": {"f": "light_hanging_lamp.glb", "lp": Vector3(0, -0.769, 0), "E": 2.6, "R": 9.0, "col": Color(1, 0.84, 0.58)},
	"lantern": {"f": "light_lantern_hook.glb", "lp": Vector3(0, -0.08, 0.20), "E": 1.3, "R": 5.0, "col": Color(1, 0.62, 0.30)},
	"floor": {"f": "light_floor_work_lamp.glb", "lp": Vector3(0, 1.68, 0.20), "E": 3.2, "R": 12.0, "col": Color(1, 0.96, 0.88)},
}
const LEGACY := ["hanging_industrial_lamp", "security_light", "mounted_fluorescent_lights"]
const WALL_LAMP := "industrial_wall_lamp"

var space: PhysicsDirectSpaceState3D
var ign: Array[RID]
var map: Node3D
var strip := ""
var plan := {}
var actions: Array = []   # dicts, applied in phase B
var final_lights: Array = []  # {pos, energy, range} for the coverage estimate
var fx_counter := 0
var floor_lamps_pos: Array = []

func _initialize() -> void:
	_main.call_deferred()

func _ray(a: Vector3, b: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = ign
	return space.intersect_ray(q)

# ---------------------------------------------------------------- probing
func wall_ok(pos: Vector3, n: Vector3) -> bool:
	var t := n.cross(Vector3.UP).normalized()
	for off in [Vector3(0, 0.25, 0), Vector3(0, -0.25, 0), t * 0.12, -t * 0.12]:
		var from: Vector3 = pos + n * 0.3 + off
		var r := _ray(from, from - n * 0.6)
		if r.is_empty() or abs((r.position - pos).dot(n)) > 0.06 or r.normal.dot(n) < 0.9:
			return false
	return true

func find_wall(p: Vector3, ys: Array, maxd: float, need_los_to := Vector3.INF) -> Dictionary:
	for y in ys:
		var best := {}
		var bd := 1e9
		for i in 16:
			var a := TAU * i / 16.0
			var d := Vector3(cos(a), 0, sin(a))
			var o := Vector3(p.x, y, p.z)
			var r := _ray(o, o + d * maxd)
			if r.is_empty() or abs(r.normal.y) > 0.25:
				continue
			var dist: float = o.distance_to(r.position)
			if dist < bd and dist > 0.25 and wall_ok(r.position, r.normal):
				if need_los_to != Vector3.INF:
					var lp: Vector3 = r.position + r.normal * 0.2
					if not _ray(lp, need_los_to).is_empty():
						continue
				bd = dist
				best = {"pos": r.position, "n": r.normal, "y": y}
		if not best.is_empty():
			return best
	return {}

func find_ceiling(p: Vector3, maxgap: float) -> Dictionary:
	var r := _ray(p + Vector3.UP * 0.05, p + Vector3.UP * maxgap)
	if r.is_empty() or r.normal.y > -0.7:
		return {}
	for off in [Vector3(0.25, 0, 0), Vector3(-0.25, 0, 0), Vector3(0, 0, 0.25), Vector3(0, 0, -0.25)]:
		var q := _ray(r.position + off - Vector3.UP * 0.4, r.position + off + Vector3.UP * 0.2)
		if q.is_empty() or abs(q.position.y - r.position.y) > 0.05:
			return {}
	return {"y": r.position.y}

func floor_below(p: Vector3, maxd := 14.0) -> Dictionary:
	var r := _ray(p, p + Vector3.DOWN * maxd)
	if r.is_empty() or r.normal.y < 0.7:
		return {}
	return r

func wall_xf(hit: Dictionary) -> Transform3D:
	var n: Vector3 = hit.n
	return Transform3D(Basis.looking_at(-n, Vector3.UP), hit.pos - n * 0.01)

func pick_wall_kind(E: float, col: Color, low_E := false) -> String:
	if col.r - col.b > 0.45 and col.g < 0.75:
		return "lantern"
	if E >= 2.5:
		return "caged"
	if E <= 1.1:
		return "lantern"
	return "caged" if E >= 2.0 else "sconce"

## Decide a mount for a light at p. Returns {fx, xf (fixture global), lightpos, rod, pole, floor_pt} or {}.
func solve(p: Vector3, E: float, col: Color, hint := "", home := Vector3.ZERO) -> Dictionary:
	var s0 := _solve1(p, E, col, hint)
	if not s0.is_empty():
		return s0
	# light buried in geometry or over a void: try nearby positions (<= 3 m)
	for d in [1.0, 2.0, 3.0]:
		for i in 8:
			var a := TAU * i / 8.0
			var s1 := _solve1(p + Vector3(cos(a), 0, sin(a)) * d, E, col, hint)
			if not s1.is_empty():
				return s1
	return {}

func _solve1(p: Vector3, E: float, col: Color, hint := "") -> Dictionary:
	if p.y < 2.2 and hint != "wall":
		var f := floor_below(p + Vector3.UP * 0.3, 4.0)
		if not f.is_empty():
			var xf := Transform3D(Basis(), f.position)
			return {"fx": "floor", "xf": xf, "lightpos": xf * FX.floor.lp}
	if hint != "wall":
		var c := find_ceiling(p, 8.0)
		if not c.is_empty():
			var gap: float = c.y - p.y
			if gap < 1.0:
				var xf := Transform3D(Basis(), Vector3(p.x, c.y, p.z))
				return {"fx": "ceiling", "xf": xf, "lightpos": xf * FX.ceiling.lp}
			var ya := p.y - FX.hanging.lp.y
			var xf := Transform3D(Basis(), Vector3(p.x, ya, p.z))
			return {"fx": "hanging", "xf": xf, "lightpos": xf * FX.hanging.lp, "rod": c.y - ya}
	var ys := []
	var y0 := clampf(p.y, 2.4, 6.5)
	while y0 >= 2.3:
		ys.append(y0)
		y0 -= 0.6
	var w := find_wall(p, ys, 6.0)
	if not w.is_empty():
		var kind := pick_wall_kind(E, col)
		var xf := wall_xf(w)
		return {"fx": kind, "xf": xf, "lightpos": xf * FX[kind].lp}
	var f := floor_below(p, 20.0)
	if not f.is_empty():
		var out := Vector3(-f.position.x, 0, -f.position.z)
		out = out.normalized() if out.length() > 0.1 else Vector3.BACK
		var h := clampf(p.y, 3.0, 7.0)
		var base: Vector3 = f.position
		var mp := base + out * 0.07 + Vector3.UP * (h - base.y)
		var xf := Transform3D(Basis.looking_at(-out, Vector3.UP), mp)
		return {"fx": "caged", "xf": xf, "lightpos": xf * FX.caged.lp, "pole": h - base.y, "pole_base": base}
	return {}

# ---------------------------------------------------------------- main
func _main() -> void:
	var path := ""
	var plan_path := ""
	var edit_path := ""
	var dry := false
	var thresh := 0.04
	var max_add := 60
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--plan="): plan_path = a.get_slice("=", 1)
		elif a.begins_with("--edit="): edit_path = a.get_slice("=", 1)
		elif a.begins_with("--strip="): strip = a.get_slice("=", 1)
		elif a.begins_with("--thresh="): thresh = float(a.get_slice("=", 1))
		elif a.begins_with("--max-add="): max_add = int(a.get_slice("=", 1))
		elif a == "--dry": dry = true
		elif a.ends_with(".tscn"): path = a
	if edit_path == "":
		edit_path = path
	if plan_path != "" and FileAccess.file_exists(plan_path):
		plan = JSON.parse_string(FileAccess.get_file_as_string(plan_path))
	for k in ["delete", "delete_nodes", "snap", "keep", "poles", "shadow_keep"]:
		if not plan.has(k):
			plan[k] = []
	map = (load(path) as PackedScene).instantiate()
	if map.get_script() != null and not (map is MapRoot):
		map.set_script(null)
	root.add_child(map)
	for i in 5:
		await physics_frame
	space = map.get_world_3d().direct_space_state
	ign = Lib.ignore_rids(map)
	var rg := map.get_node_or_null("NavigationRegion3D") as NavigationRegion3D
	if rg:
		rg.bake_navigation_mesh(false)
		for i in 20:
			await physics_frame
	var lights: Array = Lib.map_lights(map)
	print("lights before: ", lights.size())

	# --- legacy lamp props
	var wall_lamps: Array = []
	for n in map.find_children("*", "Node3D", true, false):
		var sf: String = n.scene_file_path
		if sf == "":
			continue
		for L in LEGACY:
			if sf.contains(L):
				actions.append({"t": "delete_node", "path": str(map.get_path_to(n))})
		if sf.contains(WALL_LAMP):
			wall_lamps.append(n)

	for dn in plan.delete_nodes:
		actions.append({"t": "delete_node", "path": dn})

	# --- existing lights
	var shadow_cands: Array = []
	for l: Light3D in lights:
		var rel := str(map.get_path_to(l))
		var E := l.light_energy
		var col := l.light_color
		var p := l.global_position
		if rel in plan.delete:
			actions.append({"t": "delete_light", "path": rel})
			continue
		if _under(rel, plan.keep):
			actions.append({"t": "tag", "path": _keep_root(rel)})
			_add_final(l, p)
			if l.shadow_enabled: shadow_cands.append([rel, E])
			continue
		if rel in plan.snap:
			var np := _snap(p)
			if np != p:
				actions.append({"t": "move_light", "path": rel, "pos": np})
				p = np
			actions.append({"t": "tag", "path": rel})
			_add_final(l, p)
			if l.shadow_enabled: shadow_cands.append([rel, E])
			continue
		var pole_asm := _pole_assembly(rel)
		if pole_asm != "":
			var pa := _plan_pole(pole_asm, l)
			if not pa.is_empty():
				actions.append(pa)
				_add_final(l, pa.lightpos)
				if l.shadow_enabled: shadow_cands.append([rel, E])
				continue
		var sol := solve(p, E, col)
		if sol.is_empty():
			print("WARN no mount for ", rel, " at ", p)
			_add_final(l, p)
			continue
		var fwd := -l.global_transform.basis.z
		var act := {"t": "mount", "path": rel, "sol": sol, "spot": l is SpotLight3D, "orig": p}
		if l is SpotLight3D:
			var tgt: Vector3 = p + fwd * minf(Lib.light_range(l) * 0.35, 14.0)
			act["aim"] = tgt
		actions.append(act)
		_add_final(l, sol.lightpos)
		if l.shadow_enabled: shadow_cands.append([rel, E])
		fx_counter += 1
	# shadows: max 4, keep the plan's picks first then strongest
	shadow_cands.sort_custom(func(a, b):
		var ka: bool = a[0] in plan.shadow_keep
		var kb: bool = b[0] in plan.shadow_keep
		if ka != kb: return ka
		return a[1] > b[1])
	for i in shadow_cands.size():
		if i >= 4:
			actions.append({"t": "shadow_off", "path": shadow_cands[i][0]})

	# --- coverage
	var samples: Array[Vector3] = []
	for s in Lib.floor_samples(map, space, ign, Vector2(70, 70), 2.0):
		var cp := NavigationServer3D.map_get_closest_point(map.get_world_3d().navigation_map, s)
		if cp.distance_to(s) <= 0.6:
			samples.append(s)
	var lux: Array = []
	for s in samples:
		lux.append(Lib.lux(space, s, final_lights, ign).lux + Lib.moon(space, s, ign))
	var before_dark := _dark_count(lux, thresh)
	print("walkable samples %d, dark(<%.3f) before adds: %d  %s" % [samples.size(), thresh, before_dark, _pct(lux)])
	var used_lamps := {}
	var added := 0
	var unfixable := {}
	while added < max_add:
		# darkest cluster centre
		var best_i := -1
		var best_score := 0
		for i in samples.size():
			if lux[i] >= thresh or unfixable.has(i):
				continue
			var score := 0
			for j in samples.size():
				if lux[j] < thresh and samples[i].distance_to(samples[j]) < 7.0:
					score += 1
			if score > best_score:
				best_score = score
				best_i = i
		if best_i < 0:
			break
		var s: Vector3 = samples[best_i]
		var cand := _candidate_for(s, wall_lamps, used_lamps, best_score)
		if cand.is_empty():
			unfixable[best_i] = true
			continue
		# overlap cap
		var ncount: int = Lib.lux(space, cand.lightpos, final_lights, ign).count
		var nl := {"pos": cand.lightpos, "energy": cand.E, "range": cand.R}
		final_lights.append(nl)
		cand["t"] = "add"
		actions.append(cand)
		added += 1
		fx_counter += 1
		for i in samples.size():
			if samples[i].distance_to(cand.lightpos) < cand.R:
				lux[i] = Lib.lux(space, samples[i], final_lights, ign).lux + Lib.moon(space, samples[i], ign)
		unfixable.erase(best_i)
		if lux[best_i] < thresh:
			unfixable[best_i] = true
	print("added %d lights; dark after: %d (unfixable %d)  %s" % [added, _dark_count(lux, thresh), unfixable.size(), _pct(lux)])
	var n_final := 0
	for a in actions:
		if a.t == "delete_light": n_final -= 1
		elif a.t == "add": n_final += 1
	print("lights after: ", lights.size() + n_final, " (", lights.size(), " before, -", _count("delete_light"), " +", added, ")")
	var kinds := {}
	for a in actions:
		var k := ""
		if a.t == "mount" or a.t == "pole": k = a.sol.fx if a.t == "mount" else "pole"
		elif a.t == "add": k = "add_" + a.fx
		if k != "": kinds[k] = kinds.get(k, 0) + 1
	print("fixture kinds: ", kinds)
	if dry:
		quit()
		return
	map.queue_free()
	await process_frame
	_apply(edit_path)
	quit()

func _count(t: String) -> int:
	var c := 0
	for a in actions:
		if a.t == t: c += 1
	return c

func _dark_count(lux: Array, th: float) -> int:
	var c := 0
	for v in lux:
		if v < th: c += 1
	return c

func _pct(lux: Array) -> String:
	var v := lux.duplicate()
	v.sort()
	var n := v.size()
	if n == 0: return ""
	return "p5=%.3f p10=%.3f p25=%.3f p50=%.3f p90=%.3f" % [v[n / 20], v[n / 10], v[n / 4], v[n / 2], v[n * 9 / 10]]

func _add_final(l: Light3D, p: Vector3) -> void:
	var r := Lib.light_range(l)
	if r > 0.0 and l.light_energy > 0.0:
		final_lights.append({"pos": p, "energy": l.light_energy, "range": r})

func _under(rel: String, list: Array) -> bool:
	for k in list:
		if rel == k or rel.begins_with(k + "/"):
			return true
	return false

func _keep_root(rel: String) -> String:
	for k in plan.keep:
		if rel == k or rel.begins_with(k + "/"):
			return k
	return rel

func _pole_assembly(rel: String) -> String:
	for k in plan.poles:
		if rel.begins_with(k + "/"):
			return k
	return ""

func _snap(p: Vector3) -> Vector3:
	if Lib.touching(space, p, 0.25, ign):
		return p
	var best := p
	var bd := 1e9
	for d in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var r := _ray(p, p + d * 6.0)
		if not r.is_empty() and p.distance_to(r.position) < bd:
			bd = p.distance_to(r.position)
			best = r.position + r.normal * 0.12
	return best

## Pole assembly: Node3D with a "Pole" mesh, "Head" mesh and the light. Rebuild: drop Head, caged lamp on the pole top.
func _plan_pole(asm: String, l: Light3D) -> Dictionary:
	var a := map.get_node_or_null(asm) as Node3D
	var pole := a.get_node_or_null("Pole") as MeshInstance3D if a else null
	if pole == null:
		return {}
	var bb: AABB = pole.global_transform * pole.get_aabb()
	var top := bb.end.y
	var c := bb.get_center()
	var rad := maxf(bb.size.x, bb.size.z) * 0.5
	var out := Vector3(-c.x, 0, -c.z)
	out = out.normalized() if out.length() > 0.1 else Vector3.BACK
	var mp := Vector3(c.x, top - 0.45, c.z) + out * rad
	var xf := Transform3D(Basis.looking_at(-out, Vector3.UP), mp)
	var sol := {"fx": "caged", "xf": xf, "lightpos": xf * FX.caged.lp}
	var act := {"t": "pole", "asm": asm, "path": str(map.get_path_to(l)), "sol": sol, "lightpos": sol.lightpos, "spot": l is SpotLight3D}
	if l is SpotLight3D:
		act["aim"] = l.global_position + (-l.global_transform.basis.z) * minf(Lib.light_range(l) * 0.35, 14.0)
	return act

func _candidate_for(s: Vector3, wall_lamps: Array, used: Dictionary, score: int) -> Dictionary:
	var big := score >= 10
	var eye := s + Vector3.UP * 1.0
	# existing unlit wall lamp nearby
	var bl: Node3D = null
	var bd := 9.0
	for wl: Node3D in wall_lamps:
		if used.has(wl):
			continue
		var lp: Vector3 = wl.global_transform * Vector3(0, 0, 0.14)
		var d := lp.distance_to(eye)
		if d < bd and d > 2.0 and _ray(lp + (eye - lp).normalized() * 0.2, eye).is_empty() and lp.y > s.y + 2.0:
			bd = d
			bl = wl
	if bl != null:
		used[bl] = true
		var lp: Vector3 = bl.global_transform * Vector3(0, 0, 0.14)
		return {"fx": "", "lightpos": lp, "E": 2.0 if not big else 2.6, "R": 9.0 if not big else 12.0, "col": Color(1, 0.8, 0.5), "legacy": str(map.get_path_to(bl))}
	# ceiling above the sample
	var c := find_ceiling(s + Vector3.UP * 1.9, 7.5)
	if not c.is_empty():
		var gap: float = c.y - s.y
		if gap >= 3.0:
			var sol := {}
			if gap <= 3.8:
				var xf := Transform3D(Basis(), Vector3(s.x, c.y, s.z))
				sol = {"fx": "ceiling", "xf": xf, "lightpos": xf * FX.ceiling.lp}
			else:
				var ly := s.y + 3.2
				var ya := ly - FX.hanging.lp.y
				var xf := Transform3D(Basis(), Vector3(s.x, ya, s.z))
				sol = {"fx": "hanging", "xf": xf, "lightpos": xf * FX.hanging.lp, "rod": c.y - ya}
			if _ray(sol.lightpos, eye).is_empty():
				return _with_params(sol, big)
	# wall near the sample
	var w := find_wall(s, [s.y + 2.8, s.y + 3.6, s.y + 2.4], 9.0, eye)
	if not w.is_empty():
		var kind := "caged" if c.is_empty() else "sconce"
		var xf := wall_xf(w)
		return _with_params({"fx": kind, "xf": xf, "lightpos": xf * FX[kind].lp}, big)
	# floor lamp standing at the sample (open ground far from walls)
	for fp in floor_lamps_pos:
		if fp.distance_to(s) < 10.0:
			return {}
	var f := floor_below(s + Vector3.UP * 0.3, 2.0)
	if not f.is_empty():
		floor_lamps_pos.append(s)
		var xf := Transform3D(Basis(), f.position)
		return _with_params({"fx": "floor", "xf": xf, "lightpos": xf * FX.floor.lp}, big)
	return {}

func _with_params(sol: Dictionary, big: bool) -> Dictionary:
	var f: Dictionary = FX[sol.fx]
	sol["E"] = f.E * (1.25 if big else 1.0)
	sol["R"] = f.R * (1.3 if big else 1.0)
	sol["col"] = f.col
	return sol

# ---------------------------------------------------------------- phase B
func _gparent(n: Node) -> Transform3D:
	var t := Transform3D()
	var cur := n.get_parent()
	var stack: Array = []
	while cur != null and cur.get_parent() != null:
		stack.append(cur)
		cur = cur.get_parent()
	stack.reverse()
	for c in stack:
		if c is Node3D:
			t = t * c.transform
	return t

func _rel(p: String) -> String:
	return p.trim_prefix(strip) if strip != "" and p.begins_with(strip) else p

var _rod_mat: StandardMaterial3D
var _fx_root: Node3D
var _fx_kind := {}
var _fx_of := {}  # Light3D -> its Fixture glb instance

func _apply(edit_path: String) -> void:
	var r: Node = (load(edit_path) as PackedScene).instantiate()
	_rod_mat = StandardMaterial3D.new()
	_rod_mat.albedo_color = Color(0.13, 0.12, 0.11)
	_rod_mat.metallic = 0.6
	_rod_mat.roughness = 0.65
	_fx_root = r.get_node_or_null("LightFixtures") as Node3D
	if _fx_root == null:
		_fx_root = Node3D.new()
		_fx_root.name = "LightFixtures"
		r.add_child(_fx_root)
		_fx_root.owner = r
	var n_fx := 0
	for a in actions:
		match a.t:
			"delete_node", "delete_light":
				var n := r.get_node_or_null(_rel(a.path))
				if n:
					n.get_parent().remove_child(n)
					n.free()
				else:
					print("WARN missing ", a.path)
			"tag":
				var n := r.get_node_or_null(_rel(a.path))
				if n:
					n.add_to_group(Lib.FIXTURE_GROUP, true)
				else:
					print("WARN missing tag ", a.path)
			"move_light":
				var n := r.get_node_or_null(_rel(a.path)) as Node3D
				if n:
					n.position = _gparent(n).affine_inverse() * a.pos
			"shadow_off":
				var n := r.get_node_or_null(_rel(a.path)) as Light3D
				if n:
					n.shadow_enabled = false
			"mount":
				var l := r.get_node_or_null(_rel(a.path)) as Light3D
				if l == null:
					print("WARN missing ", a.path)
					continue
				var bf := _build_fixture(r, a.sol, l.name)
				_fx_of[l] = bf.get_node("Fixture")
				_fx_kind[l] = a.sol.fx
				_place_light(l, a.sol.lightpos, a.get("aim", Vector3.INF), a.spot)
				_drop_child_meshes(l)
				n_fx += 1
			"pole":
				var l := r.get_node_or_null(_rel(a.path)) as Light3D
				var asm := r.get_node_or_null(_rel(a.asm)) as Node3D
				if l == null or asm == null:
					print("WARN missing pole ", a.asm)
					continue
				var head := asm.get_node_or_null("Head")
				if head:
					asm.remove_child(head)
					head.free()
				var g := _gparent(asm) * asm.transform  # global of assembly
				var inst := _instance_fx(a.sol.fx)
				inst.name = "Fixture"
				asm.add_child(inst)
				inst.owner = r
				inst.transform = g.affine_inverse() * a.sol.xf
				_fx_of[l] = inst
				_fx_kind[l] = a.sol.fx
				asm.add_to_group(Lib.FIXTURE_GROUP, true)
				_place_light(l, a.lightpos, a.get("aim", Vector3.INF), a.spot)
				n_fx += 1
			"add":
				fx_counter += 1
				_add_light(r, a)
				n_fx += 1
	# a shadowed light sitting inside its lamp housing would be blacked out by the housing: nudge it 0.3 m out of the housing
	# (instanced glb children cannot carry cast_shadow overrides through PackedScene, and the cap keeps this to <= 4 lights per map)
	for l in _fx_of:
		if l.shadow_enabled:
			var inst: Node3D = _fx_of[l]
			var off := Vector3(0, 0, 0.3)
			match _fx_kind[l]:
				"ceiling", "hanging": off = Vector3(0, -0.3, 0)
				"floor": off = Vector3(0, 0.3, 0)
			var g := _gparent(inst) * inst.transform
			var np: Vector3 = _gparent(l).affine_inverse() * (_gparent(l) * l.position + g.basis * off)
			l.position = np
	var ps := PackedScene.new()
	var err := ps.pack(r)
	print("pack: ", err, " fixtures: ", n_fx)
	if err == OK:
		print("save: ", ResourceSaver.save(ps, edit_path))
	r.free()

func _instance_fx(kind: String) -> Node3D:
	return (load(DIR + FX[kind].f) as PackedScene).instantiate() as Node3D

func _drop_child_meshes(l: Node) -> void:
	for c in l.get_children():
		if c is MeshInstance3D:
			l.remove_child(c)
			c.free()

func _place_light(l: Light3D, pos: Vector3, aim: Vector3, spot: bool) -> void:
	var gp := _gparent(l)
	var basis := Basis()
	if spot and aim != Vector3.INF:
		var d := (aim - pos).normalized()
		basis = Basis.looking_at(d, Vector3.UP if abs(d.y) < 0.95 else Vector3.RIGHT)
	elif spot:
		basis = gp.basis * l.transform.basis
	l.transform = gp.affine_inverse() * Transform3D(basis, pos) if spot else Transform3D(l.transform.basis, gp.affine_inverse() * pos)
	l.add_to_group(&"light_mounted", true)

## Build the fixture composite (group light_fixture) under LightFixtures: Fx node at the mount origin, Fixture glb, optional rod/pole.
func _build_fixture(r: Node, sol: Dictionary, nm: String) -> Node3D:
	var fx := Node3D.new()
	fx.name = "Fx_" + nm
	_fx_root.add_child(fx)
	fx.owner = r
	fx.add_to_group(Lib.FIXTURE_GROUP, true)
	var inst := _instance_fx(sol.fx)
	inst.name = "Fixture"
	fx.add_child(inst)
	inst.owner = r
	if sol.has("pole"):
		fx.transform = Transform3D(Basis(), sol.pole_base)
		inst.transform = Transform3D(Basis(), Vector3.ZERO).translated(Vector3.ZERO)
		inst.transform = fx.transform.affine_inverse() * sol.xf
		var m := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.07
		cm.bottom_radius = 0.09
		cm.height = sol.pole
		cm.radial_segments = 8
		cm.material = _rod_mat
		m.mesh = cm
		m.name = "Pole"
		m.position = Vector3(0, sol.pole * 0.5, 0)
		fx.add_child(m)
		m.owner = r
	else:
		fx.transform = sol.xf
	if sol.has("rod") and sol.rod > 0.02:
		var m := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.014
		cm.bottom_radius = 0.014
		cm.height = sol.rod
		cm.radial_segments = 6
		cm.material = _rod_mat
		m.mesh = cm
		m.name = "Chain"
		m.position = Vector3(0, sol.rod * 0.5, 0)
		fx.add_child(m)
		m.owner = r
	return fx

func _add_light(r: Node, a: Dictionary) -> void:
	var l := OmniLight3D.new()
	l.light_energy = a.E
	l.omni_range = a.R
	l.light_color = a.col
	l.shadow_enabled = false
	l.distance_fade_enabled = true
	l.distance_fade_begin = 40.0
	l.distance_fade_length = 12.0
	if a.has("legacy"):
		var wl := r.get_node_or_null(_rel(a.legacy)) as Node3D
		if wl == null:
			print("WARN missing legacy lamp ", a.legacy)
			l.free()
			return
		wl.add_child(l)
		l.owner = r
		l.name = "LampLight"
		l.position = Vector3(0, 0, 0.14)
		wl.add_to_group(Lib.FIXTURE_GROUP, true)
		return
	var fx := _build_fixture(r, a, "Add%d" % fx_counter)
	fx.add_child(l)
	l.owner = r
	l.name = "Light"
	var inst: Node3D = fx.get_node("Fixture")
	l.position = fx.transform.affine_inverse() * a.lightpos
