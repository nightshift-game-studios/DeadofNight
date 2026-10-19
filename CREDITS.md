# Credits

Every third-party model, texture, HDRI and animation in this project is **CC0 1.0 (public domain)**:
free for personal and commercial use, no attribution required. The two fonts are **SIL OFL 1.1**
(free for commercial use and bundling; license files are next to the fonts). Credit is still given below.
Nothing here is CC-BY, non-commercial, or of unclear license.

License text: https://creativecommons.org/publicdomain/zero/1.0/

## Weapons: Quaternius, "Ultimate Guns Pack" (CC0)
Pack page: https://poly.pizza/bundle/Ultimate-Guns-Pack-cpgUfI4t2F (author site: https://quaternius.com)

| File (assets/models/guns/) | Original model | Source URL | Author | License |
|---|---|---|---|---|
| sidearm.glb | Pistol | https://poly.pizza/m/52kQzphmeF | Quaternius | CC0 |
| hand_cannon.glb | Revolver | https://poly.pizza/m/9C26wSpMS0 | Quaternius | CC0 |
| auto_rifle.glb | Assault Rifle | https://poly.pizza/m/Bgvuu4CUMV | Quaternius | CC0 |
| scout_rifle.glb | Assault Rifle | https://poly.pizza/m/K2lXTYFSLC | Quaternius | CC0 |
| pulse_rifle.glb | Assault Rifle | https://poly.pizza/m/fpLucho45C | Quaternius | CC0 |
| smg.glb | Submachine Gun | https://poly.pizza/m/7ehatxr7FY | Quaternius | CC0 |
| shotgun.glb | Shotgun | https://poly.pizza/m/DcNE0HVdW8 | Quaternius | CC0 |
| sniper_rifle.glb | Sniper Rifle | https://poly.pizza/m/ASOMZIErq3 | Quaternius | CC0 |
| rocket_launcher.glb | Rocket Launcher | https://poly.pizza/m/GCqUvqleqN | Quaternius | CC0 |

`assets/icons/*.png` are renders of these models made with `tests/render_icons.gd` (same CC0 license).

## Zombie: "Male City Zombie" re-rig by Desi (CC0): mesh by Rikindle3D, rig/animations by Quaternius
File: `assets/models/zombies/city_zombie.glb` (single GLB, 2K textures embedded). **No Mixamo-derived data**:
the source file's original armature, bind matrices, skin weights and animations were deleted before the new rig was built.
The earlier Mixamo-rigged versions (city_zombie_pass1.glb, city_zombie_pass2_oldrig.glb, and the old 1K-texture
city_zombie.glb) are **not** included in this project.

| Part | Source | Author | License |
|---|---|---|---|
| Base mesh (geometry, normals, UV topology) and original AO | "Male City Zombie, Ready for use in Game Engines" https://opengameart.org/content/male-city-zombie-ready-for-use-in-game-engines | Rikindle3D | CC0 1.0 |
| Skeleton (bone names/hierarchy) and clips Zombie_Walk_Fwd_Loop, Zombie_Idle_Loop, Zombie_Scratch | Universal Animation Library 2 (UAL2), Standard pack https://opengameart.org/content/universal-animation-library-2 | Quaternius | CC0 1.0 |
| Clips Jog_Fwd_Loop, Death01, Hit_Chest (retargeted onto the UAL2 skeleton, zombie posture overlay on the run) | Universal Animation Library (UAL1) https://quaternius.itch.io/universal-animation-library | Quaternius | CC0 1.0 |
| Skeleton fit, new skin weights, 2048 px body/outfit albedo/normal/ORM textures | made for this project (Blender 4.5 heat weighting + procedural bakes) | Desi | CC0 1.0 |

In-game clip names: Zombie_Walk, Zombie_Idle, Zombie_Attack, Zombie_Run, Zombie_Death, Zombie_HitReact.
Tools: Blender 4.5.14 LTS, glTF-Transform (MIT), Godot 4.7.2. Preview-render-only assets (Poly Haven HDRI
"abandoned_tank_farm_05" by Sergej Majboroda, texture "damaged_concrete_floor" by Rob Tuytel, both CC0) are not in the GLB.

