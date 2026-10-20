class_name Item
extends Resource
## Base item. Gear (weapons/armor) is rolled at runtime by GearDB from data/*.json;
## consumables are .tres files in res://resources/items/.

enum ItemType { WEAPON, CONSUMABLE, EQUIPMENT }

@export var id: String = "item"
@export var display_name: String = "Item"
@export var type: ItemType = ItemType.CONSUMABLE
@export_multiline var description: String = ""
@export var color: Color = Color.WHITE ## pickup / HUD tint
@export var max_stack: int = 1


func get_summary() -> String:
	return description


## Serialise for saving (e.g. a future vault). Subclasses extend this.
func to_dict() -> Dictionary:
	return {"kind": "consumable", "id": id}


## Inverse of to_dict() for every item class (weapon / armor / consumable), via GearDB.item_from_dict.
## Netz: co-op loot grants send item.to_dict() over the wire and rebuild it here. null if unknown / no GearDB.
static func from_dict(d: Dictionary) -> Item:
	var ml := Engine.get_main_loop()
	var gdb = (ml as SceneTree).root.get_node_or_null("GearDB") if ml is SceneTree else null
	return gdb.item_from_dict(d) if gdb and d is Dictionary else null
