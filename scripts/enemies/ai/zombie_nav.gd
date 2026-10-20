extends RefCounted
## ZombieNav (Skillz, DESIGN §18 / MAIN_HOOKS §17): navmesh pathing, RVO avoidance, step-up and stuck recovery for every
## zombie (walker / worker / soldier / crawler / bloated / riot, Choir echo adds, bosses). Tunables: res://data/ai.json.
##
## enemy.gd hooks (§17):
##   _ready():            nav = ZombieNavScr.attach(self)        one-time setup (body floor settings, agent shape). Safe on
##                                                               co-op puppets: avoidance is only switched on by the first tick.
##   _chase_direction():  if nav: return nav.direction(to_player) flat direction along the current path (reads cached state)
##   _physics_process():  if nav: nav.tick(delta, move_dir * spd) the ONE per-frame call: repath throttle, avoidance, step-up,
##                                                               move_and_slide, stuck escalation. Host / authority only
##                                                               (Netz E2 returns before it on puppets).
## Targeting: only enemy.target is chased (Netz E1 sets it via Net.pick_target). "Who can see me" uses players(enemy).
## Randomness (repath jitter, sidestep side, detour pick) only runs inside tick(), so it is host-only by construction.

const DATA_PATH := "res://data/ai.json"
const DEFAULTS := {
	"nav": {"repath_interval": 0.35, "repath_jitter": 0.1, "repath_min_interval": 0.12, "target_moved_repath": 1.0,
		"waypoint_radius": 0.6, "pass_corridor": 0.9, "waypoint_dy": 1.0, "corridor_dy": 0.35, "climb_rise": 0.2, "direct_chase_dist": 2.5, "direct_chase_dy": 0.8},
	"avoidance": {"enabled": true, "suspend_off_nav": true, "radius": 0.45, "neighbor_distance": 4.0, "max_neighbors": 8, "time_horizon_agents": 0.6,
		"max_speed_mult": 1.5, "priority": 0.5},
	"body": {"floor_max_angle_deg": 46.0, "floor_snap_length": 0.45, "floor_constant_speed": true, "step_up_max": 0.45,
		"step_probe": 0.18, "step_smooth_speed": 3.0,
		"hop_max": 0.55, "hop_height": 0.7, "hop_cooldown": 0.8, "land_repath_air": 0.25},
	"stuck": {"window": 1.0, "min_move": 0.3, "crowd_radius": 3.0, "sidestep_time": 0.6, "sidestep_dist": 0.5,
		"detour_dist": 3.0, "detour_time": 2.0, "teleport_min_dist": 14.0, "teleport_ahead": 4.0, "teleport_min_player_dist": 10.0,
		"progress_window": 3.0, "progress_min": 0.6, "progress_target_move": 2.0},
	"ramp_carve": {"enabled": true, "from_height": 0.3, "width": 0.5, "extra_height": 0.3},
}
const WORLD_MASK := 1

static var _data: Dictionary = {}

var enemy: CharacterBody3D
var agent: NavigationAgent3D
var kind: String = "city"
var nav_cfg: Dictionary
var avoid_cfg: Dictionary
var body_cfg: Dictionary
var stuck_cfg: Dictionary

# path state
var path: PackedVector3Array = PackedVector3Array()
var cursor: int = 0
var path_queries: int = 0 ## total path queries (tests / perf)
var _repath_t: float = 0.0
var _since_query: float = 99.0
var _last_goal: Vector3 = Vector3.INF
var _want_frame: int = -10 ## physics frame direction() was last asked (the zombie wants to chase)
var _desired_dir: Vector3 = Vector3.ZERO
var _nav_off: float = 0.0 ## navmesh height above the floor here (path[0].y - feet at the last query)
var _strict_pos: Vector3 = Vector3.INF ## a waypoint that must be reached by radius (no corridor pass)
var ledge_backoffs: int = 0
# avoidance
var _avoid_on: bool = false
var _safe: Vector3 = Vector3.ZERO
var _safe_frame: int = -10
# off-nav phases (boss telegraph / charge / sidestep, grabs): the zombie's own script moves it and nav.tick() isn't called.
# The RVO server would keep the last wish forever (and keep answering with it), so a watcher node, created on the first
# tick (host only), replaces the wish with the zombie's real motion (zero while it holds still) on every frame without a
# tick, and the safe velocities computed meanwhile are discarded. The next tick resumes from the fresh wish.
var suspended: bool = false ## true while the zombie moves without nav (no tick this frame)
var suspends: int = 0 ## times avoidance was suspended (tests)
var resumes: int = 0
var resume_used_safe: int = 0 ## tests: ticks right after a resume that used a stale safe velocity (must stay 0)
var _watch: Node = null
var _watch_pos: Vector3 = Vector3.INF
var _resume_frame: int = -10
# stuck state
var stuck_level: int = 0 ## 0 ok, 1 repath, 2 sidestep, 3 detour, 4 last resort
var unstick_count: int = 0
var teleports: int = 0
var respawns: int = 0
var steps: int = 0 ## step-ups taken
var last_action: String = ""
var _probe_pos: Vector3
var _probe_t: float = 0.0
var _last_tick_frame: int = -10
var _side_t: float = 0.0
var _side_dir: Vector3 = Vector3.ZERO
var _detour: Vector3 = Vector3.INF
var _detour_t: float = 0.0
var _step_vis: float = 0.0
var _prog_t: float = 0.0
var _prog_start: float = INF
var _prog_best: float = INF
var _prog_goal: Vector3 = Vector3.INF
var hops: int = 0 ## hops over low blockers (step_up_max < h <= hop_max)
var map_repaths: int = 0 ## repaths triggered by NavigationServer3D.map_changed (door rebakes)
var sweep_blocks: int = 0 ## corridor passes refused because the capsule sweep to the next waypoint hit something
var _hop_cd: float = 0.0
var _map_dirty: float = -1.0 ## >= 0: the nav map changed (door rebake); repath once this many s have passed
var _air_t: float = 0.0
var debug_freeze: bool = false ## test hook: zero the zombie's walking velocity (forces the stuck escalation)


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_data = d if d is Dictionary else {}
	return _data


