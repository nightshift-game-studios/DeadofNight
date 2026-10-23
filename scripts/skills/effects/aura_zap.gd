extends SkillEffect
## Zap aura Field Card (card type "trigger"): while `cond` holds (a SkillRunner cond, default "still") the lattice
## zaps the `targets` nearest zombies within `radius` for `damage` every `interval` seconds (source "skill_aura").

var _acc: float = 0.0
var zaps: int = 0


func has_tick() -> bool:
	return true


func tick(delta: float) -> void:
	if player == null or not is_instance_valid(player) or not player.is_inside_tree() or player.dead:
		_acc = 0.0
		return
	if not runner.cond(str(params.get("cond", "still")), {}, params):
		_acc = 0.0
		return
	_acc += delta
	if _acc < float(p("interval", 0.8)):
		return
	_acc = 0.0
	var pos: Vector3 = player.global_position + Vector3(0, 0.9, 0)
	var list: Array = runner.enemies_near(pos, float(p("radius", 7.0)))
	list.sort_custom(func(a, b): return (a.global_position as Vector3).distance_to(pos) < (b.global_position as Vector3).distance_to(pos))
	for i in mini(list.size(), int(p("targets", 3))):
		var z = list[i]
		Effects.spawn_tracer(player.get_tree().current_scene, pos, SkillRunner.center_of(z), Color(0.45, 0.8, 1.0, 0.9))
		runner.deal(z, float(p("damage", 40.0)), "skill_aura", {"depth": 0}, {"element": "volt"})
		zaps += 1
