class_name GraveBellAbility
extends Ability
## Sexton, aura (DESIGN §23.2): you toll a bell `tolls` times over the ability's duration. Each toll hits every zombie
## within `radius` for `damage` (source "ability"), shoves it away, slows it, and heals you `heal_per_zombie` per zombie
## tolled. Tuning: ab_bell_radius, ab_bell_damage, ab_bell_heal, ab_bell_tolls, ab_bell_slow.
@export var radius: float = 7.0
@export var damage: float = 25.0
@export var tolls: int = 4
@export var heal_per_zombie: float = 2.0
@export var slow: float = 0.4
@export var knockback: float = 5.0
var tolled: int = 0 ## tolls rung this cast (tests)
var _next: float = 0.0
var _n: int = 0
var _elapsed: float = 0.0


func activate(player: Node) -> bool:
	_n = maxi(int(tuned(player, "bell_tolls", float(tolls))), 1)
	_elapsed = 0.0
	_next = 0.0
	tolled = 0
	_toll(player) # first toll at once
	return true


func process_active(player: Node, delta: float) -> void:
	_elapsed += delta
	var gap := maxf(duration, 0.1) / float(_n)
	while tolled < _n and _elapsed >= gap * tolled:
		_toll(player)


func _toll(player: Node) -> void:
	tolled += 1
	var p3 := player as Node3D
	var r := tuned(player, "bell_radius", radius)
	var hit := 0
	for e in AbilityField.enemies_around(player, p3.global_position + Vector3(0, 0.9, 0), r):
		hit += 1
		AbilityField.status(e, "slow", 2.0, clampf(tuned(player, "bell_slow", slow), 0.0, 0.8))
		if e.has_method("apply_knockback"):
			var d: Vector3 = (e as Node3D).global_position - p3.global_position
			d.y = 0.0
			e.apply_knockback((d.normalized() if d.length() > 0.01 else -p3.global_basis.z) * knockback + Vector3.UP * 1.5)
		AbilityField.hurt(player, e, tuned(player, "bell_damage", damage), id)
	if hit > 0 and player.has_method("heal"):
		player.heal(int(round(hit * tuned(player, "bell_heal", heal_per_zombie))))
	if p3.is_inside_tree():
		Explosion.spawn_vfx(p3.get_tree().current_scene, p3.global_position + Vector3(0, 0.5, 0), r * 0.5, Color(0.75, 0.8, 0.95))


func end(player: Node) -> void:
	while tolled < _n: # a cut-short cast still rings the rest (time scale / cancel)
		_toll(player)
