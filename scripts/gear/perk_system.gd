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
			# playtest #33 named attributes (WEAPON_ATTRS.md). damage_mult runs after the round left the mag.
			"mag_tail_damage": # Tail Rounds: the last `fraction` of the magazine
				if w.ammo < ceili(w.mag_size() * float(p.get("fraction", 0.3))):
					m *= 1.0 + float(p.amount)
			"mag_head_damage": # Opening Hymn: the first `count` rounds of a full magazine
				if w.mag_size() - w.ammo <= int(p.get("count", 3)):
					m *= 1.0 + float(p.amount)
			"still_damage": # Graveside Calm
				if player and player.has_method("is_still") and player.is_still(float(p.get("delay", 0.5))):
					m *= 1.0 + float(p.amount)
			"moving_damage": # Runaway Fire
				if _moving(player, p):
					m *= 1.0 + float(p.amount)
			"low_health_damage": # Ember Will
				if player and "health" in player and float(player.health) < float(player.max_health) * float(p.get("threshold", 0.4)):
					m *= 1.0 + float(p.amount)
	return m


## Runaway Fire: sprint-speed flat velocity, a recent slide, or off the ground.
static func _moving(player: Node, p: Dictionary) -> bool:
	if player == null:
		return false
	if player.has_method("is_sliding_recent") and player.is_sliding_recent(0.3):
		return true
	if player.has_method("is_airborne") and player.is_airborne():
		return true
	var v: Vector3 = player.get("velocity") if "velocity" in player else Vector3.ZERO
	return Vector2(v.x, v.z).length() >= float(p.get("speed_min", 6.0))


static func reload_mult(w: WeaponItem) -> float:
	var m := 1.0
	for p in _defs(w):
		if p.effect == "reload_buff" and w.buffs.get("reload_buff_t", 0.0) > 0.0:
			m *= 1.0 - float(p.amount)
		elif p.effect == "empty_reload" and w.ammo <= 0: # Spent Breath (called as the reload starts)
			m *= 1.0 - float(p.amount)
	return m


static func spread_mult(w: WeaponItem, player: Node) -> float:
	var m := 1.0
	for p in _defs(w):
		if p.effect == "crouch_stability" and player.is_crouched():
			m *= 1.0 - float(p.amount)
		elif p.effect == "ads_stability" and "ads_active" in player and player.ads_active: # Bracewire
			m *= 1.0 - float(p.amount)
		elif p.effect == "moving_damage" and _moving(player, p): # Runaway Fire
			m *= 1.0 - float(p.get("spread", 0.0))
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
			"kill_refill": # Pocket Salvage: reserve -> magazine
				var n := mini(maxi(ceili(w.mag_size() * float(p.amount)), 1), mini(w.mag_size() - w.ammo, w.reserve))
				if n > 0:
					w.ammo += n
					w.reserve -= n
					if player.has_method("emit_ammo"):
						player.emit_ammo()


## Called when a reload finishes.
static func on_reload(w: WeaponItem) -> void:
	if w.buffs.get("after_kill_ready", false):
		w.buffs["after_kill_ready"] = false
		for p in _defs(w):
			if p.effect == "reload_after_kill":
				w.buffs["after_kill_t"] = float(p.duration)


## Called on every enemy hit (before kill). Explosive rounds live here. `target`: the zombie hit (null = the
## nearest zombie to `pos`; player.gd passes only pos today).
static func on_hit(w: WeaponItem, player: Node, pos: Vector3, dealt: float, target: Node = null) -> void:
	for p in _defs(w):
		if p.effect in ["chain_hit", "ignite_hit", "slow_hit", "mark_hit"]:
			if target == null or not is_instance_valid(target):
				target = _target_at(player, pos)
			_status_hit(p, w, player, target, dealt)
			continue
		if p.effect == "explode" and randf() < float(p.chance):
			Explosion.explode(player.get_tree().current_scene, pos, float(p.radius), dealt * float(p.amount),
				2.0, Color(1.0, 0.6, 0.25), player, null, 0.5)
			var a: Node = player.get_node_or_null("/root/Sfx")
			if a:
				a.play_at("frag_explode", pos, -10.0) # small pop for explosive rounds


static func _runner(player: Node):
	return player.get("skill_runner") if player and "skill_runner" in player else null


## The zombie a hit at `pos` landed on (hit positions are on the body, within ~1 m of its centre).
static func _target_at(player: Node, pos: Vector3) -> Node:
	var r = _runner(player)
	return r.nearest_enemy(pos, 1.6) if r else null


## Arc Tether / Smolder Shot / Mire Rounds / Pale Brand on one hit.
static func _status_hit(p: Dictionary, w: WeaponItem, player: Node, target: Node, dealt: float) -> void:
	if target == null or not is_instance_valid(target) or not target.has_method("apply_status") or dealt <= 0.0:
		return
	if randf() >= float(p.get("chance", 1.0)):
		return
	match str(p.effect):
		"chain_hit":
			var r = _runner(player)
			var next = r.nearest_enemy(r.center_of(target), float(p.get("radius", 6.0)), [target]) if r else null
			if next:
				r.deal(next, dealt * float(p.amount), "arc", {}, {"weapon": w, "element": w.element, "perk": str(p.id)})
				Effects.spawn_tracer(player.get_tree().current_scene, r.center_of(target), r.center_of(next), Color(0.45, 0.75, 1.0))
		"ignite_hit":
			target.apply_status("burn", {"dur": float(p.get("duration", 3.0)), "dps": dealt * float(p.amount), "source": player})
		"slow_hit":
			target.apply_status("slow", {"dur": float(p.get("duration", 2.0)), "amp": float(p.amount), "source": player})
		"mark_hit":
			target.apply_status("mark", {"dur": float(p.get("duration", 4.0)), "amp": float(p.amount), "source": player})


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