static func reload_data(forced: Dictionary = {}) -> void:
	_data = forced


## Every player a zombie cares about (view checks, teleport distance). Co-op: Netz swaps this for Net.players().
static func players(e: Node) -> Array:
	if e == null or not e.is_inside_tree():
		return []
	return e.get_tree().get_nodes_in_group("player").filter(func(p): return p is Node3D and is_instance_valid(p))


## "boss" / "echo" / zombies.json variant id ("city", "crawler", ...).
static func kind_of(e: Node) -> String:
	if e.has_meta("is_boss") and e.get_meta("is_boss"):
		return "boss"
	if e.has_meta("boss_echo"):
		return "echo"
	var v := str(e.get("variant_id"))
	return v if v != "" else "city"


static func _section(name: String, k: String) -> Dictionary:
	var out: Dictionary = (DEFAULTS.get(name, {}) as Dictionary).duplicate()
	out.merge(data().get(name, {}), true)
	out.merge(data().get("kinds", {}).get(k, {}).get(name, {}), true)
	return out


## One-time setup from enemy._ready(). Returns the component (enemy.nav).
static func attach(e: CharacterBody3D) -> RefCounted:
	var n = load("res://scripts/enemies/ai/zombie_nav.gd").new()
	n._setup(e)
	return n


func _setup(e: CharacterBody3D) -> void:
	enemy = e
	agent = e.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	kind = kind_of(e)
	nav_cfg = _section("nav", kind)
	avoid_cfg = _section("avoidance", kind)
	body_cfg = _section("body", kind)
	stuck_cfg = _section("stuck", kind)
	e.floor_max_angle = deg_to_rad(float(body_cfg.floor_max_angle_deg))
	e.floor_snap_length = float(body_cfg.floor_snap_length)
	e.floor_constant_speed = bool(body_cfg.floor_constant_speed)
	e.floor_block_on_wall = true
	if agent:
		var cs := e.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs and cs.shape is CapsuleShape3D:
			agent.height = (cs.shape as CapsuleShape3D).height
		agent.radius = float(avoid_cfg.radius)
		agent.neighbor_distance = float(avoid_cfg.neighbor_distance)
		agent.max_neighbors = int(avoid_cfg.max_neighbors)
		agent.time_horizon_agents = float(avoid_cfg.time_horizon_agents)
		agent.time_horizon_obstacles = 0.0
		agent.avoidance_priority = float(avoid_cfg.priority)
		agent.use_3d_avoidance = false
		agent.path_max_distance = 3.0
		if not agent.velocity_computed.is_connected(_on_safe_velocity):
			agent.velocity_computed.connect(_on_safe_velocity)
	if e.has_signal("died"):
		e.died.connect(func(_z): _set_avoidance(false))
	# Door rebakes: the map only serves the new polygons 1-2 sync iterations after bake_finished, so listen to the map.
	if not NavigationServer3D.map_changed.is_connected(_on_map_changed):
		NavigationServer3D.map_changed.connect(_on_map_changed)
	_repath_t = randf() * float(nav_cfg.repath_interval) # spread the first queries
	_probe_pos = e.global_position if e.is_inside_tree() else Vector3.ZERO


## NavigationServer3D.map_changed: flag only (cheap, safe on puppets); the repath happens in the next tick (host only),
## staggered by instance id over ~0.15 s so a whole horde doesn't query on one frame.
func _on_map_changed(m: RID) -> void:
	if agent and agent.is_inside_tree() and m == agent.get_navigation_map():
		_map_dirty = float(enemy.get_instance_id() % 8) * 0.02


