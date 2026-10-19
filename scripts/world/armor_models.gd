class_name ArmorModels
extends RefCounted
## Armor slot -> 3D model lookup (res://data/armor_models.json), for the character screen / a future 3rd-person body.
##   ArmorModels.piece_for_slot("helmet")              -> "helmet"
##   ArmorModels.piece_for_slot("class_item", "scout") -> "cloak"
##   ArmorModels.display_path("chest")                 -> res://assets/models/armor/display/armor_chest_display.glb
##   ArmorModels.skinned_path("class_item", "soldier") -> res://assets/models/armor/armor_sash.glb
## Slots are the ones in data/armor.json (helmet, gauntlets, chest, legs, class_item). Unknown slot -> "".

const DATA_PATH := "res://data/armor_models.json"
static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_data = d if d is Dictionary else {}
	return _data


static func slots() -> Array:
	return data().get("slot_pieces", {}).keys()


static func piece_for_slot(slot: String, class_id: String = "") -> String:
	var opts: Array = data().get("slot_pieces", {}).get(slot, [])
	if opts.is_empty():
		return ""
	var pref: String = data().get("class_item_by_class", {}).get(class_id, "") if slot == "class_item" else ""
	return pref if pref in opts else str(opts[0])


static func piece(piece_id: String) -> Dictionary:
	return data().get("pieces", {}).get(piece_id, {})


static func display_path(slot: String, class_id: String = "") -> String:
	return piece(piece_for_slot(slot, class_id)).get("display", "")


static func skinned_path(slot: String, class_id: String = "") -> String:
	return piece(piece_for_slot(slot, class_id)).get("skinned", "")


## Every model path in the file (tests / preloading).
static func all_paths() -> Array:
	var out := []
	for p in data().get("pieces", {}).values():
		for k in ["skinned", "display"]:
			if p.has(k):
				out.append(p[k])
	return out
