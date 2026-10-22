# Map contract v0.4 (Mapz → G4M3N)

Implemented by Rustwell Foundry (v0.2), Lockout Substation (v0.3 optional hooks) and both maps' v0.6.1 playtest pass (v0.4).

Changes since v0.3 (v0.6.1 playtest, #15 #16 #27): large maps may have 2–3 spawns per area instead of 6–10 in total; optional `ChestSpots/` relocation markers (Skillz format, below); no void holes,
checked by `tools/godot/test_void_gaps.gd` (the meta `intended_pit` marks deliberate pits); stair railings with collision
(`RailCol_*`, Rustwell); the `fix_playtest_v061.gd` pipeline step.

Changes since v0.2 (Lockout Substation): optional `PerkMachineSpot`, `MysteryBoxSpot`, and `BossArenaHook` markers for Skillz perk / mystery-box / boss-arena wiring. Vault-scale boss floors should be ≥ 10×10 m clear nav.
Changes since v0.3 night: optional `AmbienceEmitters/` (Marker3D children at ~1.6 m with meta `ambience_key`) for Audi-0 3D ambience loops. Night maps place 6–12 emitters, ≥8 m apart; G4M3N attaches loops (max_distance 12–18 m). Keys: `ambience_emitter_sodium_buzz_loop`, `ambience_emitter_sparking_box_loop`, `ambience_emitter_drip_pipe_loop`.
Changes since v0.1: doors have exports `door_id` and `connects`, and they live at `NavigationRegion3D/Doors/<Dn>`. Every spawn is area-tagged.
MapRoot uses the `map_doors` group, not a class_name lookup, and queues rebakes. A `NavCarves/` node was added.
Occluders are now a real deliverable. Root metadata gained `contract_version` and `bounds`. Chest and PowerWeaponSpot markers carry `area`.

Goal: a map is **one self-contained scene** (`res://maps/<map_id>/<map_id>.tscn` plus its own folder). `main.gd` can
instance it in place of the built-in arena with about 30 lines of changes, and the default arena keeps working (smoke test untouched).

Required names are exactly the ones G4M3N confirmed: **`SpawnPoints` (6–10 Marker3D children; large maps 2–3 per area, see below), `PlayerSpawn`, chest markers (3+),
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
│        └─ <Dn>: Visual (Node3D: Panel mesh + optional door model/frame), Collision (CollisionShape3D),
│                 Trigger (Area3D layer 0 / mask 2), CostSign (Label3D). open() hides every non-Area3D Node3D child
├─ Clip/                 StaticBody3D layer 1 OUTSIDE the region (not parsed by the bake): solid indoor ceilings, invisible
│                        perimeter walls, invisible columns above wall tops / tall blocks / tanks up to 30 m, cone-tip poles.
│                        Only there to stop stacked jump skills reaching tops or leaving the map
├─ Merged/               (art pass) the Geometry + Decor meshes merged per area / material / shadow mode by tools/godot/merge_rustwell.gd.
│                        The original Geometry bodies keep their collision shapes only
├─ Props/                (art pass) non-colliding glTF props and dressing; res://maps/common/props_root.gd sets visibility ranges
├─ ReflectionProbes/     (art pass) interior probes, update once
├─ Dressing/             (art pass) Marker3D slots for Desi custom props (BreachSlot_*, HeroCarSlot, RubbleSlot_*).
│                        May contain StaticBody3D once a Desi glb is instanced under a slot
├─ Decor/                non-colliding meshes (roofs, trims), outside the region (not parsed by the bake)
├─ Occluders/            OccluderInstance3D (BoxOccluder3D) for big walls, buildings and roofs
├─ PlayerSpawn           REQUIRED Marker3D. Feet position (y = floor + 0.1), −Z of the marker = facing
├─ SpawnPoints/          REQUIRED Node3D with 6–10 Marker3D (Spawn1..N) at floor + 0.1
│     Count (v0.4): small / medium maps 6–10 in total. Large maps (> 5000 m² walkable navmesh, or ≥ 6 areas) take 2–3 per
│     area and no total cap (Ironside Depot: 23 across 10 areas). Checked by verify_map.gd after the bake.
│     metadata/area: StringName  (EVERY spawn is tagged). The area whose unlock activates this spawn
├─ Chests/               REQUIRED Node3D with ≥ 3 Marker3D (Chest1..N). Engine instances scenes/chest.tscn at each one
│     metadata/loot_table: String ("chest"), metadata/area: StringName (the area it sits in)
├─ ChestSpots/           optional (v0.4) Node3D, placed after Chests/. 8–12 EMPTY Marker3D children ChestSpot1..N, every one in the
│                        persistent group `chest_spot` (saved in the .tscn). Origin on the floor; **−Z of the marker faces the
│                        walkway** (Chests/ markers face +Z, so a spot at a chest has yaw = chest yaw + 180°).
│     metadata/area: StringName (the SpawnPoints area tags), or Array[StringName] for a spot on an area boundary
│     metadata/hidden: bool   (tucked: side rooms, behind cover, upper levels. Relocation prefers hidden spots)
│     metadata/initial: bool  (true exactly for the spots at the Chests/ markers; Chests/ stays as the fallback)
│     metadata/weight: int    optional, default 1 (all spots ship with 1)
│     metadata/note: String   optional, human description
│     Rules: ≥ 6 m apart, ≥ 6 m from PlayerSpawn, ≥ 2 per area (≥ 1 per area on maps with 6+ areas, so 8–12 still fits), a 1.2 × 0.8 m footprint on floor plus 1.2 m (1.8 m tall) clear in
│     front, front on the navmesh and reachable from PlayerSpawn by players and zombies (no perches), never in the void or inside
│     geometry, and still valid with a 1.2 × 0.8 m NavigationObstacle3D carve at every spot at once (all SpawnPoints still path).
│     Checked by `tools/godot/test_chest_spots.gd -- <map.tscn…>` (exits 1 on any failure).
├─ PickupSpots/          optional Marker3D. metadata/item: "health_pack" | "heavy_ammo" | "primary_ammo"
├─ PowerWeaponSpot       optional Marker3D (same meaning as in main.tscn), metadata/area
├─ PerkMachineSpot       optional Marker3D. metadata/area, metadata/kind = "perk_machine"
├─ MysteryBoxSpot        optional Marker3D. metadata/area, metadata/kind = "mystery_box"
├─ BossArenaHook         optional Node3D. metadata/area, metadata/arena_center (Vector3), metadata/radius (float);
│                        child Marker3D BossSpawn1..N with metadata/kind = "boss_spawn"
└─ AmbienceEmitters/     optional Node3D. Marker3D children at ear height (~1.6 m). metadata/ambience_key one of:
                         ambience_emitter_sodium_buzz_loop | ambience_emitter_sparking_box_loop |
                         ambience_emitter_drip_pipe_loop. 6–12 per night map, ≥8 m apart (not a grid).
                         G4M3N attaches AudioStreamPlayer3D (max_distance 12–18 m). Assets in res://assets/audio/ambience/.
                         Mapz does not place the 2D beds.
```
MapRoot exports: `map_id`, `display_name`, `start_area` (&"start"), `kill_y` (−25), `rebake_on_door_open` (true), `debug_all_doors_open` (false).
Root metadata (mirrors the exports for engines that don't use the script): `map_id`, `display_name`, `kill_y`, `start_area`,
`contract_version` ("0.2", "0.3" or "0.4"), `stair_rails_v061` (bool, Rustwell: the rail pass ran), `bounds` (AABB of the playable space, for minimap / out-of-bounds checks).

### Rules
- Units are metres, +Y is up, the floor of the start area is y = 0. The map fits inside ±60 m (the Sun shadow distance is 70 m in map 1).
- Collision: every walkable or blocking surface is a StaticBody3D on **layer 1** under `NavigationRegion3D`. There are no trimesh colliders.
  Stairs and ramps are wedge (convex) colliders (the player has no step-up).
- NavigationMesh: `geometry_parsed_geometry_type = STATIC_COLLIDERS (1)`, `geometry_collision_mask = 1`, `agent_height 2.0`,
  `agent_radius 0.5`, `agent_max_climb 0.5`, `agent_max_slope 40`, cell 0.25 / 0.25. **Baked at runtime**, the same as main.gd.
  `filter_baking_aabb = AABB(-200, -1.99, -200, 400, 120, 400)` (nav fix 2026-10-19): it puts the voxel grid's origin just under the
  floor heights, so the nav bakes about 0.26 m above floors instead of about 0.5 m (and 0.6–1.0 m at ramp toes). Agent and cell params are unchanged.
- Low cover a zombie must walk over (≤ 0.45 m) uses a hipped-ridge collider, not a box. The navmesh climbs 0.5 m, but zombies have no step-up.
- Ramp and stair sides are carved into the baked navmesh (NavCarves `Carve_<ramp>_Side{A,B}` and `…Front`), so zombies can't get onto
  the low end of a ramp from the side.
  - Each strip covers the side from 0.5 m outside the edge to 0.45 m inside it (0.35 m on Lockout stairs), up to a side-face height of 0.7 m.
  - On wedge ramps the strip also runs 0.8 m in front of the foot.
  - Each ramp body has the metadata `nav_side_carves` (PackedStringArray of its carve node names). A runtime fallback should skip any
    ramp that has it.
- No walkable vertical step on a nav route is 0.35 m or taller. Scanned 2026-10-19: Rustwell max 0.15 m, Lockout max 0.14 m.
- Every spawn marker sits on the navmesh and is reachable from PlayerSpawn once its `area` is unlocked, and not before (verified).
- **No zombie-proof perches:** every surface a player can reach has a zombie route (stairs, ramp, or a ≥ 2 m connection).
  At most one dead end per map (map 1: the ContainerC2 roof).
- **No void (v0.4):** inside the play area (the navmesh, doors open, plus 1 m) every point has a layer-1 floor collider and a visual
  surface at that floor, with no gaps or slits at collider / mesh seams. Deliberate pits are bodies with meta `intended_pit = true`
  (optional `pit_size: Vector3`, else the body's AABB). Run
  `godot --headless --path <project> -s res://tools/godot/test_void_gaps.gd -- <map.tscn…> [--step=0.25] [--margin=1.0] [--depth=3.0]
  [--json=path] [--no-visual] [--skip=Chests,Pickups]` (no maps = Rustwell + Lockout). It prints VOID_HOLE lines (kinds VOID,
  NAV_NO_FLOOR, VISUAL_HOLE, SEAM), VOID_RESULT JSON and VOID_SUITE PASS/FAIL, and exits 1 on any hole. Clip/ is ignored; a
  non-MapRoot root script is stripped, so `scenes/main.tscn` can be checked read-only.
- Stairs and raised walkways with a rise ≥ 1.5 m and an open side get railings (two bars + posts ≤ 2 m apart, rising with the stair)
  plus a thin layer-1 `RailCol_<ramp>_<side>` convex collider from the stair surface to +1.05 m. Low-rise walkways (< 1.5 m) have none.
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
- Art pass (v0.3): the map ships its own textures/models in `res://maps/rustwell_foundry/assets/` (82.5 MB, all CC0) and references only
  `res://assets/hdri/abandoned_tank_farm_05_2k.hdr` and `res://assets/models/props/trashbag/` from the project. It needs
  `res://maps/common/*.gd` (props_root.gd is new, map_door.gd changed). Copy all of `maps/` to `res://maps/`; the editor must import `assets/` once.
- Build pipeline: `python3 tools/gen_rustwell.py` → `build/rustwell_foundry_src.tscn`, then headless
  `godot --headless --path <project> -s res://mapz_tools/merge_rustwell.gd` → `rustwell_foundry.tscn` (the shipped file).
  **Last step for both maps (nav fix, 2026-10-19):** `python3 tools/analysis/export_nav_layout.py <map_id> maps/<map_id>/build/nav_layout.json`,
  then `godot --headless --path <project> -s res://mapz_tools/fix_nav_ramps.gd -- res://maps/<m>/<m>.tscn=res://maps/<m>/build/nav_layout.json`.
  This step is idempotent and uses tools/godot/nav_fix_lib.gd to:
  - turn stair step bodies into a single wedge;
  - give low cover a hipped-ridge collider;
  - carve debris (hull + 0.5 m);
  - carve the low-end ramp sides and the space under stair wedges;
  - carve chest tops and sync the chest markers from layout_data;
  - add the `NAV_CORNER_PADS` carves;
  - set the bake AABB.
  It then saves door costs explicitly.
- **v0.6.1 playtest step (after fix_nav_ramps.gd, both maps):** `godot --headless --path <project> -s res://mapz_tools/fix_playtest_v061.gd --
  res://maps/<m>/<m>.tscn=res://maps/<m>/build/nav_layout.json`. Idempotent. It adds the `FLOOR_FILL` slabs from layout_data (collider +
  visual; Lockout's start-yard corners beside the vault), overlaps the Lockout stair treads by 5 cm (no see-through slits), rebuilds
  the Rustwell stair rails with RailCol_* colliders (once; root meta `stair_rails_v061`), and rebuilds `ChestSpots/` from layout_data
  `CHEST_SPOTS`. Then run test_void_gaps.gd and test_chest_spots.gd.
  Note: `gen_lockout.py` writes `maps/lockout_substation/lockout_substation.tscn` directly, so rerun the whole pipeline after it.
- Clip/ colliders are on layer 1, so bullets / thrown items hit them too. They sit ≥ 8 m up (above wall tops) or outside the bounds, so
  normal play never touches them. A dedicated player-only clip layer would be cleaner if the engine adds one.
- `enemy.gd` attack range uses horizontal distance only (`to_player.y = 0`), so a zombie standing **under** a deck (3–4 m below) still
  hits a player above it. Suggest adding `and absf(global_position.y - player.global_position.y) < 1.6` to the attack check.
- (Fixed in player.gd by G4M3N: `jump_kind()` + `ground_jump_kick_lock` 0.15 s. One press is one jump. Routes were re-tuned for it, see LAYOUT.md §5.)
- Area-gated spawning: `map.active_spawn_points()` already filters by unlocked areas. Hook `map.area_unlocked` if the HUD wants an "Area opened" toast.

## Delivery
- Each map is `maps/<map_id>/` with `<map_id>.tscn`, `textures/`, `models/`, `CREDITS.md` and `LAYOUT.md`. Shared scripts go in `maps/common/`.
- Asset paths inside the scenes are `res://maps/...`, so the folder can be dropped into the project root as `res://maps/`.
  Where a texture already exists in `res://assets/textures/`, the map references that copy instead of duplicating it.
- Verification (map 1, done): headless load with zero errors, bake with doors closed and open, one nav component, every spawn / chest /
  pickup / raised area pathing to PlayerSpawn, staged door unlocks matching spawn reachability, wall-jump routes simulated with the real player.gd, screenshots.
  Test scripts: `/workspace/mapz/_test/fps_wj/tests_mapz/` (verify_map.gd, wj_live.gd, shots.gd, rebake.gd).
