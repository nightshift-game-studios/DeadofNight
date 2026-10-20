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


## Optics pass (DESIGN.md §19): the class iron-sight FOV x the optic's fov_mult (iron variants), then the narrowest of
## that and the optic's own ADS FOV (magnified glass / dots: Armory ads.fov, from the true magnification). A sniper whose
## built-in scope is replaced (an optic that hides DefaultOptic: irons, dots, 2x/3x) aims from SNIPER_IRONS_FOV instead of
## the scope's 35.
static func ads_fov(archetype_id: String, _hip_fov: float = HIP_FOV) -> float:
	return merge_fov(archetype_id, _arm(archetype_id) if archetype_id != "" else {})


const SNIPER_IRONS_FOV := 55.0 ## sniper family without its built-in scope (rifle irons FOV)


## Class (family) ADS FOV for this build before the optic: FOV_BY_FAMILY, or SNIPER_IRONS_FOV for a de-scoped sniper.
static func class_fov(archetype_id: String, ads: Dictionary = {}) -> float:
	var fam := family_for_archetype(archetype_id)
	if fam == "sniper" and bool(ads.get("scope_replaced", false)):
		return SNIPER_IRONS_FOV
	return float(FOV_BY_FAMILY.get(fam, 55.0))


## Pure merge (tests + Armory.optic_profile previews): min(class_fov x fov_mult, optic fov). An optic's ads.fov is a
## ceiling, never a widening: Lamplight's 60 tightens the 65 sidearm/SMG view and the 60.. shotgun view stays, but a rifle
## (55), heavy (55) or de-scoped sniper (SNIPER_IRONS_FOV 55) keeps 55. DESIGN.md §19 "FOV rule".
static func merge_fov(archetype_id: String, ads: Dictionary) -> float:
	var f := class_fov(archetype_id, ads) * float(ads.get("fov_mult", 1.0))
	var optic := float(ads.get("fov", 0.0))
	return clampf(minf(f, optic) if optic > 0.0 else f, 5.0, HIP_FOV + 15.0)


## True magnification of an ADS FOV against the hip view: tan(hip/2) / tan(fov/2) (Crow's Eye 28.7 -> 3.0x).
static func true_magnification(fov: float, hip_fov: float = HIP_FOV) -> float:
	return tan(deg_to_rad(hip_fov) * 0.5) / tan(deg_to_rad(maxf(fov, 1.0)) * 0.5)


# ------------------------------------------------------------------ ADS time + sway (optics pass)
## Time to fully aim (s) per family before parts (x the merged ads_time_mult). Rifle 0.25 matches the old fixed
## 12/s FOV lerp (95% in ~0.25 s), so a rifle with factory irons feels the same once MAIN_HOOKS §18 lands.
const ADS_TIME_BY_FAMILY := {
	"sidearm": 0.18,
	"smg": 0.2,
	"rifle": 0.25,
	"shotgun": 0.22,
	"sniper": 0.3,
	"heavy": 0.3,
}
const ADS_OUT_MULT := 0.8 ## leaving ADS is quicker than entering it
const VIEW_LERP_RATE := 20.0 ## player.gd gun-pose lerp at the 0.25 s reference ADS time
const ADS_TIME_REF := 0.25
## Sway (merged sway_mult, 1 = the class default): moving while aimed widens ADS spread by
## 1 + SWAY_MOVE_SPREAD x (sway - 1) x moving (0..1 of walk speed), so steadier sights are better on the move and
## high zoom is worse. Standing still: no change. Also scales the 3D view drift and Gooey's overlay drift.
const SWAY_MOVE_SPREAD := 0.6
const SWAY_VIEW_M := 0.0009 ## 3D viewmodel drift amplitude (camera-space m) at sway 1 while moving
const SWAY_STILL_MULT := 0.35
const SWAY_CROUCH_MULT := 0.6
const OVERLAY_SWAY := 0.006 ## Gooey's ScopeOverlay.sway_amount default (fraction of the short side) at sway 1


static func ads_time_for(archetype_id: String, ads: Dictionary) -> float:
	var base := float(ADS_TIME_BY_FAMILY.get(family_for_archetype(archetype_id), ADS_TIME_REF))
	return clampf(base * float(ads.get("ads_time_mult", 1.0)), 0.08, 0.9)


static func ads_time(archetype_id: String = "") -> float:
	var a := archetype_id if archetype_id != "" else _last_arch
	return ads_time_for(a, _arm(a))


static func sway_mult(archetype_id: String = "") -> float:
	return float(_arm(archetype_id).get("sway_mult", 1.0))


## ADS move speed for an ads dict (same formula as move_speed_mult(true)).
static func move_mult_for(ads: Dictionary) -> float:
	var m := maxf(float(ads.get("move_mult", 1.0)), 0.05)
	return clampf(1.0 - (1.0 - MOVE_SPEED_MULT) / m, 0.4, 1.0)


