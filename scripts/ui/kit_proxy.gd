extends Node
## Lightweight stand-in for character_screen outside a match (home Kit / Inventory).
## Holds an Inventory bound to Progress so equip/scrap persist via save_stash().
## Does not edit player.gd — only the fields character_screen.gd reads.

var inventory: Inventory
var player_class: Resource
var walk_speed: float = 5.0
var _base_walk: float = 5.0
var damage_reduction: float = 0.0
var regen_delay: float = 3.0
var grenade_cooldown: float = 8.0
var ability = null
var melee_damage: float = 40.0
var _ready_kit: bool = false


func _ready() -> void:
	if inventory == null:
		inventory = Inventory.new()
		inventory.name = "KitInventory"
		add_child(inventory)
	_load_stash()


func ensure() -> void:
	if inventory == null:
		inventory = Inventory.new()
		inventory.name = "KitInventory"
		if is_inside_tree():
			add_child(inventory)
	_load_stash()


func _load_stash() -> void:
	if _ready_kit:
		return
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("bind_inventory"):
		prog.bind_inventory(inventory)
		if prog.has_method("restore_stash") and prog.restore_stash(inventory):
			_ready_kit = true
		elif inventory.has_method("give_fresh_starter_loadout"):
			inventory.give_fresh_starter_loadout()
			_ready_kit = true
	elif inventory.has_method("give_fresh_starter_loadout"):
		inventory.give_fresh_starter_loadout()
		_ready_kit = true
	if prog and prog.has_method("load_selected_class"):
		player_class = prog.load_selected_class()


## Persist gear after the kit screen closes.
func save() -> bool:
	var prog := get_node_or_null("/root/Progress")
	if prog == null:
		return false
	if prog.has_method("bind_inventory"):
		prog.bind_inventory(inventory)
	return bool(prog.save_stash()) if prog.has_method("save_stash") else false


## Playtest #21: let go of the home kit before a character create / switch / delete. Saves the kit into the current
## character, unbinds it from Progress (Characters.blocked_reason treats a bound inventory as "in a match") and drops
## the Inventory so the next ensure() loads the new character's stash and class.
func release() -> void:
	if inventory == null:
		return
	save()
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("bind_inventory") and prog.bound_inventory() == inventory:
		prog.bind_inventory(null)
	inventory.queue_free()
	inventory = null
	_ready_kit = false


## The KitProxy whose inventory Progress has bound (home kit / merchant), or null (none, or a real match).
static func bound_proxy() -> Node:
	var ml := Engine.get_main_loop() as SceneTree
	var prog := ml.root.get_node_or_null("Progress") if ml else null
	var inv: Node = prog.bound_inventory() if prog and prog.has_method("bound_inventory") else null
	if inv and inv.get_parent() and inv.get_parent().has_method("release") and inv.get_parent().get_script() == load("res://scripts/ui/kit_proxy.gd"):
		return inv.get_parent()
	return null
