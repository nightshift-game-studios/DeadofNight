extends RefCounted
## Mapz light helpers shared by test_light_fixtures.gd and mount_lights.gd (headless, physics based).
## "Clip" bodies (invisible boundary colliders), doors and the like are not surfaces a lamp can be mounted on.

const FIXTURE_GROUP := &"light_fixture"

## Physics bodies that do not count as a mounting surface: anything under a node named Clip, plus map doors.
static func ignore_rids(map: Node) -> Array[RID]:
	var out: Array[RID] = []
	for n in map.find_children("*", "CollisionObject3D", true, false):
		var p := map.get_path_to(n)
		var s := String(p)
		if s.contains("Clip") or s.contains("/Doors/") or s.begins_with("Doors/"):
			out.append(n.get_rid())
	return out

## Lights that belong to the map (not the Player, chests, pickups or other runtime spawns) and are not Directional.
static func map_lights(map: Node) -> Array:
	var out: Array = []
	for l in map.find_children("*", "Light3D", true, false):
		if l is DirectionalLight3D:
			continue
		var skip := false
		var n: Node = l
		while n != null and n != map:
			var sf := n.scene_file_path
			if sf.ends_with("player.tscn") or sf.ends_with("chest.tscn") or sf.ends_with("pickup.tscn") or sf.ends_with("zombie.tscn"):
				skip = true
				break
			n = n.get_parent()
		if String(map.get_path_to(l)).begins_with("Player/") or String(map.get_path_to(l)).begins_with("Chests/") or String(map.get_path_to(l)).begins_with("Pickups/"):
			skip = true
		if not skip:
			out.append(l)
	return out

static func light_range(l: Light3D) -> float:
	if l is OmniLight3D: return l.omni_range
	if l is SpotLight3D: return l.spot_range
	return 0.0

static func touching(space: PhysicsDirectSpaceState3D, p: Vector3, radius: float, ignore: Array[RID]) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var s := SphereShape3D.new()
	s.radius = radius
	q.shape = s
	q.transform = Transform3D(Basis(), p)
	q.exclude = ignore
	return space.intersect_shape(q, 1).size() > 0

static func box_touching(space: PhysicsDirectSpaceState3D, a: AABB, ignore: Array[RID]) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	var s := BoxShape3D.new()
	s.size = a.size.max(Vector3(0.02, 0.02, 0.02))
	q.shape = s
	q.transform = Transform3D(Basis(), a.get_center())
	q.exclude = ignore
	return space.intersect_shape(q, 1).size() > 0

static func fixture_aabb(fx: Node3D) -> AABB:
	var a := AABB()
	var first := true
	var nodes: Array = fx.find_children("*", "MeshInstance3D", true, false)
	if fx is MeshInstance3D:
		nodes.append(fx)
	for mi in nodes:
		if mi.mesh == null:
			continue
		var bb: AABB = mi.global_transform * mi.get_aabb()
		a = bb if first else a.merge(bb)
		first = false
	return a if not first else AABB(fx.global_position, Vector3.ZERO)

## Is this light mounted? Returns "wall" (collider within tol), "fixture" (inside a light_fixture AABB that touches a collider) or "".
static func mount_state(map: Node, space: PhysicsDirectSpaceState3D, l: Light3D, ignore: Array[RID], tol := 0.3) -> String:
	var p := l.global_position
	if touching(space, p, tol, ignore):
		return "surface"
	for fx in map.find_children("*", "Node3D", true, false):
		if not fx.is_in_group(FIXTURE_GROUP):
			continue
		var a := fixture_aabb(fx)
		if a.size == Vector3.ZERO:
			continue
		if a.grow(tol).has_point(p) and box_touching(space, a.grow(0.12), ignore):
			return "fixture"
	return ""

## Walkable floor sample points (upward-facing hits with 1.8 m headroom), every `step` m, every level.
static func floor_samples(map: Node, space: PhysicsDirectSpaceState3D, ignore: Array[RID], half: Vector2, step: float, top := 30.0) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var x := -half.x
	while x <= half.x:
		var z := -half.y
		while z <= half.y:
			var from := Vector3(x, top, z)
			var ex := ignore.duplicate()
			for _i in 6:
				var r := space.intersect_ray(_ray(from, from + Vector3.DOWN * (top + 30.0), ex))
				if r.is_empty():
					break
				ex.append(r.rid)
				if r.normal.y > 0.7:
					var up := space.intersect_ray(_ray(r.position + Vector3.UP * 0.1, r.position + Vector3.UP * 1.9, ignore))
					if up.is_empty():
						out.append(r.position)
				from = r.position + Vector3.DOWN * 0.02
				ex = ignore.duplicate()
				ex.append(r.rid)
			z += step
		x += step
	return out

static func _ray(a: Vector3, b: Vector3, ex: Array) -> PhysicsRayQueryParameters3D:
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = ex
	return q

## Rough lux estimate at point s (eye height) from a list of light dicts {pos, energy, range}; line of sight tested with physics rays.
static func lux(space: PhysicsDirectSpaceState3D, s: Vector3, lights: Array, ignore: Array[RID]) -> Dictionary:
	var total := 0.0
	var count := 0
	var eye := s + Vector3.UP * 1.0
	for L in lights:
		var d: float = L.pos.distance_to(eye)
		if d >= L.range:
			continue
		var dir: Vector3 = (eye - L.pos).normalized()
		if space.intersect_ray(_ray(L.pos + dir * 0.2, eye, ignore)).size() > 0:
			continue
		var nd: float = d / L.range
		nd = nd * nd
		nd = nd * nd
		var w := clampf(1.0 - nd, 0.0, 1.0)
		total += L.energy * w * w / maxf(d * d, 1.0)
		count += 1
	return {"lux": total, "count": count}

## Moonlight stand-in for walkable points with open sky above (the Sun directional light): they are not "dark" without lamps.
const MOON_LUX := 0.045
static func moon(space: PhysicsDirectSpaceState3D, s: Vector3, ignore: Array[RID]) -> float:
	var r := space.intersect_ray(_ray(s + Vector3.UP * 1.9, s + Vector3.UP * 80.0, ignore))
	return MOON_LUX if r.is_empty() else 0.0
