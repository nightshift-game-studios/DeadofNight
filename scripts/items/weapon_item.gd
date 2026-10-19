class_name WeaponItem
extends GearItem
## A rolled weapon. `arch` is its archetype entry from data/weapons.json; the rolled
## stats (0-100) scale the archetype's base numbers. Runtime state (ammo, perk buffs)
## lives on the instance.

var arch: Dictionary = {}
var element: String = "ballistic" ## ballistic / volt / blaze / blight
var ammo: int = -1
var reserve: int = 0
var buffs: Dictionary = {} ## perk runtime state, see PerkSystem
## Magazine bonus from skills (Deep Pockets), set by player.recalc_stats(); 0.3 = +30%. Shared by all weapons.
const ARMORY_SCRIPT := "res://scripts/armory/armory.gd" ## loaded lazily (no compile cycle with GearDB / Progress)
const MAG_BONUS_META := &"skill_mag_bonus" ## Engine meta set by player.recalc_stats (Field Card mag_size_mult - 1); no static var (those keep scripts alive at exit)


func _init() -> void:
	super._init()
	type = ItemType.WEAPON


func type_name() -> String:
	return arch.get("type", "Weapon")


func stat(n: String) -> float:
	return float(stats.get(n, 50))


func init_ammo() -> void:
	if ammo < 0:
		ammo = mag_size()
		reserve = max_reserve() if slot != "heavy" else mag_size() * 2


## Armory (Skillz): this archetype's upgrade-tier + attachment multipliers (data/attachments.json, data/armory.json).
## Identity values ({*_mult: 1, *_add: 0, item_power_bonus: 0}) when nothing is bought or Progress is missing.
func armory_mods() -> Dictionary:
	var A = load(ARMORY_SCRIPT)
	return A.weapon_mods(archetype) if A else {}


func amod(key: String, fallback: float = 1.0) -> float:
	return float(armory_mods().get(key, fallback))


## Rolled Item Power + the archetype's Armory upgrade bonus. Damage uses this; tiles/cards may show both.
func effective_item_power() -> int:
	return item_power + int(amod("item_power_bonus", 0.0))


## Item Power damage multiplier: 1 + (IP - 100) * damage_per_point (IP = effective_item_power()).
func power_mult() -> float:
	return 1.0 + (effective_item_power() - 100) * float(GearDB.item_power_cfg().get("damage_per_point", 0.004))

## Precision (head) hit multiplier: archetype "headshot_multiplier" in data/weapons.json,
## falling back to the file's "headshot_multiplier_default" (2.0).
func headshot_mult() -> float:
	return float(arch.get("headshot_multiplier", GearDB.headshot_default)) + amod("headshot_add", 0.0)

func damage() -> float:
	return float(arch.get("base_damage", 20)) * (0.7 + stat("impact") * 0.006) * power_mult() * amod("damage_mult")

func rpm() -> float:
	return float(arch.get("rpm", 300)) * amod("rpm_mult")

func fire_interval() -> float:
	return 60.0 / max(rpm(), 1.0)

func automatic() -> bool:
	return arch.get("fire_mode", "semi") == "auto"

func pellets() -> int:
	var base := int(arch.get("pellets", 1))
	return base if base <= 1 else maxi(base + int(amod("pellets_add", 0.0)), 1)

func mag_size() -> int:
	return max(1, int(round(float(arch.get("base_mag", 10)) * (0.7 + stat("magazine") * 0.006) * (1.0 + float(Engine.get_meta(MAG_BONUS_META, 0.0))) * amod("mag_mult"))))

func max_reserve() -> int:
	return mag_size() * maxi(int(arch.get("reserve_mags", 5)) + int(amod("reserve_mags_add", 0.0)), 1)

func reload_time() -> float:
	return float(arch.get("base_reload", 1.5)) * (1.35 - stat("reload") * 0.007) * amod("reload_mult")

func swap_time() -> float:
	return clampf((0.6 - stat("handling") * 0.004) * amod("swap_mult"), 0.1, 0.8)

func falloff_start() -> float:
	return float(arch.get("base_range", 20)) * (0.6 + stat("range") * 0.008) * amod("range_mult")

func spread_deg() -> float:
	return float(arch.get("spread", 0.5)) * (1.4 - stat("stability") * 0.008) * amod("spread_mult")

func recoil() -> float:
	return 0.09 * (1.5 - stat("stability") * 0.01) * amod("recoil_mult")

func is_projectile() -> bool:
	return arch.has("projectile")

## Damage multiplier for distance (full until falloff_start, down to 50% at 2x).
func falloff(dist: float) -> float:
	var s := falloff_start()
	if dist <= s:
		return 1.0
	return clampf(1.0 - 0.5 * (dist - s) / s, 0.5, 1.0)


## Stats shown as bars in the tooltip (name, value 0-100).
func display_stats() -> Array:
	return [["Impact", stat("impact")], ["Range", stat("range")], ["Stability", stat("stability")],
		["Handling", stat("handling")], ["Reload Speed", stat("reload")]]


## Stats shown as plain numbers.
func display_numbers() -> Array:
	return [["Magazine", mag_size()], ["Rounds Per Minute", int(rpm())]]


## Accuracy 0-100 derived from spread (shotguns use their pellet spread).
func accuracy() -> float:
	return clampf(100.0 - spread_deg() * 9.0, 5.0, 99.0)


## Item-card stat block: [label, display text, bar fraction 0-1, raw value, higher_is_better].
## Used for the big numbers and for comparing against the equipped weapon.
func card_stats() -> Array:
	var pel := pellets()
	var dmg_txt := "%d" % roundi(damage()) + (" x%d" % pel if pel > 1 else "")
	var dmg_total := damage() * pel
	return [
		["Damage", dmg_txt, clampf(dmg_total / 400.0, 0.03, 1.0), dmg_total, true],
		["Accuracy", "%d%%" % roundi(accuracy()), accuracy() / 100.0, accuracy(), true],
		["Handling", "%d" % roundi(stat("handling")), stat("handling") / 100.0, stat("handling"), true],
		["Reload Time", "%.1fs" % reload_time(), clampf(1.0 - reload_time() / 4.5, 0.03, 1.0), reload_time(), false],
		["Fire Rate", "%.1f/s" % (rpm() / 60.0), clampf(rpm() / 900.0, 0.03, 1.0), rpm() / 60.0, true],
		["Magazine", "%d" % mag_size(), clampf(mag_size() / 60.0, 0.03, 1.0), float(mag_size()), true],
	]


func get_summary() -> String:
	return "%s %s  |  %s" % [rarity_name(), type_name(), manufacturer]


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["class"] = "weapon"
	d["element"] = element
	return d
