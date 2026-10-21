class_name ChestSpots
extends RefCounted
## Chest spots for relocating chests (Economy v2, DESIGN §21; format agreed with Mapz: /workspace/skillz/MAPZ_CHEST_SPOTS.md).
##   ChestSpots.collect(map)                      -> [spot]  (spot = {transform, areas, hidden, initial, weight, source, name})
##   ChestSpots.pick(spots, from_pos, taken, map, player_pos, cfg, rng, nav_map, nav_ref) -> spot or {} (nothing free)
##   ChestSpots.on_navmesh(spot, nav_map, cfg, nav_ref) -> bool (off-navmesh spots are only used when nothing else is free)
##   ChestSpots.is_unlocked(spot, map)            -> bool (any of its areas open; no map = always)
##   ChestSpots.chest_transform(marker)           -> Transform3D for scenes/chest.tscn at a ChestSpot marker
## Sources, first non-empty wins:
##   1. Marker3D children of the map's `ChestSpots` node, plus any other node in group `chest_spot` inside the map.
##      Origin on the floor, -Z = the open (walkway) side, so the chest's front (+Z) turns to face -Z.
##   2. Fallback: the map's `Chests/` markers (the starting chests, used as-is: +Z = front), all marked initial.
##   3. No map (built-in arena): the scene's own `ChestSpots` node if main.tscn has one (Mapz arena patch),
##      else the starting transforms of the chests themselves (arena_spots()).
## Meta on a spot: area (StringName, or Array of StringName for boundary spots), hidden (bool), initial (bool),
## weight (float, default 1). Unknown meta is ignored.

const GROUP := "chest_spot"
const NODE_NAME := "ChestSpots"
const FALLBACK_NODE := "Chests"


## The spots a map offers. `map` = MapRoot (or any Node3D); null = no map (callers use arena_spots()).
static func collect(map: Node) -> Array:
	if map == null:
		return []
	var out := []
	var seen := {}
	var holder := map.get_node_or_null(NODE_NAME)
	var nodes: Array = []
	if holder:
		nodes.append_array(holder.get_children())
	if map.is_inside_tree():
		for n in map.get_tree().get_nodes_in_group(GROUP):
			if map.is_ancestor_of(n):
				nodes.append(n)
	for n in nodes:
		if not n is Node3D or seen.has(n.get_instance_id()):
			continue
		seen[n.get_instance_id()] = true
		out.append(_spot(n as Node3D, chest_transform(n as Node3D), "chest_spots", bool(n.get_meta("initial", false)), map))
	if not out.is_empty():
		return out
	var fb := map.get_node_or_null(FALLBACK_NODE)
	if fb:
		for n in fb.get_children():
			if n is Node3D:
				out.append(_spot(n as Node3D, _xform(n as Node3D), "chests_fallback", true, map))
	return out


## Spots for a scene without a map: where its chests started (they can only swap places when one is free).
static func arena_spots(chests: Array) -> Array:
	var out := []
	for c in chests:
		if c is Node3D:
			var t: Transform3D = c.get_meta("chest_home", (c as Node3D).global_transform)
			out.append({"transform": t, "areas": [], "hidden": false, "initial": true, "weight": 1.0,
				"source": "arena", "name": str(c.name)})
	return out


static func _xform(n: Node3D) -> Transform3D:
	return n.global_transform if n.is_inside_tree() else n.transform


## ChestSpot markers point -Z at the walkway; the chest model faces +Z, so it is turned half a turn about the marker's up.
static func chest_transform(marker: Node3D) -> Transform3D:
	var t := _xform(marker)
	var b := t.basis.orthonormalized() * Basis(Vector3.UP, PI)
	return Transform3D(b, t.origin)


static func _spot(n: Node3D, t: Transform3D, source: String, initial: bool, map: Node) -> Dictionary:
	return {"transform": t, "areas": areas_of(n, map), "hidden": bool(n.get_meta("hidden", false)), "initial": initial,
		"weight": maxf(float(n.get_meta("weight", 1.0)), 0.0), "source": source, "name": str(n.name)}


## meta area: StringName / String or an Array of them (boundary spots). Missing = the map's start area.
static func areas_of(n: Node, map: Node = null) -> Array:
	var v = n.get_meta("area") if n.has_meta("area") else null
	var out := []
	if v is Array or v is PackedStringArray:
		for a in v:
			if str(a) != "":
				out.append(StringName(str(a)))
	elif v != null and str(v) != "":
		out.append(StringName(str(v)))
	if out.is_empty():
		out.append(StringName(str(map.get("start_area"))) if map != null and map.get("start_area") != null else &"start")
	return out