func _set_avoidance(on: bool) -> void:
	_avoid_on = on and bool(avoid_cfg.get("enabled", true)) and agent != null
	if agent:
		agent.avoidance_enabled = _avoid_on
	if _avoid_on:
		_ensure_watch()
	elif _watch != null and is_instance_valid(_watch):
		_watch.set_physics_process(false)


func _on_safe_velocity(v: Vector3) -> void:
	if suspended:
		return # computed from an off-nav (or stale) wish: never apply it
	_safe = v
	_safe_frame = Engine.get_physics_frames()


## Watcher: runs after the zombie each physics frame (host only, only while avoidance is on).
class Watch extends Node:
	var nav: RefCounted
	func _physics_process(delta: float) -> void:
		if nav:
			nav._watch_frame(delta)


func _ensure_watch() -> void:
	if _watch != null or not bool(avoid_cfg.get("suspend_off_nav", true)) or not enemy.is_inside_tree():
		return
	var w := Watch.new()
	w.name = "ZombieNavWatch"
	w.nav = self
	w.process_physics_priority = 100 # after the zombie's own _physics_process
	enemy.add_child(w)
	_watch = w
	_watch_pos = enemy.global_position


func _watch_frame(delta: float) -> void:
	var pos := enemy.global_position
	var motion := Vector3.ZERO
	if _watch_pos != Vector3.INF and delta > 0.0:
		motion = _flat(pos - _watch_pos) / delta
	_watch_pos = pos
	if _last_tick_frame == Engine.get_physics_frames():
		return # nav ran this frame
	if not suspended:
		suspended = true
		suspends += 1
	_safe_frame = -10
	_since_query += delta # time passes off-nav too: the resume repath (direction()) isn't blocked by the min interval
	_repath_t -= delta
	if _avoid_on and agent:
		# what others should dodge: the real motion (charge / sidestep), zero while it telegraphs in place
		agent.velocity = motion if motion.length() > 0.05 else Vector3.ZERO


func _target() -> Node3D:
	var t = enemy.get("target")
	return t if t is Node3D and is_instance_valid(t) else null


func _nav_ready() -> bool:
	if agent == null:
		return false
	var m := agent.get_navigation_map()
	return m.is_valid() and NavigationServer3D.map_get_iteration_id(m) > 0


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


# ------------------------------------------------------------------ nav data fallback

## RUNTIME FALLBACK (flagged for Mapz, AI_NAV_REPORT.md): the maps bake with agent_max_climb 0.5 at 0.25 m cells, so the
## navmesh joins the ground to a wedge ramp / stair along its SIDE wherever the side is lower than ~0.6 m, which is
## higher than any zombie can step. Paths then enter ramps from the side and zombies push into the side face. This adds
## a thin NavigationObstacle3D carve strip (navmesh only, no physics) along both sides of every 6-point wedge collider
## from the height `from_height` up, so ramps are entered from the foot. Call before the first bake (MAIN_HOOKS §17d);
## door rebakes keep them (they live under the region). Returns the number of strips added. Idempotent.
static func prepare_nav_region(region: NavigationRegion3D) -> int:
	if region == null or region.has_node("ZombieNavRampCarves"):
		return 0
	var rc: Dictionary = (DEFAULTS.ramp_carve as Dictionary).duplicate()
	rc.merge(data().get("ramp_carve", {}), true)
	if not bool(rc.enabled):
		return 0
	var holder := Node3D.new()
	holder.name = "ZombieNavRampCarves"
	region.add_child(holder)
	var n := 0
	for cs in region.find_children("*", "CollisionShape3D", true, false):
		var body := (cs as Node).get_parent() as CollisionObject3D
		if body == null or (body.collision_layer & 1) == 0 or (cs as CollisionShape3D).disabled:
			continue
		if not ((cs as CollisionShape3D).shape is ConvexPolygonShape3D):
			continue
		var r := ramp_frame(cs as CollisionShape3D)
		if r.is_empty():
			continue
		for side in [-1.0, 1.0]:
			var a0: float = float(r.length) * clampf(float(rc.from_height) / float(r.height), 0.0, 1.0)
			var a1: float = float(r.length)
			if a1 - a0 < 0.3:
				continue
			var w0: float = float(r.half_width) * side
			var w1: float = w0 + float(rc.width) * side
			var o := NavigationObstacle3D.new()
			o.name = "%s_%s" % [body.name, "L" if side < 0.0 else "R"]
			o.avoidance_enabled = false
			o.affect_navigation_mesh = true
			o.carve_navigation_mesh = true
			o.height = float(r.height) + float(rc.extra_height) + 0.2
			holder.add_child(o)
			var foot: Vector3 = r.foot
			o.global_position = Vector3(foot.x, float(r.base_y) - 0.2, foot.z)
			var ax: Vector3 = r.axis
			var px: Vector3 = r.perp
			o.vertices = PackedVector3Array([ax * a0 + px * w0, ax * a1 + px * w0, ax * a1 + px * w1, ax * a0 + px * w1])
			n += 1
	return n


