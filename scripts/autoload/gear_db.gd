extends Node
## Autoload "GearDB": loads the gear data files and rolls random weapons/armor and
## loot-table drops. All tuning lives in res://data/*.json.

const WEAPONS_PATH := "res://data/weapons.json"
const ARMOR_PATH := "res://data/armor.json"
const PERKS_PATH := "res://data/perks.json"
const LOOT_PATH := "res://data/loot_tables.json"
const GRENADES_PATH := "res://data/grenades.json"
const DIFFICULTY_SCRIPT := "res://scripts/world/difficulty.gd" ## loaded lazily: a preload const here breaks the WeaponItem <-> GearDB compile cycle
const SECONDARY_ELEMENTS: Array[String] = ["volt", "blaze", "blight"]
const ELEMENT_COLORS := {"ballistic": Color(0.85, 0.85, 0.85), "volt": Color(0.35, 0.75, 1.0),
	"blaze": Color(1.0, 0.45, 0.1), "blight": Color(0.55, 0.95, 0.2)}

var weapons: Dictionary = {} ## archetype id -> dict
var weapon_list: Array = []
var manufacturers: Array = [] ## fictional weapon makers (data/weapons.json)
var armor: Dictionary = {}
var perks: Dictionary = {} ## perk id -> dict
var attribute_cfg: Dictionary = {} ## perks.json attribute_counts (playtest #33)
var loot: Dictionary = {}
var grenades: Dictionary = {}
var grenade_items: Dictionary = {} ## grenades.json "items": grenade items (DESIGN §25, GrenadeItem)
var stat_variance: int = 12 ## +/- random roll applied to each weapon stat
var headshot_default: float = 2.0 ## weapons.json -> headshot_multiplier_default


func _ready() -> void:
	reload_data()


func reload_data() -> void:
	var w := _load_json(WEAPONS_PATH)
	weapon_list = w.get("archetypes", [])
	weapons.clear()
	for a in weapon_list:
		weapons[a.id] = a
	stat_variance = int(w.get("stat_variance", 12))
	headshot_default = float(w.get("headshot_multiplier_default", 2.0))
	manufacturers = w.get("manufacturers", [])
	armor = _load_json(ARMOR_PATH)
	perks.clear()
	var pj := _load_json(PERKS_PATH)
	for p in pj.get("perks", []):
		perks[p.id] = p
	attribute_cfg = pj.get("attribute_counts", {})
	loot = _load_json(LOOT_PATH)
	var gj := _load_json(GRENADES_PATH)
	grenades = gj.get("grenades", {})
	grenade_items = gj.get("items", {})


func _load_json(path: String) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("GearDB: could not parse " + path)
		return {}
	return parsed


func perk(id: String) -> Dictionary:
	return perks.get(id, {})


func grenade(id: String) -> Dictionary:
	if id.begins_with("@") and item_grenades.has(id): # §25: an equipped GrenadeItem's throw_data (GrenadeItem.apply_to_player)
		return item_grenades[id]
	return grenades.get(id, grenades.get("frag", {}))


## §25 bridge: "@<item_id>" -> that GrenadeItem's throw_data(), so player.gd's §24c meta path (apply_stats ->
## GearDB.grenade(meta grenade_override)) keeps the equipped item with its Fittings. Set by GrenadeItem.apply_to_player.
var item_grenades: Dictionary = {}


func set_item_grenade(key: String, d: Dictionary) -> void:
	item_grenades[key] = d


## MAIN_HOOKS §24c: drop odds per grenades.json id = drop_weight x loot_tables grenade_drops.rarity_mult[its rarity]
## (Economy v2's rarer-drops scaling). {id: weight}, ids with weight 0 left out.
func grenade_drop_weights() -> Dictionary:
	var mult: Dictionary = loot.get("grenade_drops", {}).get("rarity_mult", {})
	var out := {}
	for id in grenades:
		var g: Dictionary = grenades[id]
		var w := float(g.get("drop_weight", 0)) * float(mult.get(str(g.get("rarity", "common")), 1.0))
		if w > 0.0:
			out[id] = w
	return out


