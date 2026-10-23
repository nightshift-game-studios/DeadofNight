# Gravecrew

**Wave based zombie survival game** (Godot 4).

A first-person, wave-based zombie shooter in the style of Black Ops Zombies, with looter-shooter gear.
It's made by Nightshift Game Studios.

- **Repository:** https://github.com/nightshift-game-studios/Gravecrew
- **Download:** https://github.com/nightshift-game-studios/Gravecrew/releases

- **Survive rounds** of zombies that get faster and tougher every wave. Walkers come first, then foundry workers and armored soldiers.
- **Pick a class.** **Soldier** gets Dash and a Frag grenade. **Scout** gets Adrenaline and a Tremor Charge.
- **Loot gear.** Weapons and armor drop with random rarity, Item Power, stats and perks. You can find them on zombies, in loot chests and in the world.
- **Skill tree and progression.** XP, unlocked skills, your class and your gear stash are saved between games. After each round you pick a **Field Card** that lasts for that match.
- **Three night maps, three difficulties:** **Arena** (Easy) is the original walled arena. **Rustwell Foundry** (Medium) is an overrun steel works where you buy doors to open the Rail Spur, Warehouse, Foundry Hall and Tank Farm. **Drowned Cannery** (Hard) is a flooded harbour cannery with nine rooms, gantries and cranes, and a brine pit where the boss waits. Harder maps bring tougher, faster zombies, bosses sooner, and bigger rewards.
- **Bosses:** the Bellwether, the Choir Host and the Lantern Stalker show up on boss rounds.
- **Gravemarks and the Armory:** Gravemarks are a rare currency: bosses, chests and round milestones pay them, and zombies sometimes drop one. Spend them in the **Armory** (home menu) on weapon upgrades (Reworks) and attachments, including the **Mine Lamp** flashlight.
- **The Merchant:** the Gravedigger on the home menu sells rolled guns for Gravemarks (Common 13 up to Mythic 315). His stock refreshes every hour, and you can pay to reroll it (5, 9, 15, 24, 36, then +15 each). Mythic guns from the Merchant carry a signature perk you can't find anywhere else.

---

## Install and play (Windows)

The game ships as a Godot project. You play it with the free Godot engine, so there's nothing to compile.

### 1. Download the game
1. Open the **Releases** page: **https://github.com/nightshift-game-studios/Gravecrew/releases**
2. Download **the latest release zip** (`fps-starter-full.zip`).
   - If the release has split parts (`fps-starter-full.zip.001`, `.002`, …), download all of them into one folder.
     Open PowerShell in that folder and run this to join them into one zip:
     ```powershell
     cmd /c copy /b fps-starter-full.zip.001+fps-starter-full.zip.002 fps-starter-full.zip
     ```
     If there are more parts, add them in order (`+fps-starter-full.zip.003` …).
3. Right-click the zip, choose **Extract All…**, and pick a folder, e.g. `Documents\Games`.
   You'll get a folder called **`fps-starter`** with `project.godot` inside it (the folder keeps its original name; the game itself is Gravecrew).

### 2. Install Godot 4.7
1. Go to **https://godotengine.org/download/windows/**.
2. Download **Godot Engine 4.7.x, the standard version**. You do *not* need the ".NET" version.
3. Unzip it anywhere. There's no installer: just double-click `Godot_v4.7.x-stable_win64.exe`.

### 3. Open the game and play
1. In the Godot **Project Manager**, click **Import**.
2. Browse to the extracted `fps-starter` folder, select **`project.godot`**, then confirm with **Import** (in some versions the button says **Import & Edit**). The editor opens.
3. **The first launch takes a minute or two** while Godot imports the models, textures and sounds. This only happens once.
4. Press **F5**, or click the ▶ **Play** button at the top right. The game opens on the **home menu**: **Play** → pick a map (Easy / Medium / Hard) → **Deploy**. **Kit / Inventory**, **Armory**, **Merchant** and **Settings** are there too. Have fun!

Next time, just open Godot, double-click **Gravecrew** in the project list, and press F5.

> **System requirements:** the game uses Godot's Forward+ renderer, so you need a GPU with Vulkan or Direct3D 12 support. Any gaming PC from the last ~8 years will do.

---

## Controls

| Action | Key |
|---|---|
| Move | **W A S D** (or arrow keys) |
| Look | **Mouse** |
| Shoot | **Left mouse** (hold for automatic weapons) |
| Aim down sights | **Right mouse** (hold or toggle, see Settings → Gameplay) |
| Reload | **R** |
| Sprint | **Left Shift** |
| Jump / wall jump | **Space**. Press it in the air next to a wall to wall-jump, up to 3 times before you land again |
| Crouch / slide | **C** or **Left Ctrl**. Press it while sprinting to slide; jump during a slide to keep the momentum |
| Interact (pick up loot, open chests, buy doors) | **E** (you pick up ammo just by walking over it) |
| Class ability | **Q** (Soldier: Dash, Scout: Adrenaline) |
| Grenade | **G** |
| Melee | **V** |
| Mine Lamp flashlight | **F** (only when the Mine Lamp attachment is on the weapon in your hands) |
| Switch weapon | **1** Primary, **2** Secondary, **3** Heavy |
| Inventory / character screen (pauses the game) | **Tab** or **I** |
| Skill tree | **K** (before round 1 starts, or on the game-over screen) |
| Map picker | **M** (before round 1 starts, or on the game-over screen) |
| Pause menu (Resume / Settings / Quit to Home) | **Esc** |
| Restart after game over | **Enter** |
| Pick your class for the next game | **1** Soldier, **2** Scout (on the game-over screen) |

**In the inventory:** click a slot to see your spare items. Hover over an item to compare it with what you have equipped. **Click** an item to equip it, **right-click** to dismantle it.

