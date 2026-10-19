class_name Armory
extends RefCounted
## Armory (Skillz): Gravemark currency drops, weapon attachments and weapon upgrade tiers.
## Data: res://data/attachments.json (slots, class compatibility, parts) + res://data/armory.json (currency, drops, tiers).
## State lives in the Progress autoload (save v4): Progress.gravemarks, Progress.armory {upgrades, owned, equipped}.
## Works outside a match (home menu) because it only needs Progress.
##
## Two surfaces:
##  - Instance (Gooey's Armory tab): var api := Armory.new(); signals currency_changed(balance) / armory_changed(kind, id),
##    currency_balance(), list_weapons(), list_upgrades(weapon_id), list_attachments(weapon_id, slot), can_afford(id),
##    cost(id), purchase(id), equip_attachment(weapon_id, slot, id), unequip(weapon_id, slot). See ARMORY_HANDOFF.md.
##  - Static (gameplay): weapon_mods(arch) / ads_mods(arch) / flags(arch) / power_bonus(arch) read by WeaponItem, AdsProfile
##    and SkillRunner; drop helpers on_zombie_died / on_round_cleared / on_chest_opened / award pay Gravemarks
##    (x Difficulty.rare_currency_drop_mult, capped per match).
## weapon_id everywhere = a weapon archetype id (data/weapons.json, e.g. "auto_rifle") or a gear item_id (resolved to its
## archetype). Loadouts and upgrade tiers are per archetype: every Auto Rifle you carry uses the Auto Rifle loadout.

signal currency_changed(balance: int)
signal armory_changed(kind: String, id: String)

const ATTACHMENTS_PATH := "res://data/attachments.json"
const ARMORY_PATH := "res://data/armory.json"
const WEAPONS_PATH := "res://data/weapons.json"
const DIFFICULTY_SCRIPT := "res://scripts/world/difficulty.gd"
const BOSS_SCRIPT := "res://scripts/enemies/boss_catalog.gd"
const UPGRADE_PREFIX := "upg_"
const MULT_KEYS := ["damage_mult", "rpm_mult", "mag_mult", "reload_mult", "spread_mult", "hip_spread_mult",
	"recoil_mult", "range_mult", "swap_mult"]
const ADD_KEYS := ["pellets_add", "headshot_add", "reserve_mags_add"]

static var _att: Dictionary = {}
static var _cfg: Dictionary = {}
static var _weapons: Array = [] ## [{id, type, slot}] in data order
static var _by_id: Dictionary = {}
static var _cache_rev: int = -1
static var _cache: Dictionary = {} ## arch -> {"mods":{}, "ads":{}, "flags":{}}
## per-match drop limits (reset by reset_match_state / a new match)
static var _last_round: int = 0
static var _chest_round: int = -1
static var _chest_round_n: int = 0
static var _chest_match_n: int = 0
static var _boss_round: int = -1
static var _boss_round_n: int = 0

var currency_name: String = "Gravemark"
var currency_plural: String = "Gravemarks"
var currency_icon_key: String = "gravemark"


func _init() -> void:
	var c: Dictionary = cfg().get("currency", {})
	currency_name = str(c.get("name", currency_name))
	currency_plural = str(c.get("plural", currency_plural))
	currency_icon_key = str(c.get("icon", currency_icon_key))
	var p = prog()
	if p:
		p.currency_changed.connect(_on_currency)
		p.armory_changed.connect(_on_armory)


func _on_currency(b: int) -> void:
	currency_changed.emit(b)


func _on_armory(kind: String, id: String) -> void:
	armory_changed.emit(kind, id)


# ================================================================== data

static func _load(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text()) if f else null
	return d if d is Dictionary else {}


## Test helper: drop cached data (or inject your own attachments / armory dicts).
static func reload(att: Dictionary = {}, armory_cfg: Dictionary = {}) -> void:
	_att = att
	_cfg = armory_cfg
	_by_id.clear()
	_weapons.clear()
	_cache_rev = -1


static func data() -> Dictionary:
	if _att.is_empty():
		_att = _load(ATTACHMENTS_PATH)
	if _by_id.is_empty():
		for a in _att.get("attachments", []):
			_by_id[str(a.id)] = a
	return _att


static func cfg() -> Dictionary:
	if _cfg.is_empty():
		_cfg = _load(ARMORY_PATH)
	return _cfg