## A grenades.json id picked by grenade_drop_weights(). rng: RandomNumberGenerator (null = global randf).
func roll_grenade_id(rng: RandomNumberGenerator = null) -> String:
	var ws := grenade_drop_weights()
	var total := 0.0
	for id in ws:
		total += float(ws[id])
	if total <= 0.0:
		return "frag"
	var r := (rng.randf() if rng else randf()) * total
	for id in ws:
		r -= float(ws[id])
		if r <= 0.0:
			return str(id)
	return str(ws.keys()[-1])


## The world pickup for grenade `id`: a ConsumableItem (effect GRENADE, id "grenade_<id>", so Item.to_dict / from_dict
## and co-op grants round-trip through consumable()). Its colour is the grenade's rarity colour, its model the variant's.
func grenade_pickup(id: String) -> ConsumableItem:
	if not grenades.has(id):
		return null
	var g: Dictionary = grenades[id]
	var c := ConsumableItem.new()
	c.id = ConsumableItem.GRENADE_PREFIX + id
	c.effect = ConsumableItem.Effect.GRENADE
	c.grenade_id = id
	c.display_name = str(g.get("name", id.capitalize()))
	var r := Rarity.from_id(str(g.get("rarity", "common")))
	c.color = Rarity.color(r)
	c.description = "%s grenade. Pick up to replace your grenade for this match." % Rarity.IDS[r].capitalize()
	var model := "res://assets/models/grenades/%s.glb" % str(g.get("model", g.get("variant", id)))
	if ResourceLoader.exists(model):
		c.model_path = model
		c.model_scale = 1.6
	return c


# ------------------------------------------------------------------ grenade items (playtest 2026-10-22 #5, DESIGN §25)

## grenades.json ids of one rarity (sorted, so seeded picks are stable).
func grenade_ids_of_rarity(r: int) -> Array:
	var out: Array = grenades.keys().filter(func(k): return Rarity.from_id(str(grenades[k].get("rarity", "common"))) == r)
	out.sort()
	return out


## Fitting ids that can roll on grenade `id` (needs / types rules; sorted).
func grenade_fitting_pool(id: String) -> Array:
	var b: Dictionary = grenades.get(id, {})
	var out := []
	var defs: Dictionary = grenade_items.get("fittings", {})
	for fid in defs:
		var f: Dictionary = defs[fid]
		if f.has("needs") and float(b.get(str(f.needs), 0.0)) <= 0.0:
			continue
		if f.has("types") and not (id in (f.types as Array)):
			continue
		out.append(str(fid))
	out.sort()
	return out


