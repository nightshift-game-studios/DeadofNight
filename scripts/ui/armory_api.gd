extends RefCounted
class_name ArmoryAPI
## Placeholder Armory adapter (Pass 5). Swap the body for Skillz's real API when
## /workspace/skillz/ARMORY_HANDOFF.md lands. UI talks only to this surface.

signal currency_changed(balance: int)
signal armory_changed(kind: String, id: String)

var currency_name: String = "Scrap Marks"
var currency_icon_key: String = "scrap_marks"
var _balance: int = 0
var _upgrades: Array = []
var _attachments: Dictionary = {} ## weapon_id -> Array
var _equipped: Dictionary = {} ## weapon_id -> {slot: attachment_id}


func _init() -> void:
	_seed_placeholder()


func _seed_placeholder() -> void:
	_balance = 120
	_upgrades = [
		{"id": "u_mag_extend", "name": "Extended Mag", "summary": "Larger magazines on all weapons.", "cost": 80,
			"current_level": 0, "max_level": 3, "category": "weapon", "requirements": []},
		{"id": "u_armor_plate", "name": "Plated Weave", "summary": "Slightly tougher armor rolls.", "cost": 100,
			"current_level": 0, "max_level": 2, "category": "armor", "requirements": []},
		{"id": "u_locked", "name": "Night Optics", "summary": "COMING SOON — not yet purchasable.", "cost": 999,
			"current_level": 0, "max_level": 1, "category": "weapon", "requirements": ["placeholder"]},
	]
	_attachments = {
		"sidearm": [
			{"id": "a_side_laser", "name": "Laser Dot", "summary": "Tighter hip fire.", "cost": 40,
				"owned": false, "slot": "optic", "requirements": []},
			{"id": "a_side_grip", "name": "Rubber Grip", "summary": "Less recoil.", "cost": 35,
				"owned": false, "slot": "grip", "requirements": []},
		],
		"smg": [
			{"id": "a_smg_stock", "name": "Folding Stock", "summary": "Stability up.", "cost": 55,
				"owned": false, "slot": "stock", "requirements": []},
		],
	}


func currency_balance() -> int:
	return _balance


func list_upgrades() -> Array:
	return _upgrades.duplicate(true)


func list_attachments(weapon_id: String) -> Array:
	return (_attachments.get(weapon_id, []) as Array).duplicate(true)


func can_afford(id: String) -> bool:
	var e := _find(id)
	if e.is_empty():
		return false
	if str(e.get("id", "")).begins_with("u_locked") or e.get("requirements", []).size() > 0:
		return false
	return _balance >= int(e.get("cost", 0))


func purchase(id: String) -> bool:
	if not can_afford(id):
		return false
	var e := _find(id)
	var cost := int(e.get("cost", 0))
	_balance -= cost
	if e.has("current_level"):
		e["current_level"] = mini(int(e.get("current_level", 0)) + 1, int(e.get("max_level", 1)))
		_patch_upgrade(e)
	elif e.has("owned"):
		e["owned"] = true
		_patch_attachment(e)
	currency_changed.emit(_balance)
	armory_changed.emit("purchase", id)
	return true


func equip_attachment(weapon_id: String, slot: String, id: String) -> bool:
	var list: Array = _attachments.get(weapon_id, [])
	var found := false
	for a in list:
		if str(a.get("id", "")) == id and bool(a.get("owned", false)):
			found = true
			break
	if not found:
		return false
	if not _equipped.has(weapon_id):
		_equipped[weapon_id] = {}
	_equipped[weapon_id][slot] = id
	armory_changed.emit("equip", id)
	return true


func _find(id: String) -> Dictionary:
	for u in _upgrades:
		if str(u.get("id", "")) == id:
			return u
	for wid in _attachments:
		for a in _attachments[wid]:
			if str(a.get("id", "")) == id:
				return a
	return {}


func _patch_upgrade(e: Dictionary) -> void:
	for i in _upgrades.size():
		if str(_upgrades[i].get("id", "")) == str(e.get("id", "")):
			_upgrades[i] = e
			return


func _patch_attachment(e: Dictionary) -> void:
	for wid in _attachments:
		var arr: Array = _attachments[wid]
		for i in arr.size():
			if str(arr[i].get("id", "")) == str(e.get("id", "")):
				arr[i] = e
				_attachments[wid] = arr
				return