## Ramp geometry of a 6-point wedge (4 base points, 2 top points straight above two of them). {} if it isn't one
## (gable roofs, cones). foot = centre of the low edge on the ground; axis = uphill (flat); perp; length; half_width; height.
static func ramp_frame(cs: CollisionShape3D) -> Dictionary:
	var pts: PackedVector3Array = (cs.shape as ConvexPolygonShape3D).points
	if pts.size() != 6:
		return {}
	var xf := cs.global_transform
	var w: Array = []
	var ymin := INF
	var ymax := -INF
	for p in pts:
		var q: Vector3 = xf * p
		w.append(q)
		ymin = minf(ymin, q.y)
		ymax = maxf(ymax, q.y)
	if ymax - ymin < 0.6:
		return {}
	var top: Array = w.filter(func(q): return q.y > ymax - 0.02)
	var base: Array = w.filter(func(q): return q.y < ymin + 0.02)
	if top.size() != 2 or base.size() != 4:
		return {}
	var back: Array = []
	var foot: Array = []
	for b in base:
		var under := false
		for t in top:
			if Vector2(b.x - t.x, b.z - t.z).length() < 0.05:
				under = true
		(back if under else foot).append(b)
	if back.size() != 2 or foot.size() != 2:
		return {}
	var fc: Vector3 = (foot[0] + foot[1]) * 0.5
	var bc: Vector3 = (back[0] + back[1]) * 0.5
	var axis := _flat(bc - fc)
	var length := axis.length()
	if length < 0.5:
		return {}
	axis /= length
	var perp := Vector3(-axis.z, 0.0, axis.x)
	return {"foot": fc, "axis": axis, "perp": perp, "length": length, "half_width": _flat(foot[1] - foot[0]).length() * 0.5,
		"height": ymax - ymin, "base_y": ymin}


# ------------------------------------------------------------------ path

## Flat chase direction for this frame (enemy._chase_direction). Follows the cached path; tick() keeps it fresh.
func direction(to_target: Vector3) -> Vector3:
	_want_frame = Engine.get_physics_frames()
	var pos := enemy.global_position
	var fallback := to_target.normalized() if to_target.length() > 0.01 else Vector3.ZERO
	var d := fallback
	if _side_t > 0.0:
		d = (_side_dir * 0.8 + fallback * 0.2).normalized()
	elif _detour != Vector3.INF:
		var to_d := _flat(_detour - pos)
		d = to_d.normalized() if to_d.length() > 0.05 else fallback
	else:
		var t := _target()
		if t != null and (suspended or Engine.get_physics_frames() - _last_tick_frame > 1) \
				and _since_query >= float(nav_cfg.repath_min_interval):
			repath(t.global_position) # back from an off-nav phase (telegraph / charge): the old path is stale too
		var close := t != null and to_target.length() <= float(nav_cfg.direct_chase_dist) \
			and absf(t.global_position.y - pos.y) < float(nav_cfg.direct_chase_dy)
		if not close and not path.is_empty():
			_advance(pos)
			_back_off_ledge(pos)
			if cursor < path.size():
				var to_w := _flat(path[cursor] - pos)
				if to_w.length() > 0.05:
					d = to_w.normalized()
				else:
					# The waypoint is straight overhead (a deck / bridge above us): never stand still under it, steer
					# for the first later point that is somewhere else; the next repath fixes the path.
					for j in range(cursor + 1, path.size()):
						var to_j := _flat(path[j] - pos)
						if to_j.length() > 0.3:
							d = to_j.normalized()
							break
	_desired_dir = d
	return d


## Moves the cursor past waypoints we are on top of (flat distance) or have walked past (inside the corridor).
## Heights are compared after removing the navmesh's own offset above the floor (_nav_off, ~0.25-0.5 m at 0.25 m cells).
func _advance(pos: Vector3) -> void:
	var wr := float(nav_cfg.waypoint_radius)
	var corr := float(nav_cfg.pass_corridor)
	var wdy := float(nav_cfg.waypoint_dy)
	var feet := pos.y + _nav_off
	while cursor < path.size():
		var w := path[cursor]
		var fl := _flat(w - pos).length()
		if fl < wr and absf(w.y - feet) < wdy:
			# Corner cutting: inside the radius but more than 0.25 m out, only let go of a corner waypoint when the
			# capsule can actually sweep to the next one; otherwise keep walking into the corner point first.
			if fl > 0.25 and cursor + 1 < path.size() and not _segment_clear(pos, path[cursor + 1]):
				sweep_blocks += 1
				break
			if _strict_pos != Vector3.INF and _flat(w - _strict_pos).length() < 0.6:
				_strict_pos = Vector3.INF
			cursor += 1
			continue
		# Corridor pass (walked past a corner) only on flat-ish segments and only at the segment's own height: a waypoint
		# at the foot of a climb must be reached, or the zombie cuts the corner into the side of the ramp / stair.
		var strict := _strict_pos != Vector3.INF and _flat(w - _strict_pos).length() < 0.6
		if not strict and cursor + 1 < path.size() and path[cursor + 1].y - w.y < float(nav_cfg.climb_rise):
			var a := _flat(w)
			var b := _flat(path[cursor + 1])
			var ab := b - a
			var l2 := ab.length_squared()
			if l2 > 0.0001:
				var p := _flat(pos)
				var s := (p - a).dot(ab) / l2
				if s > 0.0 and s < 1.0 and (a + ab * s).distance_to(p) < corr \
						and absf(lerpf(w.y, path[cursor + 1].y, s) - feet) < float(nav_cfg.corridor_dy):
					if _segment_clear(pos, path[cursor + 1]):
						cursor += 1
						continue
					sweep_blocks += 1
		break


