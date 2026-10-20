class_name Inventory
extends Node
## Per-match inventory (child of the Player):
##   equipped[slot]  - one item per slot (3 weapon slots + 5 armor slots)
##   backpack[slot]  - up to `backpack_size` spare items per slot
##   bag             - stackable consumables (health packs ...)
## Everything is plain data: to_save_dict()/load_save_dict() back the persistent stash (Progress saves it at
## match end / scene exit / quit and restores it at the next match start; see /workspace/skillz/STASH_HANDOFF.md).
##
## Stash cap: at most `stash_cap` spare (non-equipped) gear pieces across all slots (default 40, data/loot_tables.json
## -> stash.cap), on top of the per-slot `backpack_size` grid limit. Equipped gear doesn't count. Scrap
## (dismantle) frees space. Consumables in `bag` are per-match supplies and are not persisted.
##
## Seen flags ('!' badge): GearItem.seen persists. New pickups land unseen; auto-equipped and equip()'d items are
## marked seen. UI calls mark_seen(item) when the player views an item.

signal changed
signal weapon_equipped(weapon: WeaponItem)
signal armor_changed
signal seen_changed(item: GearItem) ## an item's seen flag flipped, or an unseen item was added/removed (badge refresh)

const SAVE_VERSION := 1 ## to_save_dict() shape version (1 = equipped + backpack, items carry "seen")
const DEFAULT_STASH_CAP := 40

const WEAPON_SLOTS: Array[String] = ["primary", "secondary", "heavy"]
const ARMOR_SLOTS: Array[String] = ["helmet", "gauntlets", "chest", "legs", "class_item"]
const SLOT_LABELS := {"primary": "Primary", "secondary": "Secondary", "heavy": "Heavy", "helmet": "Helmet",
	"gauntlets": "Gauntlets", "chest": "Chest", "legs": "Legs", "class_item": "Class Item"}

@export var backpack_size: int = 9
@export var bag_size: int = 6
@export var stash_cap: int = DEFAULT_STASH_CAP ## max spare gear across all slots; left at 40, data/loot_tables.json stash.cap wins. -1 = no cap

var equipped: Dictionary = {} ## slot -> GearItem (or null)
var backpack: Dictionary = {} ## slot -> Array[GearItem]
var bag: Array = [] ## [{"item": ConsumableItem, "count": int}]
var active_weapon_slot: String = "primary"


func _ready() -> void:
	for s in WEAPON_SLOTS + ARMOR_SLOTS:
		equipped[s] = null
		backpack[s] = []
	var gdb := get_node_or_null("/root/GearDB")
	if gdb and stash_cap == DEFAULT_STASH_CAP:
		stash_cap = int(gdb.loot.get("stash", {}).get("cap", DEFAULT_STASH_CAP))


## Tells Progress this inventory is going away (match restart / map change) so the stash is saved.
func _exit_tree() -> void:
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("on_inventory_exit"):
		prog.on_inventory_exit(self)


## Match-start loadout (player.gd calls this from _ready). Persistent stash first: binds this inventory to
## Progress (so match end / restart / quit save it) and restores the saved gear; with no stash (first run, v2 save,
## tests) it falls back to the Common starter loadout. Idempotent with a caller that already restored.
func give_starter_loadout() -> void:
	var prog := get_node_or_null("/root/Progress")
	if prog and prog.has_method("restore_stash"):
		prog.bind_inventory(self)
		if carried_count() > 0 or equipped.values().any(func(v): return v != null):
			return # already restored by the caller
		if prog.restore_stash(self):
			return
	give_fresh_starter_loadout()


## Common primary + secondary weapons and a full common armor set (no stash lookup).
func give_fresh_starter_loadout() -> void:
	add_item(GearDB.roll_weapon("sidearm", Rarity.COMMON, 1))
	add_item(GearDB.roll_weapon("smg", Rarity.COMMON, 1))
	for s in ARMOR_SLOTS:
		add_item(GearDB.roll_armor(s, Rarity.COMMON, 1))
	equip_weapon_slot("primary")