## Zombie variants (worker, soldier) and v2 cleanup, by Desi (CC0)
Files: `assets/models/zombies/city_zombie.glb` (v2 cleanup), `zombie_worker.glb` (hi-vis coveralls + hard hat) and `zombie_soldier.glb` (woodland camo, helmet, plate carrier). Same base mesh, UAL2 skeleton and clips as above, so the same Rikindle3D / Quaternius CC0 credits apply. New textures and gear meshes are by Desi, CC0. No Mixamo-derived data; the *_v1, *_pass1 and *_oldrig files are not included.

### city_zombie.glb
Verbatim from Desi's `CREDITS.txt`:

```
city_zombie.glb: "Male City Zombie", retextured (pass 2) and fully re-rigged by Desi
==================================================================================
No Mixamo-derived data remains in city_zombie.glb. The original armature, bind matrices,
skin weights and every original animation were deleted before the new rig was built.

Base mesh (geometry, normals, UV topology) and the original AO
  Name:    Male City Zombie, Ready for use in Game Engines
  Author:  Rikindle3D
  URL:     https://opengameart.org/content/male-city-zombie-ready-for-use-in-game-engines
  License: CC0 1.0 (as listed on the OpenGameArt page)
  Copied read-only from /workspace/fps-starter/assets/models/zombies/city_zombie.glb.
  Only the mesh was kept: the skeleton, skin weights and animations in that file were discarded.

Skeleton and animations: Quaternius, CC0 1.0
  Universal Animation Library 2 (UAL2), Standard pack (bone names and hierarchy, plus the clips
  Zombie_Walk_Fwd_Loop, Zombie_Idle_Loop and Zombie_Scratch, used natively)
    https://opengameart.org/content/universal-animation-library-2  (License.txt in the zip: CC0 1.0)
  Universal Animation Library (UAL1): Jog_Fwd_Loop, Death01 and Hit_Chest, retargeted onto the
  UAL2 skeleton (same Quaternius mannequin) with a zombie posture overlay on the run
    https://quaternius.itch.io/universal-animation-library  (CC0 1.0)
  The skeleton was fitted to this mesh's proportions. Skin weights are NEW, generated with Blender
  heat weighting and then cleaned up (CC0).

Textures: NEW, made for this project and released CC0
  body_* and outfit_* albedo/normal/ORM at 2048 px: procedural Blender 4.5 bakes onto repacked
  UVs, reusing the original asset's CC0 AO and a little of its normal map.

Preview renders only (not in the GLB)
  HDRI "abandoned_tank_farm_05", Sergej Majboroda, Poly Haven, CC0: https://polyhaven.com/a/abandoned_tank_farm_05
  Texture "damaged_concrete_floor", Rob Tuytel, Poly Haven, CC0: https://polyhaven.com/a/damaged_concrete_floor

Tools: Blender 4.5.14 LTS (GPL; its output isn't covered by that license), glTF-Transform (MIT),
Godot 4.7.2 (import check only).

Older files in this folder:
  city_zombie_pass1.glb and city_zombie_pass2_oldrig.glb still contain the ORIGINAL skeleton,
  skin weights and animations from the source file (Mixamo-derived per the project's review).
  Do not ship them if the goal is to have no Mixamo data.

v2 cleanup (Oct 19 2026): the skin pores, wrinkles and fabric weave were rebaked at a lower frequency, and the baked normal map
was given a 0.6 px blur to stop aliasing at 2K. The soldier camo was redone as domain-warped woodland blobs.
The rig, clips, UVs and geometry are unchanged. The previous files are kept as *_v1.glb. All textures are still CC0
procedural bakes from this project.
```

### zombie_worker.glb
Verbatim from Desi's `CREDITS.txt`:

