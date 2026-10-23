# Drowned Cannery (`drowned_cannery`): layout v1.0, hard map (playtest #17)

Night harbour cannery, built on the Ironside Freight Depot pipeline (gen / art / merge / mount_lights / nav sim) with its own layout, theme and ids.
It replaces Lockout Substation as the hard map (`data/maps.json` difficulty `hard`).

- **Size:** 108 x 80 m (8,640 m2), bounds x -54..54, z -40..40, kill plane y = -25.
- **Theme:** flooded night cannery: pier, net loft, ice house, smokehouse, slipway, boiler house, retort hall with a sunken brine pit (boss arena), brine tanks. Water strips, moored hulls, cranes and silos outside the walls.
- **Start:** PlayerSpawn at (-1, 0.1, 29) on the Pier Head, facing north.
- **Counts:** 9 areas, 13 doors, 22 spawns (2-3 per area), 3 Chests, 11 ChestSpots, 12 ambience emitters, 4 wall-jumps, 7 loops, 6 slide lanes, 16 perches.

## Rooms
| id | room | rect x0,x1,z0,z1 | type | roof |
|---|---|---|---|---|
| start | Pier Head | -18,18,14,40 | outdoor | - |
| net_loft | Net Loft | -54,-18,14,40 | indoor | 8.5 |
| ice_house | Ice House | 18,54,14,40 | indoor | 9.0 |
| smokehouse | Smokehouse | -54,-30,-12,14 | indoor | 9.0 |
| quay | Flooded Quay | -30,30,-12,14 | outdoor | - |
| slipway | Slipway | 30,54,-12,14 | outdoor | - |
| boiler | Boiler House | -54,-26,-40,-12 | indoor | 11.0 |
| retort | Retort Hall | -26,16,-40,-12 | indoor | 12.0 |
| tank_farm | Brine Tanks | 16,54,-40,-12 | outdoor | - |

## Doors (MapDoor, explicit cost; `opens_areas` = both connects)
| door | name | at x,z | cost | connects |
|---|---|---|---|---|
| D1 | Net Loft Gate | -18,34 | 750 | start - net_loft |
| D2 | Ice House Doors | 18,24 | 750 | start - ice_house |
| D3 | Quay Gate | 4,14 | 1000 | start - quay |
| D4 | Smoke Hatch | -42,14 | 1000 | net_loft - smokehouse |
| D5 | Slip Dock Door | 36,14 | 1000 | ice_house - slipway |
| D6 | Loft Stair Gate | -24,14 | 1250 | net_loft - quay |
| D7 | Smokehouse Arch | -30,0 | 1250 | quay - smokehouse |
| D8 | Slipway Gate | 30,-2 | 1250 | quay - slipway |
| D9 | Retort Gate | -6,-12 | 1500 | quay - retort |
| D10 | Boiler Door | -42,-12 | 1500 | smokehouse - boiler |
| D11 | Tank Farm Gate | 48,-12 | 1500 | slipway - tank_farm |
| D12 | Firebox Arch | -26,-17 | 1750 | boiler - retort |
| D13 | Retort East Door | 16,-17 | 1750 | retort - tank_farm |

## Decks, ramps, wall-jumps
| deck | rect | top y |
|---|---|---|
| NetGantry | -46,-30,25,28 | 3.6 |
| IceMezzanine | 48,54,16,38 | 3.6 |
| FlueGallery | -54,-36,-12,-9 | 4.0 |
| CraneDeck | -16,16,-1.5,1.5 | 4.0 |
| LaunchGantry | 51,54,-8,12 | 3.6 |
| BoilerCatwalkN | -54,-26,-40,-37 | 4.2 |
| BoilerCatwalkLip | -43.5,-40.1,-37,-36 | 4.2 |
| BoilerCatwalkW | -54,-51,-37,-25 | 4.2 |
| RetortGallery | -26,16,-40,-37 | 4.0 |

