class_name NetHitCheck
extends RefCounted
## Host sanity checks on client hit claims (Netz phase 3d). Reject + log + count, never kick; margins are generous
## on purpose (avatar lag, perks, Field Cards, Item Power): this catches broken or forged numbers, not skill.
## Claim kinds (the client tags them, NetHitCheck.classify):
##   gun    a round of the shooter's held weapon (GameEvents shot_fired this frame, at most pellets x penetration hits):
##          range = base_range x 4 (player.gd's ray) x range_mult + slack; damage <= base_damage x headshot x damage_margin;
##          rate <= rpm / 60 x pellets x hits x rate_margin + rate_slack per second; light line of sight (world layer).
##   aoe    inside an Explosion (rockets, skills' blasts): aoe_range_m, max_hit_damage, aoe_rate_per_s; no LOS (splash).
##   other  skills / abilities / melee: other_range_m, other_cap, other_rate_per_s; no LOS (chains, fields).
## The weapon must be the one the shooter's avatar holds (or held within weapon_grace_s); else the claim counts as other.
## Weapon numbers come from data/weapons.json (GearDB.weapons) at run time; data/net.json validation.hit holds margins.

const REASONS := ["range", "damage", "rate", "los"]

var net: Node
var stats := {"checked": 0, "ok": 0, "rejected": 0, "range": 0, "damage": 0, "rate": 0, "los": 0, "no_avatar": 0, "weapon_mismatch": 0, "gun": 0, "aoe": 0, "other": 0}
var per_peer: Dictionary = {} ## peer -> {reason: count}
var _times: Dictionary = {} ## peer -> {kind: [msec ...]}
var _held: Dictionary = {} ## peer -> [current weapon id, previous id, msec of the change]
var _log_t: Dictionary = {} ## "peer|reason" -> msec of the last warning


func _init(n: Node = null) -> void:
	net = n


static func cfg(key: String, fallback: Variant) -> Variant:
	return NetConfig.get_value("validation.hit." + key, fallback)


func clear() -> void:
	for k in stats:
		stats[k] = 0
	_times.clear()
	_held.clear()
	per_peer.clear()


## The archetype dict from the real weapon data, {} if unknown.
static func weapon_def(arch: String) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	var gdb: Node = tree.root.get_node_or_null("GearDB") if tree else null
	if gdb == null or arch == "":
		return {}
	var all = gdb.get("weapons")
	return all.get(arch, {}) if all is Dictionary else {}


static func max_hits_per_round(d: Dictionary) -> int:
	return maxi(int(d.get("pellets", 1)), 1) * (int(cfg("penetrate_hits", 4)) if bool(d.get("penetrate", false)) else 1)


static func gun_cap(d: Dictionary) -> float:
	var hs := float(d.get("headshot_multiplier", 2.0))
	return float(d.get("base_damage", 20.0)) * maxf(hs, 1.0) * float(cfg("damage_margin", 12.0))


static func gun_range(d: Dictionary) -> float:
	return float(d.get("base_range", 20.0)) * 4.0 * float(cfg("range_mult", 1.5)) + float(cfg("range_slack_m", 12.0))


static func gun_rate(d: Dictionary) -> float:
	var rpm := float(d.get("rpm", 300.0))
	return rpm / 60.0 * max_hits_per_round(d) * float(cfg("rate_margin", 2.5)) + float(cfg("rate_slack", 8.0))


## Host: the weapon the peer's avatar holds; remembers the previous one for weapon_grace_s (swap latency).
func _weapon_ok(peer: int, av: Node, claimed: String) -> bool:
	var cur := ""
	var b = av.get("body") if av else null
	if b and b.get("weapon_id") != null:
		cur = str(b.weapon_id)
	var h: Array = _held.get(peer, ["", "", 0])
	if cur != h[0]:
		h = [cur, h[0], Time.get_ticks_msec()]
		_held[peer] = h
	if claimed == cur:
		return true
	return claimed == h[1] and Time.get_ticks_msec() - int(h[2]) < int(float(cfg("weapon_grace_s", 2.0)) * 1000.0)