## After a stash restore: any empty equip slot (except Heavy, which starts empty) gets a Common starter piece.
func fill_empty_slots() -> void:
	var fills := {"primary": "sidearm", "secondary": "smg"}
	for s in fills:
		if equipped.get(s) == null:
			add_item(GearDB.roll_weapon(fills[s], Rarity.COMMON, 1))
	for s in ARMOR_SLOTS:
		if equipped.get(s) == null:
			add_item(GearDB.roll_armor(s, Rarity.COMMON, 1))
	if get_equipped_weapon() == null:
		equip_weapon_slot("primary")


var last_reject: String = "" ## why the last add_item failed: "slot_full", "stash_full" or "bag_full"


## Adds an item. Gear auto-equips into an empty slot (and is marked seen), otherwise goes to the backpack
## unseen. Returns false if there is no room (see last_reject).
func add_item(item: Item) -> bool:
	last_reject = ""
	var gear := item as GearItem
	if gear:
		var s: String = gear.slot
		if equipped.get(s) == null:
			equipped[s] = gear
			_set_seen(gear, true)
			_after_equip(s)
			changed.emit()
			return true
		if backpack[s].size() >= backpack_size:
			last_reject = "slot_full"
			return false
		if stash_full():
			last_reject = "stash_full"
			return false
		backpack[s].append(gear)
		changed.emit()
		if not gear.seen:
			seen_changed.emit(gear)
		return true
	for entry in bag:
		if entry.item.id == item.id and entry.count < item.max_stack:
			entry.count += 1
			changed.emit()
			return true
	if bag.size() >= bag_size:
		last_reject = "bag_full"
		return false
	bag.append({"item": item, "count": 1})
	changed.emit()
	return true


## Swap a backpack item into its slot (the old one goes to the backpack).
func equip(item: GearItem) -> void:
	var s := item.slot
	var idx: int = backpack[s].find(item)
	if idx == -1:
		return
	backpack[s].remove_at(idx)
	var old: GearItem = equipped.get(s)
	if old:
		backpack[s].append(old)
	equipped[s] = item
	_set_seen(item, true)
	_after_equip(s)
	changed.emit()


## Can `gear` go straight into an equip slot? "" = yes, else a refusal reason for the prompt. Skillz's
## primary/secondary slot rule (GearDB.slot_for + its refusal) plugs in here.
func equip_refusal(gear: GearItem) -> String:
	if gear == null:
		return "Nothing to equip"
	var gdb := get_node_or_null("/root/GearDB")
	if gdb and gdb.has_method("slot_refusal"):
		return str(gdb.slot_refusal(gear, self))
	return ""


## Hold-E (playtest #3): take a ground item and equip it at once. The old piece goes to the backpack (seen);
## with no backpack / stash room it comes back as {displaced} for the caller to drop where the new one lay.
## Weapons are drawn. Returns {ok, displaced (GearItem|null), reason}.
func take_and_equip(gear: GearItem) -> Dictionary:
	var why := equip_refusal(gear)
	if why != "":
		return {"ok": false, "displaced": null, "reason": why}
	var s: String = gear.slot
	var old: GearItem = equipped.get(s)
	var displaced: GearItem = null
	if old:
		if backpack[s].size() < backpack_size and not stash_full():
			backpack[s].append(old)
			_set_seen(old, true)
		else:
			displaced = old
	equipped[s] = gear
	_set_seen(gear, true)
	if s in WEAPON_SLOTS:
		(gear as WeaponItem).init_ammo()
		equip_weapon_slot(s)
	else:
		armor_changed.emit()
	changed.emit()
	return {"ok": true, "displaced": displaced, "reason": ""}


## Remove an item from the backpack for good (scrap). Frees one stash space.
func dismantle(item: GearItem) -> void:
	if not backpack[item.slot].has(item):
		return
	backpack[item.slot].erase(item)
	changed.emit()
	if not item.seen:
		seen_changed.emit(item)


