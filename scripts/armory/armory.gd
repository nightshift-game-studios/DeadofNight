class_name Armory
extends RefCounted
## Armory (Skillz): Gravemark currency drops, weapon attachments and weapon upgrade tiers.
## Economy v2 (DESIGN §21): upgrade tiers cost Scrap (armory.json upgrades.currency = "scrap"; Progress.scrap, save v6,
## earned by scrapping gear, see /workspace/skillz/SCRAP_API.md). Attachments / optics: Gravemark OR Scrap (playtest
## 2026-10-22 #2, armory.json attachment_shop: Scrap price by attachment rarity; default_currency picks cost()/purchase()).
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


## Cost of tier t (1-based) for an archetype, in upgrade_currency(): cost x archetype_cost_mult. 0 outside 1..max.
## With currency "gravemark" a tier's gravemark_cost (the pre-v2 price) is used when it has one.
static func tier_cost(arch: String, t: int) -> int:
	if t < 1 or t > max_tier():
		return 0
	var m := float(cfg().get("upgrades", {}).get("archetype_cost_mult", {}).get(arch, 1.0))
	var td: Dictionary = tiers()[t - 1]
	var key := "gravemark_cost" if upgrade_currency() == "gravemark" and td.has("gravemark_cost") else "cost"
	return int(round(float(td.get(key, 0)) * m))


## What weapon upgrade tiers are paid in: "scrap" (Economy v2) or "gravemark".
static func upgrade_currency() -> String:
	var c := str(cfg().get("upgrades", {}).get("currency", "gravemark"))
	return "scrap" if c == "scrap" else "gravemark"


## Balance of a currency id ("gravemark" / "scrap").
static func balance(currency: String) -> int:
	var p = prog()
	if p == null:
		return 0
	return int(p.scrap) if currency == "scrap" and "scrap" in p else int(p.gravemarks)


static func _spend(currency: String, n: int) -> bool:
	var p = prog()
	if p == null:
		return false
	return p.spend_scrap(n) if currency == "scrap" else p.spend_gravemark(n)


## "Gravemark(s)" / "Scrap" for messages.
static func currency_word(currency: String, n: int) -> String:
	var c: Dictionary = cfg().get("scrap", {}) if currency == "scrap" else cfg().get("currency", {})
	var nm := "Scrap" if currency == "scrap" else "Gravemark"
	return str(c.get("name", nm)) if n == 1 else str(c.get("plural", nm if currency == "scrap" else nm + "s"))


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
	resolve_exclusions(arch, out)  # a blocked pair never reaches the gun, even before a save is sanitized
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
	var why := exclusion_reason(att_id, arch)
	if why != "":
		out.append(why)
	return out


# ------------------------------------------------------------------ per-gun exclusions (art pass 2b)

## attachments.json "exclusions" rules that apply to `arch` ("" = all): {id, classes, parts, reason}.
static func exclusions(arch: String = "") -> Array:
	return data().get("exclusions", []).filter(func(r): return arch == "" or arch in r.get("classes", []))


## The rule + equipped part that blocks fitting `att_id` on `arch` next to `lo` (default: the current loadout).
## A part in att_id's own slot doesn't count (equipping replaces it). {} = no conflict, else
## {rule, with (attachment id), with_name, reason (the rule's text)}.
static func exclusion_conflict(att_id: String, arch: String, lo = null) -> Dictionary:
	var cur: Dictionary = lo if lo is Dictionary else loadout(arch)
	var slot := str(attachment(att_id).get("slot", ""))
	for r in exclusions(arch):
		var parts: Array = r.get("parts", [])
		if not (att_id in parts):
			continue
		for s in cur:
			var other := str(cur[s])
			if str(s) != slot and other != att_id and other in parts:
				return {"rule": str(r.get("id", "")), "with": other, "with_name": str(attachment(other).get("name", other)),
					"reason": str(r.get("reason", ""))}
	return {}


## UI text for an exclusion conflict ("" = none), e.g. "Not with Bonesaw Bayonet on the SMG: <rule reason>".
static func exclusion_reason(att_id: String, arch: String, lo = null) -> String:
	var c := exclusion_conflict(att_id, arch, lo)
	if c.is_empty():
		return ""
	var why := str(c.reason)
	return "Not with %s on the %s" % [c.with_name, weapon_type(arch)] + (": " + why if why != "" else "")


## Drops blocked pairs from a {slot: id} loadout in place: for each rule, every listed part after the first one
## present is removed (rule order = priority). Returns [{slot, id, rule}] removed.
static func resolve_exclusions(arch: String, lo: Dictionary) -> Array:
	var removed := []
	for r in exclusions(arch):
		var keep_one := false
		for part in r.get("parts", []):
			for s in lo.keys():
				if str(lo[s]) == str(part):
					if keep_one:
						removed.append({"slot": str(s), "id": str(part), "rule": str(r.get("id", ""))})
						lo.erase(s)
					else:
						keep_one = true
	return removed


