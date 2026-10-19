# Arena night (easy) — ready for G4M3N

Do **not** edit fps-starter from Mapz. Apply:

1. Copy/sync `maps/common/night/` into the game project (or keep the mapz maps symlink).
2. Apply `patches/gen_main_arena_night.patch` to `tools/gen_main.py`, then regenerate `scenes/main.tscn`.
3. Optionally instance `lights.tscn` under `Main` (or merge its children into the gen output).

Files:
- `env_easy.tres` — WorldEnvironment resource (easy night)
- `moon.tscn` — DirectionalLight3D moon preset
- `lights.tscn` — sodium ×4, work light, barrel fire, warm interactable glow, spark stub
- `ambience_emitters.tscn` — AmbienceEmitters/ (7 Marker3D, Audi-0 keys). Instance under Main via gen_main patch.

Tested under `mapz/_test/` scratch (see `tests_mapz/arena_night_smoke.gd`).
