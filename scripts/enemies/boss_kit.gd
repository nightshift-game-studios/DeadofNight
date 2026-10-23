extends RefCounted
## Shared runtime helpers for the boss scripts (Skillz, boss rework 2026-10-22). No class_name (preload it).
## Threat shapes: one Dictionary per dangerous area, the single source of truth for the telegraph visual, the damage
## check, the sim bot and the "telegraphs are readable" test:
##   {"id": "slam", "kind": "circle", "c": Vector3, "r": 3.5}
##   {"id": "aftershock", "kind": "ring", "c": Vector3, "r0": 3.5, "r1": 7.0}
##   {"id": "charge", "kind": "line", "c": origin, "d": flat dir, "len": 8.0, "w": 1.8}
##   {"id": "dirge", "kind": "cone", "c": origin, "d": flat dir, "len": 12.0, "half": 28.0 (deg)}
## plus, once a boss registers it: "t_hit" (boss clock), "dmg", and (from threat_shapes()) "eta" seconds to impact.

const Telegraph := preload("res://scripts/enemies/boss_telegraph.gd")
const MAX_DY := 2.5


static func party_size() -> int:
	var n := NetGate.net()
	return int(n.party_size()) if n != null else 1


## Living player bodies: co-op = local player + remote avatars (NetGate), solo = the "player" group.
static func players(from: Node) -> Array:
	var all = NetGate.players_or_null()
	if all == null:
		all = from.get_tree().get_nodes_in_group("player") if from != null and from.is_inside_tree() else []
	var out: Array = []
	for p in all:
		if p is Node3D and is_instance_valid(p) and not bool(p.get("dead")) and p.has_method("take_damage"):
			out.append(p)
	return out


static func flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


static func in_circle(c: Vector3, r: float, p: Vector3) -> bool:
	return flat_dist(c, p) <= r and absf(p.y - c.y) < MAX_DY + 1.0


## Does point `p` stand inside threat `sh`? (flat test + vertical tolerance.)
static func shape_hits(sh: Dictionary, p: Vector3) -> bool:
	var c: Vector3 = sh.c
	if absf(p.y - c.y) >= MAX_DY + 1.0:
		return false
	var d := flat_dist(c, p)
	match str(sh.kind):
		"circle":
			return d <= float(sh.r)
		"ring":
			return d >= float(sh.r0) and d <= float(sh.r1)
		"line":
			var dir: Vector3 = sh.d
			var rel := Vector2(p.x - c.x, p.z - c.z)
			var fwd := Vector2(dir.x, dir.z).normalized()
			var along := rel.dot(fwd)
			var lat := absf(rel.dot(Vector2(-fwd.y, fwd.x)))
			return along >= -0.3 and along <= float(sh.len) and lat <= float(sh.w) * 0.5
		"cone":
			var dir2: Vector3 = sh.d
			var rel2 := Vector2(p.x - c.x, p.z - c.z)
			if rel2.length() > float(sh.len):
				return false
			if rel2.length() < 0.4:
				return true
			var ang := absf(rad_to_deg(Vector2(dir2.x, dir2.z).angle_to(rel2)))
			return ang <= float(sh.half)
	return false


## Nearest point outside threat `sh` from `p` (for the sim bot's escape and tests): sampled, flat.
static func escape_point(sh: Dictionary, p: Vector3, margin: float = 0.8) -> Vector3:
	var best := p
	var best_d := 1.0e9
	for i in 24:
		var ang := TAU * float(i) / 24.0
		for r in [1.0, 2.0, 3.5, 5.0, 7.0, 9.0, 12.0]:
			var q := p + Vector3(cos(ang), 0.0, sin(ang)) * float(r)
			if not shape_hits(_grown(sh, margin), q):
				if float(r) < best_d:
					best_d = float(r)
					best = q
				break
	return best


static func _grown(sh: Dictionary, m: float) -> Dictionary:
	var g := sh.duplicate()
	match str(sh.kind):
		"circle":
			g.r = float(sh.r) + m
		"ring":
			g.r0 = maxf(float(sh.r0) - m, 0.0)
			g.r1 = float(sh.r1) + m
		"line":
			g.w = float(sh.w) + 2.0 * m
			g.len = float(sh.len) + m
		"cone":
			g.len = float(sh.len) + m
			g.half = float(sh.half) + 6.0
	return g


## Telegraph visual for a shape. `dur` = seconds until impact (visual lingers FLASH longer).
static func show_shape(parent: Node3D, sh: Dictionary, dur: float, col: Color) -> Node3D:
	if parent == null:
		return null
	match str(sh.kind):
		"circle":
			return Telegraph.spawn_circle(parent, sh.c, float(sh.r), dur, col)
		"ring":
			return Telegraph.spawn_ring(parent, sh.c, float(sh.r0), float(sh.r1), dur, col)
		"line":
			return Telegraph.spawn_line(parent, sh.c, sh.d, float(sh.len), dur, col, float(sh.w))
		"cone":
			return Telegraph.spawn_cone(parent, sh.c, sh.d, float(sh.len), float(sh.half), dur, col)
	return null


## Boss adds alive (Choir echoes / pack adds / toll adds carry meta "boss_echo" and leave group "enemies" on death).
static func adds_alive(tree: SceneTree) -> int:
	var n := 0
	for e in tree.get_nodes_in_group("enemies"):
		if e.has_meta("boss_echo") and not bool(e.get("_dead")):
			n += 1
	return n


## Plays a one-shot positional SFX: `key` (Audi-0's new id) if the clip exists, else `fallback` (an existing key), else silence.
static func sfx(at: Vector3, key: String, fallback: String = "", vol: float = 0.0) -> bool:
	var ml := Engine.get_main_loop()
	var s: Node = (ml as SceneTree).root.get_node_or_null("Sfx") if ml is SceneTree else null
	if s == null:
		return false
	for k in [key, fallback]:
		if str(k) != "" and s.has(str(k)):
			s.play_at(str(k), at, vol)
			return true
	return false


static func color_of(arr: Variant, fallback: Color) -> Color:
	if arr is Array and (arr as Array).size() >= 4:
		return Color(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))
	return fallback


## A point `dist` from `origin` in direction angle `ang` (rad) - used for zone scatter.
static func polar(origin: Vector3, ang: float, dist: float) -> Vector3:
	return origin + Vector3(cos(ang), 0.0, sin(ang)) * dist


## Raycast: first solid hit between two points (mask 1), or null. Used by Lantern blink to avoid walls.
static func clear_line(from_node: Node3D, a: Vector3, b: Vector3) -> bool:
	if from_node == null or not from_node.is_inside_tree():
		return true
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	return from_node.get_world_3d().direct_space_state.intersect_ray(q).is_empty()
