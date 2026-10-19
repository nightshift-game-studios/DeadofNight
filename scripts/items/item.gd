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
