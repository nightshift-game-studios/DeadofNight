# Ironside Freight Depot (`ironside_depot`): layout v0.1, phase 1 greybox

**Theme.** A railway freight depot abandoned at night. Passengers come in through a platform concourse, and the depot
spreads out from there: a booking and freight office, a loading bay, a cold store with reefer racks, a sorting shed with a
conveyor, an open rail yard with boxcars, a coal stage on a trestle, an engine shed, a roundhouse with a sunken turntable
pit, and a fuel point beside a water tower. It's grounded and gritty, with sodium yard lamps, cold tube light indoors and
a warm lamp over the pit. It's Rustwell's industrial feel with a rail theme.

**Size.** The bounds are 120 x 88 m (x -60..60, z -44..44), or 10,560 m². That's 1.82x Rustwell (88 x 66). The navmesh
covers about 8,570 m² with all doors open. There are 10 areas, 14 doors, 13 decks and 23 wedge ramps.

The single source of truth is `layout_data.py`. `tools/sketch_ironside.py` turns it into `layout_sketch.png`, and
`tools/build_ironside.sh` turns it into `ironside_depot.tscn`.

## Rooms (grid of 32 / 28 / 28 m cells, rows north to south)
| id | room | rect x0,x1,z0,z1 | type | role |
|---|---|---|---|---|
| start | A Platform Concourse | -28,4,14,44 | outdoor | spawn. Island platform 1.0 m with canopy, coach (cover), relay hut (WJ1), L1 loop |
| freight_office | B Freight Office | -60,-28,14,44 | indoor, roof 8 | gallery and balcony 3.6 m, baggage cage, ticket booth. Mystery box on the gallery |
| loading_bay | C Loading Bay | 4,32,14,44 | outdoor | 1.0 m loading dock, trailers and a container. Dock slide lane |
| cold_store | D Cold Store | 32,60,14,44 | indoor, roof 9 | three 3.6 m reefer racks, N/S bridges. L2 rack loop, WJ2 |
| sorting_shed | E Sorting Shed | -28,4,-14,14 | indoor, roof 10 | conveyor (L4 loop), sort cage, 4.0 m gallery, perk machine, slide lane |
| rail_yard | F Rail Yard | 4,60,-14,14 | outdoor | 3.6 m boxcar train with gangways, signal bridge, hopper and tank wagon. Yard lane |
| coal_stage | G Coal Stage | -60,-28,-14,14 | outdoor | 4.0 m coal trestle (L6 loop), coal heap, bunker. Coal lane |
| loco_shed | H Engine Shed | -60,-28,-44,-14 | indoor, roof 11 | locomotive, sand tower and smoke wall (WJ3 chimney), 4.2 m catwalks |
| roundhouse | I Roundhouse | -28,16,-44,-14 | indoor, roof 12 | turntable pit at -1 m (boss arena), 4.0 m gallery, L5 loop |
| fuel_point | J Fuel Point | 16,60,-44,-14 | outdoor | water tower 14 m (L3 circle), fuel tanks, pump house (roof 4.0, power weapon, WJ4) |

## Doors (MapDoor, explicit cost; `opens_areas` = both connects)
| door | name | at | cost | connects |
|---|---|---|---|---|
| D1 | Platform Gate | 4,30 | 750 | start - loading_bay |
| D2 | Booking Hall Doors | -28,24 | 750 | start - freight_office |
| D3 | Yard Gate | 12,14 | 1000 | loading_bay - rail_yard |
| D4 | Office Back Door | -48,14 | 1000 | freight_office - coal_stage |
| D5 | Shed Roller Door | -4,14 | 1000 | start - sorting_shed |
| D6 | Reefer Door | 32,34 | 1250 | loading_bay - cold_store |
| D7 | Coal Chute Passage | -28,6 | 1250 | sorting_shed - coal_stage |
| D8 | Shed Rail Door | 4,6 | 1250 | sorting_shed - rail_yard |
| D14 | Cold Store Dock | 40,14 | 1250 | cold_store - rail_yard |
| D9 | Fuel Gate | 40,-14 | 1500 | rail_yard - fuel_point |
| D10 | Engine Shed Door | -44,-14 | 1500 | coal_stage - loco_shed |
| D11 | Turntable Passage | -16,-14 | 1500 | sorting_shed - roundhouse |
| D12 | Inspection Arch | -28,-36 | 1750 | loco_shed - roundhouse |
| D13 | Roundhouse East Door | 16,-36 | 1750 | roundhouse - fuel_point |

