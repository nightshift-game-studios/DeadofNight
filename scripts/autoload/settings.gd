extends Node
## Game settings (Gooey). Register as autoload "Settings" in project.godot when G4M3N can edit it.
## Until then, call SettingsScript.get_or_create(node) (or the same helper on this script) so tests and
## menus still work: if /root/Settings is missing, a Node is created under the root.
## Persist path: user://settings.cfg. apply() runs on _ready and after every change.

signal changed(key: String) ## any field; key is the setting name ("fullscreen", "ads_mode", "bind:jump", ...)
signal bindings_changed

const SAVE_PATH := "user://settings.cfg"
const SECTION := "settings"
const BIND_SECTION := "bindings"

## Buses we expose (Master always; others created by Sfx.ensure_buses if missing).
const AUDIO_BUSES := ["Master", "Music", "SFX", "UI", "Ambience"]

## InputMap actions the Controls tab rebinds (real project.godot names).
const BINDABLE := [
	"move_forward", "move_back", "move_left", "move_right",
	"sprint", "crouch", "jump",
	"shoot", "ads", ## ADS action (RMB); migrated from legacy "aim" in settings.cfg
	"reload", "grenade", "melee", "ability", "interact",
	"weapon_1", "weapon_2", "weapon_3",
	"inventory", "skill_tree", "map_next",
]

const BIND_LABELS := {
	"move_forward": "Move Forward", "move_back": "Move Back", "move_left": "Move Left", "move_right": "Move Right",
	"sprint": "Sprint", "crouch": "Slide / Crouch", "jump": "Jump",
	"shoot": "Fire", "ads": "Aim Down Sights", "reload": "Reload",
	"grenade": "Grenade", "melee": "Melee", "ability": "Ability", "interact": "Interact",
	"weapon_1": "Weapon 1", "weapon_2": "Weapon 2", "weapon_3": "Weapon 3",
	"inventory": "Loadout", "skill_tree": "Skills", "map_next": "Map",
}

const DEFAULTS := {
	"fullscreen": false,
	"vsync": true,
	"vol_Master": 1.0,
	"vol_Music": 0.355, ## ~-9 dB (matches default_bus_layout / Sfx.BUS_DEFAULTS)
	"vol_SFX": 1.0,
	"vol_UI": 0.631, ## ~-4 dB
	"vol_Ambience": 0.251, ## ~-12 dB — must stay quiet for the smoke ambience check
	"mouse_sensitivity": 0.0025,
	"invert_y": false,
	"fov": 75.0,
	"ads_mode": "hold", ## "hold" | "toggle" — Skillz ADS reads Settings.ads_mode
	"motion_blur": false, ## no blur effect ships yet; future camera/post blur should check Settings.motion_blur
}

var fullscreen: bool = false
var vsync: bool = true
var vol_Master: float = 1.0
var vol_Music: float = 0.355
var vol_SFX: float = 1.0
var vol_UI: float = 0.631
var vol_Ambience: float = 0.251
var mouse_sensitivity: float = 0.0025
var invert_y: bool = false
var fov: float = 75.0
## ADS input mode for Skillz: "hold" (RMB down = aim) or "toggle" (RMB flips aim).
var ads_mode: String = "hold"
## Master switch for any future motion-blur camera / post effect. Default off; nothing reads it yet.
var motion_blur: bool = false
## Co-op profile name (lobby, party HUD, name tags). "" = never set -> home shows the first-launch name prompt.
## Netz's Net.set_local_profile reads / persists this key ("player_name"). Not touched by reset_to_defaults.
var player_name: String = ""
const NAME_MIN := 2
const NAME_MAX := 16
const NAME_ALLOWED := "letters, numbers, spaces and _ - ."
## settings.cfg location; tests point this at their own file.
var save_path: String = SAVE_PATH

var _defaults_events: Dictionary = {} ## action -> Array[InputEvent] captured at first apply
var _ready_done: bool = false


## Resolve the Settings node: prefer the autoload, else create one under /root (name "Settings").
static func get_or_create(from: Node) -> Node:
	var root := from.get_tree().root
	var s := root.get_node_or_null("Settings")
	if s != null:
		return s
	var script: GDScript = load("res://scripts/autoload/settings.gd") as GDScript
	s = script.new()
	s.name = "Settings"
	root.add_child(s)
	return s


func _ready() -> void:
	_ensure_ads_action()
	_snapshot_default_binds()
	load_from_disk()
	apply_all()
	_ready_done = true