## Save clean-up (Progress.load_data, art pass 2b): unequips parts the current data no longer allows where they sit:
## wrong class / slot (e.g. Sawn Stub on hand_cannon or the LMG, Ember Window Mag on hand_cannon) and blocked pairs
## (exclusions; the last listed part goes). Unequipped parts stay in `owned` (the Armory stash), so nothing is lost;
## an equipped id that wasn't owned is not granted. Unknown ids / archetypes are left alone (data may add them back).
## Mutates `armory_dict` ({upgrades, owned, equipped}); returns [{arch, slot, id, why: "fit" | rule id}].
static func sanitize_armory(armory_dict: Dictionary) -> Array:
	var out := []
	var eq = armory_dict.get("equipped", {})
	if typeof(eq) != TYPE_DICTIONARY:
		return out
	for arch in eq.keys():
		var lo = eq[arch]
		if typeof(lo) != TYPE_DICTIONARY or not is_archetype(str(arch)):
			continue
		for slot in lo.keys():
			var id := str(lo[slot])
			if is_attachment(id) and not (is_compatible(id, str(arch)) and str(attachment(id).slot) == str(slot)):
				lo.erase(slot)
				out.append({"arch": str(arch), "slot": str(slot), "id": id, "why": "fit"})
		var known := {}
		for slot in lo:
			if is_attachment(str(lo[slot])):
				known[slot] = lo[slot]
		for r in resolve_exclusions(str(arch), known):
			lo.erase(r.slot)
			out.append({"arch": str(arch), "slot": str(r.slot), "id": str(r.id), "why": str(r.rule)})
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
	return _compute_lo(arch, loadout(arch))


## Same as _compute for any {slot: id} loadout (optic previews: Armory.optic_profile(weapon, candidate)).
## ads (optics pass): fov (0 = no optic override; the narrowest wins), fov_mult / move_mult / spread_mult / ads_time_mult /
## sway_mult (multiplied over the parts), optic (equipped optic id or ""), scope_replaced (an optic hides the built-in
## DefaultOptic scope, i.e. the sniper aims through it instead), overlay (Gooey's 2D scope overlay while ADS).
static func _compute_lo(arch: String, lo: Dictionary) -> Dictionary:
	var mods := {}
	for k in MULT_KEYS:
		mods[k] = 1.0
	for k in ADD_KEYS:
		mods[k] = 0.0
	var ads := {"fov": 0.0, "move_mult": 1.0, "spread_mult": 1.0, "fov_mult": 1.0, "ads_time_mult": 1.0, "sway_mult": 1.0,
		"optic": str(lo.get("optic", "")), "scope_replaced": false, "overlay": false}
	var flg := {}
	var parts: Array = []
	for t in range(1, upgrade_tier(arch) + 1):
		parts.append(tiers()[t - 1].get("mods", {}))
	for slot in lo:
		var a := attachment(lo[slot])
		parts.append(a.get("mods", {}))
		var ad: Dictionary = a.get("ads", {})
		if float(ad.get("fov", 0.0)) > 0.0:
			ads.fov = float(ad.fov) if ads.fov <= 0.0 else minf(ads.fov, float(ad.fov))
		for k in ["move_mult", "spread_mult", "fov_mult", "ads_time_mult", "sway_mult"]:
			ads[k] *= float(ad.get(k, 1.0))
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
	var oid := str(ads.optic)
	# Only an optic that is actually on the gun replaces the built-in scope: a pending GLB (art not delivered) leaves
	# DefaultOptic on the sniper (WeaponRig fits nothing, hides nothing), so the factory scope picture, overlay and FOV
	# stay. (art5: Kilnglass on live without its GLB = no overlay, aimed into the factory scope's opaque housing = black.)
	ads.scope_replaced = oid != "" and has_builtin_scope(arch) and _optic_hides(oid, arch).has("DefaultOptic") \
		and optic_art_status(oid) in ["shipped", "procedural"]
	ads.overlay = bool(flg.get("scope_overlay", false)) or (has_builtin_scope(arch) and not ads.scope_replaced)
	return {"mods": mods, "ads": ads, "flags": flg}


## WeaponItem multipliers for an archetype (identity values when nothing is bought/equipped).
static func weapon_mods(arch: String) -> Dictionary:
	return _entry(arch).mods


static func mod(arch: String, key: String, fallback: float = 1.0) -> float:
	return float(_entry(arch).mods.get(key, fallback))


## {fov (0 = no optic override), move_mult, spread_mult, fov_mult, ads_time_mult, sway_mult, optic, scope_replaced,
## overlay} for AdsProfile.
static func ads_mods(arch: String) -> Dictionary:
	return _entry(arch).ads


## Presentation flags for player.gd / HUD hooks: tracer_hidden, flash_mult, scope_overlay, outline_elites,
## heartbeat_counter (+ heartbeat_radius), bipod, flashlight, mine_lamp.
static func flags(arch: String) -> Dictionary:
	return _entry(arch).flags


static func flag(arch: String, key: String, fallback = false):
	return _entry(arch).flags.get(key, fallback)


## True when the archetype's loadout has an F-toggle beam part equipped (and tier-unlocked): Mine Lamp, or since art
## pass 2 the Lantern Rail (flags.flashlight). Player F-toggle reads this (name kept so player.gd needs no change).
static func has_mine_lamp(arch: String) -> bool:
	return has_flashlight(arch)


## Any equipped part with flags.flashlight (Mine Lamp, Lantern Rail).
static func has_flashlight(arch: String) -> bool:
	return bool(flag(arch, "flashlight", false)) or bool(flag(arch, "mine_lamp", false))