static func prog() -> Node:
	var ml = Engine.get_main_loop()
	return ml.root.get_node_or_null("Progress") if ml is SceneTree else null


static func weapons() -> Array:
	if _weapons.is_empty():
		for a in _load(WEAPONS_PATH).get("archetypes", []):
			_weapons.append({"id": str(a.id), "type": str(a.get("type", a.id)), "slot": str(a.get("slot", ""))})
	return _weapons


static func is_archetype(arch: String) -> bool:
	return weapons().any(func(w): return w.id == arch)


static func weapon_type(arch: String) -> String:
	for w in weapons():
		if w.id == arch:
			return w.type
	return arch.capitalize()


## Archetype id, or a gear item_id found in the live Inventory / saved stash -> its archetype. "" if unknown.
static func resolve_weapon(weapon_id: String) -> String:
	if is_archetype(weapon_id):
		return weapon_id
	var p = prog()
	if p == null:
		return ""
	var inv = p.bound_inventory() if p.has_method("bound_inventory") else null
	if inv and inv.has_method("to_save_dict"):
		var a := _arch_in_save(inv.to_save_dict(), weapon_id)
		if a != "":
			return a
	return _arch_in_save(p.stash, weapon_id)


static func _arch_in_save(d: Dictionary, item_id: String) -> String:
	var items: Array = []
	for s in d.get("equipped", {}):
		items.append(d.equipped[s])
	for s in d.get("backpack", {}):
		items.append_array(d.backpack[s])
	for it in items:
		if typeof(it) == TYPE_DICTIONARY and str(it.get("item_id", "")) == item_id and str(it.get("class", "")) == "weapon":
			return str(it.get("archetype", ""))
	return ""


static func slots() -> Array:
	return data().get("slots", [])


static func class_info(arch: String) -> Dictionary:
	return data().get("classes", {}).get(arch, {})


static func class_slots(arch: String) -> Array:
	return class_info(arch).get("slots", [])


static func attachment(id: String) -> Dictionary:
	data()
	return _by_id.get(id, {})


static func attachment_ids() -> Array:
	return data().get("attachments", []).map(func(a): return str(a.id))


static func is_attachment(id: String) -> bool:
	return not attachment(id).is_empty()


## Slot exists on the class, the part's class allow-list (if any) has it, and optics fit the class's optic_cap.
static func is_compatible(att_id: String, arch: String) -> bool:
	var a := attachment(att_id)
	if a.is_empty() or not (str(a.slot) in class_slots(arch)):
		return false
	var allow: Array = a.get("classes", [])
	if not allow.is_empty() and not (arch in allow):
		return false
	if str(a.slot) == "optic":
		var sizes: Array = data().get("optic_sizes", ["micro", "short", "mid", "long"])
		return sizes.find(str(a.get("size", "micro"))) <= sizes.find(str(class_info(arch).get("optic_cap", "micro")))
	return true


static func compatible_archetypes(att_id: String) -> Array:
	return weapons().map(func(w): return w.id).filter(func(arch): return is_compatible(att_id, arch))


## Weapon upgrade tier needed to EQUIP this attachment (tier 1 -> 0, tier 2 -> II, tier 3 -> IV).
static func tier_requirement(att_id: String) -> int:
	return int(data().get("tier_requires", {}).get(str(int(attachment(att_id).get("tier", 1))), 0))


# ================================================================== upgrades

static func tiers() -> Array:
	return cfg().get("upgrades", {}).get("tiers", [])


static func max_tier() -> int:
	return tiers().size()


static func upgrade_tier(arch: String) -> int:
	var p = prog()
	return clampi(int(p.armory.upgrades.get(arch, 0)), 0, max_tier()) if p else 0


static func tier_name(t: int) -> String:
	return str(tiers()[t - 1].get("name", str(t))) if t >= 1 and t <= max_tier() else ""


## Gravemark cost of tier t (1-based) for an archetype: cost x archetype_cost_mult. 0 outside 1..max.
static func tier_cost(arch: String, t: int) -> int:
	if t < 1 or t > max_tier():
		return 0
	var m := float(cfg().get("upgrades", {}).get("archetype_cost_mult", {}).get(arch, 1.0))
	return int(round(float(tiers()[t - 1].get("cost", 0)) * m))


static func next_upgrade_cost(arch: String) -> int:
	return tier_cost(arch, upgrade_tier(arch) + 1)