## Rolls a GrenadeItem. id "" = a drop pick (roll_grenade_id: drop_weight x rarity_mult). Rarity = the type's.
## item_power -1 = roll_item_power(rarity, round). fittings_n -1 = items.fittings_per_rarity. rng null = global RNG.
func roll_grenade(id: String = "", round_number: int = 1, item_power: int = -1, rng: RandomNumberGenerator = null, fittings_n: int = -1) -> GrenadeItem:
	if id == "" or not grenades.has(id):
		id = roll_grenade_id(rng) if id == "" else "frag"
	var b: Dictionary = grenades.get(id, {})
	var g := GrenadeItem.new()
	g.grenade_id = id
	g.archetype = id
	g.rarity = Rarity.from_id(str(b.get("rarity", "common")))
	g.color = Rarity.color(g.rarity)
	g.item_power = item_power if item_power > 0 else roll_item_power(g.rarity, round_number)
	g.display_name = str(b.get("name", id.capitalize()))
	g.id = "gi_%s_%d" % [id, g.uid]
	var makers: Array = grenade_items.get("makers", [])
	var mk: Dictionary = makers[(rng.randi() if rng else randi()) % makers.size()] if makers.size() else {}
	g.manufacturer = str(mk.get("name", "Scavenged"))
	g.manufacturer_color = Color.from_string(str(mk.get("color", "#CCCCCC")), Color(0.8, 0.8, 0.8))
	var fl: Array = mk.get("flavor", [""])
	g.flavor = str(fl[(rng.randi() if rng else randi()) % fl.size()]) if fl.size() else ""
	var n := fittings_n if fittings_n >= 0 else int(grenade_items.get("fittings_per_rarity", {}).get(Rarity.IDS[g.rarity], 1))
	var pool := grenade_fitting_pool(id)
	var defs: Dictionary = grenade_items.get("fittings", {})
	var q := 0.0
	var picked := 0
	while picked < n and not pool.is_empty():
		var fid: String = pool.pop_at((rng.randi() if rng else randi()) % pool.size())
		var rg: Array = defs[fid].get("range", [1.0, 1.0])
		var lo := float(rg[0])
		var hi := float(rg[-1])
		var t := rng.randf() if rng else randf()
		var v := snappedf(lerpf(lo, hi, t), 0.01)
		g.fittings[fid] = v
		var better_low := str(defs[fid].get("stat", "")) in ["cooldown_mult", "fuse_mult"]
		q += _range_pos(v, lo, hi) if not better_low else 1.0 - _range_pos(v, lo, hi)
		picked += 1
	g.roll_quality = q / picked if picked > 0 else 0.5
	g.description = g.effect_line()
	g.seen = false
	return g


## How good a GrenadeItem's Fittings rolled (0 worst .. 1 best; 0.5 with none). Lower is better for cooldown / fuse.
func grenade_roll_quality(g: GrenadeItem) -> float:
	var defs: Dictionary = grenade_items.get("fittings", {})
	var q := 0.0
	var n := 0
	for fid in g.fittings:
		if not defs.has(fid):
			continue
		var rg: Array = defs[fid].get("range", [1.0, 1.0])
		var p := _range_pos(float(g.fittings[fid]), float(rg[0]), float(rg[-1]))
		q += 1.0 - p if str(defs[fid].get("stat", "")) in ["cooldown_mult", "fuse_mult"] else p
		n += 1
	return q / n if n > 0 else 0.5


## The class grenade as a starter item (fresh / migrated stash): Common-type grenade, IP 100, starter_fittings.
func starter_grenade(class_grenade_id: String = "frag") -> GrenadeItem:
	var id := class_grenade_id if grenades.has(class_grenade_id) else "frag"
	return roll_grenade(id, 1, 100, null, int(grenade_items.get("starter_fittings", 0)))


func element_color(e: String) -> Color:
	return ELEMENT_COLORS.get(e, Color.WHITE)


# ------------------------------------------------------------------ rolling

## Item Power settings (data/loot_tables.json -> item_power).
func item_power_cfg() -> Dictionary:
	return loot.get("item_power", {})


## Roll an Item Power for a drop: base + per_round * (round - 1) + rarity bonus +/- variance.
func roll_item_power(rarity: int, round_number: int = 1) -> int:
	var c := item_power_cfg()
	var bonus := float(c.get("rarity_bonus", {}).get(Rarity.IDS[rarity], 0))
	var v := int(c.get("variance", 3))
	var ip: int = int(c.get("base", 100)) + int(c.get("per_round", 5)) * max(round_number - 1, 0) + int(bonus) + randi_range(-v, v)
	return clampi(ip, 1, int(c.get("max", 400)))


## Extra stat points an item gets from its Item Power (can be negative below 100).
func power_stat_bonus(ip: int, key: String = "stat_points_per_point") -> int:
	return int(round((ip - 100) * float(item_power_cfg().get(key, 0.1))))