# ================================================================== optics lineup (optics pass, DESIGN.md §19)
## Data: attachments.json -> optics {hip_fov, overlay_min_mag, lineup, price_bands, factory} + each optic-slot part's
## "optic" block {type, label, magnification, reticle_id, reticle{shape,color,size_moa}, overlay, glow{mode,energy,color},
## night, replaces_irons, rarity, tradeoff}. The ADS numbers come from AdsProfile (class profile x optic), so the Armory
## card, the HUD and the live player read the same values. Gooey: optic_profile() / optic_choices() (GOOEY_OPTICS.md).
const ADS_SCRIPT := "res://scripts/combat/ads_profile.gd"


static func optics_cfg() -> Dictionary:
	return data().get("optics", {})


## Archetypes whose factory sight is a built-in scope (DefaultOptic + OpticSightPoint): the sniper family.
static func has_builtin_scope(arch: String) -> bool:
	var ads = load(ADS_SCRIPT)
	return ads != null and ads.family_for_archetype(arch) == "sniper"


## Equipped optic id on `weapon_id` ("" = factory sights).
static func optic_id(weapon_id: String) -> String:
	return str(loadout(resolve_weapon(weapon_id)).get("optic", ""))


static func _optic_hides(att_id: String, arch: String) -> Array:
	var a := attachment(att_id)
	var h = a.get("hides", null)
	if h == null:
		for s in slots():
			if str(s.get("id", "")) == str(a.get("slot", "")):
				h = s.get("hides", [])
	var by_class = a.get("hides_by_class", {})
	if by_class is Dictionary and (by_class as Dictionary).has(arch):
		h = by_class[arch]
	if typeof(h) == TYPE_STRING:
		return [h] if str(h) != "" else []
	return Array(h) if h is Array else []


## The no-attachment choice for `arch`: the factory irons, or the sniper's built-in scope.
static func factory_optic(arch: String) -> Dictionary:
	var f: Dictionary = optics_cfg().get("factory", {})
	return f.get("scope" if has_builtin_scope(arch) else "irons", {})


## Art status of an optic part: "shipped" (GLB in the project), "pending" (GLB not delivered yet: WeaponRig shows the
## default sight picture), "procedural" (no GLB by design: Witchlight Dabs), "none" (factory / unknown).
static func optic_art_status(att_id: String) -> String:
	var a := attachment(att_id)
	if att_id == "" or a.is_empty():
		return "none"
	var m := str(a.get("model", ""))
	if m == "":
		return "procedural" if str(a.get("procedural", "")) != "" else "none"
	return "shipped" if ResourceLoader.exists(m) else "pending"


## Lineup ids that fit `weapon_id`, in data order, factory ("") first. Uniques included.
static func optic_lineup(weapon_id: String) -> Array:
	var arch := resolve_weapon(weapon_id)
	var out: Array = [""]
	for id in optics_cfg().get("lineup", []):
		if is_compatible(str(id), arch):
			out.append(str(id))
	return out