**Field Cards** (after every round): **1–4** picks a card, **R** rerolls, **S** skips, **B** banishes (if unlocked).

## Settings menu (Esc)
Open **Settings** from the home menu, or press **Esc** during a match (or before round 1, or on the game-over screen) to open the **pause menu** and choose **Settings**.
Changes apply immediately and are saved for next time.

| Tab | Options |
|---|---|
| **Video** | Fullscreen, VSync, Field of View, **Motion Blur** (on/off) |
| **Audio** | Volume sliders (Master, Music, SFX, UI, Ambience) |
| **Controls** | Rebind any key or mouse button. Click an action, then press the new key |
| **Gameplay** | Mouse Sensitivity, Invert Y, **ADS Mode**: *Hold* (aim while right mouse is held) or *Toggle* (right-click turns aiming on/off) |

**Q / E** switch tabs, and **Esc** goes back. **Reset to Defaults** restores everything.
> The Motion Blur switch is ready for blur effects that haven't arrived yet.

---

## Tips
- You get a few seconds before **Round 1**. Use them to spend skill points (**K**) or switch maps (**M**).
- Spend Gravemarks in the **Armory** on the home menu. Rework upgrades get more expensive at each tier, so the top tiers need the bigger payouts from Hard maps.
- Zombies earn you points for hits and kills. On Rustwell Foundry, spend them on doors (750 / 1000 / 1250) to open new areas.
- The crates with an **orange glow** are loot chests. You can open each one once per round.
- The **metal ammo box** refills your Primary and Secondary weapons, and the **purple box** refills your Heavy weapon.
  Your reserves are also topped up at the start of every round.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| **Mouse doesn't aim / camera won't turn** | Click inside the game window to capture the mouse. If the pause menu is open, press **Esc** or **Resume**. Check **Settings → Gameplay → Mouse Sensitivity** too. If a menu is open (inventory, skill tree, map picker, pause), close it first. |
| **First launch is slow or shows an "importing" progress bar** | That's normal. Godot imports every asset the first time, which takes about 1–2 minutes. Later launches are fast. |
| **"Your video card driver does not support Vulkan / D3D12"** | Update your GPU drivers. If that doesn't fix it, start Godot with `--rendering-driver opengl3` (it will look a bit plainer). |
| **Godot asks to upgrade or convert the project** | You're on a different Godot version. Install **4.7.x** (standard, not .NET). |
| **Missing textures / pink models** | Make sure you extracted the *whole* zip (and joined all the parts first, if it was split). Then delete the hidden `.godot` folder inside `fps-starter` and reopen it, so Godot re-imports everything. |
| **I want to reset my progress** | Your saves are in `%APPDATA%\Godot\app_userdata\Gravecrew\`. Close the game and delete `progress.cfg` **and** its backups `progress.cfg.bak` / `progress.cfg.tmp` (and `settings.cfg` for default settings). If you delete only `progress.cfg`, the game restores your progress from the backup. |
| **My progress from before the rename is gone** | It's copied automatically: the game used to be called DeadofNight (and before that FPS Starter). On the first launch as Gravecrew, it copies your saves from the old `%APPDATA%\Godot\app_userdata\DeadofNight\` and `%APPDATA%\Godot\app_userdata\FPS Starter\` folders, newest first, but only if the Gravecrew folder has no save yet. Nothing is overwritten, and the old folders are left in place as a backup. |

---

## For developers

The whole game is GDScript, with data-driven content in `data/*.json`.
**DEVELOPER.md** is the in-depth guide to every system (gear rolls, perks, loot tables, skill tree, maps, zombies, audio) and how to extend it.

```
project.godot        Input map, main scene, autoloads (SaveMigration, GearDB, Progress, Sfx, GameEvents, RunState, Settings)
scenes/              main.tscn (Arena + match), player, enemy, pickup, chest
scripts/             main.gd (rounds, points, loot, menus), player.gd, enemy.gd, hud.gd
  autoload/          GearDB (loot rolls), Progress (save data), Settings
  items/ gear/       Items, inventory, chests, rarity and perks
  skills/            Skill tree effects, Field Cards (RunState), GameEvents bus
  ui/                Character screen, skill tree, map picker, pause/settings menus, shared UI style
  world/             MapRegistry, zombie variants, armor models
data/                weapons, armor, perks, loot tables, skill tree, run picks, maps, zombies (JSON)
maps/                Extra maps (map contract in docs/map_contract.md), e.g. rustwell_foundry/
assets/              CC0 models, textures, audio, HDRI sky, fonts (see CREDITS.md)
tests/               Headless test suites
```

### Get the source
```
git clone https://github.com/nightshift-game-studios/Gravecrew.git
```
Then import `Gravecrew/project.godot` in Godot 4.7 as above.

### Running the tests
From a terminal in the project folder (with `godot` pointing at your Godot 4.7 executable):
```
godot --headless --path . -s res://tests/compile_check.gd   # every script parses
godot --headless --path . -s res://tests/smoke_test.gd      # core gameplay, loot, saving, audio
godot --headless --path . -s res://tests/skills_test.gd     # skill tree + Field Cards
godot --headless --path . -s res://tests/map_test.gd        # maps, doors, navmesh, zombie variants
godot --headless --path . -s res://tests/input_test.gd      # mouse look + menu pause (full checks need a window)
```
Each test prints PASS/FAIL lines, and its exit code is the number of failures. The tests use a separate save file, so your real progress isn't touched.
On a fresh clone, run `godot --headless --path . --import` once first, so the assets are imported.

## Credits
All art and audio are CC0 or SIL OFL. See **CREDITS.md** for every asset, author and license.