## Item Power stat bonus for one weapon stat: 0 for stats listed in item_power.ip_stat_exclude
## (Impact by default, so the IP damage multiplier is the only IP damage dial).
func weapon_stat_power_bonus(ip: int, stat: String) -> int:
	if stat in item_power_cfg().get("ip_stat_exclude", []):
		return 0
	return power_stat_bonus(ip)


## Roll-quality settings (data/loot_tables.json -> roll_quality).
func roll_quality_cfg() -> Dictionary:
	return loot.get("roll_quality", {})


static func _range_pos(v: float, lo: float, hi: float) -> float:
	return 0.5 if hi <= lo else clampf((v - lo) / (hi - lo), 0.0, 1.0)


## Weighted average, over the weapon's stats, of where each stat's random offset landed in
## [-stat_variance, +stat_variance]. Uses the stored (clamped) stats, so it works both right
## after a roll and when deriving it for an old save. `mods` = manufacturer stat_mods.
func weapon_roll_quality(w: WeaponItem, a: Dictionary, mods: Dictionary) -> float:
	var weights: Dictionary = roll_quality_cfg().get("weapon_stat_weights", {})
	var v := float(stat_variance)
	var sum := 0.0
	var wsum := 0.0
	for s in a.get("stats", {}):
		var wt := float(weights.get(s, 1.0))
		if wt <= 0.0 or not w.stats.has(s):
			continue
		var fixed := float(a.stats[s]) + Rarity.STAT_BONUS[w.rarity] + float(mods.get(s, 0)) + weapon_stat_power_bonus(w.item_power, s)
		var off := clampf(float(w.stats[s]) - fixed, -v, v)
		sum += wt * _range_pos(off, -v, v)
		wsum += wt
	return snappedf(sum / wsum, 0.001) if wsum > 0.0 else float(roll_quality_cfg().get("legacy_default", 0.5))


## Fill in roll_quality for an item loaded without one (pre-roll-quality saves).
func derive_roll_quality(item: GearItem) -> float:
	var cfg := roll_quality_cfg()
	var fallback := float(cfg.get("legacy_default", 0.5))
	if not bool(cfg.get("derive_missing", true)):
		return fallback
	if item is WeaponItem:
		var a: Dictionary = weapons.get(item.archetype, {})
		if a.is_empty():
			return fallback
		var mods: Dictionary = {}
		for m in manufacturers:
			if m.get("name", "") == item.manufacturer:
				mods = m.get("stat_mods", {})
		return weapon_roll_quality(item, a, mods)
	if item is ArmorItem:
		var range_arr: Array = armor.get("piece_totals", {}).get(Rarity.IDS[clampi(item.rarity, 0, 4)], [])
		if range_arr.size() < 2:
			return fallback
		var t := float(item.stat_total()) - power_stat_bonus(item.item_power, "armor_points_per_point")
		if item.rarity == Rarity.MYTHIC and armor.get("mythics", {}).has(item.slot):
			for s in armor.mythics[item.slot].get("bonus", {}):
				t -= float(armor.mythics[item.slot].bonus[s])
		return snappedf(_range_pos(t, float(range_arr[0]), float(range_arr[1])), 0.001)
	return fallback


static func _col(a) -> Color:
	return Color(a[0], a[1], a[2]) if a is Array and a.size() >= 3 else Color(0.8, 0.8, 0.8)


# ------------------------------------------------------------------ weapon slot rule (data/weapons.json -> slot_rules)

static var _slot_rules: Dictionary = {}


static func slot_rules() -> Dictionary:
	if _slot_rules.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(WEAPONS_PATH))
		_slot_rules = d.get("slot_rules", {}) if typeof(d) == TYPE_DICTIONARY else {}
		if _slot_rules.is_empty():
			_slot_rules = {"slots": {}}
	return _slot_rules


## The one equip slot an archetype belongs in ("" = unknown archetype / no rule).
static func slot_for(archetype: String) -> String:
	var sl: Dictionary = slot_rules().get("slots", {})
	for s in sl:
		if archetype in sl[s]:
			return str(s)
	return ""


