extends SkillEffect
## Fleeting Field Card (card type "fleeting", playtest #13): the card removes itself (RunState.remove_card) once
## `rounds` rounds have been cleared after it was picked. Its other effects are big because they don't last.

var cleared: int = 0


func default_hooks() -> Array:
	return ["round_cleared"]


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	cleared += 1
	if cleared >= int(p("rounds", 2)):
		var rs: Node = player.get_node_or_null("/root/RunState") if player and is_instance_valid(player) else null
		if rs and rs.has_method("remove_card"):
			rs.call_deferred("remove_card", source_id)


func rounds_left() -> int:
	return maxi(int(p("rounds", 2)) - cleared, 0)
