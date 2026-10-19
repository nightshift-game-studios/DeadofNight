# DeadofNight shared night kit

| Preset | sky_energy | moon_energy | ambient | fog_density | exposure | Use |
|--------|------------|-------------|---------|-------------|----------|-----|
| easy   | 0.22       | 0.55        | 0.28    | 0.008       | 1.05     | Arena |
| medium | 0.15       | 0.40        | 0.22    | 0.012       | 0.98     | Rustwell |
| hard   | 0.10       | 0.28        | 0.16    | 0.018       | 0.92     | Lockout |

HDRI: `hdri/dikhololo_night_2k.hdr` (Poly Haven, CC0).
Apply: `godot -s res://mapz_tools/apply_night.gd -- <map.tscn> <easy|medium|hard>`
Perf: ≤3–4 shadowed omni/spot besides the moon; rest unshadowed + distance fade; emissive fill.