## "" when `item` may sit in equip slot `slot`, else the refusal text for the prompt ("Secondary takes handguns only").
## Armor / consumables: only their own slot. A weapon: the slot_rules map (no rule for its archetype -> its own slot).
static func slot_refusal(item, slot: String) -> String:
	var g := _as_gear(item)
	if g == null:
		return "Nothing to equip"
	if not (g is WeaponItem):
		return "" if slot == g.slot else "Wrong slot"
	var want := slot_for(str((g as WeaponItem).archetype))
	if want == "":
		want = g.slot
	if slot == want:
		return ""
	var labels: Dictionary = slot_rules().get("labels", {})
	return "%s takes %s only" % [slot.capitalize(), str(labels.get(slot, "other weapons"))]


## G4M3N's loot markers (name locked, STATS_API.md "Loot markers"): true when `item` beats what `player` has equipped in
## that item's slot. item = GearItem or a Pickup (anything with .item); player = the Player (anything with .inventory)
## or an Inventory. An empty slot counts as an upgrade. Compares effective Item Power (weapons include their Armory
## tier bonus): at least upgrade_margin() (data, 5) more IP, or at least equal IP at a higher rarity. Consumables, nulls and the very item that is equipped -> false.
static func is_upgrade(item, player) -> bool:
	var g := _as_gear(item)
	if g == null or g.slot == "":
		return false
	var inv = player.get("inventory") if player != null and "inventory" in player else player
	if inv == null or not ("equipped" in inv):
		return false
	var cur = inv.equipped.get(g.slot)
	if cur == null:
		return true
	if cur == g or not (cur is GearItem):
		return false
	var a := _power_of(g)
	var b := _power_of(cur)
	return a >= b + upgrade_margin() or (a >= b and g.rarity > (cur as GearItem).rarity)


static var _upgrade_margin: int = -1


## data/loot_tables.json -> item_power.upgrade_margin (Item Power a piece must gain to count as an upgrade).
static func upgrade_margin() -> int:
	if _upgrade_margin < 0:
		var d = JSON.parse_string(FileAccess.get_file_as_string(LOOT_PATH))
		_upgrade_margin = maxi(int(d.get("item_power", {}).get("upgrade_margin", 1)), 1) if typeof(d) == TYPE_DICTIONARY else 1
	return _upgrade_margin


static func _as_gear(item) -> GearItem:
	if item is GearItem:
		return item
	if item is Object and item != null and "item" in item and item.get("item") is GearItem:
		return item.get("item")
	return null


static func _power_of(g: GearItem) -> int:
	return int(g.call("effective_item_power")) if g.has_method("effective_item_power") else g.item_power


func roll_rarity(weights: Dictionary, round_bonus: Dictionary = {}, round_number: int = 1) -> int:
	var total := 0.0
	var ws := []
	for i in Rarity.IDS.size():
		var id: String = Rarity.IDS[i]
		var w: float = float(weights.get(id, 0.0)) + float(round_bonus.get(id, 0.0)) * max(round_number - 1, 0)
		ws.append(w)
	# difficulty reward scaling (data/difficulty.json -> rewards.loot_rarity_bias; 0 on Easy / before main applies one)
	ws = load(DIFFICULTY_SCRIPT).bias_rarity_weights(ws, load(DIFFICULTY_SCRIPT).loot_rarity_bias())
	for w in ws:
		total += w
	var r := randf() * total
	for i in ws.size():
		r -= ws[i]
		if r <= 0.0:
			return i
	return Rarity.COMMON