## ADS blend 0 (hip) .. 1 (fully aimed), stepped each frame by player.gd (§18): in over ads_time, out over x0.8.
static func step_blend(blend: float, ads_on: bool, delta: float, archetype_id: String = "") -> float:
	var t := ads_time(archetype_id)
	if ads_on:
		return move_toward(blend, 1.0, delta / t)
	return move_toward(blend, 0.0, delta / (t * ADS_OUT_MULT))


## Camera FOV at a blend (smoothstep between hip and ADS FOV).
static func blend_fov(blend: float, archetype_id: String, hip_fov: float = HIP_FOV) -> float:
	return lerpf(hip_fov, ads_fov(archetype_id, hip_fov), smoothstep(0.0, 1.0, clampf(blend, 0.0, 1.0)))


## Spread multiplier at a blend: hip (hip_spread_mult) -> ADS (SPREAD_MULT x spread_mult x the sway-on-the-move term).
static func aim_spread_mult(blend: float, archetype_id: String = "", moving: float = 0.0) -> float:
	var b := clampf(blend, 0.0, 1.0)
	var ads := spread_mult(true, archetype_id) * sway_spread_mult(archetype_id, moving)
	return lerpf(spread_mult(false, archetype_id), ads, b)


## 1 + SWAY_MOVE_SPREAD x (sway - 1) x moving, floored at 0.7.
static func sway_spread_mult(archetype_id: String = "", moving: float = 0.0) -> float:
	return maxf(1.0 + SWAY_MOVE_SPREAD * (sway_mult(archetype_id) - 1.0) * clampf(moving, 0.0, 1.0), 0.7)


## Gun-pose lerp rate while entering / leaving ADS (player._update_view), scaled so the pose lands in ~ads_time.
static func view_lerp_rate(archetype_id: String = "") -> float:
	return VIEW_LERP_RATE * ADS_TIME_REF / ads_time(archetype_id)


## Breathing drift of the 3D viewmodel while aimed (camera space, metres): a slow figure-eight, x sway, bigger on the
## move, smaller crouched. Visual only (hits stay at the screen centre), like Gooey's overlay sway.
static func ads_sway_offset(t: float, archetype_id: String = "", moving: float = 0.0, crouched: bool = false) -> Vector3:
	var amp := SWAY_VIEW_M * sway_mult(archetype_id) * lerpf(SWAY_STILL_MULT, 1.0, clampf(moving, 0.0, 1.0))
	if crouched:
		amp *= SWAY_CROUCH_MULT
	return Vector3(sin(t * 1.1) * amp, sin(t * 2.2) * amp * 0.5, 0.0)


## Gooey's overlay drift for this build: ScopeOverlay.sway_amount default x sway_mult.
static func overlay_sway(archetype_id: String = "") -> float:
	return OVERLAY_SWAY * sway_mult(archetype_id)


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


## ADS view-model pose (Skillz art pass 2, MAIN_HOOKS §14): while aiming, the Gun node moves so the weapon's sight line
## (WeaponRig.sight_line: optic SightPoint > the gun's SightPoint, e.g. the revolver's y 0.0793 notch line) sits on the
## camera's optical axis, EYE distance in front of the camera. Camera-space metres (view models are ~0.3-0.8 m long).
const EYE_DIST_BY_FAMILY := {
	"sidearm": 0.24,
	"smg": 0.17,
	"rifle": 0.16,
	"shotgun": 0.17,
	"sniper": 0.12,
	"heavy": 0.2,
}
const ADS_BOB_MULT := 0.2 ## view bob scale while aiming


static func ads_eye_distance(archetype_id: String) -> float:
	return float(EYE_DIST_BY_FAMILY.get(family_for_archetype(archetype_id), 0.16))


## Gun node position (camera space, Gun rotation 0) that puts `sight_in_gun` (the sight line point in the Gun node's
## local space, WeaponRig.ads_offset) at (0, 0, -eye) on the screen centre.
static func ads_gun_position(sight_in_gun: Vector3, archetype_id: String) -> Vector3:
	return Vector3(0.0, 0.0, -ads_eye_distance(archetype_id)) - sight_in_gun


## Gooey's 2D scope overlay while ADS: the sniper's built-in scope (no optic, or one that keeps DefaultOptic) or a
## high-zoom optic (4x and up: Longwatch 6x, Belfry 8x; flags.scope_overlay). A sniper wearing irons, a dot or a
## 2x/3x prism aims through the 3D sight picture instead (optics pass).
static func wants_scope_overlay(archetype_id: String) -> bool:
	var A = load(ARMORY_SCRIPT)
	if A == null:
		return family_for_archetype(archetype_id) == "sniper"
	return bool(A.ads_mods(archetype_id).get("overlay", family_for_archetype(archetype_id) == "sniper"))