## Everything to take one archetype from tier 0 to max.
static func upgrade_total_cost(arch: String = "") -> int:
	var n := 0
	for t in range(1, max_tier() + 1):
		n += tier_cost(arch, t)
	return n


## Item Power the archetype's upgrade tier adds (tier data "item_power" is the running total).
static func power_bonus(arch: String) -> int:
	var t := upgrade_tier(arch)
	return int(tiers()[t - 1].get("item_power", 0)) if t > 0 else 0


# ================================================================== state queries

static func owned(att_id: String) -> bool:
	var p = prog()
	return p != null and att_id in p.armory.owned


## {slot: attachment id} for an archetype (only owned, compatible parts in its slots).
static func loadout(arch: String) -> Dictionary:
	var p = prog()
	if p == null:
		return {}
	var out := {}
	var lo: Dictionary = p.armory.equipped.get(arch, {})
	for slot in lo:
		var id := str(lo[slot])
		if owned(id) and is_compatible(id, arch) and str(attachment(id).slot) == str(slot) \
				and upgrade_tier(arch) >= tier_requirement(id):
			out[str(slot)] = id
	return out


static func equipped_on(att_id: String, arch: String) -> bool:
	return loadout(arch).values().has(att_id)


## Unmet requirements to equip `att_id` on `arch`, as display strings (empty = OK). Ownership is not a requirement.
static func equip_requirements(att_id: String, arch: String) -> Array:
	var out := []
	if not is_compatible(att_id, arch):
		out.append("Does not fit the %s" % weapon_type(arch))
	var need := tier_requirement(att_id)
	if need > 0 and upgrade_tier(arch) < need:
		out.append("%s Rework tier %s" % [weapon_type(arch), tier_name(need)])
	return out


## Unmet requirements to BUY: some compatible weapon must already be at the tier the part needs.
static func purchase_requirements(att_id: String) -> Array:
	var need := tier_requirement(att_id)
	if need <= 0:
		return []
	for arch in compatible_archetypes(att_id):
		if upgrade_tier(arch) >= need:
			return []
	return ["Any compatible weapon at Rework tier %s" % tier_name(need)]


# ================================================================== gameplay modifiers (cached on Progress.armory_rev)

static func _entry(arch: String) -> Dictionary:
	var p = prog()
	var rev: int = p.armory_rev if p else -2
	if rev != _cache_rev:
		_cache.clear()
		_cache_rev = rev
	if not _cache.has(arch):
		_cache[arch] = _compute(arch)
	return _cache[arch]


static func _compute(arch: String) -> Dictionary:
	var mods := {}
	for k in MULT_KEYS:
		mods[k] = 1.0
	for k in ADD_KEYS:
		mods[k] = 0.0
	var ads := {"fov": 0.0, "move_mult": 1.0, "spread_mult": 1.0}
	var flg := {}
	var parts: Array = []
	for t in range(1, upgrade_tier(arch) + 1):
		parts.append(tiers()[t - 1].get("mods", {}))
	var lo := loadout(arch)
	for slot in lo:
		var a := attachment(lo[slot])
		parts.append(a.get("mods", {}))
		var ad: Dictionary = a.get("ads", {})
		if float(ad.get("fov", 0.0)) > 0.0:
			ads.fov = float(ad.fov) if ads.fov <= 0.0 else minf(ads.fov, float(ad.fov))
		ads.move_mult *= float(ad.get("move_mult", 1.0))
		ads.spread_mult *= float(ad.get("spread_mult", 1.0))
		var fl: Dictionary = a.get("flags", {})
		for k in fl:
			if k == "flash_mult":
				flg[k] = float(flg.get(k, 1.0)) * float(fl[k])
			else:
				flg[k] = fl[k]
	for m in parts:
		for k in m:
			if k in MULT_KEYS:
				mods[k] *= float(m[k])
			elif k in ADD_KEYS:
				mods[k] += float(m[k])
	mods["item_power_bonus"] = power_bonus(arch)
	return {"mods": mods, "ads": ads, "flags": flg}


## WeaponItem multipliers for an archetype (identity values when nothing is bought/equipped).
static func weapon_mods(arch: String) -> Dictionary:
	return _entry(arch).mods


static func mod(arch: String, key: String, fallback: float = 1.0) -> float:
	return float(_entry(arch).mods.get(key, fallback))


## {fov (0 = no optic override), move_mult, spread_mult} for AdsProfile.
static func ads_mods(arch: String) -> Dictionary:
	return _entry(arch).ads