## Everything the Armory card / HUD / scope overlay needs about the sight on `weapon_id` (archetype or gear item_id).
## optic = null: the equipped optic. optic = "" : the factory sights. optic = "<id>": preview that optic in the loadout
## (the rest of the loadout stays, so grips/stocks that touch ADS are counted). Keys:
##   weapon_id, arch, optic_id, name, type, label ("2x"), magnification (nominal), true_magnification (vs the 75 hip view),
##   ads_fov (the effective aimed FOV, the one the camera uses), class_fov (class FOV for this build: FOV_BY_FAMILY, or 55
##   for a sniper whose scope an optic replaced), fov_mult, fov_cap (the parts' ads.fov: a ceiling, 0 = none),
##   fov_source ("optic" = the cap is narrower and wins, "class" = class_fov x fov_mult wins), ads_time (s), ads_time_mult, sway_mult, ads_spread_mult (x the ADS spread, 1 = class),
##   ads_move_mult (move speed while aiming), overlay (2D scope overlay), sight_picture ("overlay" | "3d"),
##   reticle_id, reticle {shape, color, size_moa}, glow {mode, energy, color}, night ("poor" | "fair" | "good"),
##   aperture_mm (clear window diameter around the sight axis, 0 = the gun's own irons),
##   replaces_irons, hides, rarity, tier, cost, owned, equipped, compatible, art_status, fallback (equipped/previewed
##   optic without a GLB: the default sight picture shows; on the sniper that is the factory scope with its overlay + FOV), tradeoff, summary, description, drawback, icon.
static func optic_profile(weapon_id: String, optic = null) -> Dictionary:
	var arch := resolve_weapon(weapon_id)
	var lo: Dictionary = loadout(arch).duplicate()
	var oid := str(lo.get("optic", "")) if optic == null else str(optic)
	if oid != "" and not (is_attachment(oid) and str(attachment(oid).get("slot", "")) == "optic"):
		oid = ""
	if oid == "":
		lo.erase("optic")
	else:
		lo["optic"] = oid
	var c := _compute_lo(arch, lo) if optic != null else _entry(arch)
	var ad: Dictionary = c.ads
	var A = load(ADS_SCRIPT)
	var a := attachment(oid)
	var fac := factory_optic(arch)
	var ob: Dictionary = a.get("optic", fac.get("optic", {})) if oid != "" else fac.get("optic", {})
	# A part that keeps the factory sights (Heartbeat Counter) on a scoped gun: the built-in scope is still the sight.
	if oid != "" and not bool(ob.get("replaces_irons", true)) and not bool(ad.scope_replaced) and has_builtin_scope(arch) \
			and str(ob.get("reticle_id", "")) == "factory_irons":
		ob = (fac.get("optic", {}) as Dictionary).duplicate(true)
	var fov: float = A.merge_fov(arch, ad) if A else 55.0
	var cfov: float = A.class_fov(arch, ad) * float(ad.fov_mult) if A else fov
	var art := optic_art_status(oid)
	var p := {"weapon_id": weapon_id, "arch": arch, "optic_id": oid,
		"name": str(a.get("name", fac.get("name", "Factory Irons"))) if oid != "" else str(fac.get("name", "Factory Irons")),
		"type": str(ob.get("type", "irons")), "label": str(ob.get("label", "Irons")),
		"magnification": float(ob.get("magnification", 0.0)),
		"true_magnification": A.true_magnification(fov) if A else 1.0,
		"ads_fov": fov, "class_fov": A.class_fov(arch, ad) if A else fov, "fov_mult": float(ad.fov_mult),
		"fov_cap": float(ad.fov), "fov_source": "optic" if float(ad.fov) > 0.0 and float(ad.fov) < cfov else "class",
		"ads_time": A.ads_time_for(arch, ad) if A else 0.25, "ads_time_mult": float(ad.ads_time_mult),
		"sway_mult": float(ad.sway_mult), "ads_spread_mult": float(ad.spread_mult),
		"ads_move_mult": A.move_mult_for(ad) if A else 0.7,
		"overlay": bool(ad.overlay), "sight_picture": "overlay" if bool(ad.overlay) else "3d",
		"reticle_id": str(ob.get("reticle_id", "factory_irons")), "reticle": (ob.get("reticle", {}) as Dictionary).duplicate(true),
		"glow": (ob.get("glow", {}) as Dictionary).duplicate(true), "night": str(ob.get("night", "poor")),
		"aperture_mm": float(ob.get("aperture_mm", 0.0)),
		"replaces_irons": bool(ob.get("replaces_irons", false)) if oid != "" else false,
		"hides": _optic_hides(oid, arch) if oid != "" else [],
		"rarity": str(ob.get("rarity", "common")), "tier": int(a.get("tier", 0)), "cost": cost_of(oid) if oid != "" else 0,
		"currency": attachment_currency(), "prices": attachment_prices(oid) if oid != "" else {},
		"owned": oid == "" or owned(oid), "equipped": str(loadout(arch).get("optic", "")) == oid,
		"compatible": oid == "" or is_compatible(oid, arch), "art_status": art,
		"fallback": art == "pending", "tradeoff": str(ob.get("tradeoff", "")),
		"summary": str(a.get("summary", fac.get("summary", ""))), "description": str(a.get("description", "")),
		"drawback": str(a.get("drawback", "")), "icon": str(a.get("icon", "")) if oid != "" else ""}
	return p


## The whole lineup for one weapon, for a comparison view: optic_profile(weapon, id) for the factory sights and every
## optic that fits, each with the Armory state of that part (state / requirements / purchase_requirements / can_afford,
## same rules as list_attachments; the factory row is always "equipped" or "owned").
static func optic_choices(weapon_id: String) -> Array:
	var arch := resolve_weapon(weapon_id)
	var out := []
	for id in optic_lineup(arch):
		var p := optic_profile(arch, id)
		if id == "":
			p["state"] = "equipped" if p.equipped else "owned"
			p["requirements"] = []
			p["purchase_requirements"] = []
			p["can_afford"] = false
		else:
			var req := equip_requirements(id, arch)
			var preq := purchase_requirements(id)
			p["requirements"] = req
			p["purchase_requirements"] = preq
			p["can_afford"] = can_afford_id(id)
			p["state"] = "equipped" if p.equipped else ("owned" if p.owned and req.is_empty() else
				("locked" if not req.is_empty() or (not p.owned and not preq.is_empty()) else ("owned" if p.owned else "available")))
		out.append(p)
	return out


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
	var af: Dictionary = a.get("flags", {})
	if not (bool(af.get("mine_lamp", false)) or bool(af.get("flashlight", false))):
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

static var _last_refusal: String = "" ## why the last purchase / equip attempt was refused ("" = it went through)


## Why the last purchase()/equip()/buy_*() call was refused, "" if it succeeded (Gooey: toast text).
static func last_refusal_reason() -> String:
	return _last_refusal


static func _check(ok: bool, reason: String = "") -> Dictionary:
	return {"ok": ok, "reason": "" if ok else reason}


static func _slot_name(slot: String) -> String:
	for s in slots():
		if str(s.get("id", "")) == slot:
			return str(s.get("name", slot))
	return slot.capitalize()


