class_name Chest
extends StaticBody3D
## Loot chest. Press E to open; rolls the "chest" loot table (data/loot_tables.json)
## and pops the drops out as loot shards. main.gd re-arms every chest each round.
## Also rolls the chest Gravemark source (Armory.on_chest_opened); it pays straight into
## Progress and pops Desi's gravemark.glb token (scripts/items/gravemark_pickup.gd, cosmetic) (Progress.gravemark_gained fires for HUD popups).

signal opened(chest: Chest)

@export var loot_table: String = "chest"
var is_open: bool = false
var round_number: int = 1

@onready var area: Area3D = $Area3D
@onready var glow: OmniLight3D = $Glow
@onready var model: Node3D = $Model


func _ready() -> void:
	add_to_group("chests")
	area.body_entered.connect(func(b): if b.has_method("set_nearby_interactable"): b.set_nearby_interactable(self, true))
	area.body_exited.connect(func(b): if b.has_method("set_nearby_interactable"): b.set_nearby_interactable(self, false))
	_update_visual()


func can_interact() -> bool:
	return not is_open


func get_prompt() -> String:
	return "Open Chest"


func interact(_player: Node) -> void:
	if is_open:
		return
	is_open = true
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


func rearm(new_round: int) -> void:
	round_number = new_round
	is_open = false
	_update_visual()


func _update_visual() -> void:
	if glow:
		glow.visible = not is_open