## Presentation flags for player.gd / HUD hooks: tracer_hidden, flash_mult, scope_overlay, outline_elites,
## heartbeat_counter (+ heartbeat_radius), bipod, flashlight, mine_lamp.
static func flags(arch: String) -> Dictionary:
	return _entry(arch).flags


static func flag(arch: String, key: String, fallback = false):
	return _entry(arch).flags.get(key, fallback)


## True when the archetype's loadout has Mine Lamp equipped (and tier-unlocked). Player F-toggle reads this.
static func has_mine_lamp(arch: String) -> bool:
	return bool(flag(arch, "mine_lamp", false))


## SkillRunner: [{arch, id, def}] for every effect of every equipped attachment (gated to that archetype in hand).
## Camera flashlight values for the part fitted on `arch` (Mine Lamp today), read by player.gd (MAIN_HOOKS §13).
## Missing keys fall back to FLASHLIGHT_DEFAULTS (Mapz flashlight.patch numbers, energy raised in the art pass).
## {} when no flashlight part is equipped on that archetype (or it's below the tier gate).
const FLASHLIGHT_DEFAULTS := {"light_energy": 7.0, "light_range": 22.0, "light_angle": 28.0, "light_attenuation": 1.1,
	"light_color": [0.92, 0.95, 1.0]}

static func flashlight_config(arch: String) -> Dictionary:
	if not has_mine_lamp(arch):
		return {}
	var a := attachment(str(loadout(arch).get("grip", "mine_lamp")))
	if not bool(a.get("flags", {}).get("mine_lamp", false)):
		a = attachment("mine_lamp")
	return flashlight_values(a)


## FLASHLIGHT_DEFAULTS overlaid with an attachment entry's light_* keys (also used by tests / the Armory card).
static func flashlight_values(a: Dictionary) -> Dictionary:
	var out := FLASHLIGHT_DEFAULTS.duplicate(true)
	for k in FLASHLIGHT_DEFAULTS:
		if a.has(k):
			out[k] = a[k]
	var c: Array = out.light_color
	out["color"] = Color(float(c[0]), float(c[1]), float(c[2]))
	return out


## Item Power split for Gooey's Armory / item cards: {base_rolled, rework_bonus, total} plus context keys
## archetype, item_id, tier, source ("item" | "best_owned" | "baseline").
## weapon_id = a gear item_id (that item's rolled IP) or an archetype id (the highest-IP weapon of that archetype you
## carry or have stashed; with none, the legacy baseline IP 100). rework_bonus = power_bonus(arch) from the upgrade tier.
## total = base_rolled + rework_bonus = WeaponItem.effective_item_power() for that item.
static func item_power_breakdown(weapon_id: String) -> Dictionary:
	var arch := resolve_weapon(weapon_id)
	var baseline := 100
	var gdb = Engine.get_main_loop().root.get_node_or_null("GearDB") if Engine.get_main_loop() is SceneTree else null
	if gdb and "loot" in gdb:
		baseline = int(gdb.loot.get("roll_quality", {}).get("legacy_item_power", 100))
	var base := baseline
	var source := "baseline"
	var item_id := ""
	var items := _owned_weapon_dicts()
	if not is_archetype(weapon_id):
		for it in items:
			if str(it.get("item_id", "")) == weapon_id:
				base = int(it.get("item_power", baseline))
				source = "item"
				item_id = weapon_id
				break
	else:
		var best := -1
		for it in items:
			if str(it.get("archetype", "")) == arch and int(it.get("item_power", baseline)) > best:
				best = int(it.get("item_power", baseline))
				item_id = str(it.get("item_id", ""))
		if best >= 0:
			base = best
			source = "best_owned"
	var bonus := power_bonus(arch) if arch != "" else 0
	return {"base_rolled": base, "rework_bonus": bonus, "total": base + bonus, "archetype": arch, "item_id": item_id,
		"tier": upgrade_tier(arch) if arch != "" else 0, "source": source}