## Can `id` be bought right now? id = attachment id or "upg_<arch>". {ok, reason}; reason is UI text when !ok.
## Single source of truth for buy_attachment / buy_upgrade / purchase().
static func purchase_check(id: String, currency: String = "") -> Dictionary:
	var p = prog()
	if p == null:
		return _check(false, "Save data isn't loaded")
	if id.begins_with(UPGRADE_PREFIX):
		var arch := id.substr(UPGRADE_PREFIX.length())
		if not is_archetype(arch):
			return _check(false, "Unknown weapon")
		if upgrade_tier(arch) >= max_tier():
			return _check(false, "%s is fully reworked" % weapon_type(arch))
		var c := next_upgrade_cost(arch)
		var cur := upgrade_currency()
		if balance(cur) < c:
			return _check(false, "Need %d %s (you have %d)" % [c, currency_word(cur, c), balance(cur)])
		return _check(true)
	if not is_attachment(id):
		return _check(false, "Unknown attachment")
	if owned(id):
		return _check(false, "Already owned")
	var preq := purchase_requirements(id)
	if not preq.is_empty():
		return _check(false, "Needs " + str(preq[0]))
	var cur := attachment_currency(currency)
	if cur == "":
		return _check(false, "%s can't buy that" % str(currency).capitalize())
	var cst := attachment_price(id, cur)
	if balance(cur) < cst:
		return _check(false, "Need %d %s (you have %d)" % [cst, currency_word(cur, cst), balance(cur)])
	return _check(true)


static func _currency_word(n: int) -> String:
	var c: Dictionary = cfg().get("currency", {})
	return str(c.get("name", "Gravemark")) if n == 1 else str(c.get("plural", "Gravemarks"))


## Can part `id` go on `weapon_id` (archetype id or a gear item_id) in `slot` ("" = the part's own slot)? {ok, reason}.
## Single source of truth for equip() / equip_attachment(): ownership, slot, fit, Rework tier and exclusions.
static func equip_check(weapon_id: String, slot: String, id: String) -> Dictionary:
	if prog() == null:
		return _check(false, "Save data isn't loaded")
	var arch := resolve_weapon(weapon_id)
	if arch == "":
		return _check(false, "Unknown weapon")
	if not is_attachment(id):
		return _check(false, "Unknown attachment")
	var aslot := str(attachment(id).slot)
	if slot != "" and slot != aslot:
		return _check(false, "%s goes in the %s slot" % [str(attachment(id).name), _slot_name(aslot)])
	if not owned(id):
		return _check(false, "Not owned yet")
	var req := equip_requirements(id, arch)
	if not req.is_empty():
		return _check(false, str(req[0]))
	return _check(true)


## currency "" = attachment_shop.default_currency; "scrap" / "gravemark" pay with that one (playtest 2026-10-22 #2).
static func buy_attachment(att_id: String, currency: String = "") -> bool:
	var c := purchase_check(att_id, currency) if not att_id.begins_with(UPGRADE_PREFIX) else _check(false, "Not an attachment")
	_last_refusal = str(c.reason)
	if not c.ok:
		return false
	var p = prog()
	var cur := attachment_currency(currency)
	if not _spend(cur, attachment_price(att_id, cur)):
		_last_refusal = "Purchase failed"
		return false
	p.armory.owned.append(att_id)
	p.notify_armory("purchase", att_id)
	return true


static func buy_upgrade(arch: String) -> bool:
	var c := purchase_check(UPGRADE_PREFIX + arch)
	_last_refusal = str(c.reason)
	if not c.ok:
		return false
	var p = prog()
	if not _spend(upgrade_currency(), next_upgrade_cost(arch)):
		_last_refusal = "Purchase failed"
		return false
	p.armory.upgrades[arch] = upgrade_tier(arch) + 1
	p.notify_armory("upgrade", UPGRADE_PREFIX + arch)
	return true


## Puts an owned, compatible, tier-unlocked part in its slot (replacing whatever was there). See equip_check().
static func equip(arch: String, att_id: String) -> bool:
	var c := equip_check(arch, "", att_id)
	_last_refusal = str(c.reason)
	if not c.ok:
		return false
	var p = prog()
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


static func cost_of(id: String, currency: String = "") -> int:
	if id.begins_with(UPGRADE_PREFIX):
		return next_upgrade_cost(id.substr(UPGRADE_PREFIX.length()))
	var cur := attachment_currency(currency)
	return attachment_price(id, cur if cur != "" else "gravemark")


# ================================================================== attachment shop (playtest 2026-10-22 #2, SCRAP_API.md)

static func shop_cfg() -> Dictionary:
	return cfg().get("attachment_shop", {})


## Currencies an attachment can be paid with (armory.json attachment_shop.currencies; default ["gravemark"]).
static func attachment_currencies() -> Array:
	var c: Array = shop_cfg().get("currencies", ["gravemark"])
	return c.filter(func(x): return str(x) in ["scrap", "gravemark"]).map(func(x): return str(x))


## "" -> attachment_shop.default_currency; an allowed currency -> itself; anything else -> "" (refused).
static func attachment_currency(currency: String = "") -> String:
	if currency == "":
		currency = str(shop_cfg().get("default_currency", "gravemark"))
	return currency if currency in attachment_currencies() else ""


## Attachment rarity id (common..mythic): explicit "rarity", else optic.rarity, else rarity_by_cost[cost] raised to
## tier_floor[tier], then unique parts +unique_step.
static func attachment_rarity(att_id: String) -> String:
	var a := attachment(att_id)
	if a.is_empty():
		return "common"
	if a.has("rarity"):
		return str(a.rarity)
	if a.get("optic") is Dictionary and (a.optic as Dictionary).has("rarity"):
		return str(a.optic.rarity)
	var sh := shop_cfg()
	var ids := ["common", "uncommon", "rare", "legendary", "mythic"]
	var r := ids.find(str(sh.get("rarity_by_cost", {}).get(str(int(a.get("cost", 0))), "common")))
	r = maxi(r, ids.find(str(sh.get("tier_floor", {}).get(str(int(a.get("tier", 1))), "common"))))
	if bool(a.get("unique", false)):
		r += int(sh.get("unique_step", 0))
	return ids[clampi(r, 0, 4)]