func roll_weapon(arch_id: String = "", rarity: int = -1, round_number: int = 1, slot: String = "", item_power: int = -1) -> WeaponItem:
	var pool := weapon_list.filter(func(a): return slot == "" or a.slot == slot)
	var a: Dictionary = weapons.get(arch_id, {}) if arch_id != "" else pool.pick_random()
	if a.is_empty():
		a = weapon_list[0]
	if rarity < 0:
		rarity = Rarity.COMMON
	var w := WeaponItem.new()
	w.arch = a
	w.archetype = a.id
	w.slot = a.slot
	w.rarity = rarity
	w.item_power = item_power if item_power > 0 else roll_item_power(rarity, round_number)
	w.color = Rarity.color(rarity)
	w.id = "%s_%d" % [a.id, w.uid]
	var variance := stat_variance
	var fam: String = str(a.get("family", a.slot)) # slot before the primary/secondary rule: makers + elements unchanged
	var makers := manufacturers.filter(func(m): return fam in m.get("slots", []))
	var maker: Dictionary = makers.pick_random() if makers.size() else {}
	var mods: Dictionary = maker.get("stat_mods", {})
	for s in a.stats:
		w.stats[s] = clampi(int(a.stats[s]) + randi_range(-variance, variance) + Rarity.STAT_BONUS[rarity]
			+ int(mods.get(s, 0)) + weapon_stat_power_bonus(w.item_power, s), 1, 100)
	w.roll_quality = weapon_roll_quality(w, a, mods)
	w.manufacturer = maker.get("name", "Unbranded")
	w.manufacturer_color = _col(maker.get("color"))
	var lines: Array = maker.get("flavor", [""])
	w.flavor = lines.pick_random() if lines.size() else ""
	w.element = "ballistic" if fam == "primary" else SECONDARY_ELEMENTS.pick_random()
	# Name + perks
	if rarity == Rarity.MYTHIC and a.has("mythic"):
		w.display_name = a.mythic.name
		w.perks.append(a.mythic.perk)
		w.flavor = a.mythic.get("flavor", w.flavor)
	elif rarity >= Rarity.RARE:
		w.display_name = a.names.pick_random()
	else:
		w.display_name = "%s %s" % [Rarity.name_of(rarity), a.type]
	# Named attributes (playtest #33, WEAPON_ATTRS.md): seeded from attr_seed so the same seed + rarity + archetype
	# always gives the same attributes (the host rolls, co-op peers get the dict).
	w.attr_seed = randi()
	roll_attributes(w)
	w.description = a.type
	w.init_ammo()
	return w


## Named attributes a weapon of `rarity` rolls (perks.json attribute_counts, else Rarity.PERK_SLOTS). A Mythic carries its
## archetype signature (weapons.json mythic.perk) on top of these.
func attribute_count(rarity: int) -> int:
	var r := clampi(rarity, 0, Rarity.IDS.size() - 1)
	return int(attribute_cfg.get(Rarity.IDS[r], Rarity.PERK_SLOTS[r]))


func attribute_playstyle_min(rarity: int) -> int:
	return int(attribute_cfg.get("playstyle_min", {}).get(Rarity.IDS[clampi(rarity, 0, Rarity.IDS.size() - 1)], 0))


## Random-roll attribute pool: every perk except Mythic signatures, sorted (deterministic for a seed).
func attribute_pool() -> Array:
	var ids: Array = perks.keys().filter(func(k): return not bool(perks[k].get("signature", false)))
	ids.sort()
	return ids


## Fills w.perks from w.attr_seed: keeps what is already there (a Mythic's signature at index 0), then rolls up to
## attribute_count(rarity) more from attribute_pool(), at least attribute_playstyle_min(rarity) of them playstyle.
## Same seed + rarity + starting perks -> same result on every machine.
func roll_attributes(w: GearItem) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(w.get("attr_seed")) if "attr_seed" in w else 0
	var want := attribute_count(w.rarity)
	var need_ps := mini(attribute_playstyle_min(w.rarity), want)
	var start := w.perks.size()
	var pool := attribute_pool().filter(func(k): return not (k in w.perks))
	var ps_pool := pool.filter(func(k): return bool(perks[k].get("playstyle", false)))
	for i in need_ps:
		if ps_pool.is_empty():
			break
		var pick: String = ps_pool.pop_at(rng.randi_range(0, ps_pool.size() - 1))
		pool.erase(pick)
		w.perks.append(pick)
	while w.perks.size() - start < want and not pool.is_empty():
		w.perks.append(pool.pop_at(rng.randi_range(0, pool.size() - 1)))


