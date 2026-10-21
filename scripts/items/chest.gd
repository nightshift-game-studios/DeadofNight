class_name Chest
extends StaticBody3D
## Loot chest. Press E to buy it open; rolls the "chest" loot table (data/loot_tables.json)
## and pops the drops out as loot shards.
## Economy v2 (DESIGN §21, data/economy.json -> chests): opening costs points (cost + cost_step per chest already bought
## this match, capped at cost_max). Chests are no longer re-armed every round: a bought chest waits relocate_delay seconds,
## then moves to another free, unlocked chest spot (ChestSpots: Mapz's ChestSpots markers, fallback the Chests/ markers)
## and is closed again. With no free spot (e.g. the built-in arena: 3 chests, 3 places) it stays open until the next
## round's rearm(). main.gd still calls rearm(n) every round start; that now only re-closes a chest that is waiting there.
## Also rolls the chest Gravemark source (Armory.on_chest_opened); it pays straight into
## Progress and pops Desi's gravemark.glb token (scripts/items/gravemark_pickup.gd, cosmetic) (Progress.gravemark_gained fires for HUD popups).
## Art4 (Skillz): Model = Desi's loot_chest.glb (identity transform, front +Z; Base / Lid / LootSpawn / InteractPoint).
## Clips: Idle_Closed in _ready, Open on interact, Close on rearm (only if it was open). A model without an
## AnimationPlayer (or a missing clip) is tolerated: play_clip() returns false and the chest still works.

signal opened(chest: Chest)
signal relocated(chest: Chest, from: Vector3, to: Vector3)
signal refused(chest: Chest, reason: String)

const ChestSpotsScr := preload("res://scripts/items/chest_spots.gd")

@export var loot_table: String = "chest"
var is_open: bool = false
var round_number: int = 1

@onready var area: Area3D = $Area3D
@onready var glow: OmniLight3D = $Glow
@onready var model: Node3D = $Model
var anim: AnimationPlayer
var last_clip: String = "" ## last clip play_clip() started (tests / debug)
var waiting_for_round: bool = false ## bought, nowhere free to move: closes at the next rearm()
var relocating: bool = false ## bought, the relocate timer is running
var times_bought: int = 0 ## this chest, this match
var last_price: int = 0 ## what the last open cost
var spot_name: String = "" ## the ChestSpot it sits on ("" = its starting marker)

static var _match_key: int = 0 ## current scene instance id: a new scene = a new match
static var _bought_in_match: int = 0 ## chests bought this match (all chests): drives the price step

const CLIP_IDLE := "Idle_Closed"
const CLIP_OPEN := "Open"
const CLIP_CLOSE := "Close"


func _ready() -> void:
	add_to_group("chests")
	if not has_meta("chest_home"):
		set_meta("chest_home", global_transform)
	area.body_entered.connect(func(b): if b.has_method("set_nearby_interactable"): b.set_nearby_interactable(self, true))
	area.body_exited.connect(func(b): if b.has_method("set_nearby_interactable"): b.set_nearby_interactable(self, false))
	anim = model.find_child("AnimationPlayer", true, false) as AnimationPlayer if model else null
	play_clip(CLIP_IDLE)
	_update_visual()


## Plays a chest clip on the model's AnimationPlayer. Returns false when there is nothing to play.
func play_clip(clip: String) -> bool:
	if anim == null or not anim.has_animation(clip):
		return false
	anim.play(clip)
	last_clip = clip
	return true


func can_interact() -> bool:
	return not is_open


## data/economy.json -> chests ({} = free chests, the old behaviour).
static func cfg() -> Dictionary:
	var p = Engine.get_main_loop().root.get_node_or_null("/root/Progress") if Engine.get_main_loop() else null
	return p.chest_cfg() if p and p.has_method("chest_cfg") else {}


static func _sync_match(tree: SceneTree) -> void:
	var key := tree.current_scene.get_instance_id() if tree and tree.current_scene else 0
	if key != _match_key:
		_match_key = key
		_bought_in_match = 0


## Chests bought so far this match (all chests).
static func bought_this_match() -> int:
	return _bought_in_match


static func reset_match() -> void:
	_bought_in_match = 0


## What opening a chest costs right now: cost + cost_step x chests bought this match, capped at cost_max.
func price() -> int:
	if is_inside_tree():
		_sync_match(get_tree())
	return price_for(_bought_in_match)


static func price_for(bought_before: int, c: Dictionary = {}) -> int:
	if c.is_empty():
		c = cfg()
	var base := int(c.get("cost", 0))
	var top := int(c.get("cost_max", 0))
	var v := base + int(c.get("cost_step", 0)) * maxi(bought_before, 0)
	return mini(v, top) if top > 0 else v


func get_prompt() -> String:
	var p := price()
	return "Open Chest [%d]" % p if p > 0 else "Open Chest"