## Capsule sweep from the zombie toward waypoint `to` (flat, up to 1.5 m, raised by step_up_max so floors, steps and
## ramps don't count): true when nothing solid is in the way. Other zombies / the player don't block.
func _segment_clear(pos: Vector3, to: Vector3) -> bool:
	var m := _flat(to - pos)
	if m.length() < 0.05:
		return true
	if m.length() > 1.5:
		m = m.normalized() * 1.5
	var lift := float(body_cfg.step_up_max) + 0.05
	var xf := enemy.global_transform.translated(Vector3.UP * lift)
	if enemy.test_move(enemy.global_transform, Vector3.UP * lift):
		return true # low ceiling: can't sweep raised, don't block on it
	var col := KinematicCollision3D.new()
	if not enemy.test_move(xf, m, col):
		return true
	return col.get_collider() is CharacterBody3D


## Blocked by a wall while the waypoint is above what we can step: we left the path beside a ramp / stair. Go back to
## the previous waypoint (the foot) and reach it for real before climbing.
func _back_off_ledge(pos: Vector3) -> void:
	if cursor <= 0 or cursor >= path.size() or not enemy.is_on_wall():
		return
	if path[cursor].y - (pos.y + _nav_off) > float(body_cfg.step_up_max) + 0.1:
		cursor -= 1
		_strict_pos = path[cursor]
		ledge_backoffs += 1


func repath(goal: Vector3) -> void:
	_since_query = 0.0
	_repath_t = float(nav_cfg.repath_interval) + randf_range(-1.0, 1.0) * float(nav_cfg.repath_jitter)
	_last_goal = goal
	path_queries += 1
	if not _nav_ready():
		path = PackedVector3Array()
		cursor = 0
		return
	agent.target_position = goal
	agent.get_next_path_position() # runs the agent's path query now
	path = agent.get_current_navigation_path()
	cursor = 0
	if not path.is_empty():
		_nav_off = clampf(path[0].y - enemy.global_position.y, -0.2, 0.8) if enemy.is_on_floor() else _nav_off
	_advance(enemy.global_position)


## Distance left along the path from the zombie (for tests / debug).
func path_remaining() -> float:
	if path.is_empty() or cursor >= path.size():
		return 0.0
	var d := enemy.global_position.distance_to(path[cursor])
	for i in range(cursor + 1, path.size()):
		d += path[i - 1].distance_to(path[i])
	return d


# ------------------------------------------------------------------ per-frame

## The one per-frame call (host / authority only). desired = flat walking velocity (move_dir * speed).
func tick(delta: float, desired: Vector3) -> void:
	var frame := Engine.get_physics_frames()
	if not _avoid_on and agent and bool(avoid_cfg.get("enabled", true)):
		_set_avoidance(true)
	if frame - _last_tick_frame > 2: # boss telegraph / grab / anything that skipped us: restart the stuck probe
		_probe_pos = enemy.global_position
		_probe_t = 0.0
	if suspended or frame - _last_tick_frame > 1:
		# resume after an off-nav phase: drop every safe velocity from before / during it; this frame walks the fresh wish
		if suspended:
			resumes += 1
		suspended = false
		_safe_frame = -10
		_resume_frame = frame
	_last_tick_frame = frame
	var wants := _want_frame >= frame - 1 and desired.length() > 0.05
	_update_path(delta, wants)
	_air_t = 0.0 if enemy.is_on_floor() else _air_t + delta
	_hop_cd = maxf(_hop_cd - delta, 0.0)
	_side_t = maxf(_side_t - delta, 0.0)
	if _detour != Vector3.INF:
		_detour_t -= delta
		if _detour_t <= 0.0 or _flat(_detour - enemy.global_position).length() < 0.6:
			_detour = Vector3.INF
			var t := _target()
			if t:
				repath(t.global_position)
	# avoidance (RVO): post this frame's wish, use the latest safe velocity (one physics frame behind).
	var v := desired
	if _avoid_on:
		agent.max_speed = maxf(desired.length(), float(enemy.get("speed"))) * float(avoid_cfg.max_speed_mult)
		agent.velocity = desired
		if frame - _safe_frame <= 2 and desired.length() > 0.05:
			v = _flat(_safe)
			if frame == _resume_frame:
				resume_used_safe += 1 # can't happen: resume clears _safe_frame (tests assert it stays 0)
			# never let avoidance turn us around or stall us completely on a narrow ramp
			if v.dot(desired) < 0.0 or v.length() < desired.length() * 0.25:
				v = desired * 0.35 + v * 0.65 if v.dot(desired) >= 0.0 else desired * 0.35
	if debug_freeze:
		v = Vector3.ZERO
	var kb: Vector3 = enemy.get("knockback")
	enemy.velocity.x = v.x + kb.x
	enemy.velocity.z = v.z + kb.z
	if kb.y > 0.5 and enemy.is_on_floor():
		enemy.velocity.y = kb.y
		kb.y = 0.0
		enemy.set("knockback", kb)
	if not debug_freeze and wants:
		_try_step_up(delta)
	enemy.move_and_slide()
	_ease_model(delta)
	_update_stuck(delta, wants, desired)


