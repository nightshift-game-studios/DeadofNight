class_name MapRegistry
extends RefCounted
## Which map main.tscn loads. Data: res://data/maps.json. "arena" = the built-in level in main.tscn (default + fallback).
## Resolution order (first hit wins):
##   1. MapRegistry.select(id)            (menus / Gooey's map picker; survives scene reloads, it's a static var)
##   2. command-line user arg --map=<id>  (e.g.  godot --path . -- --map=rustwell_foundry)
##   3. project setting game/maps/default_map
##   4. maps.json "default" ("arena")
## Unknown ids or missing scenes fall back to "arena".
## UI API: MapRegistry.list() -> [{id, display_name, scene, description}], select(id) -> bool, current_id(),
## then get_tree().reload_current_scene() (or main.restart_with_map(id)).

const DATA_PATH := "res://data/maps.json"
const ARENA := "arena"
const SETTING := "game/maps/default_map"

static var _selected: String = ""
static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_data = d if d is Dictionary else {"default": ARENA, "maps": [{"id": ARENA, "display_name": "Arena", "scene": ""}]}
	return _data


static func list() -> Array:
	return data().get("maps", [])


static func get_info(id: String) -> Dictionary:
	for m in list():
		if m.get("id", "") == id:
			return m
	return {}


static func is_valid(id: String) -> bool:
	var m := get_info(id)
	if m.is_empty():
		return false
	var sc: String = m.get("scene", "")
	return sc == "" or ResourceLoader.exists(sc)


## Pick the map for the next (re)load of main.tscn. "" clears the choice. Returns false for unknown ids.
static func select(id: String) -> bool:
	if id != "" and not is_valid(id):
		push_warning("MapRegistry: unknown map '%s'" % id)
		return false
	_selected = id
	return true


## --map=<id> or --map <id> from the user args (after "--") or, as a convenience, the engine args.
static func cmdline_map(args: PackedStringArray = PackedStringArray()) -> String:
	var all := args
	if all.is_empty():
		all = OS.get_cmdline_user_args() + OS.get_cmdline_args()
	for i in all.size():
		var a: String = all[i]
		if a.begins_with("--map="):
			return a.substr(6)
		if a == "--map" and i + 1 < all.size():
			return all[i + 1]
	return ""


static func current_id() -> String:
	for id in [_selected, cmdline_map(), str(ProjectSettings.get_setting(SETTING, "")), str(data().get("default", ARENA))]:
		if id != "" and is_valid(id):
			return id
	return ARENA


## PackedScene for the current map, or null for the built-in arena.
static func current_scene() -> PackedScene:
	var sc: String = get_info(current_id()).get("scene", "")
	return load(sc) as PackedScene if sc != "" else null
