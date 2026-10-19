extends "res://scripts/enemy.gd"
## Crawler (zombies.json "crawler"): low, fast, small, low HP. Own capsule / head-bar height (behavior.collision,
## bar_height). Ankle grab: when the player is within `grab_range` it lunges (Zombie_AnkleGrab, from GrabPoint) and,
## if the player is still within `grip_range` after `grip_delay`, holds them: the player is rooted (PlayerStatus;
## movement needs MAIN_HOOKS §15b) and drains `drain_per_sec` HP for up to `grab_time` s. A jump, a melee hit
## that lands on the crawler (a whiff doesn't count), or killing it frees them. `grab_cooldown` s between grabs. Headshots: normal multiplier.

const VC := preload("res://scripts/enemies/variants/variant_common.gd")
const PlayerStatusScr := preload("res://scripts/combat/player_status.gd")

signal grab_started(crawler: Node, player: Node)
signal grab_ended(crawler: Node, player: Node, why: String)

var b: Dictionary = {}
var grab_state: String = "" ## "" idle, "lunge", "held"
var grab_cd: float = 0.0
var grab_t: float = 0.0
var grab_drained: int = 0 ## HP drained during the current / last grab
var last_release: String = ""
var _drain_acc: float = 0.0
var _drain_tick: float = 0.0
var _held: Node3D


func _ready() -> void:
	b = VC.behavior(self)
	VC.apply_collision(self, b.get("collision", {}))
	attack_max_dy = VC.num(b, "attack_max_dy", attack_max_dy)
	super._ready()
	if health_bar:
		health_bar.position.y = VC.num(b, "bar_height", 0.95)
	VC.hook_bus(get_tree()) # melee-hit detection
	var bus := get_node_or_null("/root/GameEvents")
	if bus:
		bus.event.connect(_on_bus_event)


func _on_bus_event(name: StringName, ctx: Dictionary) -> void:
	if grab_state == "" or ctx.get("player") != _grab_target():
		return
	if name == &"jumped":
		release("jump")


func _grab_target() -> Node3D:
	return _held if _held else VC.player_of(self)


## Can't walk while lunging / holding.
func slow_mult() -> float:
	return 0.0 if grab_state != "" else super.slow_mult()


func _physics_process(delta: float) -> void:
	if grab_state != "":
		_attack_cd = maxf(_attack_cd, 0.3) # no swipes while it holds on
	super._physics_process(delta)
	if _dead:
		return
	grab_cd = maxf(grab_cd - delta, 0.0)
	var pl := VC.player_of(self)
	if pl == null or pl.get("dead"):
		if grab_state != "":
			release("player_dead")
		return
	var d := VC.flat_dist(pl.global_position, global_position)
	var dy := absf(pl.global_position.y - global_position.y)
	match grab_state:
		"":
			if grab_cd <= 0.0 and d <= VC.num(b, "grab_range", 1.2) and dy < 0.9:
				start_lunge()
		"lunge":
			grab_t += delta
			if grab_t >= VC.num(b, "grip_delay", 0.36):
				if d <= VC.num(b, "grip_range", 1.6) and dy < 0.9:
					_hold(pl)
				else:
					release("missed")
		"held":
			grab_t += delta
			PlayerStatusScr.root(pl, 0.2, self)
			_drain_acc += VC.num(b, "drain_per_sec", 6.0) * delta
			_drain_tick -= delta
			if _drain_tick <= 0.0 and _drain_acc >= 1.0:
				_drain_tick = 0.25
				var n := int(_drain_acc)
				_drain_acc -= n
				grab_drained += n
				pl.call("take_damage", n, self)
			if grab_t >= VC.num(b, "grab_time", 2.0):
				release("timeout")
			elif d > VC.num(b, "grip_range", 1.6) + 0.5:
				release("pulled_free")


func start_lunge() -> void:
	grab_state = "lunge"
	grab_t = 0.0
	grab_drained = 0
	_drain_acc = 0.0
	_attack_anim_t = VC.num(b, "grip_delay", 0.36) + VC.num(b, "grab_time", 2.0)
	VC.play_clip(self, "ankle_grab", str(b.get("grab_clip", "Zombie_AnkleGrab")), 0.08)


func _hold(pl: Node3D) -> void:
	grab_state = "held"
	grab_t = 0.0
	_drain_tick = 0.0
	_held = pl
	PlayerStatusScr.root(pl, 0.2, self)
	grab_started.emit(self, pl)


## Lets go (jump, melee, death, timeout ...). Starts the cooldown.
func release(why: String) -> void:
	if grab_state == "":
		return
	var was_held := grab_state == "held"
	grab_state = ""
	grab_cd = VC.num(b, "grab_cooldown", 6.0)
	last_release = why
	_attack_anim_t = 0.0
	var pl := _held
	_held = null
	if pl and is_instance_valid(pl):
		PlayerStatusScr.release(pl, self)
	if was_held:
		grab_ended.emit(self, pl, why)


## A player melee that actually lands on this crawler frees the held player (a whiffed swing doesn't).
func take_damage(amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, source: Node = null) -> bool:
	var melee := grab_state != "" and VC.is_melee_hit(source)
	var killed := super.take_damage(amount, hit_pos, crit, source)
	if melee and not killed:
		release("melee")
	return killed


## GrabPoint (hand_r) in world space: where the grab VFX / hand sits.
func grab_point() -> Vector3:
	var n := VC.node(self, "GrabPoint")
	return n.global_position if n else global_position + Vector3(0, 0.3, 0)


func _die() -> void:
	release("killed")
	super._die()


func _exit_tree() -> void:
	if grab_state != "":
		release("freed")
