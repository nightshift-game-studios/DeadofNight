class_name AdsProfile
extends RefCounted
## Pure ADS tables + mode resolution (Skillz). player.gd reads these; tests cover them without a player.
## Hip FOV defaults to Settings.fov (75). ADS FOV is per weapon family. Spread/move mult apply while ads_active.

const HIP_FOV := 75.0
const SPREAD_MULT := 0.45
const MOVE_SPEED_MULT := 0.7
const INPUT_ACTION := "ads" ## project.godot / Settings also expose "aim" on RMB; prefer ads, fall back to aim
const FALLBACK_ACTION := "aim"
const ARMORY_SCRIPT := "res://scripts/armory/armory.gd"

## Armory attachments (Skillz): optics set the ADS FOV (narrowest of family / optic wins), grips/stocks/optics scale the
## ADS move and spread penalties, some parts change hip-fire spread. Every call takes an optional archetype; when it's
## omitted, the archetype last passed to target_fov() (player.gd calls it every physics frame) is used, so the existing
## player.gd hooks pick up attachments without changes.
static var _last_arch: String = ""


static func _arm(archetype_id: String) -> Dictionary:
	var a := archetype_id if archetype_id != "" else _last_arch
	if a == "":
		return {}
	var A = load(ARMORY_SCRIPT)
	return A.ads_mods(a) if A else {}


static func _hip(archetype_id: String) -> float:
	var a := archetype_id if archetype_id != "" else _last_arch
	if a == "":
		return 1.0
	var A = load(ARMORY_SCRIPT)
	return float(A.mod(a, "hip_spread_mult", 1.0)) if A else 1.0

## Family -> ADS FOV. sidearm/smg 65, rifle 55, shotgun 60, sniper 35.
const FOV_BY_FAMILY := {
	"sidearm": 65.0,
	"smg": 65.0,
	"rifle": 55.0,
	"shotgun": 60.0,
	"sniper": 35.0,
	"heavy": 55.0,
}

## Archetype id -> family (weapons.json ids).
const ARCHETYPE_FAMILY := {
	"sidearm": "sidearm",
	"hand_cannon": "sidearm",
	"smg": "smg",
	"shotgun": "shotgun",
	"sniper_rifle": "sniper",
	"auto_rifle": "rifle",
	"scout_rifle": "rifle",
	"pulse_rifle": "rifle",
	"rocket_launcher": "heavy",
}


static func family_for_archetype(archetype_id: String) -> String:
	return str(ARCHETYPE_FAMILY.get(archetype_id, "rifle"))


static func ads_fov(archetype_id: String, _hip_fov: float = HIP_FOV) -> float:
	var fam := family_for_archetype(archetype_id)
	var f := float(FOV_BY_FAMILY.get(fam, 55.0))
	var optic := float(_arm(archetype_id).get("fov", 0.0)) if archetype_id != "" else 0.0
	return minf(f, optic) if optic > 0.0 else f


## ADS: SPREAD_MULT x attachment ads.spread_mult. Hip: attachment hip_spread_mult (1.0 without parts).
static func spread_mult(ads_active: bool, archetype_id: String = "") -> float:
	if ads_active:
		return SPREAD_MULT * float(_arm(archetype_id).get("spread_mult", 1.0))
	return _hip(archetype_id)


## ADS: the move penalty (1 - MOVE_SPEED_MULT) divided by attachment ads.move_mult (Lean Grip 1.3 = a third less
## penalty; Longwatch 0.75 = more). Clamped to 0.4..1.0. Hip: 1.0.
static func move_speed_mult(ads_active: bool, archetype_id: String = "") -> float:
	if not ads_active:
		return 1.0
	var m := maxf(float(_arm(archetype_id).get("move_mult", 1.0)), 0.05)
	return clampf(1.0 - (1.0 - MOVE_SPEED_MULT) / m, 0.4, 1.0)


static func target_fov(ads_active: bool, archetype_id: String, hip_fov: float = HIP_FOV) -> float:
	_last_arch = archetype_id
	return ads_fov(archetype_id, hip_fov) if ads_active else hip_fov


## Settings.ads_mode is "hold"|"toggle"; missing Settings -> "hold".
static func resolve_mode(settings: Variant = null) -> String:
	if settings == null:
		return "hold"
	var m := ""
	if settings is Object and settings.has_method("get_ads_mode"):
		m = str(settings.call("get_ads_mode"))
	elif settings is Dictionary:
		m = str(settings.get("ads_mode", "hold"))
	elif settings is Object and "ads_mode" in settings:
		m = str(settings.get("ads_mode"))
	return m if m in ["hold", "toggle"] else "hold"


## Hold: ads while pressed. Toggle: flip on just_pressed.
static func next_ads_state(was_ads: bool, mode: String, pressed: bool, just_pressed: bool) -> bool:
	if mode == "toggle":
		if just_pressed:
			return not was_ads
		return was_ads
	return pressed


## Which InputMap action to read (ads if registered, else aim).
static func input_action() -> String:
	if InputMap.has_action(INPUT_ACTION):
		return INPUT_ACTION
	if InputMap.has_action(FALLBACK_ACTION):
		return FALLBACK_ACTION
	return INPUT_ACTION


## Sniper family needs Gooey's scope overlay when ADS.
static func wants_scope_overlay(archetype_id: String) -> bool:
	if family_for_archetype(archetype_id) == "sniper":
		return true
	var A = load(ARMORY_SCRIPT)
	return A != null and bool(A.flag(archetype_id, "scope_overlay", false)) # Longwatch 6x on a Scout Rifle
