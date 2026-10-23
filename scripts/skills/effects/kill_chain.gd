extends SkillEffect
## Kill-chain Field Card (card type "trigger"): `n` qualifying kills (JSON "if" filters, e.g. headshot / melee) with
## no more than `gap` seconds between them complete a chain and pay out; the chain then restarts.
## Payout (any mix): refill_mag (magazine filled from nothing), overshield, heal, heal_full, melee_reset, grenade_reset, drop (list of pickup ids, used in turn: a pickup spawns where the last kill fell).

var count: int = 0
var chains: int = 0
var _last: float = -INF


var _drops: int = 0
var dropped: int = 0


func _drop_item() -> String:
	var items: Array = params.get("drop", ["ammo_box"])
	var it := str(items[_drops % items.size()])
	_drops += 1
	return it


func _drop(pl, ctx: Dictionary, item: String) -> void:
	var main: Node = pl.get_tree().current_scene
	var it = GearDB.consumable(item)
	if main == null or it == null or not main.has_method("spawn_pickup"):
		return
	var t = ctx.get("target")
	var pos: Vector3 = (t as Node3D).global_position if t is Node3D and is_instance_valid(t) else pl.global_position
	main.spawn_pickup(it, pos + Vector3(0, 0.3, 0), false)
	dropped += 1


func default_hooks() -> Array:
	return ["enemy_killed"]


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var gap := float(p("gap", 0.0))
	if gap > 0.0 and now() - _last > gap:
		count = 0
	_last = now()
	count += 1
	if count < int(p("n", 3)):
		return
	count = 0
	chains += 1
	var pl = player
	if pl == null or not is_instance_valid(pl):
		return
	if params.get("refill_mag", false):
		var w = pl.current_weapon()
		if w != null:
			w.ammo = w.mag_size()
			pl.emit_ammo()
	if params.has("overshield"):
		pl.grant_overshield(float(p("overshield", 0.0)), float(p("cap", -1.0)))
	if params.has("heal"):
		pl.heal(int(p("heal", 0)))
	if params.get("heal_full", false):
		pl.heal(int(pl.max_health))
	if params.has("drop"):
		_drop(pl, ctx, str(_drop_item()))
	if params.get("melee_reset", false):
		pl.reset_cooldown("melee")
	if params.get("grenade_reset", false):
		pl.reset_cooldown("grenade")
