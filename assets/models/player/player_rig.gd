extends Node3D
## Gravecrew player body helper. Attach to the root of an instanced player.glb (or call the static funcs).
## - Sets clip loop modes (glTF carries none).
## - Per-player tint: TintBand is surface 1 of the body mesh; we override it with a duplicate whose albedo_color is the preset.

const LOOPS := {
	"Idle": true, "Walk": true, "Run": true, "Sprint": true, "Crouch": true, "CrouchWalk": true,
	"Hold_Rifle": true, "ADS_Aim": true, "Fall": true, "Downed": true, "Revive": true,
	"Fire": false, "Reload": false, "Jump": false, "Land": false, "Death": false, "Throw": false,
	"HitReact": false, "ReviveStart": false, "ReviveEnd": false,
}
const TINTS := [Color("#D9601F"), Color("#C9D12B"), Color("#1E9FC8"), Color("#C2307A")]  # P1 orange, P2 yellow, P3 cyan, P4 magenta
const TINT_SURFACE := 1

@export_range(0, 3) var player_index := 0:
	set(v):
		player_index = v
		if is_inside_tree(): apply_tint(self, TINTS[v])

func _ready() -> void:
	setup_loops(self)
	apply_tint(self, TINTS[player_index])

static func setup_loops(root: Node) -> void:
	for ap in root.find_children("*", "AnimationPlayer", true, false):
		for n in LOOPS:
			if ap.has_animation(n):
				ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR if LOOPS[n] else Animation.LOOP_NONE

static func body(root: Node) -> MeshInstance3D:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh and mi.mesh.get_surface_count() > TINT_SURFACE: return mi
	return null

static func apply_tint(root: Node, c: Color) -> void:
	var mi := body(root)
	if mi == null: return
	var m := mi.mesh.surface_get_material(TINT_SURFACE).duplicate() as StandardMaterial3D
	m.albedo_color = c
	mi.set_surface_override_material(TINT_SURFACE, m)
