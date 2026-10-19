class_name PerkSystem
## Runtime logic for weapon perks (definitions in data/perks.json). Buff state lives
## in WeaponItem.buffs so each gun keeps its own stacks. To add a perk, add a JSON
## entry with a new "effect" and handle it in the functions below.


static func _defs(w: WeaponItem) -> Array:
	var out := []
	for id in w.perks:
		var p: Dictionary = GearDB.perk(id)
		if not p.is_empty():
			out.append(p)
	return out


## Called every physics frame for each carried weapon.
static func tick(w: WeaponItem, delta: float) -> void:
	for k in w.buffs.keys():
		if k.ends_with("_t"):
			w.buffs[k] = max(float(w.buffs[k]) - delta, 0.0)
	if w.buffs.get("stack_t", 0.0) <= 0.0:
		w.buffs["stack"] = 0


static func damage_mult(w: WeaponItem, player: Node) -> float:
	var m := 1.0
	for p in _defs(w):
		match p.effect:
			"damage_stack":
				m *= 1.0 + float(p.amount) * int(w.buffs.get("stack", 0))
			"reload_after_kill":
				if w.buffs.get("after_kill_t", 0.0) > 0.0:
					m *= 1.0 + float(p.amount)
	return m


static func reload_mult(w: WeaponItem) -> float:
	var m := 1.0
	for p in _defs(w):
		if p.effect == "reload_buff" and w.buffs.get("reload_buff_t", 0.0) > 0.0:
			m *= 1.0 - float(p.amount)
	return m


static func spread_mult(w: WeaponItem, player: Node) -> float:
	var m := 1.0
	for p in _defs(w):
		if p.effect == "crouch_stability" and player.is_crouched():
			m *= 1.0 - float(p.amount)
	return m


static func on_kill(w: WeaponItem, player: Node) -> void:
	for p in _defs(w):
		match p.effect:
			"damage_stack":
				w.buffs["stack"] = min(int(w.buffs.get("stack", 0)) + 1, int(p.max_stacks))
				w.buffs["stack_t"] = float(p.duration)
			"reload_buff":
				w.buffs["reload_buff_t"] = float(p.duration)
			"reload_after_kill":
				w.buffs["after_kill_ready"] = true
			"grenade_refund":
				player.refund_grenade(float(p.amount))
			"heal_on_kill":
				player.heal(int(p.amount))


## Called when a reload finishes.
static func on_reload(w: WeaponItem) -> void:
	if w.buffs.get("after_kill_ready", false):
		w.buffs["after_kill_ready"] = false
		for p in _defs(w):
			if p.effect == "reload_after_kill":
				w.buffs["after_kill_t"] = float(p.duration)


## Called on every enemy hit (before kill). Explosive rounds live here.
static func on_hit(w: WeaponItem, player: Node, pos: Vector3, dealt: float) -> void:
	for p in _defs(w):
		if p.effect == "explode" and randf() < float(p.chance):
			Explosion.explode(player.get_tree().current_scene, pos, float(p.radius), dealt * float(p.amount),
				2.0, Color(1.0, 0.6, 0.25), player, null, 0.5)
			var a: Node = player.get_node_or_null("/root/Sfx")
			if a:
				a.play_at("frag_explode", pos, -10.0) # small pop for explosive rounds


## Name of the first perk on `w` with this effect (names come from data/perks.json).
static func _name_for(w: WeaponItem, effect: String) -> String:
	for id in w.perks:
		var p: Dictionary = GearDB.perk(id)
		if p.get("effect", "") == effect:
			return p.get("name", id)
	return effect.capitalize()


## Short status text for the HUD (active buffs).
static func status_text(w: WeaponItem) -> String:
	var parts := []
	if int(w.buffs.get("stack", 0)) > 0:
		parts.append("%s x%d" % [_name_for(w, "damage_stack"), int(w.buffs.stack)])
	if w.buffs.get("reload_buff_t", 0.0) > 0.0:
		parts.append(_name_for(w, "reload_buff"))
	if w.buffs.get("after_kill_t", 0.0) > 0.0:
		parts.append(_name_for(w, "reload_after_kill"))
	elif w.buffs.get("after_kill_ready", false):
		parts.append(_name_for(w, "reload_after_kill") + " (reload!)")
	return "  ".join(parts)