## Weapon item dicts from the live Inventory (equipped + backpack) and the saved stash, deduplicated by item_id.
static func _owned_weapon_dicts() -> Array:
	var out: Array = []
	var seen := {}
	var p = prog()
	if p == null:
		return out
	var saves: Array = []
	var inv = p.bound_inventory() if p.has_method("bound_inventory") else null
	if inv and inv.has_method("to_save_dict"):
		saves.append(inv.to_save_dict())
	if "stash" in p and typeof(p.stash) == TYPE_DICTIONARY:
		saves.append(p.stash)
	for d in saves:
		var items: Array = []
		for s in d.get("equipped", {}):
			items.append(d.equipped[s])
		for s in d.get("backpack", {}):
			items.append_array(d.backpack[s])
		for it in items:
			if typeof(it) != TYPE_DICTIONARY or str(it.get("class", "")) != "weapon":
				continue
			var iid := str(it.get("item_id", ""))
			if iid != "" and seen.has(iid):
				continue
			seen[iid] = true
			out.append(it)
	return out


static func effect_defs() -> Array:
	var out := []
	for w in weapons():
		var lo := loadout(w.id)
		for slot in lo:
			for def in attachment(lo[slot]).get("effects", []):
				out.append({"arch": w.id, "id": str(lo[slot]), "def": def})
	return out


## Heartbeat Counter HUD number: zombies within radius of pos (group "enemies").
static func nearby_zombie_count(tree: SceneTree, pos: Vector3, radius: float = 10.0) -> int:
	var n := 0
	if tree == null:
		return 0
	for e in tree.get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e is Node3D and e.global_position.distance_to(pos) <= radius:
			n += 1
	return n


# ================================================================== mutations (static; the instance API wraps these)

static func buy_attachment(att_id: String) -> bool:
	var p = prog()
	if p == null or not can_afford_id(att_id) or owned(att_id):
		return false
	if not p.spend_gravemark(int(attachment(att_id).cost)):
		return false
	p.armory.owned.append(att_id)
	p.notify_armory("purchase", att_id)
	return true


static func buy_upgrade(arch: String) -> bool:
	var p = prog()
	if p == null or not is_archetype(arch) or upgrade_tier(arch) >= max_tier():
		return false
	if not p.spend_gravemark(next_upgrade_cost(arch)):
		return false
	p.armory.upgrades[arch] = upgrade_tier(arch) + 1
	p.notify_armory("upgrade", UPGRADE_PREFIX + arch)
	return true


## Puts an owned, compatible, tier-unlocked part in its slot (replacing whatever was there).
static func equip(arch: String, att_id: String) -> bool:
	var p = prog()
	if p == null or not owned(att_id) or not equip_requirements(att_id, arch).is_empty():
		return false
	var slot := str(attachment(att_id).slot)
	if not p.armory.equipped.has(arch):
		p.armory.equipped[arch] = {}
	p.armory.equipped[arch][slot] = att_id
	p.notify_armory("equip", att_id)
	return true


static func unequip_slot(arch: String, slot: String) -> bool:
	var p = prog()
	if p == null or not p.armory.equipped.get(arch, {}).has(slot):
		return false
	var id := str(p.armory.equipped[arch][slot])
	p.armory.equipped[arch].erase(slot)
	p.notify_armory("unequip", id)
	return true


static func cost_of(id: String) -> int:
	if id.begins_with(UPGRADE_PREFIX):
		return next_upgrade_cost(id.substr(UPGRADE_PREFIX.length()))
	return int(attachment(id).get("cost", 0))


## Balance covers the cost and the item is buyable (not owned / not maxed, requirements met).
static func can_afford_id(id: String) -> bool:
	var p = prog()
	if p == null:
		return false
	if id.begins_with(UPGRADE_PREFIX):
		var arch := id.substr(UPGRADE_PREFIX.length())
		return is_archetype(arch) and upgrade_tier(arch) < max_tier() and p.gravemarks >= next_upgrade_cost(arch)
	if not is_attachment(id) or owned(id) or not purchase_requirements(id).is_empty():
		return false
	return p.gravemarks >= cost_of(id)


# ================================================================== Gravemark drops

static func drop_mult() -> float:
	return float(load(DIFFICULTY_SCRIPT).rare_currency_drop_mult())


static func src(name: String) -> Dictionary:
	return cfg().get("currency", {}).get("sources", {}).get(name, {})


static func match_cap() -> int:
	return int(cfg().get("currency", {}).get("match_cap", 30))


static func reset_match_state() -> void:
	_last_round = 0
	_chest_round = -1
	_chest_round_n = 0
	_chest_match_n = 0
	_boss_round = -1
	_boss_round_n = 0


## A round number lower than the last one seen means a new match started (no main.gd hook needed for that).
static func _see_round(r: int) -> void:
	if r > 0 and r < _last_round:
		reset_match_state()
		var p = prog()
		if p:
			p.match_gravemarks = 0
	_last_round = maxi(_last_round, r)


