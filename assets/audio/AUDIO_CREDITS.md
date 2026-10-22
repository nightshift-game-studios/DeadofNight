# Audio Credits & Licensing

## Sourced (third-party) files
None. No third-party recordings, samples, loops, soundfonts or packs were used anywhere.

## Self-generated files
Every file in this folder was **procedurally synthesized from scratch** by the scripts in
`tools/` (Python + numpy/scipy, encoded with ffmpeg/libvorbis). The building blocks are noise,
sine/additive oscillators, modal (decaying-resonance) synthesis, Karplus-Strong strings, a
glottal-pulse + formant voice model, and synthetic impulse responses. No recorded material is
involved, so no third-party rights apply. The generated audio is dedicated to the project under
**CC0 1.0**. All melodies and motifs are original, and nothing was derived from or modeled on
Treyarch/Call of Duty audio or music.

| Path | Generator | Content |
|---|---|---|
| sfx/weapons/* | tools/gen_weapons.py | tier 1: gunshots, rocket/explosion, reload, dry fire, swap, impacts |
| sfx/ui/hitmarker_* | tools/gen_weapons.py | hit markers (mono) |
| sfx/zombies/* | tools/gen_zombies.py | tier 2: zombie vocals + footsteps/shuffles |
| sfx/player/* | tools/gen_player.py | tiers 3-4: player foley/vocals, heartbeat loop, frag throw, dash, adrenaline |
| sfx/world/* | tools/gen_player.py | tier 4: frag bounce/explode, Tremor Charge loop |
| sfx/ui/* (other) | tools/gen_ui.py | tier 5: stingers, menu/UI, loot chimes, chest |
| music/*, ambience/* | tools/gen_music.py | tier 6: seamless OGG loops |
| ambience/ambience_map_ironside_loop.ogg | tools/gen_ambience_night.py (map_ironside) | Ironside Freight Depot night layer (84 s seamless): yard wind + container-gap whistles, container groans, railcar squeals, far coupler clanks, sparse far synthetic train horns (invented chord, low-passed long tails), drips. Self-synthesized, CC0 |
| sfx/zombies/gallspitter_windup_01..02.wav | tools/gen_gallspitter.py | Gallspitter wind-up (0.70 s telegraph): wet throat gurgle, throat-sac blub, rattly inhale |
| sfx/zombies/gallspitter_spit_01..03.wav | tools/gen_gallspitter.py | Gallspitter spit/launch (0.45 s): hock, wet burst, ejected liquid, push thump |
| sfx/world/bile_glob_travel_loop.wav | tools/gen_gallspitter.py | bile_glob projectile: seamless 1.4 s mono fizz/bubble hiss loop (3D) |
| sfx/world/bile_glob_impact_01..03.wav | tools/gen_gallspitter.py | bile_glob impact: splat, spray, droplets, short acid sizzle |
| sfx/world/gall_puddle_sizzle_01.wav | tools/gen_gallspitter.py | gall puddle: 4.0 s one-shot sizzle/bubbling with built-in fade-out |
| sfx/world/gall_puddle_sizzle_loop.wav | tools/gen_gallspitter.py | gall puddle: seamless 2.0 s mono sizzle loop (for non-4 s puddles) |
| sfx/zombies/gallspitter_idle/aggro/hurt/death/swipe_01..02.wav | tools/gen_gallspitter.py | Gallspitter voice set (Skillz VOICE_KEYS): higher, wetter throat + gular sac blub; death = sac rupture + bubbling drain |
| sfx/player/grenade_pickup_01..02.wav | tools/gen_grenades_rare.py | shared grenade pickup: palm slap, casing ring, pin/spoon rattle, clip onto rig |
| sfx/player/grenade_throw_01..02.wav | tools/gen_grenades_rare.py | shared grenade throw/release: spoon ping + arm whoosh |
| sfx/player/grenade_rarity_common/uncommon/rare/legendary/mythic.wav | tools/gen_grenades_rare.py | rarity sweetener layered on pickup/throw (loot-chime harmonic family) |
| sfx/world/grenade_cinderjar_detonate_01..03.wav | tools/gen_grenades_rare.py | Cinderjar: glass jar shatter + fuel whoomp ignition |
| sfx/world/grenade_cinderjar_fire_01.wav, grenade_cinderjar_fire_loop.wav | tools/gen_grenades_rare.py | Cinderjar fire patch: 5.0 s one-shot with fade-out, and seamless 5.0 s loop |
| sfx/world/grenade_shiverglass_detonate_01..03.wav | tools/gen_grenades_rare.py | Shiverglass crystal burst: cold crack, ice shatter, glassy chime |
| sfx/world/grenade_shiverglass_frost_01..02.wav | tools/gen_grenades_rare.py | Shiverglass frost puff + ice ticking over the 3 s slow |
| sfx/world/grenade_tallyhook_stick/charge/arc/detonate_*.wav | tools/gen_grenades_rare.py | Tallyhook: stick thunk (x2), 1.0 s charge whine, chain arc (x3), shock discharge (x3) |
| sfx/world/grenade_rookery_detonate_01..03.wav, grenade_rookery_bomblet_01..04.wav | tools/gen_grenades_rare.py | Rookery split pop + scatter; small bomblet blasts |
| sfx/world/grenade_gravewell_vortex_loop.wav, grenade_gravewell_detonate_01..03.wav | tools/gen_grenades_rare.py | Gravewell: seamless 2.5 s vortex loop; implode-then-blast |
| sfx/world/grenade_leechbell_detonate_01..03.wav, grenade_leechbell_orb_loop.wav | tools/gen_grenades_rare.py | Leechbell: blast with dark bell ring; seamless 2.0 s orb hum loop |
| sfx/player/grenade_leechbell_heal_01..02.wav | tools/gen_grenades_rare.py | Leechbell heal-orb pickup chime |
| sfx/world/grenade_requiem_bell_bounce/detonate_01..03.wav | tools/gen_grenades_rare.py | Requiem Bell: bell-metal bounce clank; small per-bounce blast |
| sfx/world/grenade_requiem_bell_toll_01..02.wav, grenade_requiem_bell_mark_01..02.wav | tools/gen_grenades_rare.py | Requiem Bell: deep final toll (~5 s); mark-applied ping |
| sfx/player/q_breach_rush_01..02.wav | tools/gen_q_abilities.py | Q Breach Rush: heavy boot thud, lunge whoosh, shoulder-into-body impact |
| sfx/player/q_hares_break_01..02.wav | tools/gen_q_abilities.py | Q Hare's Break: quick inhale, cloth whip, snap-reload click-clack |
| sfx/player/q_rally_banner_01..02.wav | tools/gen_q_abilities.py | Q Rally Banner: pole stab (wood thunk + dirt) and cloth flap |
| sfx/player/q_chalk_mark_01..02.wav | tools/gen_q_abilities.py | Q Chalk Mark: two dry chalk scrapes with stick-slip chatter |
| sfx/player/q_grave_bell_01..02.wav | tools/gen_q_abilities.py | Q Grave Bell: deep low bronze toll (~3 s ring) |
| sfx/player/q_headstone_01..02.wav | tools/gen_q_abilities.py | Q Headstone: stone slab drop, heavy crunch, settling grit |
| sfx/player/q_vigil_candle_01..02.wav | tools/gen_q_abilities.py | Q Vigil Candle: match strike, phosphor flare, soft flame |
| sfx/player/q_ember_brand_01..02.wav | tools/gen_q_abilities.py | Q Ember Brand: hot-iron clink, violent sizzle, steam hiss |

Shared code: `tools/dsp.py`, `tools/synth.py`. Regenerate everything with `tools/build_all.sh`.
The seeds are fixed, so the decoded audio is bit-identical on every run (OGG container serial
numbers differ between runs).

## Announcer callouts (callouts/*.ogg, game copy: fps-starter/data/audio/callouts/)
Generator: `tools/gen_callouts.py`. The voice is offline TTS, run through heavy processing (pitch and
formant down, low-end weight, saturation, PA band-pass, compression, slap reverb). Stings are synthesized.
- TTS engine: **Festival 2.5** (CSTR, University of Edinburgh). Free, MIT-style licence: "use and
  distribute this software ... without restriction".
- Voices: **kal_diphone** (Debian package festvox-kallpc16k, (c) 1998 CSTR/OGI) for the _01 variants and
  **ked_diphone** (festvox-kdlpc16k, (c) 1997 CSTR/OGI) for the _02 variants. Both use the same
  MIT-style "without restriction" licence (see /usr/share/doc/festvox-kallpc16k/copyright and
  /usr/share/doc/festvox-kdlpc16k/copyright). Festival's own copyright file states: "the US voices, kal
  and ked are free".
- Not used: no MBROLA, no OALD lexicon (non-commercial), no Piper or other neural models.
- The rendered callout audio contains no third-party recordings and is dedicated under **CC0 1.0**.
