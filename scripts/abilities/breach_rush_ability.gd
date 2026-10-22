class_name BreachRushAbility
extends DashAbility
## Soldier, movement (DESIGN §24.4, replaces the generic Dash): shoulder-charge a few metres forward. You gain overshield
## at once, and every zombie you plough through takes `damage` once per rush (source "ability", through
## AbilityField.hurt -> SkillRunner.deal: the same host-authoritative damage path as Grave Bell) and is knocked aside.
## No RNG. Tuning: ab_rush_damage, ab_rush_radius, ab_rush_os, ab_rush_knock.
@export var damage: float = 45.0
@export var radius: float = 1.6
@export var overshield: float = 15.0
@export var knockback: float = 7.0
var _hit: Dictionary = {}
var hits: int = 0 ## zombies hit this rush (tests)
var _vfx: Node3D = null ## Desi's dust / streak (AbilityVFX)


func activate(player: Node) -> bool:
	_hit.clear()
	hits = 0
	if not super.activate(player):
		return false
	if player.has_method("grant_overshield"):
		player.grant_overshield(tuned(player, "rush_os", overshield))
	_vfx = AbilityVFX.rush_start(player, duration)
	_plough(player)
	return true


func process_active(player: Node, _delta: float) -> void:
	_plough(player)


func end(player: Node) -> void:
	_plough(player)


func _plough(player: Node) -> void:
	var p3 := player as Node3D
	if p3 == null or not p3.is_inside_tree():
		return
	var v: Vector3 = Vector3(player.velocity.x, 0, player.velocity.z) if "velocity" in player else Vector3.ZERO
	var dir: Vector3 = v.normalized() if v.length() > 0.1 else -p3.global_basis.z
	dir.y = 0.0
	for e in AbilityField.enemies_around(player, p3.global_position + Vector3(0, 0.9, 0), tuned(player, "rush_radius", radius)):
		var key: int = e.get_instance_id()
		if _hit.has(key):
			continue
		_hit[key] = true
		hits += 1
		if e.has_method("apply_knockback"):
			e.apply_knockback(dir.normalized() * tuned(player, "rush_knock", knockback) + Vector3.UP * 2.0)
		AbilityField.hurt(player, e, tuned(player, "rush_damage", damage), id)
		if e is Node3D:
			AbilityVFX.rush_hit(_vfx, (e as Node3D).global_position)