## Price of an attachment in `currency` ("scrap": attachment_shop.scrap_price[rarity]; "gravemark": attachments.json cost).
static func attachment_price(att_id: String, currency: String) -> int:
	var a := attachment(att_id)
	if a.is_empty():
		return 0
	if currency == "scrap":
		if a.has("scrap_cost"):
			return int(a.scrap_cost)
		return int(shop_cfg().get("scrap_price", {}).get(attachment_rarity(att_id), 0))
	return int(a.get("cost", 0))


## {currency: price} for every allowed currency, e.g. {"scrap": 14, "gravemark": 3}.
static func attachment_prices(att_id: String) -> Dictionary:
	var out := {}
	for c in attachment_currencies():
		out[c] = attachment_price(att_id, c)
	return out


## Scrap price list by rarity (Gooey / docs): [{rarity_id, name, scrap, salvage_ip100}].
static func attachment_price_table() -> Array:
	var out := []
	var names := ["Common", "Uncommon", "Rare", "Legendary", "Mythic"]
	var ids := ["common", "uncommon", "rare", "legendary", "mythic"]
	for i in 5:
		out.append({"rarity": i, "rarity_id": ids[i], "name": names[i], "scrap": int(shop_cfg().get("scrap_price", {}).get(ids[i], 0)),
			"salvage_ip100": scrap_yield(i, 100)})
	return out


## Salvage (scrap) payout per rarity at Item Power ip: [{rarity, rarity_id, name, scrap}] (Progress.salvage_table).
static func salvage_table(ip: int = 100) -> Array:
	var out := []
	var names := ["Common", "Uncommon", "Rare", "Legendary", "Mythic"]
	var ids := ["common", "uncommon", "rare", "legendary", "mythic"]
	for i in 5:
		out.append({"rarity": i, "rarity_id": ids[i], "name": names[i], "scrap": scrap_yield(i, ip)})
	return out


## Balance covers the cost and the item is buyable (not owned / not maxed, requirements met).
static func can_afford_id(id: String, currency: String = "") -> bool:
	var p = prog()
	if p == null:
		return false
	if id.begins_with(UPGRADE_PREFIX):
		var arch := id.substr(UPGRADE_PREFIX.length())
		return is_archetype(arch) and upgrade_tier(arch) < max_tier() and balance(upgrade_currency()) >= next_upgrade_cost(arch)
	if not is_attachment(id) or owned(id) or not purchase_requirements(id).is_empty():
		return false
	var cur := attachment_currency(currency)
	return cur != "" and balance(cur) >= attachment_price(id, cur)


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
	var paid := _zombie_payout(zombie, round_number, roll)
	if paid > 0 and zombie is Node3D and (zombie as Node3D).is_inside_tree():
		# Desi's gravemark.glb token pops out of the body and flies to the player (cosmetic, already paid).
		var z := zombie as Node3D
		load(PICKUP_SCRIPT).spawn(z.get_tree().current_scene, z.global_position, paid)
	return paid


const PICKUP_SCRIPT := "res://scripts/items/gravemark_pickup.gd"


static func _zombie_payout(zombie: Object, round_number: int = 0, roll: float = -1.0) -> int:
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


## main.gd at round clear (MAIN_HOOKS §9): the per-round trickle (sources.round, Economy v2) plus the milestone
## (amount every `every` rounds), each x drop mult. roll = test override for both rolls. Returns what was paid.
static func on_round_cleared(round_number: int, roll: float = -1.0) -> int:
	_see_round(round_number)
	if round_number <= 0:
		return 0
	var paid := 0
	var rd := src("round")
	if not rd.is_empty() and round_number >= int(rd.get("from_round", 1)):
		paid += award(roll_count(float(rd.get("amount", 0.0)), roll), "round")
	var m := src("milestone")
	var every := maxi(int(m.get("every", 10)), 1)
	if round_number % every == 0:
		paid += award(roll_count(float(m.get("amount", 1)), roll), "milestone")
	return paid


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
	var out := {"boss": 0.0, "milestone": 0.0, "round": 0.0, "chest": 0.0, "special": 0.0, "regular": 0.0, "kills": 0}
	var rd := src("round")
	var sp := src("special")
	var rg := src("regular")
	var ch := src("chest")
	var chest_p := minf(float(ch.get("chance", 0.05)) * mult, 1.0)
	var opens := float(ex.get("chest_opens_per_round", 2))
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
		if not rd.is_empty() and n >= int(rd.get("from_round", 1)):
			out["round"] += float(rd.get("amount", 0.0)) * mult
	out.chest = minf(chest_total, float(ch.get("match_max", 2)))
	out["total"] = minf(out.boss + out.milestone + out["round"] + out.chest + out.special + out.regular, float(match_cap()))
	return out


