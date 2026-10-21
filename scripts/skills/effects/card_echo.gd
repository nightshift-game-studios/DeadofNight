extends SkillEffect
## Echo Field Card (card type "echo", playtest #13): when picked, ranks up one random other Field Card you own that
## is below its max rank (RunState.add_card). Nothing to rank up: +fallback_points_per_round x the offer round.
## params: copies (how many rank-ups), fallback_points_per_round.

var echoed: Array = [] ## card ids this effect ranked up (tests / HUD)


func default_hooks() -> Array:
	return ["card_picked"]


func wants(ctx: Dictionary) -> bool:
	return str(ctx.get("card_id", "")) == source_id and passes(ctx)


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	var pl = player
	var rs: Node = pl.get_node_or_null("/root/RunState") if pl and is_instance_valid(pl) else null
	if rs == null:
		return
	for i in maxi(int(p("copies", 1)), 1):
		var ids: Array = rs.cards.keys().filter(func(k): return k != source_id and rs.card_def(k).get("type", "") != "echo" \
			and int(rs.cards[k]) < int(rs.card_def(k).get("ranks", 1)))
		ids.sort()
		if ids.is_empty():
			var pts := int(p("fallback_points_per_round", 0)) * maxi(int(rs.get("offer_round")), 1)
			if pts > 0 and pl.has_method("add_points"):
				pl.add_points(pts, "card")
			return
		var pick: String = ids[rs.rng.randi_range(0, ids.size() - 1)]
		echoed.append(pick)
		rs.add_card(pick)