| ramp | rect | high / low | descent |
|---|---|---|---|
| RampPierW | -12,-8,32.5,36.5 | 1.0 / 0.0 | -z |
| RampPierE | 8,12,32.5,36.5 | 1.0 / 0.0 | -z |
| RampGantryE | -30,-22.3,25,28 | 3.6 / 0.0 | +x |
| RampIceN | 40.5,48,18,21 | 3.6 / 0.0 | -x |
| RampIceS | 40.5,48,31,34 | 3.6 / 0.0 | -x |
| RampFlueW | -53.7,-50.7,-9,-1 | 4.0 / 0.0 | +z |
| RampFlueE | -39,-36,-9,-1 | 4.0 / 0.0 | +z |
| RampCraneW | -24,-16,-1.5,1.5 | 4.0 / 0.0 | -x |
| RampCraneE | 16,24,-1.5,1.5 | 4.0 / 0.0 | +x |
| RampSlipHut | 39.5,44.5,-8.75,-5.75 | 2.0 / 0.0 | +x |
| RampLaunchN | 43,51,-2.5,0.5 | 3.6 / 0.0 | -x |
| RampLaunchS | 43,51,6,9 | 3.6 / 0.0 | -x |
| RampBoilerW | -54,-51,-25,-17 | 4.2 / 0.0 | +z |
| RampBoilerE | -29.7,-26.7,-37,-29 | 4.2 / 0.0 | +z |
| RampRetortW | -25.7,-22.7,-37,-29 | 4.0 / 0.0 | +z |
| RampRetortE | 12.7,15.7,-37,-29 | 4.0 / 0.0 | +z |
| RampPitW | -12,-8,-21.5,-18.5 | 0.0 / -1.0 | +x |
| RampPitE | 0,4,-33.5,-30.5 | 0.0 / -1.0 | -x |
| RampPumpRoofS | 42,45,-28,-20 | 4.0 / 0.0 | +z |
| RampPumpRoofW | 34,42,-31,-28 | 4.0 / 0.0 | -x |

| wall-jump | start | kicks | target h |
|---|---|---|---|
| WJ1 Slip Hut | (30.75, 0.0, -7.25) | 1 | 2.0 |
| WJ2 Rack Aisle | (-35.6, 0.0, 31.0) | 2 | 3.6 |
| WJ3 Smoke Chimney | (-43.1, 0.0, -35.0) | 3 | 4.2 |
| WJ4 Pump Slot | (39.0, 0.0, -36.0) | 2 | 4.0 |

WJ1 (Slip Hut roof) is the single zombie-proof dead end; its roof is a perch, not an objective.

## Loops and slide lanes
- L1 Trawler loop ~82 m
- L2 Rack loop ~77 m
- L3 Brine tower circle ~44 m
- L4 Ice core loop ~60 m
- L5 Retort pit loop ~86 m
- L6 Quay hull loop ~66 m
- L7 Pier-Quay-Loft ring A-E-B-A ~110 m
- Pier lane: (-6.0, 32.5) to (6.0, 32.5)
- Quay south lane: (-26.0, 10.0) to (-2.0, 10.0)
- Quay north lane: (2.0, -9.0) to (28.0, -9.0)
- Smokehouse lane: (-52.0, 2.0) to (-34.0, 2.0)
- Slip lane: (32.0, 11.5) to (48.0, 11.5)
- Retort south lane: (-24.0, -15.0) to (12.0, -15.0)

## Markers
| spawn | at | area | note |
|---|---|---|---|
| Spawn1 | -16.5,0.1,16.0 | start | NW culvert by the loft wall |
| Spawn2 | -10.5,0.1,18.5 | start | behind the trawler, bilge drain |
| Spawn3 | 12.0,1.1,38.5 | start | on the pier, bait chute |
| Spawn4 | -52.5,0.1,37.5 | net_loft | winch pit corner |
| Spawn5 | -20.5,0.1,16.0 | net_loft | NE drain by the quay gate |
| Spawn6 | -30.5,0.1,38.5 | net_loft | net chute, south wall |
| Spawn7 | 52.5,0.1,38.0 | ice_house | reefer vent SE |
| Spawn8 | 20.5,0.1,38.5 | ice_house | SW loading hatch |
| Spawn9 | 20.5,0.1,16.0 | ice_house | NW cold drain |
| Spawn10 | -52.5,0.1,12.5 | smokehouse | SW flue |
| Spawn11 | -31.5,0.1,12.5 | smokehouse | SE ash chute |
| Spawn12 | -28.5,0.1,12.5 | quay | west dock steps |
| Spawn13 | 28.5,0.1,12.5 | quay | east dock steps |
| Spawn14 | 12.0,0.1,-10.5 | quay | under the north wall, drain |
| Spawn15 | 52.5,0.1,-10.5 | slipway | NE slip gutter |
| Spawn16 | 32.0,0.1,12.5 | slipway | SW slip gutter |
| Spawn17 | -52.5,0.1,-14.5 | boiler | west wall breach |
| Spawn18 | -34.0,0.1,-38.5 | boiler | under the north catwalk |
| Spawn19 | -20.5,0.1,-38.5 | retort | NW retort stall |
| Spawn20 | 14.0,0.1,-38.5 | retort | NE retort stall |
| Spawn21 | 52.5,0.1,-14.0 | tank_farm | SE fence |
| Spawn22 | 18.0,0.1,-38.5 | tank_farm | NW fence |