## Expected Scrap from a match of `rounds` on `diff` if the player scraps expected.scrap_share of the gear that drops
## (zombie table: kills x drop_chance x gear share; chests: chest_opens_per_round x rolls x gear share), each piece
## yielding Scrap.yield_for(rarity, typical IP of that round). {total, zombie_gear, chest_gear, per_round[]}.
static func expected_match_scrap(diff: String, rounds: int) -> Dictionary:
	var D = load(DIFFICULTY_SCRIPT)
	var ex: Dictionary = cfg().get("expected", {})
	var w: Dictionary = D.profile(diff).get("wave", {})
	var loot = JSON.parse_string(FileAccess.get_file_as_string("res://data/loot_tables.json"))
	var tables: Dictionary = loot.get("tables", {}) if typeof(loot) == TYPE_DICTIONARY else {}
	var ip_cfg: Dictionary = loot.get("item_power", {}) if typeof(loot) == TYPE_DICTIONARY else {}
	var bias := float(D.loot_rarity_bias(diff))
	var first := maxi(int(round(float(ex.get("first_round_zombies", 6)) * float(w.get("count_mult", 1.0)))), 1)
	var per := int(round(float(ex.get("zombies_per_round", 3)) * float(w.get("count_ramp_mult", 1.0))))
	var share := clampf(float(ex.get("scrap_share", 0.7)), 0.0, 1.0)
	var opens := float(ex.get("chest_opens_per_round", 0.35))
	var out := {"total": 0.0, "zombie_gear": 0.0, "chest_gear": 0.0, "per_round": []}
	for n in range(1, rounds + 1):
		var z := first + per * (n - 1)
		var ip := int(ip_cfg.get("base", 100)) + int(ip_cfg.get("per_round", 5)) * (n - 1)
		var zg := z * table_gear_rate(tables.get("zombie", {}))
		var cg := opens * table_gear_rate(tables.get("chest", {}))
		var sc := (zg * mean_yield(tables.get("zombie", {}), n, ip, bias) + cg * mean_yield(tables.get("chest", {}), n, ip, bias)) * share
		out.zombie_gear += zg
		out.chest_gear += cg
		out.total += sc
		out.per_round.append(sc)
	return out


## Expected gear pieces per roll of a loot table: drop_chance x rolls x (gear entries' weight share).
static func table_gear_rate(t: Dictionary) -> float:
	if t.is_empty():
		return 0.0
	var tot := 0.0
	var gear := 0.0
	for e in t.get("entries", []):
		tot += float(e.get("weight", 0))
		if str(e.get("kind", "")) in ["gear", "weapon", "armor"]:
			gear += float(e.get("weight", 0))
	return minf(float(t.get("drop_chance", 1.0)), 1.0) * float(t.get("rolls", 1)) * (gear / maxf(tot, 0.0001))


## Rarity odds (common..mythic, sum 1) of a loot table at round n with Difficulty bias, the same math as GearDB.roll_rarity.
static func table_rarity_odds(t: Dictionary, n: int, bias: float = 0.0) -> Array:
	var ids := ["common", "uncommon", "rare", "legendary", "mythic"]
	var ws := []
	var rw: Dictionary = t.get("rarity_weights", {})
	var rb: Dictionary = t.get("rarity_round_bonus", {})
	for id in ids:
		ws.append(float(rw.get(id, 0.0)) + float(rb.get(id, 0.0)) * maxi(n - 1, 0))
	var D = load(DIFFICULTY_SCRIPT)
	ws = D.bias_rarity_weights(ws, bias)
	var tot := 0.0
	for v in ws:
		tot += float(v)
	return ws.map(func(v): return float(v) / maxf(tot, 0.0001))


static func mean_yield(t: Dictionary, n: int, ip: int, bias: float = 0.0) -> float:
	var odds := table_rarity_odds(t, n, bias)
	var y := 0.0
	for r in odds.size():
		y += float(odds[r]) * float(scrap_yield(r, ip))
	return y


## Scrap for one piece of gear of rarity r (0..4) and Item Power ip: armory.json scrap.yield[rarity]
## + 1 per scrap.item_power_step IP above 100 (step 0 = off).
static func scrap_yield(r: int, ip: int = 100) -> int:
	var sc: Dictionary = cfg().get("scrap", {})
	var ids := ["common", "uncommon", "rare", "legendary", "mythic"]
	var base := int(sc.get("yield", {}).get(ids[clampi(r, 0, 4)], 0))
	var step := int(sc.get("item_power_step", 0))
	var extra := maxi(ip - 100, 0) / step if step > 0 else 0
	return maxi(base + extra, 0)