static func is_unlocked(spot: Dictionary, map: Node) -> bool:
	if map == null or not map.has_method("is_area_open"):
		return true
	for a in spot.get("areas", []):
		if map.is_area_open(StringName(a)):
			return true
	return spot.get("areas", []).is_empty()


## Weighted pick of a free spot: not within cfg.occupied_radius of `from_pos` (the chest's own spot) or of any
## position in `taken` (other chests), not locked. Hidden spots x hidden_bias; spots within min_player_distance of
## the player x near_player_mult. Returns {} when nothing qualifies. rng: RandomNumberGenerator (null = global randf).
## nav_map (a NavigationServer3D map with regions): spots whose front is off the navmesh (e.g. the arena Tower perch,
## which zombies cannot reach) are skipped while any on-navmesh spot is free; with only off-navmesh spots left they are
## added at weight x off_nav_mult (default 0 = left out); when no on-navmesh spot is free they are used at full weight.
static func pick(spots: Array, from_pos: Vector3, taken: Array, map: Node, player_pos = null, cfg: Dictionary = {},
		rng: RandomNumberGenerator = null, nav_map: RID = RID(), nav_ref = null) -> Dictionary:
	var cands := candidates(spots, from_pos, taken, map, player_pos, cfg, nav_map, nav_ref)
	var total := 0.0
	for c in cands:
		total += float(c.w)
	if total <= 0.0:
		return {}
	var r := (rng.randf() if rng else randf()) * total
	for c in cands:
		r -= float(c.w)
		if r <= 0.0:
			return c.spot
	return cands[-1].spot


## [{spot, w}] for every spot pick() may choose (tests / debug).
static func candidates(spots: Array, from_pos: Vector3, taken: Array, map: Node, player_pos = null, cfg: Dictionary = {},
		nav_map: RID = RID(), nav_ref = null) -> Array:
	var check_nav := nav_map.is_valid() and not NavigationServer3D.map_get_regions(nav_map).is_empty()
	var off_m := float(cfg.get("off_nav_mult", 0.0))
	var off_nav := []
	var occ := float(cfg.get("occupied_radius", 2.0))
	var hb := float(cfg.get("hidden_bias", 3.0))
	var near_d := float(cfg.get("min_player_distance", 10.0))
	var near_m := float(cfg.get("near_player_mult", 0.25))
	var out := []
	for s in spots:
		var p: Vector3 = (s.transform as Transform3D).origin
		if p.distance_to(from_pos) < occ:
			continue
		if taken.any(func(q): return p.distance_to(q) < occ):
			continue
		if not is_unlocked(s, map):
			continue
		var w := float(s.get("weight", 1.0))
		if bool(s.get("hidden", false)):
			w *= hb
		if player_pos is Vector3 and p.distance_to(player_pos) < near_d:
			w *= near_m
		if w <= 0.0:
			continue
		if check_nav and not on_navmesh(s, nav_map, cfg, nav_ref):
			off_nav.append({"spot": s, "w": w, "off_nav": true})
			continue
		out.append({"spot": s, "w": w})
	if out.is_empty():
		return off_nav # nowhere zombies can reach is free: a perch beats a chest stuck open
	for c in off_nav:
		if off_m > 0.0:
			c.w = float(c.w) * off_m
			out.append(c)
	return out


## True when the walkway in front of the chest (front_probe m along the chest's +Z, the side a player opens it from)
## snaps to the navmesh within nav_snap m horizontally and 0.6 m vertically, and (nav_ref = a Vector3, e.g. the
## player spawn) a navmesh path from nav_ref ends there: a navmesh island zombies can't reach (the arena Tower top)
## counts as off the navmesh.
static func on_navmesh(spot: Dictionary, nav_map: RID, cfg: Dictionary = {}, nav_ref = null) -> bool:
	var t: Transform3D = spot.transform
	var probe := t.origin + t.basis.orthonormalized().z * float(cfg.get("front_probe", 1.0))
	var snap := float(cfg.get("nav_snap", 0.6))
	var q := NavigationServer3D.map_get_closest_point(nav_map, probe)
	if Vector2(q.x - probe.x, q.z - probe.z).length() > snap or absf(q.y - probe.y) > 0.6:
		return false
	if not nav_ref is Vector3:
		return true
	var a := NavigationServer3D.map_get_closest_point(nav_map, nav_ref)
	var path := NavigationServer3D.map_get_path(nav_map, a, q, true)
	return path.size() > 0 and path[path.size() - 1].distance_to(q) <= snap