func _update_path(delta: float, wants: bool) -> void:
	_since_query += delta
	_repath_t -= delta
	var t := _target()
	if t == null or not wants:
		return
	var goal := t.global_position
	var due := _repath_t <= 0.0
	var moved := _last_goal == Vector3.INF or goal.distance_to(_last_goal) > float(nav_cfg.target_moved_repath)
	var finished := not path.is_empty() and cursor >= path.size() \
		and _flat(goal - enemy.global_position).length() > float(nav_cfg.direct_chase_dist)
	var map_changed := false
	if _map_dirty >= 0.0:
		_map_dirty -= delta
		map_changed = _map_dirty < 0.0
	# Landed after a drop / hop / knock-up: the old path may start on the deck we left.
	var landed := enemy.is_on_floor() and _air_t > float(body_cfg.land_repath_air)
	if (due or moved or finished or path.is_empty() or map_changed or landed) and _since_query >= float(nav_cfg.repath_min_interval):
		if map_changed:
			map_repaths += 1
		repath(goal)
	elif map_changed:
		_map_dirty = 0.0 # retry next frame (min interval)


## Shape-tested step-up: blocked by a wall-ish contact -> try up step_up_max, forward, down onto a walkable floor.
func _try_step_up(delta: float) -> bool:
	if not enemy.is_on_floor():
		return false
	var h := _flat(enemy.velocity)
	if h.length() < 0.2:
		return false
	if not enemy.is_on_wall() and _flat(enemy.get_real_velocity()).length() > h.length() * 0.85:
		return false # last frame's slide wasn't held back by anything: skip the probes (perf on open floor)
	var xf := enemy.global_transform
	var motion := h * delta
	var col := KinematicCollision3D.new()
	if not enemy.test_move(xf, motion, col):
		return false
	if col.get_normal().y > 0.7 or col.get_collider() is CharacterBody3D:
		return false # a floor-ish contact (move_and_slide handles it) or another zombie / the player
	var smax := float(body_cfg.step_up_max)
	var up := Vector3.UP * smax
	if enemy.test_move(xf, up):
		return false
	var xf_up := xf.translated(up)
	var fwd := h.normalized() * maxf(motion.length(), float(body_cfg.step_probe))
	if enemy.test_move(xf_up, fwd):
		return _try_hop(h) # taller than a step: hop if it is still under hop_max
	var xf_f := xf_up.translated(fwd)
	var down := KinematicCollision3D.new()
	if not enemy.test_move(xf_f, Vector3.DOWN * (smax + 0.05), down):
		return false
	if down.get_normal().y < cos(enemy.floor_max_angle):
		return false
	var dest := xf_f.origin + down.get_travel()
	var rise := dest.y - xf.origin.y
	if rise < 0.03 or rise > smax + 0.01:
		return false
	enemy.global_position = dest
	_step_vis -= rise
	steps += 1
	return true


## Hop over a low blocker (step_up_max < height <= hop_max: cable ducts, sandbags, kerbs) when it is clear above it.
## No off-mesh links exist for drops, so the reverse (walking off a deck) is just gravity + the landing repath.
func _try_hop(h: Vector3) -> bool:
	if _hop_cd > 0.0 or kind == "boss" or not enemy.is_on_floor() or h.length() < 0.2:
		return false
	var xf := enemy.global_transform
	var hmax := float(body_cfg.hop_max)
	var fwd := h.normalized() * maxf(float(body_cfg.step_probe), 0.25)
	if enemy.test_move(xf, Vector3.UP * (hmax + 0.05)):
		return false # low ceiling
	if enemy.test_move(xf.translated(Vector3.UP * (hmax + 0.05)), fwd):
		return false # a real wall, not a low blocker
	var g := float(enemy.get("_gravity")) if enemy.get("_gravity") != null else 9.8
	enemy.velocity.y = sqrt(2.0 * g * float(body_cfg.hop_height))
	_hop_cd = float(body_cfg.hop_cooldown)
	hops += 1
	return true