```
zombie_worker.glb: "worker" variant of city_zombie.glb (by Desi)
=================================================================
Built on the re-rigged city_zombie.glb. It has the same mesh, UVs, UAL2 skeleton (65 bones, same names),
the same 6 clips, origin and -Z facing. There is no Mixamo-derived data in this file.

Base mesh (geometry, UV topology) and the original AO
  "Male City Zombie, Ready for use in Game Engines", Rikindle3D, CC0 1.0
  https://opengameart.org/content/male-city-zombie-ready-for-use-in-game-engines

Skeleton and animations: Quaternius, CC0 1.0
  Universal Animation Library 2: https://opengameart.org/content/universal-animation-library-2
  Universal Animation Library:   https://quaternius.itch.io/universal-animation-library
  The skin weights are new (Blender heat weighting plus cleanup), CC0.

Textures: NEW, made for this project and released CC0
  Skin: pale grey-blue skin with a different wound set (neck/shoulder bite, forearm bites, cheek, scalp, shins).
  Clothes: faded hi-vis orange coveralls with torn and scuffed reflective strips (chest and both shins), plus oil, grease and blood stains.
  These are procedural Blender 4.5 bakes, 2048 px for the skin and clothes and 1024 px for the gear.
  They reuse a little of the original asset's CC0 AO and normal map. No other third-party images were used.
Gear geometry
  Hard hat (300 tris): a NEW low-poly mesh made for this project, rigid, skinned 100% to Head. Its textures are NEW procedural bakes (CC0).

Preview renders only (not in the GLB)
  Poly Haven, CC0: HDRI "abandoned_tank_farm_05" (Sergej Majboroda), texture "damaged_concrete_floor" (Rob Tuytel).
Tools: Blender 4.5.14 LTS, glTF-Transform (MIT), Godot 4.7.2 (import check only).

v2 cleanup (Oct 19 2026): the skin pores, wrinkles and fabric weave were rebaked at a lower frequency, and the baked normal map
was given a 0.6 px blur to stop aliasing at 2K. The soldier camo was redone as domain-warped woodland blobs.
The rig, clips, UVs and geometry are unchanged. The previous files are kept as *_v1.glb. All textures are still CC0
procedural bakes from this project.
```

### zombie_soldier.glb
Verbatim from Desi's `CREDITS.txt`:

```
zombie_soldier.glb: "soldier" variant of city_zombie.glb (by Desi)
=================================================================
Built on the re-rigged city_zombie.glb. It has the same mesh, UVs, UAL2 skeleton (65 bones, same names),
the same 6 clips, origin and -Z facing. There is no Mixamo-derived data in this file.

Base mesh (geometry, UV topology) and the original AO
  "Male City Zombie, Ready for use in Game Engines", Rikindle3D, CC0 1.0
  https://opengameart.org/content/male-city-zombie-ready-for-use-in-game-engines

Skeleton and animations: Quaternius, CC0 1.0
  Universal Animation Library 2: https://opengameart.org/content/universal-animation-library-2
  Universal Animation Library:   https://quaternius.itch.io/universal-animation-library
  The skin weights are new (Blender heat weighting plus cleanup), CC0.

Textures: NEW, made for this project and released CC0
  Skin: darker brown decayed skin with shrapnel-style peppered wounds, a neck gash and a large forearm wound.
  Clothes: faded, torn woodland/OCP-style camo fatigues with ripstop, mud, burn holes and blood.
  These are procedural Blender 4.5 bakes, 2048 px for the skin and clothes and 1024 px for the gear.
  They reuse a little of the original asset's CC0 AO and normal map. No other third-party images were used.
Gear geometry
  Helmet and plate carrier with 3 pouches (948 tris): NEW low-poly meshes made for this project. The helmet is rigid and skinned 100% to Head. The vest is skinned to the torso bones (pelvis, spine_01-03, neck_01, clavicles); see the note below. Its textures are NEW procedural bakes (CC0).

Preview renders only (not in the GLB)
  Poly Haven, CC0: HDRI "abandoned_tank_farm_05" (Sergej Majboroda), texture "damaged_concrete_floor" (Rob Tuytel).
Tools: Blender 4.5.14 LTS, glTF-Transform (MIT), Godot 4.7.2 (import check only).

v2 cleanup (Oct 19 2026): the skin pores, wrinkles and fabric weave were rebaked at a lower frequency, and the baked normal map
was given a 0.6 px blur to stop aliasing at 2K. The soldier camo was redone as domain-warped woodland blobs.
The rig, clips, UVs and geometry are unchanged. The previous files are kept as *_v1.glb. All textures are still CC0
procedural bakes from this project.
```

