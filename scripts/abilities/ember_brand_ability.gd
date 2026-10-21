class_name EmberBrandAbility
extends Ability
## Chandler, mark (DESIGN §23.2): brands every zombie in a cone ahead (up to `max_targets`): it burns (`dps`) for
## `brand_time` seconds, and if it dies while branded it bursts for `burst` damage in `burst_radius` (source "ability").
## Tuning: ab_brand_count, ab_brand_dps, ab_brand_time, ab_brand_burst.
@export var range_m: float = 20.0
@export var cone_deg: float = 35.0
@export var max_targets: int = 6
@export var dps: float = 30.0
@export var brand_time: float = 4.0
@export var burst: float = 40.0
@export var burst_radius: float = 2.5
var last_branded: Array = [] ## tests


class Watch:
	extends AbilityField
	var burst: float = 40.0
	var burst_radius: float = 2.5
	var bursts: int = 0
	func _on_game_event(name: StringName, ctx: Dictionary) -> void:
		if name != &"enemy_killed":
			return
		var t = ctx.get("target")
		if t == null or not is_instance_valid(t) or not t.has_method("has_status") or not t.has_status("brand"):
			return
		bursts += 1
		var pos: Vector3 = (t as Node3D).global_position + Vector3(0, 0.9, 0)
		if player.has_method("skill_explosion"):
			player.skill_explosion(pos, burst_radius, burst, 3.0, {"source": "ability", "ability": ability_id,
				"depth": int(ctx.get("depth", 0)) + 1})


func activate(player: Node) -> bool:
	last_branded = ChalkMarkAbility.targets_in_cone(player, range_m, cone_deg, int(tuned(player, "brand_count", float(max_targets))))
	var t := tuned(player, "brand_time", brand_time)
	for e in last_branded:
		AbilityField.status(e, "burn", t, 0.0, tuned(player, "brand_dps", dps), player)
		AbilityField.status(e, "brand", t)
	for old in AbilityField.live(player, id):
		old.queue_free()
	var w := Watch.new()
	w.ability_id = id
	w.name = "EmberBrandWatch"
	w._listen = true
	w.life = t + 0.5
	w.pulse_every = 1.0
	w.burst = tuned(player, "brand_burst", burst)
	w.burst_radius = burst_radius
	AbilityField.place(w, player, (player as Node3D).global_position)
	return true