## UI rows for a gear item's attributes (GearItem.attributes() / to_dict "attributes"): [{id, name, description, tag,
## playstyle, signature, glyph, icon_color "#rrggbb"}]. signature = a Mythic's own perk or a Merchant signature.
func attribute_rows(g: GearItem) -> Array:
	var out := []
	var arch_sig := ""
	if g.rarity == Rarity.MYTHIC and weapons.has(g.archetype):
		arch_sig = str(weapons[g.archetype].get("mythic", {}).get("perk", ""))
	for i in g.perks.size():
		var id: String = g.perks[i]
		var p: Dictionary = perks.get(id, {})
		if p.is_empty():
			continue
		var c = p.get("icon_color", [0.8, 0.8, 0.8])
		out.append({"id": id, "name": str(p.get("name", id)), "description": str(p.get("description", "")),
			"tag": str(p.get("tag", "")), "playstyle": bool(p.get("playstyle", false)),
			"signature": bool(p.get("signature", false)) or (i == 0 and id == arch_sig),
			"glyph": str(p.get("glyph", "")), "icon_color": "#" + Color(float(c[0]), float(c[1]), float(c[2])).to_html(false)})
	return out


func roll_armor(slot: String = "", rarity: int = -1, round_number: int = 1, item_power: int = -1) -> ArmorItem:
	var slots: Array = armor.get("slots", ["helmet"])
	if slot == "":
		slot = slots.pick_random()
	if rarity < 0:
		rarity = Rarity.COMMON
	var a := ArmorItem.new()
	a.slot = slot
	a.archetype = slot
	a.rarity = rarity
	a.item_power = item_power if item_power > 0 else roll_item_power(rarity, round_number)
	var brands: Array = armor.get("brands", [])
	var brand: Dictionary = brands.pick_random() if brands.size() else {}
	a.manufacturer = brand.get("name", "Scavenged")
	a.manufacturer_color = _col(brand.get("color"))
	var bl: Array = brand.get("flavor", [""])
	a.flavor = bl.pick_random() if bl.size() else ""
	a.color = Rarity.color(rarity)
	a.slot_label = armor.get("slot_names", {}).get(slot, slot.capitalize())
	a.id = "%s_%d" % [slot, a.uid]
	# Distribute a random total over the six stats.
	var range_arr: Array = armor.get("piece_totals", {}).get(Rarity.IDS[rarity], [10, 20])
	var base_total: int = randi_range(int(range_arr[0]), int(range_arr[1]))
	a.roll_quality = _range_pos(base_total, int(range_arr[0]), int(range_arr[1]))
	var total: int = base_total + power_stat_bonus(a.item_power, "armor_points_per_point")
	total = max(total, 1)
	for s in ArmorItem.STAT_ORDER:
		a.stats[s] = 0
	for i in total:
		var s: String = ArmorItem.STAT_ORDER.pick_random()
		a.stats[s] += 1
	if rarity == Rarity.MYTHIC and armor.get("mythics", {}).has(slot):
		var ex: Dictionary = armor.mythics[slot]
		a.display_name = ex.name
		a.flavor = ex.get("flavor", a.flavor)
		for s in ex.get("bonus", {}):
			a.stats[s] = int(a.stats.get(s, 0)) + int(ex.bonus[s])
	else:
		a.display_name = armor.get("names", {}).get(slot, ["Armor"]).pick_random()
	a.description = a.slot_label
	if slot == "class_item": # DESIGN §23.3: every class item is a class effect for the class being played
		var prog := get_node_or_null("/root/Progress")
		ClassItems.assign(a, str(prog.selected_class) if prog else "soldier", rarity == Rarity.MYTHIC and armor.get("mythics", {}).has(slot))
	return a


