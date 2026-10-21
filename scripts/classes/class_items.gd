class_name ClassItems
extends RefCounted
## Class item effects (DESIGN §23.3, data/class_items.json). A class item (ArmorItem in slot "class_item") carries one
## effect id (`class_effect`) for one class (`class_id`). While that class is played, SkillRunner adds the effect at
## rank = rarity + 1 (Common 1 .. Mythic 5); if the character also owns the effect's paired keystone, the synergy
## effects join too. Item cards show line(item) + synergy_line(item) (see /workspace/skillz/CHARACTER_API.md).

const PATH := "res://data/class_items.json"

static var _data: Dictionary = {}
static var _by_id: Dictionary = {}


static func _load() -> void:
	if not _by_id.is_empty():
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	_data = d if d is Dictionary else {}
	for it in _data.get("items", []):
		_by_id[str(it.id)] = it


static func all_ids() -> Array:
	_load()
	return _by_id.keys()


static func def(effect_id: String) -> Dictionary:
	_load()
	return _by_id.get(effect_id, {})


static func for_class(class_id: String) -> Array:
	_load()
	var out: Array = []
	for id in _by_id:
		if str(_by_id[id].get("class", "")) == class_id:
			out.append(id)
	return out


static func rank_for(item) -> int:
	return clampi(int(item.rarity) + 1, 1, 5) if item else 1


## Roll-time: give `item` a random effect for `class_id` (the class being played) and name it after the effect,
## unless it already has a hand-authored (Mythic) name.
static func assign(item, class_id: String, keep_name := false) -> void:
	var ids := for_class(class_id)
	if ids.is_empty():
		ids = for_class("soldier")
	if ids.is_empty() or item == null:
		return
	ids.sort()
	item.class_effect = str(ids[randi() % ids.size()])
	item.class_id = str(def(item.class_effect).get("class", class_id))
	if not keep_name:
		item.display_name = str(def(item.class_effect).get("name", item.display_name))


## Load-time upgrade for pre-Batch C class items (no effect yet): a deterministic pick (hash of item_id) from the
## class being played when the stash loads, so the same old item always becomes the same effect.
static func legacy_assign(item, class_id: String) -> void:
	var ids := for_class(class_id)
	if ids.is_empty() or item == null:
		return
	ids.sort()
	var key: String = str(item.item_id) if str(item.item_id) != "" else str(item.display_name)
	item.class_effect = str(ids[absi(key.hash()) % ids.size()])
	item.class_id = class_id


## One-line description with this item's numbers ("" when it has no effect).
static func line(item) -> String:
	if item == null or str(item.get("class_effect")) == "":
		return ""
	return fill(def(item.class_effect), "line", rank_for(item))


## The synergy sentence, prefixed with the keystone's name: "With Glass Sight: every hit on ...".
static func synergy_line(item) -> String:
	if item == null or str(item.get("class_effect")) == "":
		return ""
	var syn: Dictionary = def(item.class_effect).get("synergy", {})
	if syn.is_empty():
		return ""
	return "With %s: %s" % [keystone_name(str(syn.get("keystone", ""))), fill(syn, "line", 1)]


static func synergy_keystone(item) -> String:
	if item == null or str(item.get("class_effect")) == "":
		return ""
	return str(def(item.class_effect).get("synergy", {}).get("keystone", ""))


static func keystone_name(id: String) -> String:
	var prog = _prog()
	if prog and prog.has_method("get_skill"):
		return str(prog.get_skill(id).get("name", id))
	return id


static func fill(d: Dictionary, field: String, r: int) -> String:
	var text := str(d.get(field, ""))
	var vals: Dictionary = d.get("values", {})
	for k in vals:
		var v = vals[k]
		if v is Array:
			v = v[clampi(r - 1, 0, v.size() - 1)] if not v.is_empty() else 0
		text = text.replace("{%s}" % k, _fmt(v))
	return text


static func _fmt(v) -> String:
	if typeof(v) == TYPE_FLOAT:
		if is_equal_approx(v, roundf(v)):
			return str(int(roundf(v)))
		return ("%.2f" % v).rstrip("0").rstrip(".")
	return str(v)


## Status for UI: "active" (class matches), "wrong_class", "none" (no effect).
static func state(item, class_id: String) -> String:
	if item == null or str(item.get("class_effect")) == "":
		return "none"
	return "active" if str(item.class_id) == class_id else "wrong_class"


## SkillRunner source list for an equipped class item: [{def, rank, source}] (main effect + synergy when the
## keystone is owned). Empty when there is no item, no effect, or the item belongs to another class.
static func active_defs(item, class_id := "", prog: Node = null) -> Array:
	if item == null or str(item.get("class_effect")) == "":
		return []
	if prog == null:
		prog = _prog()
	if class_id == "":
		class_id = str(prog.selected_class) if prog else "soldier"
	if str(item.class_id) != class_id:
		return []
	var d := def(item.class_effect)
	if d.is_empty():
		return []
	var out: Array = [{"def": d, "rank": rank_for(item), "source": "ci:" + str(item.class_effect)}]
	var syn: Dictionary = d.get("synergy", {})
	var ks := str(syn.get("keystone", ""))
	if ks != "" and prog and prog.has_method("rank") and prog.rank(ks) > 0 and prog.class_active(ks):
		out.append({"def": syn, "rank": 1, "source": "ci_syn:" + str(item.class_effect)})
	return out


static func _prog() -> Node:
	var ml := Engine.get_main_loop()
	return (ml as SceneTree).root.get_node_or_null("Progress") if ml is SceneTree else null