## Rolls `chance` x drop_mult: the whole part pays outright, the remainder is a roll. roll = test override (0..1).
static func roll_count(chance: float, roll: float = -1.0) -> int:
	var c := maxf(chance, 0.0) * drop_mult()
	var n := int(floor(c))
	var r := roll if roll >= 0.0 else randf()
	if r < c - float(n):
		n += 1
	return n


## Pays n Gravemarks into Progress, clipped to what's left of the match cap. Returns what was paid.
static func award(n: int, source: String) -> int:
	var p = prog()
	if p == null or n <= 0:
		return 0
	var pay := mini(n, maxi(match_cap() - int(p.match_gravemarks), 0))
	if pay > 0:
		p.add_gravemark(pay, source)
	return pay


## main.gd _on_zombie_died (MAIN_HOOKS §9). Bosses: BossCatalog reward x drop mult for the first boss of a round,
## extra_boss_amount for later ones; echoes pay nothing; elites / specials / regulars roll their chance.
static func on_zombie_died(zombie: Object, round_number: int = 0, roll: float = -1.0) -> int:
	_see_round(round_number)
	if zombie == null:
		return 0
	if zombie.has_meta("boss_echo") and zombie.get_meta("boss_echo"):
		return 0
	if zombie.has_meta("is_boss") and zombie.get_meta("is_boss"):
		return award(boss_amount(str(zombie.get_meta("boss_id", "")), round_number), "boss")
	var vid := str(zombie.get("variant_id")) if "variant_id" in zombie else ""
	var el := src("elite")
	if (zombie.has_meta("elite") and zombie.get_meta("elite")) or vid in el.get("variants", []):
		return award(roll_count(float(el.get("chance", 0.2)), roll) * int(el.get("amount", 1)), "elite")
	var sp := src("special")
	if vid != "" and vid in sp.get("variants", []):
		return award(roll_count(float(sp.get("chance", 0.01)), roll) * int(sp.get("amount", 1)), "special")
	var rg := src("regular")
	return award(roll_count(float(rg.get("chance", 0.0015)), roll) * int(rg.get("amount", 1)), "regular")


## Boss payout (before the match cap): first boss of the round = BossCatalog.gravemark_scaled, later ones extra_boss_amount.
static func boss_amount(boss_id: String, round_number: int) -> int:
	if round_number != _boss_round:
		_boss_round = round_number
		_boss_round_n = 0
	_boss_round_n += 1
	if _boss_round_n > 1:
		return int(src("boss").get("extra_boss_amount", 1))
	return int(load(BOSS_SCRIPT).gravemark_scaled(boss_id))


## main.gd at round clear (MAIN_HOOKS §9): 1 Gravemark (x drop mult) every `every` rounds.
static func on_round_cleared(round_number: int, roll: float = -1.0) -> int:
	_see_round(round_number)
	var m := src("milestone")
	var every := maxi(int(m.get("every", 10)), 1)
	if round_number <= 0 or round_number % every != 0:
		return 0
	return award(roll_count(float(m.get("amount", 1)), roll), "milestone")


## chest.gd interact(): chance x drop mult, at most per_round_max per round and match_max per match.
static func on_chest_opened(round_number: int, roll: float = -1.0) -> int:
	_see_round(round_number)
	var c := src("chest")
	if round_number != _chest_round:
		_chest_round = round_number
		_chest_round_n = 0
	if _chest_round_n >= int(c.get("per_round_max", 1)) or _chest_match_n >= int(c.get("match_max", 2)):
		return 0
	var n := award(roll_count(float(c.get("chance", 0.05)), roll) * int(c.get("amount", 1)), "chest")
	if n > 0:
		_chest_round_n += 1
		_chest_match_n += 1
	return n


# ================================================================== income model (tests + matches-to-max table)