## Armor set by Desi (CC0; textures baked from Poly Haven CC0 materials)
Files: `assets/models/armor/armor_{helmet,gauntlets,chest,legs,cloak,sash}.glb` (skinned to the UAL2 skeleton) and `assets/models/armor/display/*_display.glb` (unskinned, centred). Mapping: `data/armor_models.json`.

| Source texture | URL | License |
|---|---|---|
| metal_plate_02 | https://polyhaven.com/a/metal_plate_02 | CC0 1.0 |
| green_metal_rust | https://polyhaven.com/a/green_metal_rust | CC0 1.0 |
| brown_leather | https://polyhaven.com/a/brown_leather | CC0 1.0 |
| denim_fabric | https://polyhaven.com/a/denim_fabric | CC0 1.0 |
| poly_wool_herringbone | https://polyhaven.com/a/poly_wool_herringbone | CC0 1.0 |

### armor
Verbatim from Desi's `CREDITS.txt`:

```
Armor set (military-survival style), made by Desi for this project and released CC0
================================================================================
Pieces: armor_helmet, armor_gauntlets (nodes gauntlet_l and gauntlet_r), armor_chest, armor_legs, armor_cloak, armor_sash.
Each piece has a skinned GLB (in this folder) and a centered display GLB (display/*_display.glb).

Geometry: NEW. It was modelled procedurally in Blender 4.5 by ray-casting shells fitted to the "Male City Zombie" body
(Rikindle3D, CC0, https://opengameart.org/content/male-city-zombie-ready-for-use-in-game-engines), with no mesh copied.
Skeleton: Quaternius Universal Animation Library 2 (UAL2), CC0, https://opengameart.org/content/universal-animation-library-2
  The pieces are skinned to the same 65 UAL2 bone names and the same rest pose as city_zombie.glb. Weights were transferred from
  that body's (new, CC0) weights and limited per piece to the relevant bones.
  The UAL2 "Idle_No_Loop" clip (CC0) was used only to pose the mannequin in armor_set.png.

Tiling source textures (all CC0, Poly Haven, 1K). They were baked together with procedural wear, grime and edge chipping
into each piece's own albedo/normal/ORM set:
  metal_plate_02         https://polyhaven.com/a/metal_plate_02          (bare/worn steel)
  green_metal_rust       https://polyhaven.com/a/green_metal_rust        (painted helmet steel)
  brown_leather          https://polyhaven.com/a/brown_leather           (leather)
  denim_fabric           https://polyhaven.com/a/denim_fabric            (canvas, quilted gambeson and webbing: weave and normal only, recoloured)
  poly_wool_herringbone  https://polyhaven.com/a/poly_wool_herringbone   (cloak wool and sash cloth, recoloured)
Preview renders only: HDRI abandoned_tank_farm_05 (Sergej Majboroda) and damaged_concrete_floor (Rob Tuytel), Poly Haven, CC0.
Tools: Blender 4.5.14 LTS, Godot 4.7.2 (import check only).
```

## Map: Rustwell Foundry by Mapz (greybox v0.2)
`maps/rustwell_foundry/` and `maps/common/` were written for this project by Mapz (procedural geometry, `gen_rustwell.py`). The map ships no third-party assets of its own; it reuses the Poly Haven CC0 textures and HDRI already credited in this file. Details: `maps/rustwell_foundry/CREDITS.md`.

## Audio: self-synthesized (CC0)
All 141 sounds in `assets/audio/` (sfx/weapons, sfx/zombies, sfx/player, sfx/world, sfx/ui, music, ambience)
were synthesized for this project and are released CC0 1.0. Per-file notes: `assets/audio/AUDIO_CREDITS.md`.

