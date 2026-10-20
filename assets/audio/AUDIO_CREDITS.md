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
| sfx/zombies/gallspitter_windup_01..02.wav | tools/gen_gallspitter.py | Gallspitter wind-up (0.70 s telegraph): wet throat gurgle, throat-sac blub, rattly inhale |
| sfx/zombies/gallspitter_spit_01..03.wav | tools/gen_gallspitter.py | Gallspitter spit/launch (0.45 s): hock, wet burst, ejected liquid, push thump |
| sfx/world/bile_glob_travel_loop.wav | tools/gen_gallspitter.py | bile_glob projectile: seamless 1.4 s mono fizz/bubble hiss loop (3D) |
| sfx/world/bile_glob_impact_01..03.wav | tools/gen_gallspitter.py | bile_glob impact: splat, spray, droplets, short acid sizzle |
| sfx/world/gall_puddle_sizzle_01.wav | tools/gen_gallspitter.py | gall puddle: 4.0 s one-shot sizzle/bubbling with built-in fade-out |
| sfx/world/gall_puddle_sizzle_loop.wav | tools/gen_gallspitter.py | gall puddle: seamless 2.0 s mono sizzle loop (for non-4 s puddles) |

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