## ADS reads InputMap action "ads". Create it with RMB if missing.
func _ensure_ads_action() -> void:
	if not InputMap.has_action("ads"):
		InputMap.add_action("ads")
		var mb := InputEventMouseButton.new()
		mb.button_index = MOUSE_BUTTON_RIGHT
		InputMap.action_add_event("ads", mb)
	# Legacy "aim" action: leave in InputMap if present but drop from BINDABLE; migration copies binds to ads.


func _snapshot_default_binds() -> void:
	if not _defaults_events.is_empty():
		return
	for a in BINDABLE:
		if not InputMap.has_action(a):
			continue
		_defaults_events[a] = InputMap.action_get_events(a).duplicate(true)


# ---------------------------------------------------------------- persist

func load_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) != OK:
		_reset_values_only()
		return
	fullscreen = bool(cfg.get_value(SECTION, "fullscreen", DEFAULTS.fullscreen))
	vsync = bool(cfg.get_value(SECTION, "vsync", DEFAULTS.vsync))
	for b in AUDIO_BUSES:
		set("vol_" + b, clampf(float(cfg.get_value(SECTION, "vol_" + b, DEFAULTS["vol_" + b])), 0.0, 1.0))
	mouse_sensitivity = clampf(float(cfg.get_value(SECTION, "mouse_sensitivity", DEFAULTS.mouse_sensitivity)), 0.0005, 0.02)
	invert_y = bool(cfg.get_value(SECTION, "invert_y", DEFAULTS.invert_y))
	fov = clampf(float(cfg.get_value(SECTION, "fov", DEFAULTS.fov)), 60.0, 110.0)
	var am := str(cfg.get_value(SECTION, "ads_mode", DEFAULTS.ads_mode))
	ads_mode = am if am in ["hold", "toggle"] else "hold"
	motion_blur = bool(cfg.get_value(SECTION, "motion_blur", DEFAULTS.motion_blur))
	var pn := str(cfg.get_value(SECTION, "player_name", ""))
	player_name = str(validate_player_name(pn).name) if bool(validate_player_name(pn).ok) else ""
	_load_bindings(cfg)


func save_to_disk() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value(SECTION, "fullscreen", fullscreen)
	cfg.set_value(SECTION, "vsync", vsync)
	for b in AUDIO_BUSES:
		cfg.set_value(SECTION, "vol_" + b, float(get("vol_" + b)))
	cfg.set_value(SECTION, "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value(SECTION, "invert_y", invert_y)
	cfg.set_value(SECTION, "fov", fov)
	cfg.set_value(SECTION, "ads_mode", ads_mode)
	cfg.set_value(SECTION, "motion_blur", motion_blur)
	if player_name != "":
		cfg.set_value(SECTION, "player_name", player_name)
	_save_bindings(cfg)
	cfg.save(save_path)


func _save_bindings(cfg: ConfigFile) -> void:
	for a in BINDABLE:
		if not InputMap.has_action(a):
			continue
		var packed: Array = []
		for e in InputMap.action_get_events(a):
			packed.append(_event_to_dict(e))
		cfg.set_value(BIND_SECTION, a, packed)


func _load_bindings(cfg: ConfigFile) -> void:
	# Migrate legacy bind:aim → bind:ads once (Skillz ADS reads "ads").
	if cfg.has_section_key(BIND_SECTION, "aim") and not cfg.has_section_key(BIND_SECTION, "ads"):
		cfg.set_value(BIND_SECTION, "ads", cfg.get_value(BIND_SECTION, "aim"))
		cfg.erase_section_key(BIND_SECTION, "aim")
		cfg.save(save_path)
	elif cfg.has_section_key(BIND_SECTION, "aim"):
		cfg.erase_section_key(BIND_SECTION, "aim")
		cfg.save(save_path)
	for a in BINDABLE:
		if not InputMap.has_action(a) or not cfg.has_section_key(BIND_SECTION, a):
			continue
		var packed = cfg.get_value(BIND_SECTION, a, [])
		if typeof(packed) != TYPE_ARRAY:
			continue
		InputMap.action_erase_events(a)
		for d in packed:
			var e := _event_from_dict(d)
			if e:
				InputMap.action_add_event(a, e)


func _reset_values_only() -> void:
	fullscreen = DEFAULTS.fullscreen
	vsync = DEFAULTS.vsync
	for b in AUDIO_BUSES:
		set("vol_" + b, DEFAULTS["vol_" + b])
	mouse_sensitivity = DEFAULTS.mouse_sensitivity
	invert_y = DEFAULTS.invert_y
	fov = DEFAULTS.fov
	ads_mode = DEFAULTS.ads_mode
	motion_blur = DEFAULTS.motion_blur


## Restore defaults (values + bindings), apply, save, emit.
func reset_to_defaults() -> void:
	_reset_values_only()
	for a in _defaults_events:
		if not InputMap.has_action(a):
			continue
		InputMap.action_erase_events(a)
		for e in _defaults_events[a]:
			InputMap.action_add_event(a, e.duplicate())
	apply_all()
	save_to_disk()
	changed.emit("reset")
	bindings_changed.emit()


# ---------------------------------------------------------------- apply

func apply_all() -> void:
	_apply_video()
	_apply_audio()
	# gameplay fields are read live by player / Skillz; still notify
	changed.emit("apply_all")


func _apply_video() -> void:
	if fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)


