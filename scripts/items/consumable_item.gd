class_name ConsumableItem
extends Item
## One-shot item used from the inventory. Add new effects to the Effect enum + use().

enum Effect { HEAL, AMMO, HEAVY_AMMO }

@export var effect: Effect = Effect.HEAL
@export var amount: int = 50
@export var auto_use: bool = false ## used instantly when walked over (ammo bricks)
@export_file("*.glb", "*.gltf") var model_path: String = "" ## world model for the pickup
@export var model_scale: float = 1.0
## Art4: old world model kept as a fallback, used only when model_path is missing (e.g. a stripped build).
@export_file("*.glb", "*.gltf") var fallback_model_path: String = ""
@export var fallback_model_scale: float = 1.0


## [path, scale] of the world model to show: model_path if it exists, else the fallback, else ["", 1.0].
func world_model() -> Array:
	if model_path != "" and ResourceLoader.exists(model_path):
		return [model_path, model_scale]
	if fallback_model_path != "" and ResourceLoader.exists(fallback_model_path):
		return [fallback_model_path, fallback_model_scale]
	return ["", 1.0]


## Returns true if the item was consumed.
func use(player: Node) -> bool:
	match effect:
		Effect.HEAL:
			if player.health >= player.max_health:
				return false
			player.heal(amount)
			return true
		Effect.AMMO:
			# Refill primary + secondary reserves.
			var any := false
			for slot in ["primary", "secondary"]:
				var w: WeaponItem = player.inventory.equipped.get(slot)
				if w:
					w.reserve = max(w.reserve, w.max_reserve())
					any = true
			player.emit_ammo()
			return any
		Effect.HEAVY_AMMO:
			var hw: WeaponItem = player.inventory.equipped.get("heavy")
			if hw == null:
				return false
			hw.reserve = min(hw.reserve + max(amount, hw.mag_size() * 2), hw.max_reserve())
			player.emit_ammo()
			return true
	return false
