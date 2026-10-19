# Map contract v0.2 (Mapz → G4M3N), implemented by Rustwell Foundry

Changes since v0.1: doors have exports `door_id` and `connects`, and they live at `NavigationRegion3D/Doors/<Dn>`. Every spawn is area-tagged.
MapRoot uses the `map_doors` group, not a class_name lookup, and queues rebakes. A `NavCarves/` node was added.
Occluders are now a real deliverable. Root metadata gained `contract_version` and `bounds`. Chest and PowerWeaponSpot markers carry `area`.

Goal: a map is **one self-contained scene** (`res://maps/<map_id>/<map_id>.tscn` plus its own folder). `main.gd` can
instance it in place of the built-in arena with about 30 lines of changes, and the default arena keeps working (smoke test untouched).

Required names are exactly the ones G4M3N confirmed: **`SpawnPoints` (6–10 Marker3D children), `PlayerSpawn`, chest markers (3+),
world collision on layer 1, navmesh baked from colliders.** Everything marked *optional* can be ignored by the engine and the map still works.

## Node tree
```
<MapRoot>                Node3D + res://maps/common/map_root.gd (class_name MapRoot). Exports + metadata below
├─ WorldEnvironment      REQUIRED. The map owns sky (HDRI), fog and tonemap. main.gd removes its own when a map is loaded
├─ Sun                   REQUIRED DirectionalLight3D (the only shadowed directional light)
├─ Lights/               optional Omni/Spot (few shadowed, the rest have distance fade)
├─ NavigationRegion3D    REQUIRED, exact name. NavigationMesh with main.gd's params (below). Not prebaked
│  ├─ Geometry/          StaticBody3D, collision_layer 1, mask 0. Everything walkable or blocking (+ metadata/surface)
│  ├─ NavCarves/         NavigationObstacle3D (affect + carve navmesh, avoidance off) that remove sealed nav islands
│  │                     inside solids and on unreachable tops. Not physics; the bake reads them
│  └─ Doors/             MapDoor nodes D1..Dn (StaticBody3D layer 1). Inside the region so a closed door cuts the navmesh
│        └─ <Dn>: Visual (MeshInstance3D), Collision (CollisionShape3D), Trigger (Area3D layer 0 / mask 2), CostSign (Label3D)
├─ Decor/                non-colliding meshes (roofs, trims), outside the region (not parsed by the bake)
├─ Occluders/            OccluderInstance3D (BoxOccluder3D) for big walls, buildings and roofs
├─ PlayerSpawn           REQUIRED Marker3D. Feet position (y = floor + 0.1), −Z of the marker = facing
├─ SpawnPoints/          REQUIRED Node3D with 6–10 Marker3D (Spawn1..N) at floor + 0.1
│     metadata/area: StringName  (EVERY spawn is tagged). The area whose unlock activates this spawn
├─ Chests/               REQUIRED Node3D with ≥ 3 Marker3D (Chest1..N). Engine instances scenes/chest.tscn at each one
│     metadata/loot_table: String ("chest"), metadata/area: StringName (the area it sits in)
├─ PickupSpots/          optional Marker3D. metadata/item: "health_pack" | "heavy_ammo" | "primary_ammo"
└─ PowerWeaponSpot       optional Marker3D (same meaning as in main.tscn), metadata/area
```
MapRoot exports: `map_id`, `display_name`, `start_area` (&"start"), `kill_y` (−25), `rebake_on_door_open` (true), `debug_all_doors_open` (false).
Root metadata (mirrors the exports for engines that don't use the script): `map_id`, `display_name`, `kill_y`, `start_area`,
`contract_version` ("0.2"), `bounds` (AABB of the playable space, for minimap / out-of-bounds checks).

### Rules
- Units are metres, +Y is up, the floor of the start area is y = 0. The map fits inside ±60 m (the Sun shadow distance is 70 m in map 1).
- Collision: every walkable or blocking surface is a StaticBody3D on **layer 1** under `NavigationRegion3D`. There are no trimesh colliders.
  Stairs and ramps are wedge (convex) colliders (the player has no step-up).
- NavigationMesh: `geometry_parsed_geometry_type = STATIC_COLLIDERS (1)`, `geometry_collision_mask = 1`, `agent_height 2.0`,
  `agent_radius 0.5`, `agent_max_climb 0.5`, `agent_max_slope 40`, cell 0.25 / 0.25. **Baked at runtime**, the same as main.gd.
- Every spawn marker sits on the navmesh and is reachable from PlayerSpawn once its `area` is unlocked, and not before (verified).
- **No zombie-proof perches:** every surface a player can reach has a zombie route (stairs, ramp, or a ≥ 2 m connection).
  At most one dead end per map (map 1: the ContainerC2 roof).
- The map does **not** contain Player, HUD, Zombies or Pickups containers (Main keeps those).

## Doors and areas
`MapDoor` (`res://maps/common/map_door.gd`, `class_name MapDoor extends StaticBody3D`):
```gdscript
signal opened(door: MapDoor)
@export var door_id: StringName              # "D1"
@export var cost: int = 750                  # data-driven price (map 1: 750 / 1000 / 1250)
@export var connects: PackedStringArray      # the two areas either side, e.g. ["start", "rail_spur"]
@export var opens_areas: PackedStringArray   # areas unlocked on open, e.g. ["rail_spur"]
@export var prompt_name: String = "Door"
var is_open := false
func can_interact() -> bool               # not is_open
func get_prompt() -> String               # "Open Rail Gate [750]"
func interact(player) -> void             # player.spend_points(cost) then open(player)
func open(player = null) -> void          # free open (tests / scripted). Collision layer+mask 0, shapes disabled,
                                          # visuals hidden, Trigger off, player.set_nearby_interactable(self, false), opened.emit
```
Doors join group `map_doors`. The Trigger Area3D (layer 0, mask 2) calls `body.set_nearby_interactable(self, true/false)`, same as chest.gd.

`MapRoot` (`res://maps/common/map_root.gd`):
```gdscript
signal area_unlocked(area: StringName)
func get_nav_region() -> NavigationRegion3D
func player_spawn_transform() -> Transform3D
func doors() -> Array                      # NavigationRegion3D/Doors children
func is_area_open(a: StringName) -> bool
func active_spawn_points() -> Array        # SpawnPoints children whose metadata/area is unlocked
func open_all_doors() -> void              # one rebake at the end
func request_rebake() -> void              # async bake; if one is running, queues exactly one more (no "already baking" error)
```
On `opened` it unlocks `opens_areas`, emits `area_unlocked`, and (if `rebake_on_door_open`) calls `request_rebake()`.
Why rebake: a closed door is a layer-1 collider inside the region, so it cuts the navmesh and zombies never path into locked areas.
Measured on map 1: a full bake takes 30–65 ms (headless, this box), so it is cheap enough to do on every door.

**Fallback if the engine ignores areas:** set `debug_all_doors_open = true` (all doors open at `_ready`, all spawns valid).

## Engine side: proposed main.gd changes (sketch, not applied)
```gdscript
const CHEST_SCENE := preload("res://scenes/chest.tscn")
@export var map_scene: PackedScene      # null = built-in arena (smoke test keeps passing)
var map: Node3D
var kill_y := -25.0

func _load_map() -> void:              # call first thing in _ready(), before the bake
	if map_scene == null:
		return
	for n in ["NavigationRegion3D", "SpawnPoints", "Chests", "Decor", "WorldEnvironment", "Sun", "PowerWeaponSpot"]:
		var old := get_node_or_null(n)
		if old:
			remove_child(old)
			old.queue_free()
	map = map_scene.instantiate()
	map.name = "Map"
	add_child(map)
	move_child(map, 0)
	nav_region = map.get_node("NavigationRegion3D")
	spawn_points = map.get_node("SpawnPoints")
	kill_y = map.get_meta("kill_y", -25.0)
	player.global_transform = map.get_node("PlayerSpawn").global_transform
	for m: Node3D in map.get_node("Chests").get_children():
		var c := CHEST_SCENE.instantiate()
		c.loot_table = m.get_meta("loot_table", "chest")
		nav_region.add_child(c)          # inside the region so the bake routes around it
		c.global_transform = m.global_transform
	var spots := map.get_node_or_null("PickupSpots")
	if spots:
		for m: Node3D in spots.get_children():
			var p := PICKUP_SCENE.instantiate()
			p.item = load("res://resources/items/%s.tres" % m.get_meta("item", "health_pack"))
			pickups_root.add_child(p)
			p.global_position = m.global_position
```
Then three small edits:
1. In `_ready()`: `_load_map()` before `nav_region.bake_navigation_mesh(true)`. The PowerWeaponSpot lookup becomes
   `(map if map else self).get_node_or_null("PowerWeaponSpot")`.
2. In `_spawn_zombie()`: `var points: Array = map.active_spawn_points() if map and map.has_method("active_spawn_points") else spawn_points.get_children()`.
3. In `_physics_process()`: `if player.global_position.y < kill_y: player.global_position = map.get_node("PlayerSpawn").global_position`.

Map selection can then just set `map_scene` (e.g. from a menu or `--map=<id>` user arg) before `_ready`, or use a tiny `Maps` autoload
listing `res://maps/*/<id>.tscn`.

### Integration notes (from the map 1 build)
- `project.godot`: set `rendering/occlusion_culling/use_occlusion_culling = true`. Otherwise the map's 25 occluders do nothing.
- The map's ground-truth geometry is in `NavigationRegion3D/Geometry`. Spawned chests must be added under `NavigationRegion3D`
  **before** the first bake so zombies route around them.
- The map references `res://assets/textures/*` and `res://assets/hdri/abandoned_tank_farm_05_2k.hdr` (already in the project), and
  `res://maps/common/*.gd`. Copy `maps/` to `res://maps/`. Nothing else is needed.
- `enemy.gd` attack range uses horizontal distance only (`to_player.y = 0`), so a zombie standing **under** a deck (3–4 m below) still
  hits a player above it. Suggest adding `and absf(global_position.y - player.global_position.y) < 1.6` to the attack check.
- Pressing jump while touching a wall can register as a wall-kick from the ground (`is_on_floor()` flickers against walls), which
  spends one of the 3 kicks. It's harmless, but it's why measured kick heights are ~0.4 m above the analytic numbers.
- Area-gated spawning: `map.active_spawn_points()` already filters by unlocked areas. Hook `map.area_unlocked` if the HUD wants an "Area opened" toast.

## Delivery
- Each map is `maps/<map_id>/` with `<map_id>.tscn`, `textures/`, `models/`, `CREDITS.md` and `LAYOUT.md`. Shared scripts go in `maps/common/`.
- Asset paths inside the scenes are `res://maps/...`, so the folder can be dropped into the project root as `res://maps/`.
  Where a texture already exists in `res://assets/textures/`, the map references that copy instead of duplicating it.
- Verification (map 1, done): headless load with zero errors, bake with doors closed and open, one nav component, every spawn / chest /
  pickup / raised area pathing to PlayerSpawn, staged door unlocks matching spawn reachability, wall-jump routes simulated with the real player.gd, screenshots.
  Test scripts: `/workspace/mapz/_test/fps/tests_mapz/` (verify_map.gd, walljump.gd, shots.gd, rebake.gd).
