class_name GearItem
extends Item
## Shared data for rolled gear (weapons + armor): rarity, rolled stats, perks, maker, flavor.
## Every piece carries its own Diablo-style Item Power (rolled from the round it dropped in
## plus a rarity bonus, see data/loot_tables.json -> item_power). It scales the stat rolls
## and weapon damage, and is shown on tiles and item cards.

@export var rarity: int = Rarity.COMMON
@export var item_power: int = 100
## How far through its random roll range this item landed for its Item Power and rarity:
## 0 = worst possible roll, 1 = best (see data/loot_tables.json -> roll_quality). -1 = unknown.
@export var roll_quality: float = -1.0
@export var manufacturer: String = "" ## fictional maker / brand shown on the item card
@export var manufacturer_color: Color = Color(0.8, 0.8, 0.8)
@export var flavor: String = "" ## short flavor-text line
@export var slot: String = "" ## primary / secondary / heavy / helmet / gauntlets / chest / legs / class_item
@export var archetype: String = "" ## weapon archetype id, or armor slot
@export var stats: Dictionary = {} ## stat name -> 0..100
@export var perks: Array[String] = []

## Persistent "seen" flag for the character screen '!' badge (saved with the item).
## New rolls/pickups start false; Inventory marks auto-equipped items seen; legacy saves (no key) load true.
@export var seen: bool = false

static var _next_uid: int = 1
var uid: int = 0 ## unique per instance (handy for UI / vault)


func _init() -> void:
	uid = _next_uid
	_next_uid += 1


func rarity_name() -> String:
	return Rarity.name_of(rarity)


func rarity_color() -> Color:
	return Rarity.color(rarity)


func type_name() -> String:
	return ""


func to_dict() -> Dictionary:
	return {
		"kind": "gear", "id": id, "display_name": display_name, "rarity": rarity, "item_power": item_power, "roll_quality": snappedf(roll_quality, 0.001),
		"manufacturer": manufacturer, "manufacturer_color": manufacturer_color.to_html(), "flavor": flavor,
		"slot": slot, "archetype": archetype, "stats": stats.duplicate(), "perks": Array(perks), "seen": seen,
	}


func apply_dict(d: Dictionary) -> void:
	id = d.get("id", id)
	display_name = d.get("display_name", display_name)
	rarity = int(d.get("rarity", rarity))
	# Legacy saves (before Item Power) have no item_power: they load as IP 100 (configurable).
	var legacy_ip := int(GearDB.loot.get("roll_quality", {}).get("legacy_item_power", 100)) if GearDB else 100
	item_power = int(d.get("item_power", legacy_ip))
	# Missing roll_quality stays -1 here; GearDB.item_from_dict() derives or defaults it.
	roll_quality = float(d.get("roll_quality", -1.0))
	manufacturer = d.get("manufacturer", manufacturer)
	manufacturer_color = Color.from_string(str(d.get("manufacturer_color", "cccccc")), manufacturer_color)
	flavor = d.get("flavor", flavor)
	slot = d.get("slot", slot)
	archetype = d.get("archetype", archetype)
	stats = d.get("stats", {}).duplicate()
	perks.assign(d.get("perks", []))
	seen = bool(d.get("seen", true)) # pre-stash items (no key) count as seen so old stashes don't light up
	color = rarity_color()
