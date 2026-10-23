extends RefCounted
## Player standing on a zombie's head (Skillz, playtest 2026-10-22 #18: "zombies must be able to hit you when you stand on
## their heads"). One per zombie, owned by ZombieNav (nav.head). Tunables: data/ai.json "head_stand" (kinds.<kind>.head_stand
## overrides). Host / authority only (it lives in the nav component, which puppets never tick).
##
## REACH   enemy.in_attack_reach() = the old flat + |dy| < attack_max_dy test OR reach(): the target's feet are within
##         [capsule top - below_tol, capsule top + above_tol] of the zombie's origin, and flat distance <= zombie capsule
##         radius + target capsule radius + radius_slack (+ the swing's `extra`), and no level geometry (world layer) on the line from the
##         zombie's head to the target's feet (occluded(): a gantry / deck / ledge beside or over the zombie is not a head). The capsule top comes from the zombie's own
##         CollisionShape3D (per-variant capsules included), not a constant. A player jumping well above it is out of reach.
## HOLD    once the player has been on the head for hold_delay s (hold = true) the zombie stands still: no chase / steering / avoidance, so it never
##         walks out from under the player or shoves them off the capsule; it keeps swinging (enemy.gd melee).
## SHAKE   optional, modest: stood on for shake.after s -> a shake.telegraph s rear-back (shaking = true, model leans) ->
##         a shove (shove_speed flat + shove_up) on the player and a lurch of the zombie the other way; then shake.cooldown s
##         before the next one. No damage of its own (the normal swings are the damage), host RNG for the direction.
##         Remote co-op avatars (NetRemoteAvatar, has push_state) are not shoved: their body lives on the owner's machine (Netz note).

const DEFAULTS := {
	"enabled": true,
	"hold": true,
	"below_tol": 0.35,
	"above_tol": 0.6,
	"radius_slack": 0.15,
	"target_radius": 0.4,
	"grace": 0.4,
	"hold_delay": 0.25,
	"world_mask": 1,
	"shake": {"enabled": true, "after": 4.0, "telegraph": 0.7, "cooldown": 10.0, "shove_speed": 5.5, "shove_up": 3.0, "lurch": 4.0, "lean": 0.35},
}

var enemy: CharacterBody3D
var nav: RefCounted
var cfg: Dictionary = DEFAULTS
var on_head: bool = false ## the target stands on this zombie's head right now (set by tick())
var stood_t: float = 0.0 ## seconds the target has been on the head (resets after `grace` s off it)
var shaking: bool = false ## true during the shake telegraph (Desi / Audi hook; enemy meta "head_shake" mirrors it)
var shake_left: float = 0.0
var cooldown: float = 0.0
var shakes: int = 0 ## shake-offs performed (tests)
var cancelled: int = 0 ## telegraphs abandoned because the player left the head (tests)
var last_shove: Vector3 = Vector3.ZERO ## last shove applied to the target (tests)
var _off_t: float = 0.0


static func make(e: CharacterBody3D, n: RefCounted, kind: String, ai_data: Dictionary) -> RefCounted:
	var h = load("res://scripts/enemies/ai/head_stand.gd").new()
	h.enemy = e
	h.nav = n
	h.cfg = merged(ai_data, kind)
	return h


static func merged(ai_data: Dictionary, kind: String) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate(true)
	_merge(out, ai_data.get("head_stand", {}))
	_merge(out, (ai_data.get("kinds", {}) as Dictionary).get(kind, {}).get("head_stand", {}))
	return out


static func _merge(into: Dictionary, over) -> void:
	if not (over is Dictionary):
		return
	for k in over:
		if k.begins_with("_"):
			continue
		if into.get(k) is Dictionary and over[k] is Dictionary:
			_merge(into[k], over[k])
		else:
			into[k] = over[k]


func enabled() -> bool:
	return bool(cfg.get("enabled", true))


## Top of this zombie's capsule above its origin (m).
func head_top() -> float:
	var cs := enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs and cs.shape is CapsuleShape3D:
		return cs.position.y + (cs.shape as CapsuleShape3D).height * 0.5
	return float(enemy.get("model_height")) if enemy.get("model_height") != null else 1.8


func body_radius() -> float:
	var cs := enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs and cs.shape is CapsuleShape3D:
		return (cs.shape as CapsuleShape3D).radius
	return 0.35


static func target_radius(t: Node, fallback: float) -> float:
	if t != null:
		var cs := t.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if cs and cs.shape is CapsuleShape3D:
			return (cs.shape as CapsuleShape3D).radius
	return fallback