# ------------------------------------------------------------------ stash cap

## Pickup prompt text for the last refused add_item (player.receive_item can show it; see skillz/MAIN_HOOKS.md).
func reject_message() -> String:
	match last_reject:
		"stash_full":
			return "No room for that! (stash full: %d/%d, scrap something)" % [carried_count(), stash_cap]
		"bag_full":
			return "No room for that! (bag full)"
	return "No room for that! (backpack full)"


## Spare gear across all slots (equipped pieces don't count against the stash cap).
func carried_count() -> int:
	var n := 0
	for s in backpack:
		n += backpack[s].size()
	return n


func stash_full() -> bool:
	return stash_cap >= 0 and carried_count() >= stash_cap


func stash_space() -> int:
	return maxi(stash_cap - carried_count(), 0) if stash_cap >= 0 else 9999


# ------------------------------------------------------------------ seen flags ('!' badge API, agreed with Gooey)

func _slot_items(slot: String) -> Array:
	var out := []
	for s in (WEAPON_SLOTS + ARMOR_SLOTS if slot == "" else [slot]):
		if equipped.get(s):
			out.append(equipped[s])
		out.append_array(backpack.get(s, []))
	return out


func _set_seen(item: GearItem, v: bool) -> void:
	if item == null or item.seen == v:
		return
	item.seen = v
	seen_changed.emit(item)


## Marks one item seen (no-op if already seen). Emits seen_changed(item).
func mark_seen(item: GearItem) -> void:
	_set_seen(item, true)


## Marks every item in `slot` ("" = all slots) seen.
func mark_all_seen(slot: String = "") -> void:
	for it in _slot_items(slot):
		_set_seen(it, true)


## slot: "primary" / "secondary" / "heavy" / an armor slot id, or "" for everything.
func has_unseen(slot: String = "") -> bool:
	return unseen_count(slot) > 0


func unseen_count(slot: String = "") -> int:
	var n := 0
	for it in _slot_items(slot):
		if not (it as GearItem).seen:
			n += 1
	return n


func _after_equip(s: String) -> void:
	if s in WEAPON_SLOTS:
		var w: WeaponItem = equipped[s]
		w.init_ammo()
		if s == active_weapon_slot or get_equipped_weapon() == null:
			equip_weapon_slot(s)
	else:
		armor_changed.emit()


func equip_weapon_slot(s: String) -> void:
	if equipped.get(s) == null:
		return
	active_weapon_slot = s
	changed.emit()
	weapon_equipped.emit(equipped[s])


## Draw an equipped weapon by item (mouse wheel, playtest #7). False if `w` isn't equipped in a weapon slot.
func equip_weapon_item(w: WeaponItem) -> bool:
	for s in WEAPON_SLOTS:
		if w != null and equipped.get(s) == w:
			equip_weapon_slot(s)
			return true
	return false


## The equipped weapon `dir` steps from the active one (+1 next, -1 previous), wrapping and skipping empty
## slots; null with fewer than two weapons.
func cycle_weapon_item(dir: int) -> WeaponItem:
	var ws := weapons()
	if ws.size() < 2:
		return null
	var i := ws.find(get_equipped_weapon())
	return ws[posmod((i if i >= 0 else 0) + (1 if dir >= 0 else -1), ws.size())]


## Keys 1-3.
func equip_index(i: int) -> void:
	if i >= 0 and i < WEAPON_SLOTS.size():
		equip_weapon_slot(WEAPON_SLOTS[i])


func get_equipped_weapon() -> WeaponItem:
	return equipped.get(active_weapon_slot)


func weapons() -> Array:
	var out := []
	for s in WEAPON_SLOTS:
		if equipped.get(s):
			out.append(equipped[s])
	return out


## Sum of all equipped armor stats, each capped at 100.
func total_armor_stats() -> Dictionary:
	var t := {}
	for st in ArmorItem.STAT_ORDER:
		t[st] = 0
	for s in ARMOR_SLOTS:
		var a: ArmorItem = equipped.get(s)
		if a:
			for st in ArmorItem.STAT_ORDER:
				t[st] += int(a.stats.get(st, 0))
	for st in t:
		t[st] = min(t[st], 100)
	return t