## True when something lower than hop_max blocks the way ahead (stuck level 2 picks a hop over a side-step then).
func _low_blocker_ahead() -> bool:
	var fwd := _flat(_desired_dir if _desired_dir.length() > 0.1 else -enemy.global_basis.z).normalized() * 0.3
	var xf := enemy.global_transform
	var col := KinematicCollision3D.new()
	if not enemy.test_move(xf, fwd, col) or col.get_collider() is CharacterBody3D:
		return false
	var hmax := float(body_cfg.hop_max)
	return not enemy.test_move(xf, Vector3.UP * (hmax + 0.05)) and not enemy.test_move(xf.translated(Vector3.UP * (hmax + 0.05)), fwd)


## Lowers the model by the step rise and eases it back, so a step-up reads as a climb.
func _ease_model(delta: float) -> void:
	if _step_vis == 0.0:
		return
	_step_vis = move_toward(_step_vis, 0.0, float(body_cfg.step_smooth_speed) * delta)
	_step_vis = maxf(_step_vis, -float(body_cfg.step_up_max))
	var mr = enemy.get("model_root")
	if mr is Node3D:
		(mr as Node3D).position.y = _step_vis


# ------------------------------------------------------------------ stuck

func _update_stuck(delta: float, wants: bool, desired: Vector3) -> void:
	var pos := enemy.global_position
	var t := _target()
	var busy := float(enemy.get("_attack_anim_t")) > 0.0
	var crowd := t != null and _flat(t.global_position - pos).length() < float(stuck_cfg.crowd_radius) \
		and absf(t.global_position.y - pos.y) < 1.5
	if not wants or busy or crowd or _air_t > 0.1:
		_probe_pos = pos
		_probe_t = 0.0
		_prog_t = 0.0
		_prog_goal = Vector3.INF
		if not wants or crowd:
			stuck_level = 0
		return
	_progress_watch(delta, t)
	_probe_t += delta
	var window := float(stuck_cfg.window)
	if _probe_t < window:
		return
	var expected := desired.length() * window
	var limit := minf(float(stuck_cfg.min_move), expected * 0.25)
	var moved := pos.distance_to(_probe_pos)
	_probe_pos = pos
	_probe_t = 0.0
	if moved < limit:
		stuck_level += 1
		if stuck_level == 1 and enemy.is_on_wall():
			stuck_level = 2 # pressed into a wall: a lateral nudge beats another identical path
		_unstick()
	elif moved > limit * 2.0 and _side_t <= 0.0 and _detour == Vector3.INF:
		stuck_level = 0


## Second detector: moving but not getting anywhere (sliding back and forth along a ledge, orbiting a corner).
## Over progress_window s the path distance left must drop by progress_min m, unless the target itself moved away.
func _progress_watch(delta: float, t: Node3D) -> void:
	if t == null:
		return
	var rem := path_remaining() if not path.is_empty() else _flat(t.global_position - enemy.global_position).length()
	if _prog_goal == Vector3.INF:
		_prog_goal = t.global_position
		_prog_start = rem
		_prog_best = rem
		_prog_t = 0.0
		return
	_prog_best = minf(_prog_best, rem)
	_prog_t += delta
	if _prog_t < float(stuck_cfg.progress_window):
		return
	var target_moved := t.global_position.distance_to(_prog_goal) > float(stuck_cfg.progress_target_move)
	if not target_moved and _prog_start - _prog_best < float(stuck_cfg.progress_min) and _side_t <= 0.0 and _detour == Vector3.INF:
		stuck_level = maxi(stuck_level + 1, 2) # it already moves, so a plain repath won't help: start at sidestep
		last_action = "no_progress"
		_unstick()
	_prog_goal = Vector3.INF


func _unstick() -> void:
	var t := _target()
	unstick_count += 1
	match stuck_level:
		1:
			last_action = "repath"
			if t:
				repath(t.global_position)
		2:
			if _hop_cd <= 0.0 and kind != "boss" and enemy.is_on_floor() and _low_blocker_ahead():
				last_action = "hop"
				var g := float(enemy.get("_gravity")) if enemy.get("_gravity") != null else 9.8
				enemy.velocity.y = sqrt(2.0 * g * float(body_cfg.hop_height))
				_hop_cd = float(body_cfg.hop_cooldown)
				hops += 1
			else:
				last_action = "sidestep"
				_begin_sidestep()
		3:
			last_action = "detour"
			if not _begin_detour():
				_begin_sidestep()
		_:
			if can_teleport():
				last_action = "teleport"
				_teleport_along_path()
				stuck_level = 0
			else:
				last_action = "cycle"
				stuck_level = 1
				if t:
					repath(t.global_position)