## Expected Gravemarks for a match that ends after `rounds` cleared rounds on difficulty `diff`, every boss killed.
## Uses main.gd's default wave sizes x the profile's count mults, Difficulty's variant shares and boss roster,
## and armory.json -> expected.chest_opens_per_round. Returns {total, boss, milestone, chest, special, regular, kills}.
static func expected_match_income(diff: String, rounds: int) -> Dictionary:
	var D = load(DIFFICULTY_SCRIPT)
	var B = load(BOSS_SCRIPT)
	var ex: Dictionary = cfg().get("expected", {})
	var w: Dictionary = D.profile(diff).get("wave", {})
	var mult := float(D.rare_currency_drop_mult(diff))
	var first := maxi(int(round(float(ex.get("first_round_zombies", 6)) * float(w.get("count_mult", 1.0)))), 1)
	var per := int(round(float(ex.get("zombies_per_round", 3)) * float(w.get("count_ramp_mult", 1.0))))
	var out := {"boss": 0.0, "milestone": 0.0, "chest": 0.0, "special": 0.0, "regular": 0.0, "kills": 0}
	var sp := src("special")
	var rg := src("regular")
	var ch := src("chest")
	var chest_p := minf(float(ch.get("chance", 0.05)) * mult, 1.0)
	var opens := int(ex.get("chest_opens_per_round", 2))
	var chest_total := 0.0
	for n in range(1, rounds + 1):
		var z := first + per * (n - 1)
		out.kills += z
		var sp_share := 0.0
		for v in sp.get("variants", []):
			sp_share += float(D.variant_share(str(v), n, diff))
		out.special += z * sp_share * float(sp.get("chance", 0.01)) * mult
		out.regular += z * (1.0 - sp_share) * float(rg.get("chance", 0.0015)) * mult
		var p_round := 1.0 - pow(1.0 - chest_p, opens) # chance at least one chest pays this round (per_round_max 1)
		chest_total += p_round
		var roster: Array = B.pick_roster(n, diff)
		for i in roster.size():
			out.boss += float(B.gravemark_scaled(str(roster[i]), diff)) if i == 0 else float(src("boss").get("extra_boss_amount", 1))
		if n % maxi(int(src("milestone").get("every", 10)), 1) == 0:
			out.milestone += float(src("milestone").get("amount", 1)) * mult
	out.chest = minf(chest_total, float(ch.get("match_max", 2)))
	out["total"] = minf(out.boss + out.milestone + out.chest + out.special + out.regular, float(match_cap()))
	return out


## Matches of `rounds` (default: armory.json expected.typical_rounds[diff]) to afford tiers I..max for ONE archetype,
## and for all 9 archetypes plus every attachment once. {per_match, tiers_to_iv, one_weapon_max, everything}.
static func matches_to_max(diff: String, rounds: int = -1, arch: String = "auto_rifle") -> Dictionary:
	if rounds <= 0:
		rounds = int(cfg().get("expected", {}).get("typical_rounds", {}).get(diff, 15))
	var inc := float(expected_match_income(diff, rounds).total)
	var to_iv := 0
	for t in range(1, mini(4, max_tier()) + 1):
		to_iv += tier_cost(arch, t)
	var all := 0
	for w in weapons():
		all += upgrade_total_cost(w.id)
	for a in data().get("attachments", []):
		all += int(a.get("cost", 0))
	return {"rounds": rounds, "per_match": inc, "tiers_to_iv": ceilf(to_iv / maxf(inc, 0.01)),
		"one_weapon_max": ceilf(upgrade_total_cost(arch) / maxf(inc, 0.01)), "everything": ceilf(all / maxf(inc, 0.01)),
		"everything_cost": all}


# ================================================================== instance API (Gooey's Armory tab)

func currency_balance() -> int:
	var p = prog()
	return int(p.gravemarks) if p else 0


## [{id, name, type, slot, slots, tier, max_tier, equipped: {slot: id}}] for every weapon archetype.
func list_weapons() -> Array:
	var out := []
	for w in weapons():
		out.append({"id": w.id, "name": w.type, "type": w.type, "slot": w.slot, "slots": class_slots(w.id),
			"tier": upgrade_tier(w.id), "max_tier": max_tier(), "equipped": loadout(w.id),
			"optic_cap": str(class_info(w.id).get("optic_cap", ""))})
	return out


func list_slots(weapon_id: String) -> Array:
	var arch := resolve_weapon(weapon_id)
	var out := []
	for s in slots():
		if str(s.id) in class_slots(arch):
			out.append({"id": str(s.id), "name": str(s.name), "socket": str(s.socket),
				"equipped": str(loadout(arch).get(str(s.id), ""))})
	return out


func equipped(weapon_id: String) -> Dictionary:
	return loadout(resolve_weapon(weapon_id))


