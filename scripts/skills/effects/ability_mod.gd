extends SkillEffect
## Class ability tweaks. params (any mix):
##  charges        +N ability charges (stat "ability_charges_add")
##  cooldown_add   +s ability cooldown (stat "ability_cooldown_add")
##  duration       ability lasts at least this long (on ability_used)
##  extend_on_kill / max_extend   kills while active extend it
##  contact_damage / knockback / radius   zombies touched while the ability is active take damage once per use

var _extended: float = 0.0
var _touched: Dictionary = {}
var touches: int = 0


func default_hooks() -> Array:
	var h := []
	if params.has("duration") or params.has("extend_on_kill") or params.has("contact_damage"):
		h.append("ability_used")
	if params.has("extend_on_kill"):
		h.append("enemy_killed")
	if params.has("contact_damage"):
		h.append("ability_tick")
	return h


func stats() -> Array:
	var s := []
	if params.has("charges"):
		s.append("ability_charges_add")
	if params.has("cooldown_add"):
		s.append("ability_cooldown_add")
	return s


func modify(stat: String, value: float, _ctx: Dictionary) -> float:
	if stat == "ability_charges_add":
		return value + float(p("charges", 0))
	if stat == "ability_cooldown_add":
		return value + float(p("cooldown_add", 0.0))
	return value


func on_event(name: StringName, _ctx: Dictionary) -> void:
	match name:
		&"ability_used":
			_extended = 0.0
			_touched.clear()
			if params.has("duration"):
				player.set_ability_active_time(maxf(player.ability_active_time(), float(p("duration", 0.0))))
			if params.has("contact_damage"):
				_contact()
		&"ability_tick":
			_contact()
		&"enemy_killed":
			if player.is_ability_active() and _extended < float(p("max_extend", 3.0)):
				var add := minf(float(p("extend_on_kill", 0.5)), float(p("max_extend", 3.0)) - _extended)
				_extended += add
				player.set_ability_active_time(player.ability_active_time() + add)


func _contact() -> void:
	if not params.has("contact_damage"):
		return
	var dir: Vector3 = Vector3(player.velocity.x, 0, player.velocity.z)
	dir = dir.normalized() if dir.length() > 0.1 else -player.global_basis.z
	for e in runner.enemies_near(player.global_position + Vector3(0, 0.9, 0), float(p("radius", 1.5))):
		var id: int = e.get_instance_id()
		if _touched.has(id):
			continue
		_touched[id] = true
		touches += 1
		if e.has_method("apply_knockback"):
			e.apply_knockback(dir * float(p("knockback", 8.0)) + Vector3.UP * 2.0)
		runner.deal(e, float(p("contact_damage", 40.0)), "dash", {"depth": 0})