func _begin_sidestep() -> void:
	var fwd := _desired_dir if _desired_dir.length() > 0.1 else -enemy.global_basis.z
	fwd = _flat(fwd).normalized()
	var left := Vector3(-fwd.z, 0.0, fwd.x)
	var dist := float(stuck_cfg.sidestep_dist)
	var free_l := not enemy.test_move(enemy.global_transform, left * dist)
	var free_r := not enemy.test_move(enemy.global_transform, -left * dist)
	var side := left
	if free_l and free_r:
		side = left if randf() < 0.5 else -left
	elif free_r:
		side = -left
	elif not free_l:
		side = -fwd # boxed in: back off
	_side_dir = side
	# ~sidestep_dist m of lateral travel (0.8 of the walk speed goes sideways), capped at sidestep_time s
	var spd := maxf(float(enemy.get("speed")), 0.5)
	_side_t = clampf(float(stuck_cfg.sidestep_dist) / (spd * 0.8), 0.15, float(stuck_cfg.sidestep_time))


## A reachable navmesh point detour_dist m off to the side / back. False if none.
func _begin_detour() -> bool:
	if not _nav_ready():
		return false
	var m := agent.get_navigation_map()
	var pos := enemy.global_position
	var fwd := _flat(_desired_dir if _desired_dir.length() > 0.1 else -enemy.global_basis.z).normalized()
	var angles := [70.0, -70.0, 110.0, -110.0, 160.0, -160.0]
	if randf() < 0.5:
		angles = [-70.0, 70.0, -110.0, 110.0, -160.0, 160.0]
	for a in angles:
		var dir := fwd.rotated(Vector3.UP, deg_to_rad(a))
		var cand := pos + dir * float(stuck_cfg.detour_dist)
		var p := NavigationServer3D.map_get_closest_point(m, cand)
		if _flat(p - cand).length() < 1.0 and _flat(p - pos).length() > 1.5 and absf(p.y - pos.y) < 1.0:
			_detour = p
			_detour_t = float(stuck_cfg.detour_time)
			return true
	return false


## Last resort only when no player could notice: far from every player and out of every player's view.
func can_teleport() -> bool:
	var pls := players(enemy)
	for p in pls:
		if (p as Node3D).global_position.distance_to(enemy.global_position) < float(stuck_cfg.teleport_min_dist):
			return false
	return not visible_to_player()


## True if any player's camera has this zombie in its frustum with a clear line of sight (world layer).
func visible_to_player(at: Vector3 = Vector3.INF) -> bool:
	var pt := (enemy.global_position if at == Vector3.INF else at) + Vector3(0, 1.0, 0)
	for p in players(enemy):
		var cam = p.get("camera")
		if not (cam is Camera3D) or not (cam as Camera3D).is_inside_tree():
			return true # can't tell: assume seen
		var c := cam as Camera3D
		if not c.is_position_in_frustum(pt):
			continue
		var space := enemy.get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(c.global_position, pt, WORLD_MASK)
		var ex: Array[RID] = [enemy.get_rid()]
		if p is CollisionObject3D:
			ex.append((p as CollisionObject3D).get_rid())
		q.exclude = ex
		if space.intersect_ray(q).is_empty():
			return true
	return false


func _teleport_along_path() -> void:
	var dest := Vector3.INF
	if _nav_ready() and not path.is_empty() and cursor < path.size():
		var want := float(stuck_cfg.teleport_ahead)
		var prev := enemy.global_position
		var acc := 0.0
		for i in range(cursor, path.size()):
			var seg := prev.distance_to(path[i])
			if acc + seg >= want:
				dest = prev.lerp(path[i], (want - acc) / maxf(seg, 0.001))
				break
			acc += seg
			prev = path[i]
		if dest == Vector3.INF:
			dest = path[path.size() - 1]
		dest = NavigationServer3D.map_get_closest_point(agent.get_navigation_map(), dest)
		for p in players(enemy):
			if (p as Node3D).global_position.distance_to(dest) < float(stuck_cfg.teleport_min_player_dist):
				dest = Vector3.INF
				break
		if dest != Vector3.INF and visible_to_player(dest):
			dest = Vector3.INF
	if dest != Vector3.INF:
		enemy.global_position = dest + Vector3(0, 0.05, 0)
		teleports += 1
	else:
		var main := enemy.get_tree().current_scene
		if main and main.has_method("respawn_zombie"):
			main.respawn_zombie(enemy)
			respawns += 1
		else:
			return
	enemy.velocity = Vector3.ZERO
	_detour = Vector3.INF
	_side_t = 0.0
	path = PackedVector3Array()
	_probe_pos = enemy.global_position
	_probe_t = 0.0
