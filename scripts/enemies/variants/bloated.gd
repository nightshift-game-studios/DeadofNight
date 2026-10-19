extends "res://scripts/enemy.gd"
## Bloater (zombies.json "bloated"): slow, tanky, Pustules visible. On death it swells (Zombie_BurstWindup, ~0.6 s)
## and bursts from BurstPoint: hurts the player AND other zombies in `burst_radius`, then leaves a bile puddle that
## slows the player for `puddle_time`. A melee kill, or a kill within `instant_range` of the player, skips the
## windup (it pops in your face). Player damage per burst is capped per difficulty (player_damage_cap()). Shooting the pustules (hits near BurstPoint) pops them: after `pustule_hits`
## they hide and the burst shrinks to `popped_mult`. Kill points are normal (main.gd's died handler).
## Knobs: data/zombies.json variants.bloated.behavior. Tests: tests/variants_test.gd.

const VC := preload("res://scripts/enemies/variants/variant_common.gd")
const PuddleScr := preload("res://scripts/enemies/variants/bile_puddle.gd")
const PlayerStatusScr := preload("res://scripts/combat/player_status.gd")
const BURST_COLOR := Color(0.55, 0.75, 0.15)

signal burst(bloater: Node, info: Dictionary)

var b: Dictionary = {}
var pustule_hits: int = 0
var pustules_popped: bool = false
var burst_state: String = "" ## "" alive, "windup", "done"
var last_burst: Dictionary = {} ## {pos, radius, player_damage, zombie_hits, instant, popped}
var _killed_by_melee: bool = false
var _windup_t: float = -1.0


func _ready() -> void:
	b = VC.behavior(self)
	VC.hook_bus(get_tree())
	super._ready()


func burst_point() -> Vector3:
	var n := VC.node(self, "BurstPoint")
	if n == null:
		n = VC.node(self, "Spine")
	return n.global_position if n else global_position + Vector3(0, 1.1, 0)


func burst_radius() -> float:
	return VC.num(b, "burst_radius", 3.5) * (VC.num(b, "popped_mult", 0.6) if pustules_popped else 1.0)


## Uncapped burst damage to a player `d` m from the burst centre (falls off to 30% at radius `r`).
func player_burst_damage(d: float, r: float) -> int:
	return maxi(int(round(float(contact_damage) * VC.num(b, "player_damage_mult", 2.0) * (1.0 - 0.7 * clampf(d / r, 0.0, 1.0))
			* (VC.num(b, "popped_mult", 0.6) if pustules_popped else 1.0))), 1)


## Most one burst can take from the player: difficulty.json variants.bloater_burst_player_cap (active profile),
## else behavior.player_damage_cap (40).
func player_damage_cap() -> int:
	var D = load("res://scripts/world/difficulty.gd")
	return int(D.variant_knob("bloater_burst_player_cap", VC.num(b, "player_damage_cap", 40.0)))


func take_damage(amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, source: Node = null) -> bool:
	if _dead:
		return false
	var kind := VC.hit_kind(self, source)
	if kind == "bullet" and not pustules_popped and hit_pos != Vector3.ZERO \
			and hit_pos.distance_to(burst_point()) <= VC.num(b, "pustule_hit_radius", 0.45):
		pustule_hits += 1
		if pustule_hits >= int(VC.num(b, "pustule_hits", 4)):
			pop_pustules()
	_killed_by_melee = kind == "melee"
	return super.take_damage(amount, hit_pos, crit, source)


func pop_pustules() -> void:
	if pustules_popped:
		return
	pustules_popped = true
	var p := VC.node(self, "Pustules")
	if p:
		p.visible = false
	if is_inside_tree() and get_parent():
		Explosion.spawn_vfx(get_parent(), burst_point(), 0.5, BURST_COLOR)


## True if this death skips the windup (melee kill, or the player is within instant_range).
func instant_death() -> bool:
	if _killed_by_melee:
		return true
	var pl := VC.player_of(self)
	return pl != null and VC.flat_dist(pl.global_position, global_position) <= VC.num(b, "instant_range", 2.0)


func _die() -> void:
	var instant := instant_death()
	super._die()
	if instant:
		burst_state = "windup"
		_do_burst.call_deferred(true)
		return
	burst_state = "windup"
	VC.play_clip(self, "burst_windup", str(b.get("windup_clip", "Zombie_BurstWindup")), 0.08)
	_windup_t = VC.num(b, "windup", 0.6)


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	if _windup_t >= 0.0:
		_windup_t -= delta
		if _windup_t < 0.0:
			_do_burst(false)


func _do_burst(instant: bool) -> void:
	if burst_state == "done" or not is_inside_tree():
		return
	burst_state = "done"
	_windup_t = -1.0
	var pos := burst_point()
	var r := burst_radius()
	var scene: Node = get_parent() if get_parent() else get_tree().current_scene
	var zdmg := float(max_health) * VC.num(b, "zombie_damage_frac", 0.8) * (VC.num(b, "popped_mult", 0.6) if pustules_popped else 1.0)
	var before: Array = get_tree().get_nodes_in_group("enemies").filter(
			func(e): return is_instance_valid(e) and (e.global_position + Vector3(0, 0.9, 0)).distance_to(pos) <= r)
	Explosion.explode(scene, pos, r, zdmg, VC.num(b, "knockback", 5.0), BURST_COLOR, null, null, 0.8,
			{"source": "bloater_burst", "bloater": self})
	var pdmg := 0
	var raw := 0
	var pl := VC.player_of(self)
	if pl and not pl.get("dead"):
		var d := (pl.global_position + Vector3(0, 0.9, 0)).distance_to(pos)
		if d <= r:
			raw = player_burst_damage(d, r)
			pdmg = mini(raw, player_damage_cap()) # one hit per burst, capped once; a chained burst caps on its own
			pl.call("take_damage", pdmg, self)
	var floor_pos := Vector3(pos.x, global_position.y, pos.z)
	if scene:
		PuddleScr.spawn(scene, floor_pos, VC.num(b, "puddle_radius", 2.2) * (0.75 if pustules_popped else 1.0),
				VC.num(b, "puddle_time", 4.0), VC.num(b, "puddle_slow", 0.45))
	var p := VC.node(self, "Pustules")
	if p:
		p.visible = false
	last_burst = {"pos": pos, "radius": r, "player_damage": pdmg, "player_damage_raw": raw, "player_cap": player_damage_cap(), "zombie_hits": before.size(), "instant": instant,
			"popped": pustules_popped}
	burst.emit(self, last_burst)
	if _anim and _anims.has("death"):
		_anim.play(_anims["death"], 0.05)