## Fonts (SIL Open Font License 1.1)
| File (assets/fonts/) | Used for | Source URL | Author | License |
|---|---|---|---|---|
| BlackOpsOne-Regular.ttf | Stencil headings, numbers, round counter | https://fonts.google.com/specimen/Black+Ops+One | The Black Ops One Project Authors (James Grieshaber, Eben Sorkin) | OFL 1.1 (BlackOpsOne-OFL.txt) |
| Oswald-Variable.ttf | Body text and labels (default UI font) | https://fonts.google.com/specimen/Oswald | The Oswald Project Authors (Vernon Adams et al.) | OFL 1.1 (Oswald-OFL.txt) |

## PBR textures: Poly Haven (CC0), 1k diffuse, normal (GL) and ARM maps
| Folder (assets/textures/) | Used for | Source URL | Author(s) | License |
|---|---|---|---|---|
| damaged_concrete_floor | Floor | https://polyhaven.com/a/damaged_concrete_floor | Rob Tuytel | CC0 |
| dirty_concrete | Outer walls | https://polyhaven.com/a/dirty_concrete | Rob Tuytel | CC0 |
| broken_brick_wall | Tall alley / ruin walls | https://polyhaven.com/a/broken_brick_wall | Amal Kumar | CC0 |
| concrete_wall_006 | Cover walls, pillars, tower | https://polyhaven.com/a/concrete_wall_006 | Dario Barresi, Charlotte Baglioni | CC0 |
| rusty_metal_02 | Platform, ledge, ramp | https://polyhaven.com/a/rusty_metal_02 | Rob Tuytel | CC0 |

## Sky: Poly Haven HDRI (CC0)
| File | Source URL | Author | License |
|---|---|---|---|
| assets/hdri/abandoned_tank_farm_05_2k.hdr | https://polyhaven.com/a/abandoned_tank_farm_05 | Sergej Majboroda | CC0 |

## Props: Poly Haven models (CC0), 1k glTF
| Folder (assets/models/props/) | Used for | Source URL | Author(s) | License |
|---|---|---|---|---|
| wooden_crate_01 | Cover crates | https://polyhaven.com/a/wooden_crate_01 | James Ray Cock | CC0 |
| wooden_crate_02 | Loot chests | https://polyhaven.com/a/wooden_crate_02 | James Ray Cock, Jurita Burger | CC0 |
| barrel_03 | Barrels | https://polyhaven.com/a/barrel_03 | Serhii Khromov | CC0 |
| concrete_road_barrier | Barriers | https://polyhaven.com/a/concrete_road_barrier | Amal Kumar | CC0 |
| metal_trash_can | Decor | https://polyhaven.com/a/metal_trash_can | GurJas Studios | CC0 |
| trashbag | Decor | https://polyhaven.com/a/trashbag | Benny Weimer | CC0 |
| industrial_pastic_container | Cover | https://polyhaven.com/a/industrial_pastic_container | Galo Benivegna | CC0 |
| medical_box | Health Pack pickup | https://polyhaven.com/a/medical_box | Ulan Cabanilla | CC0 |
| ammo_box | Ammo pickups | https://polyhaven.com/a/ammo_box | DanKit | CC0 |
| metal_jerrycan | Decor | https://polyhaven.com/a/metal_jerrycan | Sean Buckley | CC0 |
| worn_metal_rack | Decor | https://polyhaven.com/a/worn_metal_rack | Luca B | CC0 |
| power_box_01 | Decor | https://polyhaven.com/a/power_box_01 | Rico Cilliers, Yann Kervran | CC0 |
| covered_car | Cover | https://polyhaven.com/a/covered_car | MP | CC0 |

Poly Haven license page: https://polyhaven.com/license (all assets CC0).

## Everything else
Code, JSON data, loot shards, the explosion/grenade effects, HUD and the character-screen mannequin
were made for this project from Godot built-in meshes and materials.
