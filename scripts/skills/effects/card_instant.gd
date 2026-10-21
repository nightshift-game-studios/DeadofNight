extends SkillEffect
## Instant Field Card (card type "instant", playtest #13): pays out once each time the card is picked, then
## does nothing. Hooked to card_picked for its own card id, so a rebuild never pays twice.
## params: points_per_round (x the offer round), refill_ammo (mags + reserves of every equipped gun, heavy too),
## grenade (all grenade charges ready), heal (HP; -1 = to full).


func default_hooks() -> Array:
	return ["card_picked"]


func wants(ctx: Dictionary) -> bool:
	return str(ctx.get("card_id", "")) == source_id and passes(ctx)


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	var pl = player
	if pl == null or not is_instance_valid(pl):
		return
	var rs: Node = pl.get_node_or_null("/root/RunState")
	var pts := int(p("points_per_round", 0)) * maxi(int(rs.get("offer_round")) if rs else 1, 1)
	if pts > 0 and pl.has_method("add_points"):
		pl.add_points(pts, "card")
	if bool(p("refill_ammo", false)) and "inventory" in pl and pl.inventory:
		for s in ["primary", "secondary", "heavy"]:
			var w = pl.inventory.equipped.get(s)
			if w is WeaponItem:
				w.reserve = maxi(w.reserve, w.max_reserve())
				w.ammo = w.mag_size()
		if pl.has_method("emit_ammo"):
			pl.emit_ammo()
	if bool(p("grenade", false)) and pl.has_method("reset_cooldown"):
		pl.reset_cooldown("grenade")
	var h := int(p("heal", 0))
	if h != 0 and pl.has_method("heal"):
		pl.heal(int(pl.max_health) if h < 0 else h)
