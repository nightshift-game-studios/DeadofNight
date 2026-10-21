class_name RallyBannerAbility
extends Ability
## Soldier, deployable (DESIGN §23.2): plants a banner at your feet. While you stand within its radius you gain
## overshield every pulse (up to a cap), and zombies inside are slowed. One banner at a time (a new one replaces it).
## Tuning stats (skill tree / class items): ab_banner_time, ab_banner_radius, ab_banner_os, ab_banner_cap, ab_banner_slow.
@export var banner_time: float = 8.0
@export var radius: float = 6.0
@export var overshield_per_pulse: float = 3.0 ## pulses every 0.5 s -> 6 / s
@export var overshield_cap: float = 50.0
@export var slow: float = 0.3


class Banner:
	extends AbilityField
	var os_amount: float = 3.0
	var os_cap: float = 50.0
	var slow_amp: float = 0.3
	func _pulse() -> void:
		var pp: Vector3 = (player as Node3D).global_position
		if Vector3(pp.x, global_position.y, pp.z).distance_to(global_position) <= radius and player.has_method("grant_overshield"):
			player.grant_overshield(os_amount, os_cap)
		for e in enemies():
			AbilityField.status(e, "slow", pulse_every + 0.2, slow_amp)


func activate(player: Node) -> bool:
	for old in AbilityField.live(player, id):
		old.queue_free()
	var b := Banner.new()
	b.ability_id = id
	b.name = "RallyBanner"
	b.life = tuned(player, "banner_time", banner_time)
	b.radius = tuned(player, "banner_radius", radius)
	b.os_amount = tuned(player, "banner_os", overshield_per_pulse)
	b.os_cap = tuned(player, "banner_cap", overshield_cap)
	b.slow_amp = clampf(tuned(player, "banner_slow", slow), 0.0, 0.8)
	b.build_post(Color(0.95, 0.75, 0.35), 2.2, 0.08, b.radius)
	AbilityField.place(b, player, (player as Node3D).global_position)
	return true
