class_name NetAvatarBody
extends Node3D
## Adapter between NetRemoteAvatar and whatever third-person body it shows (Netz). Swapping the body means a new
## subclass (or data/net.json avatar.body), not touching the avatar / netcode. Implementations:
##   NetDesiBody    - Desi's rigged Gravecrew player.glb + an AnimationTree built from NETZ_NOTES (default)
##   NetCapsuleBody - placeholder capsule (tests, missing asset)
## Only state and event triggers come over the wire; every client animates its own copy.

## Reload / throw timing marks (data/net.json avatar.*): "mag_out", "mag_out_done", "mag_in", "slap", "throw_release", "throw_done".
signal marker(name: String)

const LIFE_ALIVE := "alive"
const LIFE_DOWNED := "downed"
const LIFE_REVIVING := "reviving"
const LIFE_DEAD := "dead"

var slot := 0
var weapon_id := ""
var life := LIFE_ALIVE
var ads := false
var airborne := false
var speed := 0.0
var crouch := 0.0
var pitch := 0.0
var _marks: Array = [] ## [[seconds_left, name], ...]


## Party slot 0..3 -> tint preset (P1 orange, P2 yellow, P3 cyan, P4 magenta).
func set_slot(s: int) -> void:
	slot = clampi(s, 0, 3)
	_apply_tint(tint_for(slot))


static func tint_for(s: int) -> Color:
	var t: Array = NetConfig.get_value("avatar.tints", ["#D9601F", "#C9D12B", "#1E9FC8", "#C2307A"])
	return Color(str(t[clampi(s, 0, t.size() - 1)]))


## Weapon archetype id (data/weapons.json) shown in the right-hand socket; "" = empty hands.
func set_weapon(arch_id: String) -> void:
	if arch_id == weapon_id:
		return
	weapon_id = arch_id
	_apply_weapon(arch_id)


## Continuous state (already interpolated by the avatar): speed m/s, crouch 0..1, airborne, ads, aim pitch (rad).
func apply_state(s: Dictionary) -> void:
	var was_air := airborne
	speed = float(s.get("speed", speed))
	crouch = float(s.get("crouch", crouch))
	airborne = bool(s.get("airborne", airborne))
	ads = bool(s.get("ads", ads))
	pitch = float(s.get("pitch", pitch))
	if was_air and not airborne:
		trigger("land")
	elif airborne and not was_air:
		_on_air_start()
	_apply_state()


## Full-body override: alive / downed / reviving (this player is reviving someone) / dead.
func set_life(state: String) -> void:
	if state == life:
		return
	var prev := life
	life = state
	_apply_life(prev, state)


## One-shot events: fire, reload {time}, throw, jump, land, hit.
func trigger(event_id: String, data: Dictionary = {}) -> void:
	match event_id:
		"reload":
			var t := maxf(float(data.get("time", reload_clip_len())), 0.1)
			var k := t / reload_clip_len()
			_marks = [[mark("mag_out_start") * k, "mag_out"], [mark("mag_out_end") * k, "mag_out_done"],
				[mark("mag_in") * k, "mag_in"], [mark("slap") * k, "slap"]]
		"throw":
			_marks.append([float(NetConfig.get_value("avatar.throw_release_s", 0.33)), "throw_release"])
			_marks.append([float(NetConfig.get_value("avatar.throw_clip_len_s", 1.333)), "throw_done"]) # rifle back in the hands
	_trigger(event_id, data)


static func mark(key: String) -> float:
	return float(NetConfig.get_value("avatar.reload_marks_s." + key, 0.0))


static func reload_clip_len() -> float:
	return float(NetConfig.get_value("avatar.reload_marks_s.clip_len", 2.167))


## Where the name tag rides (head bone socket on the real body).
func name_tag_anchor() -> Node3D:
	return self


## Tests / debug: the upper-body state ("Hold_Rifle" / "ADS_Aim") and the active override.
func upper_state() -> String:
	return "ADS_Aim" if ads else "Hold_Rifle"


func _process(delta: float) -> void:
	if _marks.is_empty():
		return
	var fired: Array = []
	for m in _marks:
		m[0] -= delta
		if m[0] <= 0.0:
			fired.append(m)
	for m in fired:
		_marks.erase(m)
		_on_marker(m[1])
		marker.emit(m[1])


# ---- overridables
func _apply_tint(_c: Color) -> void: pass
func _apply_weapon(_arch_id: String) -> void: pass
func _apply_state() -> void: pass
func _apply_life(_prev: String, _state: String) -> void: pass
func _trigger(_event_id: String, _data: Dictionary) -> void: pass
func _on_air_start() -> void: pass
func _on_marker(_name: String) -> void: pass


## Shared helper: the 3P gun model for an archetype id, or null.
static func weapon_model(arch_id: String) -> Node3D:
	if arch_id == "":
		return null
	var gdb := (Engine.get_main_loop() as SceneTree).root.get_node_or_null("GearDB") if Engine.get_main_loop() is SceneTree else null
	var a: Dictionary = gdb.weapons.get(arch_id, {}) if gdb else {}
	var path := str(a.get("model", ""))
	if path == "" or not ResourceLoader.exists(path):
		return null
	return (load(path) as PackedScene).instantiate() as Node3D
