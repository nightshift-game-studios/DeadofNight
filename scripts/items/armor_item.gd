class_name ArmorItem
extends GearItem
## A rolled armor piece: one of helmet / gauntlets / chest / legs / class_item,
## with six stats (mobility, resilience, recovery, discipline, intellect, strength).

const STAT_ORDER: Array[String] = ["agility", "toughness", "vitality", "ordnance", "focus", "brawn"]
const STAT_LABELS := {"agility": "Agility", "toughness": "Toughness", "vitality": "Vitality",
	"ordnance": "Ordnance", "focus": "Focus", "brawn": "Brawn"}

var slot_label: String = "Armor"


func _init() -> void:
	super._init()
	type = ItemType.EQUIPMENT


func type_name() -> String:
	return slot_label


func stat_total() -> int:
	var t := 0
	for s in STAT_ORDER:
		t += int(stats.get(s, 0))
	return t


func display_stats() -> Array:
	var out := []
	for s in STAT_ORDER:
		out.append([STAT_LABELS[s], float(stats.get(s, 0))])
	return out


## Item-card stat block (same shape as WeaponItem.card_stats()).
func card_stats() -> Array:
	var out := []
	for s in STAT_ORDER:
		var v := float(stats.get(s, 0))
		out.append([STAT_LABELS[s], "%d" % int(v), clampf(v / 30.0, 0.0, 1.0), v, true])
	out.append(["Total", "%d" % stat_total(), clampf(stat_total() / 60.0, 0.0, 1.0), float(stat_total()), true])
	return out


func get_summary() -> String:
	return "%s %s  |  %s  |  Total %d" % [rarity_name(), type_name(), manufacturer, stat_total()]


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["class"] = "armor"
	return d