## Item Power comparison vs the equipped item in the same slot: {delta, better, worse, text}.
func compare_power(item: GearItem) -> Dictionary:
	var cur: GearItem = equipped.get(item.slot)
	if cur == null or cur == item:
		return {}
	var d := item.item_power - cur.item_power
	return {"label": "Item Power", "delta": float(d), "better": d > 0, "worse": d < 0, "text": "%+d" % d if d != 0 else ""}


## Low-key average Item Power of equipped gear (empty slots ignored).
func average_item_power() -> int:
	var t := 0
	var n := 0
	for s in equipped:
		if equipped[s]:
			t += (equipped[s] as GearItem).item_power
			n += 1
	return int(round(float(t) / max(n, 1)))


## Stat-by-stat comparison of `item` against what's equipped in its slot.
## Returns [{label, delta, better (bool), text}] - empty if nothing to compare.
func compare(item: GearItem) -> Array:
	var cur: GearItem = equipped.get(item.slot)
	if cur == null or cur == item:
		return []
	var a: Array = item.call("card_stats")
	var b: Array = cur.call("card_stats")
	var out := []
	for i in min(a.size(), b.size()):
		var d: float = float(a[i][3]) - float(b[i][3])
		var higher_better: bool = a[i][4]
		var better := (d > 0.0) == higher_better
		var txt := ""
		if absf(d) >= 0.05:
			txt = ("%+.1f" % d) if absf(d) < 10.0 and absf(d - roundf(d)) > 0.05 else ("%+d" % roundi(d))
		out.append({"label": a[i][0], "delta": d, "better": better and absf(d) >= 0.05,
			"worse": (not better) and absf(d) >= 0.05, "text": txt})
	return out


func use_bag_item(index: int, player: Node) -> bool:
	if index < 0 or index >= bag.size():
		return false
	var entry: Dictionary = bag[index]
	if entry.item is ConsumableItem and entry.item.use(player):
		entry.count -= 1
		if entry.count <= 0:
			bag.remove_at(index)
		changed.emit()
		return true
	return false


# ------------------------------------------------------------------ vault-ready save/load

func to_save_dict() -> Dictionary:
	var d := {"version": SAVE_VERSION, "equipped": {}, "backpack": {}}
	for s in equipped:
		d.equipped[s] = equipped[s].to_dict() if equipped[s] else null
		d.backpack[s] = backpack[s].map(func(i): return i.to_dict())
	return d


func load_save_dict(d: Dictionary) -> void:
	for s in WEAPON_SLOTS + ARMOR_SLOTS:
		var e = d.get("equipped", {}).get(s)
		var eq := GearDB.item_from_dict(e) if typeof(e) == TYPE_DICTIONARY else null
		equipped[s] = eq if _loadable(eq, s) else null
		if equipped[s]:
			equipped[s].seen = true # equipped gear is always "looked at"
		backpack[s] = []
		for bd in d.get("backpack", {}).get(s, []):
			var it := GearDB.item_from_dict(bd) if typeof(bd) == TYPE_DICTIONARY else null
			if _loadable(it, s):
				backpack[s].append(it)
	armor_changed.emit()
	changed.emit()
	seen_changed.emit(null) # whole inventory replaced: badge UI should recount
	if equipped.get(active_weapon_slot) == null:
		for s in WEAPON_SLOTS:
			if equipped.get(s):
				active_weapon_slot = s
				break
	weapon_equipped.emit(get_equipped_weapon())


## Drops saved items that no longer fit the data (removed weapon archetype, wrong slot).
func _loadable(it: Item, s: String) -> bool:
	var g := it as GearItem
	if g == null or g.slot != s:
		return false
	if g is WeaponItem and (g as WeaponItem).arch.is_empty():
		return false
	return true