```
 B ==D2(750)== A ==D1(750)== C ==D6(1250)== D
 |D4(1000)     |D5(1000)     |D3(1000)     |D14(1250)
 G ==D7(1250)= E ==D8(1250)= F ============+
 |D10(1500)    |D11(1500)    |D9(1500)
 H ==D12(1750) I ==D13(1750) J
```

**Flow.** The start (A) has two 750 exits: west into the office (B) and east into the bay (C). Then come three 1000
doors, which lead to the yard, the coal stage and the sorting shed. The middle row (G-E-F) is the trunk, and every room
has at least 2 doors except the far corners, which close the outer ring. The 1500 doors open the south row, and the 1750
doors join the engine shed, roundhouse and fuel point into a back corridor, so a full lap runs B-A-C-D-F-J-I-H-G-B. Any
order of opening is valid; the verify script stages them D1..D14. Each new door opens up 2 to 3 spawns.

## Verticality, wall-jumps, slides, loops
- **Decks:** 3.6 to 4.2 m catwalks, galleries and bridges. Every deck has at least 2 wedge ramps (≤ 28.5°, no box
  stairs), and a step scan found no step ≥ 0.35 m. The one deliberate dead end is the Relay Hut roof at 2.0 m (one ramp
  plus WJ1). Every raised area has a zombie route at least 2 m wide.
- **Wall-jumps:** these were tested with the stock `walljump.gd` in the `_test/ironside/proj` copy. Its movement code is
  the same as live `player.gd`; the only diff is a camera-sway line. All four pass for both soldier and scout.

  | jump | kicks | target height |
  |---|---|---|
  | WJ1 Relay Hut | 1 | 2.0 m |
  | WJ2 Rack Aisle | 2 | 3.6 m, onto ColdBridgeN |
  | WJ3 Smoke Chimney | 3 | 4.2 m, onto the engine catwalk |
  | WJ4 Pump Slot | 2 | 4.0 m pump roof (needs forward held after the 2nd kick) |
- **Slide lanes (≥ 12 m, flat, clear):** shed (27 m), dock (14 m), coal north (27 m), yard north (36 m), roundhouse
  south (32 m).
- **Training loops (≥ 2 m clear, on nav):**

  | loop | length |
  |---|---|
  | L1 Platform | 84 m |
  | L2 Rack | 80 m |
  | L3 Water tower circle | 46 m |
  | L4 Shed conveyor | 54 m |
  | L5 Turntable | 89 m |
  | L6 Trestle | 57 m |
  | L7 Depot ring A-C-F-E | 81 m |

## Markers
- **Spawns:** PlayerSpawn (-10, 0.1, 21), facing south. There are 23 SpawnPoints, each tagged with an area: 3 in start, 3
  in freight_office, 3 in roundhouse (one in the pit) and 2 in every other area. Each sits at a breach point (window,
  chute, fence gap) and has a red breach decal.
- **Chests:** 5 Chests. There are 28 ChestSpots: empty Marker3Ds in the persistent group `chest_spot`, with meta `area`
  (a StringName), `hidden` (15 hidden), `initial` (the 5 under Chests) and `weight` 1.
  - The closest pair is 8.25 m apart (the minimum is 6).
  - -Z faces the walkway, and each has a 1.2 x 0.8 m footprint plus 1.2 m clear in front.
  - All are on nav, and every room has at least 2. Some are on upper decks.
- **Hooks:**
  - PowerWeaponSpot is on the pump-house roof.
  - PerkMachineSpot is under the shed gallery.
  - MysteryBoxSpot is on the office gallery.
  - BossArenaHook is the turntable pit (r 5.5 m, 3 BossSpawns).
  - There are 6 pickups and 12 AmbienceEmitters, at least 14 m apart.
- **Nav:** NavigationRegion3D is baked at runtime and uses the contract bake AABB. Every wedge has `nav_side_carves`
  with 4 strips. There are 10 corner pads (coal heap, boxcar gangway gap, baggage cage) from the stall sim.
  BalconyCrates (a cap block) closes a route-flip squeeze under the office balcony.

## Lighting and performance
- **Night:** medium-hard. The moon has energy 0.65 and casts shadows. There are 3 shadowed spots (PlatformFlood,
  ShedFlood, PitLamp), so 4 shadowed lights in total, and 27 unshadowed omnis with distance fade.
