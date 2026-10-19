extends SkillEffect
## Drops a consumable pickup (resources/items/<item>.tres) where the event happened.
## params: item.

var dropped: int = 0


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var main: Node = player.get_tree().current_scene
	if main == null or not main.has_method("spawn_pickup"):
		return
	var it = GearDB.consumable(str(params.get("item", "ammo_box")))
	if it == null:
		return
	var t = ctx.get("target")
	var pos: Vector3 = (t as Node3D).global_position if t is Node3D and is_instance_valid(t) else player.global_position
	main.spawn_pickup(it, pos + Vector3(0, 0.3, 0), false)
	dropped += 1
