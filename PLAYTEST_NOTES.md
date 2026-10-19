# Playtest notes

Open the project in Godot 4.7 and press F5 (see README.md for setup).

## Controls
| Action | Key |
|---|---|
| Move | W A S D (or arrow keys) |
| Sprint | Shift |
| Jump / wall jump | Space (in the air next to a wall: up to 3 wall jumps) |
| Crouch / slide | Hold C or Ctrl / press it while sprinting (jump during a slide to slide-jump) |
| Look / shoot | Mouse / left mouse (hold for automatic weapons) |
| Reload | R |
| Grenade | G (Soldier: Frag, Scout: Tremor Charge) |
| Melee | V |
| Class ability | Q (Soldier: Dash, Scout: Adrenaline) |
| Interact (loot, chests) | E (ammo is picked up by walking over it) |
| Switch weapon | 1 Primary, 2 Secondary, 3 Heavy |
| Character screen | Tab or I (pauses). Click = equip, right-click = dismantle |
| Skill tree | K (before round 1, or on the game-over screen) |
| Free / recapture mouse | Esc / click |
| Restart / pick class after game over | Enter / 1 Soldier, 2 Scout |
| **Change map** | M (before round 1 or on the game-over screen): Arena ↔ Rustwell Foundry |

## What's new in this build
- **New map: Rustwell Foundry** (Mapz, greybox: untextured blocks for now, the art pass is coming). An overrun steel works:
  you start in the **Loading Yard** and buy your way out. Press **M** before round 1 to switch from the Arena; the choice sticks
  when you restart. The Arena is still the default.
  - **Doors** (walk up, press E): Rail Gate / Warehouse Roller Door **750** → Rail Spur and Warehouse, **1000** into the
    Foundry Hall (from the Rail Spur or the Warehouse), **1250** into the Tank Farm (from the Warehouse, or the Fence Breach in
    the yard). The price is on the door.
  - **Zombies only spawn in areas you've opened**: 3 spawns with everything closed, up to 10 with everything open.
  - 5 chests, ammo/health spots and the rocket launcher on its spot; wall-jump routes on the containers, racks and decks.
    Every raised spot has stairs or a ramp, so zombies can follow you up (one dead end: the roof of container C2).
- **Zombie variety:** Desi's **Foundry Workers** (hi-vis coveralls, hard hat) show up from round 1, **Soldiers** (camo, helmet,
  plate carrier; a bit tougher: +20% health, +10% damage, slightly slower) from round 3. More of both in later rounds.
  All three zombies got a texture cleanup (no more fishnet shimmer on fabric and skin; proper woodland camo).
- **Fixes:** a zombie standing under a deck can no longer hit you on top of it (it goes for the stairs instead). Jumping
  next to a wall no longer burns one of your 3 wall kicks; you get the full ground jump plus 3 kicks.
- Armor 3D models from Desi are in the project (for the character screen later); nothing changes in game yet.

### Earlier in this build line
- **Full audio:** guns, reloads, dry fire, swaps, impacts (flesh/concrete/metal), rockets, grenades, zombie voices and
  footsteps in 3D, player footsteps/jump/land/slide/wall jump/hurt/death, UI sounds, music and ambience.
- **New zombie model:** clean CC0 UAL2 re-rig with 2K textures, hunched pose. The head hitbox follows the head bone, so aim at the actual head.
- **Hit markers, zombie health bars, headshot ×2** (Gooey's UI pass).
- **Balance:** Item Power no longer adds to Impact; IP only scales damage through its multiplier (IP 400 ≈ 2.2× base).
- **Pulse rifle** now fires a real 3-round burst.
- **Navigation fix:** zombies no longer get stuck on low crates and rubble.

## Listen for
- Music: calm loop before round 1 and between rounds, combat loop during a round, with a ~1.6 s crossfade. Round start/end stingers.
- Zombies: random groans, a scream when one starts chasing you, swipes, hurt and death sounds. With a big horde no more than ~6 voices at once. Is it readable or too busy?
- Heartbeat under 30% health. Tremor Charge pulse loop. Frag bounce and explosion.
- Loot chime pitch/colour by rarity when loot drops; chest open; points ticking.
- Mix: are guns too loud versus zombies, reloads audible, music/ambience too quiet or loud?

## Look for
- **Rustwell flow:** do the door prices feel right against your points (r1 ≈ 600, r5 ≈ 1,800)? Is it obvious where to go next?
  Do zombies arrive from the right places, and does it ever feel like they're stuck behind a door?
- Zombie variety: can you tell walkers, workers and soldiers apart at a distance? Are soldiers noticeably (but not annoyingly) tougher?
- Wall jumps on Rustwell's containers and racks: any route that feels impossible or too easy?
- Headshots on walking, running and attacking zombies: does the head marker fire when it should? Shots just above the hunched head now miss the head and count as body hits on the capsule.
- Zombies chasing around cover without getting stuck.
- Health bars and hit markers lining up with the new model.
- Anything that sounds wrong for its surface (impact surfaces are guessed from object names).