func interact(_player: Node) -> void:
	if is_open:
		return
	var cost := price()
	if cost > 0 and _player != null and _player.has_method("spend_points"):
		if not _player.spend_points(cost):
			var why := "Need %d points" % cost
			refused.emit(self, why)
			if _player.has_signal("pickup_prompt_changed"):
				_player.pickup_prompt_changed.emit("%s (you have %d)" % [why, int(_player.get("points"))], "")
			return
	last_price = cost
	_bought_in_match += 1
	times_bought += 1
	is_open = true
	play_clip(CLIP_OPEN)
	_update_visual()
	var a := get_node_or_null("/root/Sfx")
	if a:
		a.play_at("chest_open", global_position + Vector3(0, 0.6, 0))
	var items: Array = GearDB.roll_table(loot_table, round_number)
	var main := get_tree().current_scene
	for i in items.size():
		var angle: float = TAU * i / max(items.size(), 1) + randf() * 0.5
		var p := global_position + global_basis.z * 1.3 + Vector3(cos(angle), 0, sin(angle)) * 0.8
		if main.has_method("spawn_pickup"):
			main.spawn_pickup(items[i], p)
	# Gravemark (Skillz): small chance x difficulty, max 1 per round / 2 per match from chests (data/armory.json).
	var A = load("res://scripts/armory/armory.gd")
	if A:
		var gm: int = A.on_chest_opened(round_number)
		if gm > 0: # Desi's gravemark.glb token (cosmetic; already paid)
			load("res://scripts/items/gravemark_pickup.gd").spawn(get_tree().current_scene, global_position, gm)
	var t := create_tween()
	t.tween_property(model, "scale", Vector3(1.1, 0.9, 1.1), 0.08)
	t.tween_property(model, "scale", Vector3.ONE, 0.2)
	opened.emit(self)
	_after_open()


## Bought: relocate after relocate_delay (data), or wait for the next round when relocation is off / impossible.
func _after_open() -> void:
	var c := cfg()
	if not bool(c.get("relocate", false)):
		waiting_for_round = true
		return
	relocating = true
	var d := float(c.get("relocate_delay", 3.0))
	if d <= 0.0 or not is_inside_tree():
		relocate_now()
	else:
		get_tree().create_timer(d, false).timeout.connect(relocate_now)


func _map() -> Node:
	var main := get_tree().current_scene if is_inside_tree() else null
	return main.get("map") if main and "map" in main else null


## Every spot this chest could ever use (cached per map / scene).
func spots() -> Array:
	var m := _map()
	if m:
		if not m.has_meta("chest_spots_cache"):
			m.set_meta("chest_spots_cache", ChestSpotsScr.collect(m))
		return m.get_meta("chest_spots_cache")
	if not is_inside_tree():
		return []
	var scene := get_tree().current_scene
	if scene and scene.get_node_or_null(ChestSpotsScr.NODE_NAME):
		if not scene.has_meta("chest_spots_cache"):
			scene.set_meta("chest_spots_cache", ChestSpotsScr.collect(scene))
		return scene.get_meta("chest_spots_cache")
	return ChestSpotsScr.arena_spots(get_tree().get_nodes_in_group("chests"))


## Moves to another free spot now (closed, buyable). No free spot: stays open until the next rearm(). Returns moved.
func relocate_now() -> bool:
	if not is_instance_valid(self) or not is_inside_tree() or not relocating:
		return false
	relocating = false
	var taken := []
	for o in get_tree().get_nodes_in_group("chests"):
		if o != self and o is Node3D:
			taken.append((o as Node3D).global_position)
	var player := get_tree().current_scene.get_node_or_null("Player") if get_tree().current_scene else null
	var ppos = (player as Node3D).global_position if player is Node3D else null
	var spot := ChestSpotsScr.pick(spots(), global_position, taken, _map(), ppos, cfg(), null, get_world_3d().navigation_map, _nav_ref())
	if spot.is_empty():
		waiting_for_round = true
		return false
	var from := global_position
	global_transform = spot.transform
	spot_name = str(spot.get("name", ""))
	_close()
	var m := _map()
	if m and m.has_method("request_rebake"):
		m.request_rebake() # chests sit under the NavigationRegion3D: zombies path around the new spot
	relocated.emit(self, from, global_position)
	return true


## Where zombies' navmesh is anchored: the player spawn (main.gd _player_spawn, else the map's PlayerSpawn). A spot
## whose front the navmesh can't reach from here (the arena Tower perch) is only used when nothing else is free.
func _nav_ref():
	var main := get_tree().current_scene
	if main and "_player_spawn" in main and main.get("_player_spawn") is Transform3D:
		return (main.get("_player_spawn") as Transform3D).origin
	var m := _map()
	var ps := m.get_node_or_null("PlayerSpawn") as Node3D if m else null
	return ps.global_position if ps else null


func _close() -> void:
	if is_open:
		play_clip(CLIP_CLOSE)
	is_open = false
	waiting_for_round = false
	_update_visual()


## main.gd, every round start: only updates the drop round, and closes a bought chest that had nowhere to move.
func rearm(new_round: int) -> void:
	round_number = new_round
	if waiting_for_round or (is_open and not relocating and not bool(cfg().get("relocate", false))):
		_close()


func _update_visual() -> void:
	if glow:
		glow.visible = not is_open