func roll_gear(rarity: int, round_number: int = 1) -> GearItem:
	if randf() < 0.5:
		return roll_weapon("", rarity, round_number)
	return roll_armor("", rarity, round_number)


func consumable(id: String) -> ConsumableItem:
	if id.begins_with(ConsumableItem.GRENADE_PREFIX):
		return grenade_pickup(id.trim_prefix(ConsumableItem.GRENADE_PREFIX))
	var path := "res://resources/items/%s.tres" % id
	if ResourceLoader.exists(path):
		return load(path) as ConsumableItem
	push_warning("GearDB: no consumable " + path)
	return null


## Roll a loot table. Returns an Array of Items (may be empty).
## `drop_bonus` is added to the table's drop_chance (Gleaner).
func roll_table(table_id: String, round_number: int = 1, drop_bonus: float = 0.0) -> Array:
	var t: Dictionary = loot.get("tables", {}).get(table_id, {})
	var out := []
	if t.is_empty() or randf() > float(t.get("drop_chance", 1.0)) + drop_bonus:
		return out
	for i in int(t.get("rolls", 1)):
		var e := _pick_entry(t.get("entries", []))
		if e.is_empty():
			continue
		var rarity := roll_rarity(t.get("rarity_weights", {}), t.get("rarity_round_bonus", {}), round_number)
		match e.get("kind", "gear"):
			"gear":
				out.append(roll_gear(rarity, round_number))
			"weapon":
				out.append(roll_weapon(e.get("archetype", ""), rarity, round_number, e.get("slot", "")))
			"armor":
				out.append(roll_armor(e.get("slot", ""), rarity, round_number))
			"consumable":
				var c := consumable(e.get("id", ""))
				if c:
					out.append(c)
			"grenade": # §25: a GrenadeItem (equippable gear); id by grenades.json drop_weight x rarity_mult (not the table's rarity roll)
				out.append(roll_grenade("", round_number))
	return out


func _pick_entry(entries: Array) -> Dictionary:
	var total := 0.0
	for e in entries:
		total += float(e.get("weight", 1))
	var r := randf() * total
	for e in entries:
		r -= float(e.get("weight", 1))
		if r <= 0.0:
			return e
	return {} if entries.is_empty() else entries[-1]


## Rebuild an item from Item.to_dict() (used by Inventory save/load - vault-ready).
func item_from_dict(d: Dictionary) -> Item:
	match d.get("class", d.get("kind", "")):
		"weapon":
			var w := WeaponItem.new()
			w.apply_dict(d)
			w.arch = weapons.get(w.archetype, {})
			var right := slot_for(w.archetype)
			if right != "" and w.slot != right: # saves from before the slot rule (Inventory.load_save_dict re-homes it)
				w.set_meta("slot_migrated_from", w.slot)
				w.slot = right
			w.element = d.get("element", "ballistic")
			if w.roll_quality < 0.0:
				w.roll_quality = derive_roll_quality(w)
			w.init_ammo()
			return w
		"armor":
			var a := ArmorItem.new()
			a.apply_dict(d)
			a.slot_label = armor.get("slot_names", {}).get(a.slot, a.slot)
			a.description = a.slot_label
			if a.roll_quality < 0.0:
				a.roll_quality = derive_roll_quality(a)
			return a
		"grenade": # §25 GrenadeItem
			var g := GrenadeItem.new()
			g.apply_dict(d)
			if not grenades.has(g.grenade_id):
				return null # removed grenade type
			g.description = g.effect_line()
			if g.roll_quality < 0.0:
				g.roll_quality = grenade_roll_quality(g)
			return g
		"consumable":
			return consumable(d.get("id", ""))
	return null