## Matches of `rounds` (default: armory.json expected.typical_rounds[diff]) to afford tiers I..max for ONE archetype,
## and for all 9 archetypes plus every attachment once. {per_match, tiers_to_iv, one_weapon_max, everything}.
static func matches_to_max(diff: String, rounds: int = -1, arch: String = "auto_rifle") -> Dictionary:
	if rounds <= 0:
		rounds = int(cfg().get("expected", {}).get("typical_rounds", {}).get(diff, 15))
	var inc := float(expected_match_income(diff, rounds).total)
	var up_cur := upgrade_currency()
	var up_inc := float(expected_match_scrap(diff, rounds).total) if up_cur == "scrap" else inc
	var to_iv := 0
	for t in range(1, mini(4, max_tier()) + 1):
		to_iv += tier_cost(arch, t)
	var ups := 0
	for w in weapons():
		ups += upgrade_total_cost(w.id)
	var atts := 0
	var atts_scrap := 0
	for a in data().get("attachments", []):
		atts += int(a.get("cost", 0))
		atts_scrap += attachment_price(str(a.id), "scrap")
	var gm_all := atts + (ups if up_cur == "gravemark" else 0)
	return {"rounds": rounds, "per_match": inc, "scrap_per_match": up_inc if up_cur == "scrap" else 0.0,
		"upgrade_currency": up_cur, "tiers_to_iv": ceilf(to_iv / maxf(up_inc, 0.01)),
		"one_weapon_max": ceilf(upgrade_total_cost(arch) / maxf(up_inc, 0.01)),
		"all_upgrades": ceilf(ups / maxf(up_inc, 0.01)), "upgrades_cost": ups,
		"everything": maxf(ceilf(gm_all / maxf(inc, 0.01)), ceilf(ups / maxf(up_inc, 0.01))),
		"everything_cost": gm_all, "attachments_cost": atts, "attachments": ceilf(atts / maxf(inc, 0.01)),
		"attachments_scrap_cost": atts_scrap, "attachments_in_scrap": ceilf(atts_scrap / maxf(float(expected_match_scrap(diff, rounds).total), 0.01))}


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
			tl.append({"tier": t, "name": str(td.get("name", t)), "cost": tier_cost(arch, t), "currency": upgrade_currency(),
				"summary": str(td.get("summary", "")), "item_power": int(td.get("item_power", 0))})
		var tpl := str(cfg().get("upgrades", {}).get("name_template", "{type} Rework"))
		out.append({"id": UPGRADE_PREFIX + arch, "name": tpl.replace("{type}", weapon_type(arch)),
			"summary": "Fully upgraded." if maxed else str(tiers()[lvl].get("summary", "")),
			"cost": 0 if maxed else next_upgrade_cost(arch), "currency": upgrade_currency(), "level": lvl, "current_level": lvl, "max_level": max_tier(),
			"owned": lvl > 0, "maxed": maxed, "slot": "upgrade", "category": "weapon", "weapon_id": arch,
			"tier_name": tier_name(lvl), "next_tier_name": "" if maxed else tier_name(lvl + 1), "tiers": tl,
			"item_power_bonus": power_bonus(arch), "requirements": [], "can_afford": can_afford_id(UPGRADE_PREFIX + arch),
			"state": "maxed" if maxed else "available"})
	return out


## Parts that fit `weapon_id` (optionally one slot). Entry: id, name, summary, description, drawback, cost, owned,
## equipped (on this weapon), slot, tier, unique, icon, model, requirements (unmet, to equip here: tier gates and
## exclusion text), conflict (Armory.exclusion_conflict: {} or {rule, with, with_name, reason}),
## purchase_requirements (unmet, to buy), can_afford, state: "equipped" | "owned" | "locked" (requirements) | "available",
## optic (optic-slot parts only: Armory.optic_profile(weapon, id), the zoom / ADS time / reticle preview; {} otherwise).
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
			"drawback": str(a.get("drawback", "")), "cost": cost_of(id), "owned": own, "equipped": eq,
			# playtest 2026-10-22 #2: Scrap or Gravemark. currency = what cost / purchase(id) use; prices = every option.
			"currency": attachment_currency(), "rarity": attachment_rarity(id), "prices": attachment_prices(id),
			"scrap_cost": attachment_price(id, "scrap"), "gravemark_cost": int(a.cost),
			"can_afford_scrap": can_afford_id(id, "scrap"), "can_afford_gravemark": can_afford_id(id, "gravemark"),
			"slot": str(a.slot), "tier": int(a.get("tier", 1)), "unique": bool(a.get("unique", false)),
			"icon": str(a.get("icon", id)), "model": str(a.get("model", "")), "weapon_id": arch,
			"requirements": req, "purchase_requirements": preq, "can_afford": can_afford_id(id),
			"conflict": exclusion_conflict(id, arch),
			"optic": optic_profile(arch, id) if str(a.slot) == "optic" else {},
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
	var c := purchase_check(id)
	_last_refusal = str(c.reason)
	if not c.ok:
		return false
	if id.begins_with(UPGRADE_PREFIX):
		return buy_upgrade(id.substr(UPGRADE_PREFIX.length()))
	return buy_attachment(id)


## Buys attachment `id` paying in `currency` ("scrap" / "gravemark"); upgrades ignore it (they use upgrade_currency()).
func purchase_with(id: String, currency: String) -> bool:
	if id.begins_with(UPGRADE_PREFIX):
		return purchase(id)
	var c := purchase_check(id, currency)
	_last_refusal = str(c.reason)
	if not c.ok:
		return false
	return buy_attachment(id, currency)


func cost_in(id: String, currency: String) -> int:
	return attachment_price(id, currency) if not id.begins_with(UPGRADE_PREFIX) else cost_of(id)


## Gooey's placeholder signature. `slot` must match the part's slot ("" = take it from the part).
func equip_attachment(weapon_id: String, slot: String, id: String) -> bool:
	var c := equip_check(weapon_id, slot, id)
	_last_refusal = str(c.reason)
	if not c.ok:
		return false
	return equip(resolve_weapon(weapon_id), id)


func unequip(weapon_id: String, slot: String) -> bool:
	return unequip_slot(resolve_weapon(weapon_id), slot)


## Optics pass: the lineup for Gooey's optic picker (same as the static optic_choices).
func list_optics(weapon_id: String) -> Array:
	return optic_choices(weapon_id)