## Host: "" = accept, else the reject reason. Counts and (rate-limited) logs a rejection.
func check(peer: int, z: Node3D, amount: float, hit_pos: Vector3, kind: String, weapon: String, av: Node3D) -> String:
	stats.checked += 1
	if av == null or not is_instance_valid(av):
		stats.no_avatar += 1 # no avatar here yet (loading): nothing to measure against; the hard cap still applies
		stats.ok += 1
		return ""
	if not (kind in ["gun", "aoe", "other"]):
		kind = "other"
	var d := {}
	if kind == "gun":
		d = weapon_def(weapon)
		if d.is_empty() or not _weapon_ok(peer, av, weapon):
			stats.weapon_mismatch += 1
			kind = "other"
	stats[kind] = int(stats[kind]) + 1
	var eye := av.global_position + Vector3(0, float(cfg("eye_height", 1.5)), 0)
	var dist := eye.distance_to(hit_pos)
	var why := ""
	var max_r: float = gun_range(d) if kind == "gun" else float(cfg(kind + "_range_m", 90.0 if kind == "other" else 120.0))
	var cap: float = gun_cap(d) if kind == "gun" else float(cfg("other_cap", 2500.0)) if kind == "other" else float(NetConfig.get_value("validation.max_hit_damage", 5000.0))
	var rate: float = gun_rate(d) if kind == "gun" else float(cfg(kind + "_rate_per_s", 60.0 if kind == "other" else 120.0))
	if dist > max_r or (z and eye.distance_to(z.global_position) > max_r + 3.0):
		why = "range"
	elif amount > cap:
		why = "damage"
	elif not _rate_ok(peer, kind, rate):
		why = "rate"
	elif kind == "gun" and bool(cfg("los", true)) and not los_ok(av, eye, hit_pos):
		why = "los"
	if why == "":
		stats.ok += 1
		return ""
	stats.rejected += 1
	stats[why] = int(stats[why]) + 1
	var pp: Dictionary = per_peer.get(peer, {})
	pp[why] = int(pp.get(why, 0)) + 1
	per_peer[peer] = pp
	var key := "%d|%s" % [peer, why]
	var now := Time.get_ticks_msec()
	if now - int(_log_t.get(key, -999999)) > int(float(cfg("log_every_s", 5.0)) * 1000.0):
		_log_t[key] = now
		push_warning("NetHitCheck: peer %d hit claim refused (%s): %s %s dmg %.0f (cap %.0f) dist %.1f m (max %.1f) [%d refused so far]" % [peer, why, kind, weapon, amount, cap, dist, max_r, int(pp[why])])
	return why


func _rate_ok(peer: int, kind: String, per_s: float) -> bool:
	var now := Time.get_ticks_msec()
	var by: Dictionary = _times.get(peer, {})
	var lst: Array = (by.get(kind, []) as Array).filter(func(t): return now - int(t) < 1000)
	var ok := lst.size() < int(ceil(per_s))
	if ok:
		lst.append(now)
	by[kind] = lst
	_times[peer] = by
	return ok


## Light line of sight: a world-layer ray from the shooter's eye (and a few nearby points, for avatar lag and
## crouching) to the hit point. Blocked only if every ray stops more than los_tolerance_m short of it.
func los_ok(av: Node3D, eye: Vector3, hit_pos: Vector3) -> bool:
	if eye.distance_to(hit_pos) < float(cfg("los_min_m", 4.0)) or not av.is_inside_tree():
		return true
	var space := av.get_world_3d().direct_space_state
	var tol := float(cfg("los_tolerance_m", 0.75))
	var side := (hit_pos - eye).cross(Vector3.UP)
	side = side.normalized() * float(cfg("los_offset_m", 0.8)) if side.length() > 0.01 else Vector3.RIGHT * 0.8
	for o in [eye, eye + side, eye - side, eye + Vector3(0, 0.5, 0), eye - Vector3(0, 0.7, 0)]:
		var q := PhysicsRayQueryParameters3D.create(o, hit_pos, int(cfg("los_mask", 1)))
		if av is CollisionObject3D:
			q.exclude = [(av as CollisionObject3D).get_rid()]
		var r := space.intersect_ray(q)
		if r.is_empty() or (r.position as Vector3).distance_to(hit_pos) <= tol:
			return true
	return false


# ------------------------------------------------------------------ client side: tag the claim
var _shot := {"pf": -1, "f": -1, "arch": "", "left": 0}


## Client: GameEvents shot_fired from the local player (weapon + this frame).
func note_shot(w: Object) -> void:
	var arch := str(w.get("archetype")) if w and w.get("archetype") != null else ""
	var d := weapon_def(arch)
	_shot = {"pf": Engine.get_physics_frames(), "f": Engine.get_process_frames(), "arch": arch,
		"left": max_hits_per_round(d) if not d.is_empty() else 1}


## Client: [kind, weapon id] for the claim being sent now.
func classify() -> Array:
	var ex: Script = load("res://scripts/combat/explosion.gd")
	var cur = ex.get("current") if ex else null
	if cur is Dictionary and not (cur as Dictionary).is_empty():
		return ["aoe", ""]
	var same: bool = int(_shot.pf) == Engine.get_physics_frames() or int(_shot.f) == Engine.get_process_frames()
	if same and int(_shot.left) > 0 and str(_shot.arch) != "":
		_shot.left = int(_shot.left) - 1
		return ["gun", str(_shot.arch)]
	return ["other", ""]