| chest spot | at | area | hidden | initial |
|---|---|---|---|---|
| ChestSpot1 | 6.0,1.0,39.2 | start | False | True |
| ChestSpot2 | -17.3,0.0,19.0 | start | True | False |
| ChestSpot3 | -53.2,0.0,20.0 | net_loft | True | False |
| ChestSpot4 | 53.2,3.6,27.0 | ice_house | False | True |
| ChestSpot5 | -53.2,0.0,6.0 | smokehouse | True | False |
| ChestSpot6 | -29.2,0.0,8.0 | quay | True | False |
| ChestSpot7 | 29.2,0.0,-8.5 | quay | True | False |
| ChestSpot8 | 30.8,0.0,10.5 | slipway | True | False |
| ChestSpot9 | -36.0,0.0,-13.0 | boiler | True | False |
| ChestSpot10 | -4.0,-1.0,-33.5 | retort | False | True |
| ChestSpot11 | 53.1,0.0,-34.0 | tank_farm | True | False |

Perk machine (-48.0, 0.0, -10.9), mystery box (53.0, 3.6, 34.0), power weapon (48.0, 4.0, -34.0), boss arena centre (-4.0, -1.0, -26.0) (radius 5.5; 16 x 16 m pit floor at -1.0).

| ambience emitter | at | key |
|---|---|---|
| Amb_PierSodium | -12.0,1.6,18.0 | ambience_emitter_sodium_buzz_loop |
| Amb_LoftDrip | -44.0,1.6,19.0 | ambience_emitter_drip_pipe_loop |
| Amb_IceDrip | 24.0,1.6,36.0 | ambience_emitter_drip_pipe_loop |
| Amb_QuaySodium | -12.0,1.6,10.0 | ambience_emitter_sodium_buzz_loop |
| Amb_SmokeSpark | -33.0,1.6,11.0 | ambience_emitter_sparking_box_loop |
| Amb_CraneSpark | 14.0,1.6,-9.0 | ambience_emitter_sparking_box_loop |
| Amb_SlipSodium | 46.0,1.6,10.0 | ambience_emitter_sodium_buzz_loop |
| Amb_BoilerDrip | -47.0,1.6,-15.0 | ambience_emitter_drip_pipe_loop |
| Amb_BoilerSpark | -29.0,1.6,-22.0 | ambience_emitter_sparking_box_loop |
| Amb_RetortDrip | -20.0,1.6,-34.0 | ambience_emitter_drip_pipe_loop |
| Amb_TankSodium | 36.0,1.6,-24.0 | ambience_emitter_sodium_buzz_loop |
| Amb_PumpDrip | 49.0,1.6,-22.0 | ambience_emitter_drip_pipe_loop |

## Lighting
Every light sits on a Desi fixture (`assets/models/props/light_*.glb`), mounted with `tools/godot/mount_lights.gd` and the plan
`tools/godot/light_plans/drowned_cannery.json`. At most 4 shadowed lights including the moon (PierFlood, QuayFlood, PitLamp + moon).
`tools/godot/test_light_fixtures.gd` passes. Zombies read at 15-20 m against the lit floor (contrast probe, see PROGRESS notes).

## Build and checks (Mapz scratch project, not shipped)
gen_cannery.py -> export_nav_layout.py -> --import -> fix_nav_ramps.gd -> merge_cannery.gd -> mount_lights.gd.
Checks: verify_map, verify_cannery (LOS, loop width, routes >= 2 m), void gaps, chest spots, rails, light fixtures, wall-jump sim,
nav sim (all doors open and all closed, 0 stalls), magenta scan on the screenshots.
