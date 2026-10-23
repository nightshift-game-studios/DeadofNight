# Gravecrew – Developer Guide (systems, data files, extending the game)

> Player install guide: see README.md. This file is the in-depth technical reference.

A playable first-person zombie shooter written entirely in GDScript. It's the foundation for a
classic round-based zombies game with looter-shooter gear. It has:
- rounds of zombies, points, classes with abilities, a persistent skill tree and saved progression;
- randomly rolled weapons and armor (rarity, **Item Power**, stats, fictional manufacturers, perks) dropped by zombies and chests;
- a chunky cut-corner character screen with item cards that compare against what you have equipped;
- a rugged, low-clutter HUD (stencil fonts, painted tally-mark round counter, icon cooldowns, low-health vignette);
- grenades, and slide/crouch/wall-jump movement.

Art is real CC0 assets (Quaternius guns, an OpenGameArt CC0 zombie re-rigged onto the Quaternius CC0 UAL2 skeleton, self-synthesized CC0 audio,
Poly Haven textures, props and HDRI sky) and two SIL OFL fonts (Black Ops One, Oswald).
See **CREDITS.md**.

Tested with **Godot 4.7.2 stable** (standard version, not .NET/C#). The renderer is Forward+, so you
need a GPU with Vulkan or Direct3D 12 support (any gaming PC from the last ~8 years).

## 1. Install Godot on Windows
1. Go to **https://godotengine.org/download** and pick **Windows**.
2. Download the standard **Godot Engine** build. You do *not* need the ".NET" version.
3. Unzip it anywhere. There's no installer: just double-click `Godot_v4.x-stable_win64.exe`.

## 2. Open this project
1. Unzip `fps-starter.zip` somewhere (e.g. `Documents\fps-starter`).
2. In the Godot Project Manager, click **Import**, browse to the folder, and select **`project.godot`**.
   Then click **Import & Edit**. The first import takes about 30–60 seconds because the textures and models are being imported.
3. Press **F5** (or the ▶ Play button at top-right) to play.

## 3. Controls
| Action | Key |
|---|---|
| Move | W A S D (or arrow keys) |
| Sprint | Shift |
| Jump | Space |
| **Wall jump** | Space while in the air next to a wall. Up to 3 jumps before you land again. Try the tall brick alley in the north-west corner |
| **Crouch** | Hold C or Ctrl |
| **Slide** | Press C or Ctrl while sprinting. Jump during a slide to keep the momentum (slide-jump) |
| Look | Mouse |
| Shoot | Left mouse (hold it for automatic weapons) |
| Reload | R |
| **Grenade** | G (Soldier: Frag, Scout: Tremor Charge). Cooldown depends on Ordnance |
| **Melee** | V |
| Class ability | Q (Soldier: Dash, Scout: Adrenaline). Cooldown depends on Focus |
| Interact (pick up loot, open chest) | E. Ammo is picked up just by walking over it |
| Switch weapon | 1 = Primary, 2 = Secondary, 3 = Heavy |
| **Character screen** | Tab or I (pauses the game) |
| Skill tree | K (before round 1 starts, or on the game-over screen) |
| **Change map** | M (before round 1 starts, or on the game-over screen): Arena ↔ Rustwell Foundry. Restarts the match on that map |
| Free / recapture mouse | Esc (click to recapture) |
| Restart after game over | Enter |
| Choose class for next game | 1 = Soldier, 2 = Scout (on the game-over screen) |

**Character screen:** your weapons are on the left (Primary / Secondary / Heavy), your armor is on the right
(Helmet / Gauntlets / Chest / Legs / Class Item), and the character is in the middle with your total stats under it.
- Every tile shows the item's **Item Power** in its corner. Stash tiles get a green/red arrow if they look better/worse.
- Click a slot to open its grid of spare items.
- Hover over an item to see its card: icon, rarity tag, **Item Power with a +/- delta vs equipped**, name in rarity
  colour, manufacturer, big damage number, stat block with bars and ▲/▼ deltas vs equipped, perks, flavor text.
- **Click** an item to equip it. **Right-click** it to dismantle it.

## 4. How a match plays
- **Maps:** the original **Arena** (default) or **Rustwell Foundry** (Mapz's overrun steel works). Press **M** before round 1
  or on the game-over screen to switch; the choice sticks for restarts. See "Maps" in section 6.
- You start with a Common Sidearm, a Common SMG and a full set of Common armor.
- You get a few seconds before **Round 1** starts. Use them to open the skill tree with K.
- **Field Cards:** after every cleared round the game pauses and offers 3 cards (pick one, reroll for points, skip for
  +100 × round points, or banish if you own Black Ledger). Every 5th round is a milestone with 2 legendaries. Cards last one match.
- Zombies come from 7 spawn points in the Arena. On Rustwell Foundry they only come from areas you've opened (see Maps below).
  Every round brings more of them, with more health and speed.
- **Zombie types:** Walkers (city clothes) at first, then Foundry Workers (hi-vis coveralls, hard hat) and, from round 3,
  Soldiers (camo, helmet, plate carrier; 20% more health, 10% harder hits, slightly slower). The mix shifts toward
  workers and soldiers in later rounds (`data/zombies.json`).
- **Points:** +10 per hit and +100 per kill (top-left). `player.spend_points()` is ready for wall-buys later.
- **Loot:**
  - Zombies sometimes drop **loot shards** (glowing gems in the item's rarity colour), ammo or health packs.
  - The **3 crates with an orange glow** are chests. Each one can be opened once per round and gives 2 better items.
    One chest is on the ledge at the end of the wall-jump alley.
  - A **Rare Rocket Launcher** is waiting on the raised metal platform.
- **Ammo:** Primary ammo (metal ammo box) refills your Primary and Secondary weapons. **Heavy ammo** (purple box)
  refills the Heavy weapon. Reserves are also topped up at the start of every round.
- When you die you earn **XP** (10 per kill + 50 per round reached). XP gives skill points and is saved.
  Gear is per-match, so you start fresh every game. See "Vault" below for how to make gear persist.

## 5. Project layout
```
project.godot                  Input map, main scene, autoloads (GearDB, Progress, Sfx, GameEvents, RunState), [skills] settings
CREDITS.md                     Every third-party asset with source URL, author and license
assets/                        CC0 models, textures, HDRI sky, weapon icons (~47 MB)
data/weapons.json              Weapon archetypes (stats, model, view-model placement, mythic version) + manufacturers
data/armor.json                Armor slots, stat totals per rarity, names, brands, mythic armor
data/perks.json                Weapon perks
data/loot_tables.json          Drop tables (zombie, chest, ...), rarity weights, Item Power curve
data/grenades.json             Grenade types (frag, Tremor Charge = "pulse")
data/skill_tree.json           Meta skill tree v2 (35 nodes, 7 branches, x/y grid, ranks, choices, class strips)
data/run_picks.json            Field Cards: 52 temporary field cards (normal + legendary) + offer economy
data/maps.json                 Map list (arena = built-in, rustwell_foundry) + default
data/zombies.json              Zombie variants (model, height, stat multipliers) + wave mix per round
data/armor_models.json         Armor slot -> skinned / display model paths
maps/                          Mapz's maps (map contract v0.2): common/map_root.gd, common/map_door.gd, rustwell_foundry/
scripts/world/                 MapRegistry (map selection), ZombieVariants, ArmorModels
tests/map_test.gd              Headless map / variants / armor-mapping / movement-fix test
scenes/main.tscn               Arena (generated), lights, sky, navmesh, spawn points, chests, pickups
scenes/player.tscn             Player body, camera, view-model mount, Inventory node
scenes/enemy.tscn              Zombie (city_zombie.glb by default; variants from data/zombies.json)
scripts/audio/sfx.gd           Sfx autoload: sound bank, buses, pooled 2D/3D players, music crossfade, zombie voice cap
scripts/audio/hit_sfx.gd       Hit-marker sounds (body / head / kill)
assets/audio/                  141 CC0 sounds (sfx/weapons, zombies, player, world, ui, music, ambience)
default_bus_layout.tres        Audio buses: Master, Music, SFX, UI, Ambience
scenes/pickup.tscn             World pickup (loot shard or item model)
scenes/chest.tscn              Loot chest
scripts/main.gd                Rounds, points, loot drops, chests, menus, game over and saving
scripts/player.gd              Movement (crouch/slide/wall jump), shooting, grenades, melee, armor stats
scripts/enemy.gd               Zombie AI (navmesh chase), animations, knockback, precision hits
scripts/hud.gd                 HUD: health, tally round counter, points, weapon/ammo, cooldown icons, hints, loot feed
scripts/autoload/gear_db.gd    GearDB: loads the JSON files and rolls random weapons, armor and loot
scripts/autoload/progress.gd   Progress: saved XP, kills, best round, class, skill tree
scripts/gear/rarity.gd         Rarity names, colours, stat bonus and perk slots per rarity
scripts/gear/perk_system.gd    What each perk effect does
scripts/items/                 Item, GearItem, WeaponItem, ArmorItem, ConsumableItem, Inventory, Pickup, Chest
scripts/combat/                Explosion (area damage + VFX), Grenade, Rocket
scripts/ui/character_screen.gd Character screen + hover item card (tooltip) + comparison
scripts/ui/ui_style.gd         Shared palette, fonts, cut-corner panels, grit overlay, bars
scripts/ui/perk_badge.gd       Hex perk icon   scripts/ui/delta_arrow.gd  ▲/▼ comparison arrow
scripts/ui/cooldown_icon.gd    HUD cooldown badge   scripts/ui/tally_counter.gd  painted round counter
assets/fonts/                  Black Ops One + Oswald (SIL OFL 1.1)
scripts/ui/skill_tree_menu.gd  Skill tree menu
scripts/skills/                GameEvents bus, RunState (Field Cards), SkillRunner, EffectRegistry, effects/*.gd
resources/classes/*.tres       Soldier, Scout (stats, ability, grenade type)
resources/items/*.tres         Consumables: Health Pack, Primary Ammo, Heavy Ammo
tests/smoke_test.gd            Automated headless test (see the end of this file)
tests/skills_test.gd           Headless skills test: every effect script, node and card, offers, refund cap, time-scale flag
tests/field_card_audit_test.gd Data-only audit: no field card duplicates a skill / perk / armor stat / card name, all cards temporary
tests/input_test.gd            Headless mouse-look / menu pause regression test (full checks under a display)
tests/art_test.gd              Headless art-wiring test: boss GLBs/clips/sockets, echo height, guns per archetype, WeaponRig attachments, Mine Lamp light, IP breakdown
tests/compile_check.gd         Loads every script under scripts/ and tests/ and reports parse errors
tests/render_icons.gd          Re-renders assets/icons/*.png from the gun models
```

## 6. How the systems work (and how to extend them)

### Gear: rarity, Item Power, stats
- **Rarity** (`scripts/gear/rarity.gd`): Common (white), Uncommon (green), Rare (blue), Legendary (purple),
  Mythic (orange-gold).
  - Higher rarity gives a bigger stat bonus and more perks (Common 0, Uncommon/Rare 1, Legendary 2).
  - Mythics get a fixed signature name, perk and flavor line plus 2 random perks, and armor gets bigger stat totals.
- **Item Power (Diablo-style, per item):** every weapon and armor piece rolls its own Item Power when it drops
  (`loot_tables.json → item_power`): `base + per_round × (round − 1) + rarity_bonus ± variance`, capped at `max`.
  Item Power then scales the item itself:
  - weapon damage × `1 + (IP − 100) × damage_per_point` (`WeaponItem.power_mult()`);
  - every rolled weapon stat **except Impact** gets `+ (IP − 100) × stat_points_per_point` (before the 1–100 clamp).
    Impact is listed in `item_power.ip_stat_exclude`, so the damage multiplier above is the only IP damage dial (IP 400 ≈ 2.2× base damage);
  - armor stat totals get `+ (IP − 100) × armor_points_per_point`.
  It is shown on tiles, item cards (with a +/- delta vs equipped), the HUD weapon line, pickup prompts and the loot feed.
  There is no character-wide power level; the character screen header shows a low-key "avg IP" only.
- **Manufacturers** (`weapons.json → manufacturers`, `armor.json → brands`): fictional brands (Rustwell Arms,
  Kestrel & Vane, Hollowpoint Collective, Grimtide Industries, Voltaic Foundry, Cinderjaw Munitions; Patchwork
  Outfitters, Barricade Supply Co., Ironmoth Tactical). Each has a colour, allowed slots, small `stat_mods` and flavor lines.
- **Elements:** Primary weapons are Ballistic; Secondary/Heavy roll Volt, Blaze or Blight (cosmetic colour for now).
- **Weapon stats** (0–100, rolled ± `stat_variance` around the archetype's base). Formulas are in `scripts/items/weapon_item.gd`:
  | Stat | Effect |
  |---|---|
  | Impact | damage per shot |
  | Range | distance before damage falls off (down to 50%) |
  | Stability | less spread and recoil |
  | Handling | faster weapon swap |
  | Reload Speed | shorter reload |
  | Magazine | bigger magazine |
  | RPM | fire rate (fixed per archetype) |
  Headshots (precision hits) do ×2.0 damage (`headshot_multiplier` in the data) and show yellow damage numbers.
- **Armor stats**. Each piece rolls a random spread over 6 stats, and each total is capped at 100. The code is in `player.gd → recalc_stats()`:
  | Stat | Effect (at 100) |
  |---|---|
  | Agility | +20% walk/sprint speed |
  | Toughness | 30% damage reduction |
  | Vitality | health regen starts after 2 s instead of 4 s, and regenerates faster |
  | Ordnance | grenade cooldown halved |
  | Focus | class ability cooldown −40% |
  | Brawn | melee damage +60%, melee cooldown −40% |

### Adding a weapon
Add an object to `archetypes` in **`data/weapons.json`**:
- `id`, `type`, and `slot` (`primary`, `secondary` or `heavy`).
- `model`: a `.glb` under `assets/`. Guns are expected to point along +X, which is how Quaternius models are exported.
- `view`: `length` is the on-screen size in metres, and `offset` is the position in front of the camera.
- `fire_mode` (`semi` or `auto`), `rpm`, `base_damage`, `pellets`, `spread`, `base_range`, `base_mag`, `base_reload`, `reserve_mags`.
- `stats` (the six base stats) and `names` (used for Rare and higher).
- `mythic`: `{name, perk, flavor}`.
- Add `"projectile": {"speed", "radius", "knockback"}` to make it fire rockets instead of hitscan.

It appears in loot straight away. To give it a tile icon, run `tests/render_icons.gd`.

### Adding armor
**`data/armor.json`** sets the stat total range per rarity (`piece_totals`), the name pools per slot (`names`)
and one mythic per slot (`mythics`: `name` plus a `bonus` of extra stat points), plus `brands`. Armor has no 3D model.
The character in the middle of the screen is a mannequin whose parts are tinted by the rarity of each equipped piece.

### Adding a perk
1. Add an entry to **`data/perks.json`** with `id`, `name`, `description`, an `effect` and any parameters you like.
2. If the effect is one of the existing ones (`damage_stack`, `reload_buff`, `explode`, `reload_after_kill`,
   `grenade_refund`, `heal_on_kill`, `crouch_stability`), that's all you need to do.
3. For a new effect, handle it in **`scripts/gear/perk_system.gd`**. Its hooks are `on_kill`, `on_reload`, `on_hit`, `damage_mult`,
   `reload_mult`, `spread_mult`, `tick` and `status_text`. Timed buffs live in `weapon.buffs`.
4. Any perk in the file can roll on any weapon. To make a perk mythic-only, reference it from a `mythic` entry instead.
5. `glyph` (2 letters) and `icon_color` drive the hex perk badge on item cards.

### Loot tables
**`data/loot_tables.json`** has one table per source. `main.gd` rolls `"zombie"` on every kill, and each chest
rolls the table named in its `loot_table` property (default `"chest"`). A table has:
- `drop_chance`: 0–1, rolled once per kill or open.
- `rolls`: number of items.
- `entries`, weighted. The `kind` of an entry is one of:
  - `gear`: any weapon or armor;
  - `weapon`, with optional `archetype` or `slot`;
  - `armor`, with optional `slot`;
  - `consumable`, with `id` = a file name in `resources/items/`.
- `rarity_weights`, plus `rarity_round_bonus`, which adds weight every round so later rounds drop better gear.

To make a new table, for example a boss drop, add it to the file and call
`GearDB.roll_table("boss", round)` then `main.spawn_pickup(item, position)` for each result.

### Inventory and vault
- `Inventory` (`scripts/items/inventory.gd`) is a node on the player. It holds:
  - `equipped`: slot → item, for 3 weapon and 5 armor slots;
  - `backpack`: slot → up to 9 spare items;
  - `bag`: consumables.
- It resets every match.
- New items are equipped automatically if their slot is empty. Otherwise they go to the backpack.
  Equipping swaps the old item into the backpack. Dismantling deletes an item.
- **Vault-ready:** every item serialises with `to_dict()` and is rebuilt with `GearDB.item_from_dict()`, and
  `Inventory.to_save_dict()` / `load_save_dict()` save and load a whole loadout (tested by the smoke test).
  To add a persistent vault:
  1. Store an array of item dicts in `Progress`.
  2. Add a "Vault" column to `character_screen.gd` that moves items between it and the backpack.
  3. Call `load_save_dict()` at match start if you want gear to carry over.
- **Consumables** are `ConsumableItem` resources (`resources/items/*.tres`) with `effect` HEAL, AMMO or HEAVY_AMMO.
  `auto_use` makes one get used on touch. For a new effect, add it to the enum and handle it in `use()`.

### Grenades
**`data/grenades.json`** defines the grenade types:
- `frag`: bounces, then explodes after its fuse.
- `pulse` (shown as **Tremor Charge**): sticks after its fuse and does several damage pulses.

Each type has `fuse`, `radius`, `damage`, `knockback`, `cooldown` (before Ordnance), `throw_speed`, `bounce` and `color`.
A class picks its grenade with `grenade_id` in its `.tres`. Explosions (`scripts/combat/explosion.gd`):
- do full damage in the centre, falling off to 30% at the edge (there is no line-of-sight check yet);
- knock zombies back;
- shake the screen and spawn a fireball, a shockwave ring, a light, sparks and smoke.

Rockets, the Shrapnel Tips perk and skill blasts (`player.skill_explosion`, source `skill`) use the same code.
Grenade explosions tag their hits `source: "grenade"`, so grenade kills feed grenade skills.

### HUD and hints
- `scripts/hud.gd` keeps everything small and at the edges: tally-mark round counter + points (top-left),
  horde counter (top-right), health bar (bottom-left), active weapon + ammo + small icons for the other slots
  (bottom-right), grenade / ability / melee cooldown icons (bottom-centre), loot feed (left).
- Contextual hints go through one method: **`hud.show_hint(text, key)`**. `key` is an input action name
  (its bound key is looked up, e.g. `"interact"` → E) or a literal label; empty text hides it. The player emits
  `pickup_prompt_changed(text, key_action)`, which `main.gd` connects straight to `show_hint`.
- Low health shows a pulsing red vignette instead of a full-screen flash.

### Movement
All values are `@export` on the **Player** node, so you can tune them in the Inspector:
- slide: `slide_boost`, `slide_friction`, `slide_drag`, `slide_steer`;
- wall jump: `max_wall_jumps`, `wall_jump_cooldown`, `wall_jump_push`, `wall_jump_up`. A jump press on (or within
  `floor_probe_distance` of) the ground is always a ground jump, one press is one jump, and wall kicks are locked for
  `ground_jump_kick_lock` (0.15 s) after a ground jump, so jumping next to a wall never spends a wall kick;
- heights: `crouch_height`, `slide_height`, `crouch_speed`.

In the air you keep momentum from slides and wall jumps. The camera drops and tilts while you slide.

### Classes and abilities
- A **class** is a `PlayerClass` resource (`resources/classes/*.tres`). It has max health, walk/sprint speed, jump, one `ability`
  and a `grenade_id`.
- An **ability** is a resource that extends `Ability` (`scripts/abilities/ability.gd`). It has `cooldown`, `duration`
  and the hooks `activate(player)`, `process_active(player, delta)` and `end(player)`.
- **New ability:** create a script with `class_name MyAbility extends Ability`.
- **New class:** in the FileSystem dock, right-click `resources/classes` → New Resource → PlayerClass, then add a key for it in `main.gd → _pick_class`.

### Progression (save system)
- `Progress` (`scripts/autoload/progress.gd`) saves total kills, best round, XP, games played, the selected class
  and skill ranks (`skills/ranks`, save version 2) to `user://progress.cfg`. Older saves (`skills/unlocked`) migrate automatically.
  On Windows that's `%APPDATA%\Godot\app_userdata\Gravecrew\progress.cfg` (saves from the old `DeadofNight` and `FPS Starter` folders are copied over once, newest first, by the SaveMigration autoload). Delete the file to reset.
- `main.gd` calls `Progress.record_match(kills, round)` at game over.

### Skill tree (meta) and Field Cards (per match)
Two layers. Design: `/workspace/skillz/DESIGN.md` (§12 holds the decisions). UI contract: `/workspace/skillz/GOOEY_HANDOFF.md`.
- **Meta tree, `data/skill_tree.json` (v2):** 5 shared branches (Marksman, Sapper, Ledger, Survivor, Freerunner) plus a
  3-node strip per class (Soldier, Scout; only your class's strip is active). Nodes have ranks with a cost per rank, `requires`
  (all-of), `requires_any`, an optional `requires_rank`, a `choice_group` (one per group; all keystones share `"keystone"`),
  `class`, grid `x`/`y`, `icon`, `type`, and `description`/`drawback` templates filled from `values`. Skill points =
  XP / 250, and the level shown is 1 + points. **Respec is free** at round 0 and on game over (`Progress.respec()`).
  K opens the tree only then.
- **Field Cards, `data/run_picks.json`:** an offer after every cleared round (`RunState.open_offer`, which pauses the game until
  `choose` / `skip`). Rerolls cost points: 50 × round × 2^k (milestones 100 × round × 2^k); free rerolls (Spare Coin) go first.
  Branch roots unlock that branch's normal cards; branch capstones unlock its legendaries. Cards are wiped at game over.
- **Effects:** every node and card lists `effects` → scripts in `scripts/skills/effects/` (registered in `effect_registry.gd`).
  The `SkillRunner` on the player subscribes them to `GameEvents.event(name, ctx)` hooks (`hit`, `enemy_killed`, `shot_fired`,
  `landed`, `slide_started`, `damage_taken`, ...) and folds stat modifiers (`player.mod_stat(stat, base, ctx)`: additive, then
  multiplicative). Chain reactions carry `ctx.depth` (max 4).
- **Engine features:** overshield (absorbed before health, cap 50 by default; `overshield_changed`), grenade and ability
  charges, zombie statuses (`apply_status`: mark, rot, burn, slow), and a shared **grenade refund cap of 60% of one cooldown
  per rolling 5 s** (skills and the Pin Puller perk).
- **Time scale:** slow-mo skills (Second Breath, Kite String) only touch `Engine.time_scale` when the project setting
  `skills/allow_time_scale` is true (default false). Otherwise they slow nearby zombies and reduce your damage taken.
- **Adding a node or card:** add an entry to the JSON (maintainers: `/workspace/skillz/tools/gen_data.py` generates both files and
  checks the layout rules). Reuse an effect script with new params, or add a script under `effects/` and register it.
  Add a check to `tests/skills_test.gd` and make sure the name passes the smoke test's homage check.

### Maps (`data/maps.json`, `scripts/world/map_registry.gd`, `maps/`)
- **arena** is the level built into `scenes/main.tscn` (default and fallback). Other maps are self-contained scenes that follow
  Mapz's map contract (`maps/<id>/<id>.tscn`, shared scripts in `maps/common/`): Rustwell Foundry is `maps/rustwell_foundry/`.
- **Choosing a map:** press **M** in game (before round 1 / game over), or set the project setting `game/maps/default_map`
  (`arena` or `rustwell_foundry`), or run with a user arg: `godot --path . -- --map=rustwell_foundry`.
  Code/UI: `MapRegistry.list()`, `MapRegistry.select(id)`, `MapRegistry.current_id()`, then `main.restart_with_map(id)`
  (or reload `main.tscn`). Order of precedence: `select()` > `--map` > project setting > `maps.json` default.
- **How a map loads** (`main.gd → _load_map()`, before the first navmesh bake): the arena's NavigationRegion3D, SpawnPoints,
  Chests, Decor, WorldEnvironment, Sun, PowerWeaponSpot and hand-placed pickups are removed; the map is added; chests are
  instanced at the map's `Chests` markers **under its NavigationRegion3D** (so zombies path around them); pickups at
  `PickupSpots`; the rocket launcher at its `PowerWeaponSpot`; the player at `PlayerSpawn`. Falling below the map's `kill_y`
  puts you back at PlayerSpawn.
- **Doors and areas:** doors are `MapDoor` nodes (E to buy; the price is on the door: 750 / 1000 / 1250 on Rustwell). Buying one
  spends points through `player.spend_points()`, opens the area(s) behind it (`MapRoot.area_unlocked`) and the map rebakes the
  navmesh itself. Zombies only spawn from `map.active_spawn_points()`, i.e. areas you've opened. A watchdog moves any zombie that
  has had no navmesh path back to PlayerSpawn for 4 s (knocked into a locked area, off the mesh, below `kill_y`) to an open spawn
  (`stuck_check_interval`, `stuck_respawn_time` on Main).
- **Rendering:** `rendering/occlusion_culling/use_occlusion_culling` is on, so the map's occluders cull hidden geometry.
- **Adding a map:** build it to Mapz's map contract (`maps/rustwell_foundry/` is the reference), drop it in `maps/<id>/`
  and add an entry to `data/maps.json`.

### Armor models (`data/armor_models.json`, `scripts/world/armor_models.gd`)
Desi's armor set is in `assets/models/armor/`: skinned GLBs (helmet, gauntlets, chest, legs, cloak, sash) on the same 65-bone
UAL2 skeleton as the zombies, and unskinned, centred `display/*_display.glb` versions for the character screen.
`ArmorModels.display_path(slot, class_id)` / `skinned_path(slot, class_id)` map the armor slots in `data/armor.json` to models
(class item: sash for Soldier, cloak for Scout). The player is first-person only (no body), so nothing wears them in game yet;
the mapping is there for the character screen and a future third-person body.

### Zombies and rounds
- Wave settings are exported on the **Main** node: zombies per round, health and speed per round, max alive at once, and timings.
- Spawn points are the `Marker3D` nodes under `Main/SpawnPoints` (Arena) or the map's area-tagged `SpawnPoints`.
- The navmesh is baked from the arena's colliders when the game starts. Zombies can't climb, so the alley ledge is a safe spot for now.
  `agent_max_climb` is 0.25 (was 0.5): a CharacterBody3D has no step-up, so a higher value made paths cross low crates and
  rubble and zombies got stuck on them.
- **Variants** (`data/zombies.json`, `scripts/world/zombie_variants.gd`): `city` (city_zombie.glb, 1.795 m), `worker`
  (zombie_worker.glb, 1.821 m) and `soldier` (zombie_soldier.glb, 1.821 m, ×1.2 health, ×1.1 damage, ×0.95 speed). Each has
  its own `model_height`, so the auto-scale keeps it at its real height (±`size_variety` 6% random scale). `wave_mix` sets the
  weights by round (r1 85/15/0, r3 65/25/10, r6 50/30/20, r10+ 40/30/30). main.gd calls `zombie.set_variant()` on spawn;
  turn the mix off with `use_zombie_variants` on Main. Without a variant a zombie uses the `models` on `scenes/enemy.tscn`.
  This model faces -Z, so `model_faces_plus_z` is off (no 180° flip). The **head hitbox** is a small sphere on a
  `BoneAttachment3D` that follows the `Head` bone (`head_bone`, `head_radius`, `head_offset` exports; physics layer 32,
  only queried by weapon rays and rockets). Without that bone it falls back to `head_height`.
  Animations are found by name (also with a prefix, e.g. `Zombie_Walk`): Walk, Run, Attack/Punch, Death, HitRecieve/HitReact.
  Damage lands `attack_windup` seconds into the attack animation. You can drop in any rigged glTF that uses those names.
- A zombie only swings (and the swing only lands) if the player is within `attack_max_dy` (1.6 m) vertically, so a zombie
  under a deck can't hit you on top of it; it keeps pathing toward the stairs instead.
- `scenes/main.tscn` is generated by a Python script during development. It is an ordinary scene, so you can edit it in the editor.

### Audio
- `Sfx` (autoload, `scripts/audio/sfx.gd`) scans `assets/audio/` at start-up. A sound's key is its file name without the
  `_01`/`_02` variation suffix (e.g. `zombie_groan_03.ogg` → `zombie_groan`); a random variation is picked each time with slight pitch jitter.
- API: `Sfx.play(key)`, `Sfx.play_at(key, pos)`, `Sfx.attach_loop(key, node)`, `Sfx.impact(collider, pos, is_flesh)`,
  `Sfx.loot_chime(rarity)`, `Sfx.set_music("menu" | "break" | "combat")`, `Sfx.set_low_health(on)`, `Sfx.zombie_voice(player3d, key, priority)`.
- Volumes and buses per key live in the `MIX` table at the top of `sfx.gd`. Buses (`default_bus_layout.tres`): Music −9 dB,
  SFX 0, UI −4, Ambience −12. At most 6 zombie voices play at once (death > aggro/attack > hurt > groan steals the quietest slot).
- Weapon fire sound: `fire_sfx` in `data/weapons.json`. The pulse rifle is a real 3-round burst (`burst`, `burst_interval`) and plays its burst file once per burst.
- Impact surface: set meta `surface` = `"metal"`/`"concrete"` on a collider, otherwise it's guessed from the node name.
- To add a sound: drop `my_sound_01.wav` into a folder under `assets/audio/` and call `Sfx.play("my_sound")`.
  Loops: enable *Loop* in the import dock (OGG) or Loop Mode = Forward (WAV), and end the key with `_loop`.

## 7. Automated check (optional)
From a terminal in the project folder:
```
godot --headless --path . -s res://tests/smoke_test.gd
```
It runs about 143 checks and prints PASS/FAIL for each:
- data loading, random rolls, loot tables and chests;
- equip, swap and dismantle, and the save/load round trip;
- armor stat effects;
- shooting and reloading;
- slide, crouch and wall jump;
- grenades, explosions with falloff, and rockets;
- Item Power: rises with round and rarity; higher IP gives higher weapon stats, armor totals and damage;
- renamed terms (slots, elements, armor stats, Mythic tier, perk/weapon names);
- the character screen, item card, stat + Item Power comparison deltas, and `hud.show_hint`;
- skills, rounds, points, and game-over saving;
- audio: buses, key streams, loop flags, music switching menu → combat → break → combat → menu, heartbeat, zombie voice cap;
- headshots on the walking zombie's head bone, deterministic navmesh chase, and Item Power damage scaling (IP 400 ≈ 2.2× base, Impact excluded from IP).

The map test covers Rustwell Foundry (load, navmesh bake, door-gated spawns, buying a door, rebake, stuck zombies, kill_y),
map selection, the zombie attack height limit, ground jump vs wall kick, the three zombie variants and the armor model mapping
(about 90 checks):
```
godot --headless --path . -s res://tests/map_test.gd
```

The skills test runs separately (about 249 checks: every effect script, node and card, offer economy, milestones,
the refund cap, the time-scale flag on and off, v1 save migration, choice and keystone exclusivity, respec and the round flow):
```
godot --headless --path . -s res://tests/skills_test.gd
```

`field_card_audit_test.gd` (data only, runs without a scene) fails if any field card in `data/run_picks.json` has the same effect signature
(`scripts/skills/effect_signature.gd`) or name as a skill node, weapon perk, armor stat or another card, or is a permanent bump. Run it after editing cards:
```
godot --headless --path . -s res://tests/field_card_audit_test.gd
```

The exit code is the number of failures. It saves to a separate test file and deletes it afterwards, so your real progress isn't touched.
