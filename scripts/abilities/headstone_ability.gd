class_name HeadstoneAbility
extends Ability
## Sexton, deployable (DESIGN §23.2): sets a ward stone in front of you. Zombies within its radius are slowed and
## marked (take +`amp` damage) while they stay inside. One stone at a time. Tuning: ab_stone_time, ab_stone_radius,
## ab_stone_slow, ab_stone_amp.
@export var stone_time: float = 10.0
@export var radius: float = 5.0
@export var slow: float = 0.5
@export var amp: float = 0.2


class Stone:
	extends AbilityField
	var slow_amp: float = 0.5
	var mark_amp: float = 0.2
	func _pulse() -> void:
		for e in enemies():
			AbilityField.status(e, "slow", pulse_every + 0.2, slow_amp)
			AbilityField.status(e, "mark", pulse_every + 0.2, mark_amp)


func activate(player: Node) -> bool:
	for old in AbilityField.live(player, id):
		old.queue_free()
	var s := Stone.new()
	s.ability_id = id
	s.name = "Headstone"
	s.life = tuned(player, "stone_time", stone_time)
	s.radius = tuned(player, "stone_radius", radius)
	s.slow_amp = clampf(tuned(player, "stone_slow", slow), 0.0, 0.85)
	s.mark_amp = tuned(player, "stone_amp", amp)
	s.build_post(Color(0.6, 0.65, 0.75), 0.9, 0.5, s.radius)
	var p3 := player as Node3D
	var fwd: Vector3 = -p3.global_basis.z
	fwd.y = 0.0
	AbilityField.place(s, player, p3.global_position + fwd.normalized() * 2.0)
	return true