func _apply_audio() -> void:
	var sfx := get_node_or_null("/root/Sfx")
	if sfx and sfx.has_method("ensure_buses"):
		sfx.ensure_buses()
	for b in AUDIO_BUSES:
		var idx := AudioServer.get_bus_index(b)
		if idx < 0:
			continue
		var lin: float = float(get("vol_" + b))
		AudioServer.set_bus_mute(idx, lin <= 0.0001)
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(lin, 0.0001)) if lin > 0.0001 else -80.0)


# ---------------------------------------------------------------- setters (live apply + save + signal)

func set_fullscreen(v: bool) -> void:
	fullscreen = v
	_apply_video()
	_commit("fullscreen")


func set_vsync(v: bool) -> void:
	vsync = v
	_apply_video()
	_commit("vsync")


func set_bus_volume(bus: String, linear: float) -> void:
	if not AUDIO_BUSES.has(bus):
		return
	set("vol_" + bus, clampf(linear, 0.0, 1.0))
	_apply_audio()
	_commit("vol_" + bus)


func set_mouse_sensitivity(v: float) -> void:
	mouse_sensitivity = clampf(v, 0.0005, 0.02)
	_commit("mouse_sensitivity")


func set_invert_y(v: bool) -> void:
	invert_y = v
	_commit("invert_y")


func set_fov(v: float) -> void:
	fov = clampf(v, 60.0, 110.0)
	_commit("fov")


func set_ads_mode(v: String) -> void:
	ads_mode = v if v in ["hold", "toggle"] else "hold"
	_commit("ads_mode")


func get_ads_mode() -> String:
	return ads_mode


func set_motion_blur(v: bool) -> void:
	motion_blur = v
	_commit("motion_blur")


# ---------------------------------------------------------------- co-op profile name

## {ok, name (trimmed, inner spaces collapsed), reason}. 2-16 chars of letters, digits, space, _ - . and at least one
## letter or digit. The ONE validator is Netz's NetNames (scripts/net/net_names.gd, = Net.validate_name /
## is_valid_name / sanitize_name): used whenever it's installed. The rules below are only the fallback for builds
## without scripts/net (solo / the lobby stub); they're byte-identical (Netz net_ui_api_test checks both).
const NET_NAMES_PATH := "res://scripts/net/net_names.gd"
static var _net_names: Variant = null ## GDScript once loaded, false when absent


static func _net_validator():
	if _net_names == null:
		_net_names = load(NET_NAMES_PATH) if ResourceLoader.exists(NET_NAMES_PATH) else false
	return _net_names if _net_names is GDScript else null


static func validate_player_name(raw: String) -> Dictionary:
	var nn = _net_validator()
	if nn:
		var v = nn.validate(raw)
		if v is Dictionary and v.has("ok"):
			return v
	return _validate_fallback(raw)


static func _validate_fallback(raw: String) -> Dictionary:
	var n := raw.strip_edges()
	while n.contains("  "):
		n = n.replace("  ", " ")
	if n.length() < NAME_MIN:
		return {"ok": false, "name": n, "reason": "Name needs at least %d characters." % NAME_MIN}
	if n.length() > NAME_MAX:
		return {"ok": false, "name": n, "reason": "Name can be at most %d characters." % NAME_MAX}
	var re := RegEx.create_from_string("^[A-Za-z0-9 _.\\-]+$")
	if re.search(n) == null:
		return {"ok": false, "name": n, "reason": "Use only %s" % NAME_ALLOWED}
	if RegEx.create_from_string("[A-Za-z0-9]").search(n) == null:
		return {"ok": false, "name": n, "reason": "Name needs a letter or a number."}
	return {"ok": true, "name": n, "reason": ""}


func has_player_name() -> bool:
	return player_name != ""


## Validates, stores and saves. Returns validate_player_name()'s dict (name not changed when !ok).
func set_player_name(raw: String) -> Dictionary:
	var v := validate_player_name(raw)
	if v.ok:
		player_name = str(v.name)
		_commit("player_name")
	return v


