class_name VigilCandleAbility
extends Ability
## Chandler, deployable (DESIGN §23.2): sets a candle at your feet that burns every zombie within its radius
## (burn status, `dps` per second, through you as the source). Up to `max_candles` burn at once (oldest goes out).
## Tuning: ab_candle_time, ab_candle_radius, ab_candle_dps, ab_candle_count.
@export var candle_time: float = 12.0
@export var radius: float = 4.5
@export var dps: float = 20.0
@export var max_candles: int = 1


class Candle:
	extends AbilityField
	var burn_dps: float = 20.0
	func _pulse() -> void:
		for e in enemies():
			AbilityField.status(e, "burn", 1.0, 0.0, burn_dps, player)


func activate(player: Node) -> bool:
	var live := AbilityField.live(player, id)
	var cap := maxi(int(tuned(player, "candle_count", float(max_candles))), 1)
	while live.size() >= cap:
		live.pop_front().queue_free()
	var c := Candle.new()
	c.ability_id = id
	c.name = "VigilCandle"
	c.life = tuned(player, "candle_time", candle_time)
	c.radius = tuned(player, "candle_radius", radius)
	c.burn_dps = tuned(player, "candle_dps", dps)
	c.build_post(Color(1.0, 0.62, 0.25), 0.45, 0.12, c.radius + 1.0)
	AbilityField.place(c, player, (player as Node3D).global_position)
	return true
