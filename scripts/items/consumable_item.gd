class_name ConsumableItem
extends Item
## One-shot item used from the inventory. Add new effects to the Effect enum + use().

enum Effect { HEAL, AMMO, HEAVY_AMMO, GRENADE }

const GRENADE_PREFIX := "grenade_" ## id of a grenade pickup: "grenade_<grenades.json id>" (GearDB.grenade_pickup)

@export var effect: Effect = Effect.HEAL
@export var amount: int = 50
@export var auto_use: bool = false ## used instantly when walked over (ammo bricks)
@export_file("*.glb", "*.gltf") var model_path: String = "" ## world model for the pickup
@export var model_scale: float = 1.0
## Art4: old world model kept as a fallback, used only when model_path is missing (e.g. a stripped build).
@export_file("*.glb", "*.gltf") var fallback_model_path: String = ""
@export var fallback_model_scale: float = 1.0
@export var grenade_id: String = "" ## Effect.GRENADE: the grenades.json id it gives (MAIN_HOOKS §24c)


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
		Effect.GRENADE:
			return give_grenade(player)
	return false


## Effect.GRENADE (MAIN_HOOKS §24c): the player throws this grenade for the rest of the match. Sets grenade_data and
## meta grenade_override (player.gd §24c makes apply_stats() keep it; without the hunk a class change / respec reverts it),
## then plays grenade_pickup + grenade_rarity_<rarity>. False when the player already has it.
func give_grenade(player: Node) -> bool:
	var ml := Engine.get_main_loop()
	var root: Node = (ml as SceneTree).root if ml is SceneTree else null
	var gdb: Node = root.get_node_or_null("GearDB") if root else null
	if gdb == null or not (gdb.get("grenades") as Dictionary).has(grenade_id) or not "grenade_data" in player:
		return false
	var d: Dictionary = gdb.grenade(grenade_id)
	if str((player.get("grenade_data") as Dictionary).get("variant", "")) == str(d.get("variant", grenade_id)) \
			and str((player.get("grenade_data") as Dictionary).get("name", "")) == str(d.get("name", "")):
		return false
	player.set_meta("grenade_override", grenade_id) # player.gd §24c: apply_stats() keeps it (class change, respec)
	player.set("grenade_data", d)
	if player.has_method("recalc_stats"):
		player.recalc_stats() # grenade_cooldown follows the new grenade's cooldown
	if player.has_signal("grenade_changed"):
		player.emit_signal("grenade_changed", str(d.get("name", "Grenade")), float(player.get("_grenade_cd")) if "_grenade_cd" in player else 0.0,
			float(player.get("grenade_cooldown")) if "grenade_cooldown" in player else 20.0)
	var sfx: Node = root.get_node_or_null("Sfx")
	if sfx:
		sfx.play("grenade_pickup")
		sfx.play("grenade_rarity_" + str(d.get("rarity", "common")))
	return true
