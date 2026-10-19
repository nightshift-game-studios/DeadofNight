extends RefCounted
## Shared helpers for the zombie variant behaviour scripts (bloated.gd / crawler.gd / riot.gd). Skillz, art pass 3.
## Variants are plain enemy.gd zombies with a script swapped in by ZombieVariants.apply_script() (MAIN_HOOKS §15a),
## the same way bosses extend enemy.gd. Every knob lives in data/zombies.json variants[id].behavior.

const ENEMY_SCENE := "res://scenes/enemy.tscn"
const BossArt := preload("res://scripts/enemies/boss_art.gd")

static var _melee_frame: int = -100 ## physics frame of the player's last melee swing (GameEvents melee_swung)
static var _bus_hooked: bool = false


static func behavior(enemy: Node) -> Dictionary:
	return ZombieVariants.behavior(str(enemy.get("variant_id")))


static func num(b: Dictionary, key: String, fallback: float) -> float:
	return float(b.get(key, fallback))


## Listens for the player's melee swing so a variant can tell a melee hit from a bullet (player.melee() emits
## melee_swung, then calls take_damage() in the same frame).
static func hook_bus(tree: SceneTree) -> void:
	if _bus_hooked or tree == null:
		return
	var bus := tree.root.get_node_or_null("GameEvents")
	if bus == null:
		return
	bus.event.connect(_on_event)
	_bus_hooked = true


static func _on_event(name: StringName, _ctx: Dictionary) -> void:
	if name == &"melee_swung":
		_melee_frame = Engine.get_physics_frames()


## True if the take_damage() running now is a player melee hit.
static func is_melee_hit(source: Node) -> bool:
	return source != null and source.is_in_group("player") and Explosion.current.is_empty() \
		and Engine.get_physics_frames() - _melee_frame <= 1


## Test hook: pretend the player just swung.
static func mark_melee() -> void:
	_melee_frame = Engine.get_physics_frames()


## Hit category for armour / pustule rules: "explosive", "burn", "melee" or "bullet".
static func hit_kind(enemy: Node, source: Node) -> String:
	if bool(enemy.get("_status_tick")):
		return "burn"
	if not Explosion.current.is_empty():
		return "explosive"
	if is_melee_hit(source):
		return "melee"
	return "bullet"


## A node inside the zombie's model (BurstPoint, GrabPoint, Pustules, ArmorVest ...).
static func node(enemy: Node, name: String) -> Node3D:
	var mr = enemy.get("model_root")
	if not (mr is Node):
		return null
	return (mr as Node).find_child(name, true, false) as Node3D


## Gives this zombie its own capsule (the scene's CapsuleShape3D is shared by every zombie) and nav height.
static func apply_collision(enemy: Node, c: Dictionary) -> void:
	if c.is_empty():
		return
	var cs := enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if cs and cs.shape is CapsuleShape3D:
		var cap := (cs.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
		cap.radius = float(c.get("radius", cap.radius))
		cap.height = maxf(float(c.get("height", cap.height)), cap.radius * 2.0)
		cs.shape = cap
		cs.position.y = float(c.get("center_y", cap.height * 0.5))
	var ag := enemy.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	if ag:
		ag.height = float(c.get("height", ag.height))
		ag.radius = float(c.get("nav_radius", ag.radius))


static func capsule(enemy: Node) -> CapsuleShape3D:
	var cs := enemy.get_node_or_null("CollisionShape3D") as CollisionShape3D
	return cs.shape as CapsuleShape3D if cs else null


## Flat (XZ) distance.
static func flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


## Plays a named GLB clip (Zombie_BurstWindup ...) from the start, registering it under `key`. Returns its length (0 = missing).
static func play_clip(enemy: Node, key: String, clip: String, blend: float = 0.1) -> float:
	var ap := BossArt.anim_player(enemy)
	if ap == null:
		return 0.0
	var c := BossArt.find_clip(ap, clip)
	if c == "":
		return 0.0
	var anims: Dictionary = enemy.get("_anims")
	anims[key] = c
	BossArt.play(enemy, key, blend)
	return ap.get_animation(c).length


static func player_of(enemy: Node) -> Node3D:
	var t = enemy.get("target")
	if t is Node3D and is_instance_valid(t):
		return t
	return enemy.get_tree().get_first_node_in_group("player") as Node3D if enemy.is_inside_tree() else null
