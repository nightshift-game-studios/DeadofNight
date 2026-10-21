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
	var ch := get_node_or_null("/root/Characters")
	if ch and ch.has_signal("switching") and not ch.switching.is_connected(_on_switching):
		ch.switching.connect(_on_switching) # Skillz 570e1bd: drop the kit before the character swap
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


## Characters.switching(from, to): Characters captures this kit into the CURRENT character and unbinds it right after
## this signal; the kit just drops its Inventory (no save here, or the old gear could land in the new character) so the
## next ensure() loads the new character's stash and class.
func _on_switching(_from_id: int = 0, _to_id: int = 0) -> void:
	if inventory == null:
		return
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("bound_inventory") and prog.bound_inventory() == inventory:
		prog.capture_stash() # same as Characters does next; keeps the kit's last edits with their owner
		prog.bind_inventory(null)
	inventory.queue_free()
	inventory = null
	_ready_kit = false