func _commit(key: String) -> void:
	if _ready_done:
		save_to_disk()
	changed.emit(key)


# ---------------------------------------------------------------- rebind

## Returns "" if free, or the other action name that already uses this event.
func find_conflict(action: String, event: InputEvent) -> String:
	for a in BINDABLE:
		if a == action or not InputMap.has_action(a):
			continue
		for e in InputMap.action_get_events(a):
			if _events_equal(e, event):
				return a
	return ""


## Bind `event` to `action`. If `swap_on_conflict`, moves the event off the other action; else refuses.
## Returns {ok: bool, conflict: String}.
func rebind(action: String, event: InputEvent, swap_on_conflict: bool = true) -> Dictionary:
	if not InputMap.has_action(action) or event == null:
		return {"ok": false, "conflict": ""}
	var other := find_conflict(action, event)
	if other != "" and not swap_on_conflict:
		return {"ok": false, "conflict": other}
	if other != "":
		_erase_matching(other, event)
	# Replace same-class binding (one key + one pad button kept per action for simplicity)
	_erase_same_class(action, event)
	InputMap.action_add_event(action, event)
	save_to_disk()
	changed.emit("bind:" + action)
	bindings_changed.emit()
	return {"ok": true, "conflict": other}


func reset_binding(action: String) -> void:
	if not _defaults_events.has(action) or not InputMap.has_action(action):
		return
	InputMap.action_erase_events(action)
	for e in _defaults_events[action]:
		InputMap.action_add_event(action, e.duplicate())
	save_to_disk()
	changed.emit("bind:" + action)
	bindings_changed.emit()


func _erase_matching(action: String, event: InputEvent) -> void:
	for e in InputMap.action_get_events(action):
		if _events_equal(e, event):
			InputMap.action_erase_event(action, e)


func _erase_same_class(action: String, event: InputEvent) -> void:
	for e in InputMap.action_get_events(action):
		if event is InputEventKey and e is InputEventKey:
			InputMap.action_erase_event(action, e)
		elif event is InputEventMouseButton and e is InputEventMouseButton:
			InputMap.action_erase_event(action, e)
		elif event is InputEventJoypadButton and e is InputEventJoypadButton:
			InputMap.action_erase_event(action, e)


static func _events_equal(a: InputEvent, b: InputEvent) -> bool:
	if a is InputEventKey and b is InputEventKey:
		return a.physical_keycode == b.physical_keycode and a.keycode == b.keycode
	if a is InputEventMouseButton and b is InputEventMouseButton:
		return a.button_index == b.button_index
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		return a.button_index == b.button_index
	return false


static func _event_to_dict(e: InputEvent) -> Dictionary:
	if e is InputEventKey:
		return {"t": "key", "physical": int(e.physical_keycode), "key": int(e.keycode)}
	if e is InputEventMouseButton:
		return {"t": "mouse", "button": int(e.button_index)}
	if e is InputEventJoypadButton:
		return {"t": "joy", "button": int(e.button_index)}
	return {}


static func _event_from_dict(d) -> InputEvent:
	if typeof(d) != TYPE_DICTIONARY:
		return null
	match str(d.get("t", "")):
		"key":
			var e := InputEventKey.new()
			e.physical_keycode = int(d.get("physical", 0)) as Key
			e.keycode = int(d.get("key", 0)) as Key
			return e
		"mouse":
			var m := InputEventMouseButton.new()
			m.button_index = int(d.get("button", 0)) as MouseButton
			return m
		"joy":
			var j := InputEventJoypadButton.new()
			j.button_index = int(d.get("button", 0)) as JoyButton
			return j
	return null


static func event_label(e: InputEvent) -> String:
	if e is InputEventKey:
		var k: Key = e.physical_keycode if e.physical_keycode != KEY_NONE else e.keycode
		return OS.get_keycode_string(k)
	if e is InputEventMouseButton:
		match e.button_index:
			MOUSE_BUTTON_LEFT: return "Mouse Left"
			MOUSE_BUTTON_RIGHT: return "Mouse Right"
			MOUSE_BUTTON_MIDDLE: return "Mouse Middle"
			MOUSE_BUTTON_WHEEL_UP: return "Wheel Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Wheel Down"
			_: return "Mouse %d" % e.button_index
	if e is InputEventJoypadButton:
		return "Pad %d" % e.button_index
	return "?"


func binding_labels(action: String) -> PackedStringArray:
	var out: PackedStringArray = []
	if not InputMap.has_action(action):
		return out
	for e in InputMap.action_get_events(action):
		out.append(event_label(e))
	return out