## One upgrade track per archetype (weapon_id "" = all). Entry: id "upg_<arch>", name, summary (next tier),
## cost (next tier, 0 maxed), level / current_level, max_level, owned (level > 0), maxed, slot "upgrade",
## category "weapon", weapon_id, tier_name / next_tier_name, tiers [{tier, name, cost, summary, item_power}],
## item_power_bonus, requirements [] (upgrades have none), can_afford, state ("available" | "maxed").
func list_upgrades(weapon_id: String = "") -> Array:
	var archs: Array = weapons().map(func(w): return w.id) if weapon_id == "" else [resolve_weapon(weapon_id)]
	var out := []
	for arch in archs:
		if not is_archetype(arch):
			continue
		var lvl := upgrade_tier(arch)
		var maxed := lvl >= max_tier()
		var tl := []
		for t in range(1, max_tier() + 1):
			var td: Dictionary = tiers()[t - 1]
			tl.append({"tier": t, "name": str(td.get("name", t)), "cost": tier_cost(arch, t),
				"summary": str(td.get("summary", "")), "item_power": int(td.get("item_power", 0))})
		var tpl := str(cfg().get("upgrades", {}).get("name_template", "{type} Rework"))
		out.append({"id": UPGRADE_PREFIX + arch, "name": tpl.replace("{type}", weapon_type(arch)),
			"summary": "Fully upgraded." if maxed else str(tiers()[lvl].get("summary", "")),
			"cost": 0 if maxed else next_upgrade_cost(arch), "level": lvl, "current_level": lvl, "max_level": max_tier(),
			"owned": lvl > 0, "maxed": maxed, "slot": "upgrade", "category": "weapon", "weapon_id": arch,
			"tier_name": tier_name(lvl), "next_tier_name": "" if maxed else tier_name(lvl + 1), "tiers": tl,
			"item_power_bonus": power_bonus(arch), "requirements": [], "can_afford": can_afford_id(UPGRADE_PREFIX + arch),
			"state": "maxed" if maxed else "available"})
	return out


## Parts that fit `weapon_id` (optionally one slot). Entry: id, name, summary, description, drawback, cost, owned,
## equipped (on this weapon), slot, tier, unique, icon, model, requirements (unmet, to equip here: tier gates),
## purchase_requirements (unmet, to buy), can_afford, state: "equipped" | "owned" | "locked" (requirements) | "available".
func list_attachments(weapon_id: String, slot: String = "") -> Array:
	var arch := resolve_weapon(weapon_id)
	var out := []
	for a in data().get("attachments", []):
		var id := str(a.id)
		if not is_compatible(id, arch) or (slot != "" and str(a.slot) != slot):
			continue
		var req := equip_requirements(id, arch)
		var preq := purchase_requirements(id)
		var own := owned(id)
		var eq := equipped_on(id, arch)
		out.append({"id": id, "name": str(a.name), "summary": str(a.summary), "description": str(a.description),
			"drawback": str(a.get("drawback", "")), "cost": int(a.cost), "owned": own, "equipped": eq,
			"slot": str(a.slot), "tier": int(a.get("tier", 1)), "unique": bool(a.get("unique", false)),
			"icon": str(a.get("icon", id)), "model": str(a.get("model", "")), "weapon_id": arch,
			"requirements": req, "purchase_requirements": preq, "can_afford": can_afford_id(id),
			"state": "equipped" if eq else ("owned" if own and req.is_empty() else ("locked" if not req.is_empty() or (not own and not preq.is_empty()) else ("owned" if own else "available")))})
	return out


func cost(id: String) -> int:
	return cost_of(id)


func can_afford(id: String) -> bool:
	return can_afford_id(id)


func is_owned(id: String) -> bool:
	if id.begins_with(UPGRADE_PREFIX):
		return upgrade_tier(id.substr(UPGRADE_PREFIX.length())) > 0
	return owned(id)


## Buys an attachment (one-time unlock) or the next tier of "upg_<arch>". Saves at once. False if not affordable.
func purchase(id: String) -> bool:
	if id.begins_with(UPGRADE_PREFIX):
		return buy_upgrade(id.substr(UPGRADE_PREFIX.length()))
	return buy_attachment(id)


## Gooey's placeholder signature. `slot` must match the part's slot ("" = take it from the part).
func equip_attachment(weapon_id: String, slot: String, id: String) -> bool:
	if slot != "" and str(attachment(id).get("slot", "")) != slot:
		return false
	return equip(resolve_weapon(weapon_id), id)


func unequip(weapon_id: String, slot: String) -> bool:
	return unequip_slot(resolve_weapon(weapon_id), slot)
