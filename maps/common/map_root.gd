class_name MapRoot
extends Node3D
## Root script for Mapz maps (map contract v0.2). Tracks unlocked areas, listens to MapDoor nodes,
## rebakes the navmesh when a door opens and exposes the active spawn points.
## Engine-side usage (main.gd): map.active_spawn_points(), map.get_nav_region(), map.player_spawn_transform(), map.kill_y.

signal area_unlocked(area: StringName)

@export var map_id: StringName = &""
@export var display_name: String = ""
@export var start_area: StringName = &"start"
@export var kill_y: float = -25.0
## Rebake the navmesh (async) after every door opens. Turn off if the engine handles it.
@export var rebake_on_door_open: bool = true
## Debug: open every door at startup (use if area-gated spawning isn't wired up yet).
@export var debug_all_doors_open: bool = false

var unlocked: Dictionary = {}
var _rebake_pending: bool = false


func _ready() -> void:
	unlocked[start_area] = true
	for d in get_tree().get_nodes_in_group("map_doors"):
		if is_ancestor_of(d):
			d.opened.connect(_on_door_opened)
	get_nav_region().bake_finished.connect(_on_bake_finished)
	if debug_all_doors_open:
		open_all_doors()


## Async rebake that never collides with a bake already running (two doors bought back to back).
func request_rebake() -> void:
	var r := get_nav_region()
	if r.is_baking():
		_rebake_pending = true
	else:
		r.bake_navigation_mesh(true) # async; the old navmesh stays live until it's done


func _on_bake_finished() -> void:
	if _rebake_pending:
		_rebake_pending = false
		get_nav_region().bake_navigation_mesh(true)


func get_nav_region() -> NavigationRegion3D:
	return $NavigationRegion3D


func player_spawn_transform() -> Transform3D:
	return ($PlayerSpawn as Node3D).global_transform


func doors() -> Array:
	return $NavigationRegion3D/Doors.get_children()


func is_area_open(area: StringName) -> bool:
	return unlocked.has(area)


## Marker3Ds under SpawnPoints whose meta "area" is unlocked (missing meta = start area).
func active_spawn_points() -> Array:
	return $SpawnPoints.get_children().filter(
		func(m): return is_area_open(StringName(m.get_meta("area", start_area))))


func open_all_doors() -> void:
	var was := rebake_on_door_open
	rebake_on_door_open = false
	for d in doors():
		d.open()
	rebake_on_door_open = was
	if rebake_on_door_open:
		request_rebake()


func _on_door_opened(d: Node) -> void:
	for a in d.opens_areas:
		var an := StringName(a)
		if not unlocked.has(an):
			unlocked[an] = true
			area_unlocked.emit(an)
	if rebake_on_door_open:
		request_rebake()