- **Environment:** the shared HDRI with sky energy 0.2, ambient colour (0.29, 0.32, 0.45) at 0.3, ACES tonemapping,
  exposure 1.08 and fog 0.011.
- **Visibility:** a dark capsule at 15 m and 20 m was tested from 7 eyes (3 outdoor, 4 indoor). Weber contrast was at
  least 0.37 everywhere (target 0.35), so it's never pitch black.
- **Performance:**
  - Rooms are separated by full-height walls and roofs, with 48 OccluderInstance3D (walls and roofs) for occlusion
    culling.
  - The greybox is 1.4 MB in total.
  - Shadows are capped at 4.

## Art pass (phase 2, Rustwell style)
- **Built by** `tools/art_ironside.py` (imported by gen unless `--greybox`), then `tools/godot/merge_ironside.gd`. Merging is
  per (area, material, shadow): 2758 meshes become 180, plus a FloorScatter MultiMesh (140 pieces, visibility 40 m).
- **Materials:** world-triplanar ORM using the Rustwell CC0 textures, referenced in place. Procedural decals are under
  `assets/decals/`. See CREDITS.md.
- **Railings (80):** every open drop of 1.4 m or more on decks, walk tops and ramp sides gets a railing.
  - Each railing sits on the open edge with the toe board on the outward (drop) face. Ramp railings follow the slope from
    `ramp_y`.
  - Each railing has a matching 8-point convex collider under `NavigationRegion3D/Railings` (meta `rail_a`, `rail_b`,
    `rail_n`). These are baked, so paths keep 0.5 m off rails and go around rail ends.
  - Rail runs reach the corners, so there are no gaps at ramp heads. Wall-jump landing edges are left open.
  - 1.0 m platform and dock edges and the turntable pit get painted edge or hazard lines instead of railings.
  - `mapz_tools/rails_ironside.gd` checks that the rail base matches the walk surface and that the outer side is a drop.
- **Nav stall fixes (ship):** corner pads were added at OfficeRampFoot (the U-turn round the gallery ramp foot), ColdRampWTop and
  ColdRampETop (where the ramp head meets the bridge rail end), and CoalHeapNW/NE was widened to 1.3 m. The capsule sim now has
  0 stalls in 98 routes with doors closed and 0 in 989 with all doors open.
- **Doors:** Desi rail_gate (slide: D1, D3, D9), foundry_side (swing: D2, D11-D13), blast (swing: D4, D7), and rollershutter
  (hide: D5, D6, D8, D10, D14). `open_mode` is always written explicitly.
- **Dressing:**
  - Desi wall-breach barricades at the spawns. Debris is visual only (`scripts/strip_prop_colliders.gd`).
  - Themed props per room, emissive windows, a skyline, fence cards, sleepers and bogies.
  - 12 ambience emitters, 3 spark bursts and 4 flickering lamps.
- **Lights:** 37 in total, with 4 shadowed (moon plus 3 spots). Three short-range wall-wash fills (ShedWallWash,
  EngineWallWash, FuelYardWash) sit behind the 20 m probe spots, so zombies read as silhouettes. The worst Weber contrast
  is 0.36.
- **Size:** the map folder is 9.8 MB. With the referenced shared assets it comes to about 124 MB. No texture is above 2K.

## Build and checks
`tools/build_ironside.sh` runs gen_ironside.py, then export_nav_layout.py, then fix_nav_ramps.gd (in the scratch project from
`tools/setup_ironside_proj.sh`), then the cost check. After that, run these:
- `mapz_tools/verify_ironside.gd`
- stock `tests_mapz/verify_map.gd`
- `mapz_tools/test_void_gaps.gd`
- `mapz_tools/nav_sim_ironside.gd` (`tools/audit_ironside.sh <out> closed all`): reach plus a capsule sim that uses
  zombie_nav's corner rule
- `mapz_tools/rails_ironside.gd`
- `tests_mapz/walljump.gd`
- `mapz_tools/shots_ironside.gd` (under xvfb; modes shots|vis|all|perf; env SHOT_ONLY / VIS_ONLY)


The scratch test project is recreated on demand by `tools/setup_ironside_proj.sh`. It copies the live fps-starter (without .git, .godot or maps), links `maps` and `mapz_tools`, copies the stock tests from `_test/fps_wj/tests_mapz`, adds a maps.json entry, and is deleted after each session to save disk.