## Max flat distance (m) from the zombie's axis to the target's at which a player can stand on / be hit on the head.
func head_radius(t: Node = null) -> float:
	return body_radius() + target_radius(t, float(cfg.target_radius)) + float(cfg.radius_slack)


## Pure geometry (tests): dist_h = flat distance, dy = target feet y - zombie origin y. `extra` widens the flat reach (the
## swing's landing slack).
func reach(dist_h: float, dy: float, extra: float = 0.0, t: Node = null) -> bool:
	if not enabled():
		return false
	var top := head_top()
	return dist_h <= head_radius(t) + extra and dy >= top - float(cfg.below_tol) and dy <= top + float(cfg.above_tol)


## reach() plus the world-occlusion test against the target's real position: what the game uses (ZombieNav.head_reach / tick).
## reach() stays pure geometry (tests feed it abstract numbers).
func reach_checked(dist_h: float, dy: float, extra: float = 0.0, t: Node = null) -> bool:
	return reach(dist_h, dy, extra, t) and (t == null or not occluded(t, head_top()))


## True when level geometry (a deck / ledge / wall layer) lies between the zombie's head and the target's feet: the target then
## stands on that geometry beside / above the zombie, not on its head (the swing would go through the deck, and holding still
## would freeze a zombie that should be pathing to the stairs). Ray from inside the head (0.1 m under the top: a deck can't overlap the capsule) to just over the feet.
func occluded(t: Node, top: float) -> bool:
	if not (t is Node3D) or not enemy.is_inside_tree() or not (t as Node3D).is_inside_tree():
		return false
	var from := enemy.global_position + Vector3(0.0, top - 0.1, 0.0)
	var to := (t as Node3D).global_position + Vector3(0.0, 0.05, 0.0)
	var q := PhysicsRayQueryParameters3D.create(from, to, int(cfg.get("world_mask", 1)))
	return not enemy.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## Called every physics frame by enemy.gd (via ZombieNav.head_stand_tick). Returns true when the zombie should hold still
## (the target is on its head and hold is on).
func tick(delta: float, t: Node3D, dist_h: float, dy: float) -> bool:
	_cd_tick(delta)
	var on: bool = enabled() and t != null and is_instance_valid(t) and t.get("dead") != true and reach_checked(dist_h, dy, 0.0, t)
	on_head = on
	if on:
		stood_t += delta
		_off_t = 0.0
	else:
		_off_t += delta
		if _off_t > float(cfg.grace):
			stood_t = 0.0
			if shaking:
				_end_shake()
				cancelled += 1
	var sh: Dictionary = cfg.shake
	if enabled() and bool(sh.get("enabled", true)):
		if not shaking and on and cooldown <= 0.0 and stood_t >= float(sh.after):
			shaking = true
			shake_left = float(sh.telegraph)
			enemy.set_meta("head_shake", true)
		if shaking and on: # off the head: the grace period above abandons the telegraph
			shake_left -= delta
			if shake_left <= 0.0:
				_shake_off(t)
	elif shaking:
		_end_shake()
	_lean(shaking, delta)
	return on and bool(cfg.get("hold", true)) and stood_t >= float(cfg.get("hold_delay", 0.25)) # a fly-by / hop over a head does not freeze the zombie


func _cd_tick(delta: float) -> void:
	cooldown = maxf(cooldown - delta, 0.0)


func _lean(on_: bool, delta: float) -> void:
	var mr = enemy.get("model_root")
	if mr is Node3D:
		var goal := -float(cfg.shake.get("lean", 0.35)) if on_ else 0.0
		(mr as Node3D).rotation.x = move_toward((mr as Node3D).rotation.x, goal, 3.0 * delta)


func _end_shake() -> void:
	shaking = false
	shake_left = 0.0
	if enemy.has_meta("head_shake"):
		enemy.remove_meta("head_shake")


func _shake_off(t: Node3D) -> void:
	var sh: Dictionary = cfg.shake
	var a: float = nav._roll("head_shake") * TAU
	var dir := Vector3(cos(a), 0.0, sin(a))
	last_shove = dir * float(sh.shove_speed) + Vector3.UP * float(sh.shove_up)
	if _can_shove(t):
		t.set("velocity", (t.get("velocity") as Vector3) + last_shove)
	var kb: Vector3 = enemy.get("knockback")
	enemy.set("knockback", kb - dir * float(sh.lurch))
	shakes += 1
	cooldown = float(sh.cooldown)
	stood_t = 0.0
	_end_shake()


## Local players are shoved here (host solo / the host's own player). A remote co-op avatar is a puppet of a body that lives
## on its owner's machine: nothing to move on the host.
func _can_shove(t: Node) -> bool:
	return t is CharacterBody3D and not t.has_method("push_state") and t.is_in_group("player")
