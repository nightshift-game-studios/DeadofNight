class_name ArmorItem
extends GearItem
## A rolled armor piece: one of helmet / gauntlets / chest / legs / class_item,
## with six stats (mobility, resilience, recovery, discipline, intellect, strength).

const STAT_ORDER: Array[String] = ["agility", "toughness", "vitality", "ordnance", "focus", "brawn"]
const STAT_LABELS := {"agility": "Agility", "toughness": "Toughness", "vitality": "Vitality",
	"ordnance": "Ordnance", "focus": "Focus", "brawn": "Brawn"}

var slot_label: String = "Armor"
## Class items only (DESIGN §23.3): the effect id in data/class_items.json and the class it works for.
var class_effect: String = ""
var class_id: String = ""


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
	var s := "%s %s  |  %s  |  Total %d" % [rarity_name(), type_name(), manufacturer, stat_total()]
	var l := class_line()
	return s + ("\n" + l if l != "" else "")


## The class item's one-line effect with this item's numbers ("" for other armor). See ClassItems.
func class_line() -> String:
	return ClassItems.line(self) if class_effect != "" else ""


## "With <keystone>: ..." synergy sentence ("" for other armor).
func class_synergy_line() -> String:
	return ClassItems.synergy_line(self) if class_effect != "" else ""


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["class"] = "armor"
	if class_effect != "":
		d["class_effect"] = class_effect
		d["class_id"] = class_id
	return d


func apply_dict(d: Dictionary) -> void:
	super.apply_dict(d)
	class_effect = str(d.get("class_effect", ""))
	class_id = str(d.get("class_id", ""))
	if slot == "class_item" and (class_effect == "" or ClassItems.def(class_effect).is_empty()):
		# pre-Batch C class item: give it an effect for the class being played (deterministic per item)
		var prog = Engine.get_main_loop().root.get_node_or_null("Progress") if Engine.get_main_loop() is SceneTree else null
		ClassItems.legacy_assign(self, str(prog.selected_class) if prog else "soldier")
