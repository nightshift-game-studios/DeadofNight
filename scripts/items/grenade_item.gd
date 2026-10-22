class_name GrenadeItem
extends GearItem
## A grenade you equip (playtest 2026-10-22 #5, Skillz, DESIGN §25, /workspace/skillz/GRENADE_ITEMS_API.md).
## Lives in the Inventory "grenade" equip slot like armor; the equipped one is what the player throws. Grenade COUNT
## (charges + cooldown refill) stays on the player: swapping the item changes the type and its rolled Fittings only.
##   grenade_id  data/grenades.json id = the ThrownProjectile variant (never renamed). rarity = that type's rarity.
##   fittings    {fitting id: rolled value}, e.g. {"heavy_packing": 1.12, "quick_rearm": 0.9} (data/grenades.json items.fittings)
##   item_power  rolled like other gear; scales every damage key (items.ip_damage_per_point).
## throw_data() = grenades.json base + Item Power + Fittings: the dict player.grenade_data / Grenade.throw_from use.
## Co-op (Netz): the client sends to_dict() on join + every equip change; the host rebuilds the same numbers with
## GrenadeItem.throw_data_from_dict(d) (static, no instance needed) and puts them in the spawn spec.

const SLOT := "grenade"

@export var grenade_id: String = "frag"
@export var fittings: Dictionary = {}


func _init() -> void:
	super._init()
	type = ItemType.EQUIPMENT
	slot = SLOT


static func _gdb() -> Node:
	var ml := Engine.get_main_loop()
	return (ml as SceneTree).root.get_node_or_null("GearDB") if ml is SceneTree else null


static func cfg() -> Dictionary:
	var g := _gdb()
	return g.get("grenade_items") if g and g.get("grenade_items") is Dictionary else {}


## grenades.json entry for this item's type ({} if unknown).
func base_data() -> Dictionary:
	var g := _gdb()
	return (g.get("grenades") as Dictionary).get(grenade_id, {}) if g else {}


func variant() -> String:
	return str(base_data().get("variant", grenade_id))


func type_name() -> String:
	return str(cfg().get("type_name", "Grenade"))


## Damage multiplier from Item Power: 1 + (IP - 100) x ip_damage_per_point (never below ip_mult_min).
static func ip_mult(ip: int) -> float:
	var c := cfg()
	return maxf(1.0 + float(ip - 100) * float(c.get("ip_damage_per_point", 0.003)), float(c.get("ip_mult_min", 0.7)))


## The thrown grenade's data for (type id, fittings, item power). Static so the co-op host can rebuild a client's
## grenade from its dict. Adds: grenade_id, item_id, item_power, fittings, ip_mult. "rarity" / "variant" stay the type's.
static func throw_data_for(id: String, fit: Dictionary, ip: int, item_id_v: String = "") -> Dictionary:
	var g := _gdb()
	if g == null:
		return {}
	var all: Dictionary = g.get("grenades")
	if not all.has(id):
		id = "frag"
	var d: Dictionary = (all.get(id, {}) as Dictionary).duplicate(true)
	if d.is_empty():
		return d
	var c := cfg()
	var defs: Dictionary = c.get("fittings", {})
	var m := {"damage_mult": 1.0, "radius_mult": 1.0, "cooldown_mult": 1.0, "fuse_mult": 1.0, "throw_speed_mult": 1.0, "effect_mult": 1.0}
	for fid in fit:
		var st := str((defs.get(fid, {}) as Dictionary).get("stat", ""))
		if m.has(st):
			m[st] = float(m[st]) * float(fit[fid])
	var ipm := ip_mult(ip)
	var eff_keys: Array = (c.get("effect_keys", {}) as Dictionary).get(id, [])
	for k in eff_keys:
		if d.has(k):
			d[k] = float(d[k]) * float(m.effect_mult)
	for k in c.get("damage_keys", []):
		if d.has(k):
			d[k] = float(d[k]) * float(m.damage_mult) * ipm
	for k in c.get("radius_keys", []):
		if d.has(k):
			d[k] = float(d[k]) * float(m.radius_mult)
	if d.has("cooldown"):
		d["cooldown"] = float(d.cooldown) * float(m.cooldown_mult)
	if float(d.get("fuse", 0.0)) > 0.0:
		d["fuse"] = float(d.fuse) * float(m.fuse_mult)
	if d.has("throw_speed"):
		d["throw_speed"] = float(d.throw_speed) * float(m.throw_speed_mult)
	if d.has("heal_frac"):
		d["heal_frac"] = minf(float(d.heal_frac), float(c.get("heal_frac_cap", 0.45)))
	d["grenade_id"] = id
	d["item_id"] = item_id_v
	d["item_power"] = ip
	d["ip_mult"] = snappedf(ipm, 0.001)
	d["fittings"] = fit.duplicate()
	return d


## Host-side rebuild from a GrenadeItem.to_dict() (Netz: the dict a client sent for its equipped grenade).
static func throw_data_from_dict(d: Dictionary) -> Dictionary:
	var fit: Dictionary = d.get("fittings", {}) if d.get("fittings") is Dictionary else {}
	return throw_data_for(str(d.get("grenade_id", "frag")), fit, int(d.get("item_power", 100)), str(d.get("item_id", "")))


func throw_data() -> Dictionary:
	return throw_data_for(grenade_id, fittings, item_power, item_id)


## What `player` throws: the equipped GrenadeItem, else a §24c pickup override (meta grenade_override), else `fallback`
## (the class grenade). player.gd §25 hunk: apply_stats() calls this, so class changes / respecs keep the equipped item.
static func resolve(player: Node, fallback: Dictionary) -> Dictionary:
	var inv: Node = player.get("inventory") if player and "inventory" in player else null
	var gi = inv.equipped.get(SLOT) if inv and "equipped" in inv else null
	if gi is GrenadeItem:
		return (gi as GrenadeItem).throw_data()
	var g := _gdb()
	if player and player.has_meta("grenade_override") and g:
		return g.grenade(str(player.get_meta("grenade_override")))
	return fallback


## The class grenade of `player` (PlayerClass.grenade_id, else frag): what an empty grenade slot throws.
static func class_grenade(player: Node) -> Dictionary:
	var g := _gdb()
	if g == null:
		return {}
	var pc = player.get("player_class") if player and "player_class" in player else null
	return g.grenade(str(pc.grenade_id) if pc and "grenade_id" in pc else "frag")


## Makes `player` throw what its inventory has equipped now (Inventory calls it on every grenade equip). Keeps the
## charges / cooldown, re-derives grenade_cooldown (recalc_stats) and emits grenade_changed. Works without the player.gd
## hunk; that hunk only makes apply_stats() keep it too. False if `player` isn't a Player.
static func apply_to_player(player: Node) -> bool:
	if player == null or not ("grenade_data" in player):
		return false
	var gi = player.get("inventory").equipped.get(SLOT) if "inventory" in player and player.get("inventory") and "equipped" in player.get("inventory") else null
	# player.gd's apply_stats() reads the §24c meta through GearDB.grenade(): point it at this item's throw data
	# ("@<item_id>"), so class changes / respecs / round-start re-applies keep the item and its Fittings.
	var g := _gdb()
	if gi is GrenadeItem and g and g.has_method("set_item_grenade"):
		var key := "@" + str((gi as GrenadeItem).item_id)
		g.set_item_grenade(key, (gi as GrenadeItem).throw_data())
		player.set_meta("grenade_override", key)
	elif player.has_meta("grenade_override"):
		player.remove_meta("grenade_override")
	var d := resolve(player, class_grenade(player))
	player.set("grenade_data", d)
	if player.has_method("recalc_stats"):
		player.recalc_stats()
	if player.has_signal("grenade_changed"):
		player.emit_signal("grenade_changed", str(d.get("name", "Grenade")), float(player.get("_grenade_cd")) if "_grenade_cd" in player else 0.0,
			float(player.get("grenade_cooldown")) if "grenade_cooldown" in player else 20.0)
	if player.has_signal("grenade_item_changed"):
		player.emit_signal("grenade_item_changed", gi)
	return true


# ------------------------------------------------------------------ UI rows

## Fitting rows for the item card: [{id, name, value, pct, text}] in roll order.
func fitting_rows() -> Array:
	var defs: Dictionary = cfg().get("fittings", {})
	var labels: Dictionary = cfg().get("effect_labels", {})
	var out := []
	for fid in fittings:
		var def: Dictionary = defs.get(fid, {})
		var v := float(fittings[fid])
		var pct := int(round(absf(v - 1.0) * 100.0))
		var txt := str(def.get("text", "")).replace("{pct}", str(pct)).replace("{effect}", str(labels.get(grenade_id, "effect")))
		out.append({"id": str(fid), "name": str(def.get("name", fid)), "value": v, "pct": pct, "text": txt})
	return out


## Item-card stat block (same shape as WeaponItem / ArmorItem.card_stats(): [label, text, bar 0..1, value, higher_better]).
func card_stats() -> Array:
	var d := throw_data()
	var dmg := float(d.get("damage", 0.0))
	var out := []
	out.append(["Damage", "%d" % int(round(dmg)), clampf(dmg / 450.0, 0.0, 1.0), dmg, true])
	out.append(["Radius", "%.1f m" % float(d.get("radius", 0.0)), clampf(float(d.get("radius", 0.0)) / 6.0, 0.0, 1.0), float(d.get("radius", 0.0)), true])
	out.append(["Cooldown", "%.1f s" % float(d.get("cooldown", 20.0)), clampf(1.0 - float(d.get("cooldown", 20.0)) / 32.0, 0.0, 1.0), float(d.get("cooldown", 20.0)), false])
	var fz := float(d.get("fuse", 0.0))
	out.append(["Fuse", "impact" if fz <= 0.0 else "%.1f s" % fz, clampf(1.0 - fz / 6.0, 0.0, 1.0), fz, false])
	return out


## One-line description of what the type does (GRENADES_SPEC wording, from grenades.json + the item's numbers).
func effect_line() -> String:
	var d := throw_data()
	match str(d.get("type", "frag")):
		"pulse": return "%d pulses of %d damage." % [int(d.get("pulses", 5)), int(round(float(d.damage)))]
		"cinderjar": return "Shatters on impact; fire patch burns for %.1f s." % float(d.get("patch_duration", 5.0))
		"shiverglass": return "Chills for %.1f s; chilled zombies take +%d%% damage." % [float(d.get("slow_time", 3.0)), int(round((float(d.get("frozen_damage_mult", 1.15)) - 1.0) * 100.0))]
		"tallyhook": return "Hooks a zombie, then chains to %d more." % int(d.get("chain_count", 4))
		"rookery": return "Splits into %d bomblets." % int(d.get("bomblets", 5))
		"gravewell": return "Pulls zombies in for %.1f s, then blasts." % float(d.get("pull_time", 2.5))
		"leechbell": return "%d%% of the damage comes back as healing." % int(round(float(d.get("heal_frac", 0.3)) * 100.0))
		"requiem_bell": return "Bounces %d times, then marks zombies within %.0f m (+%d%% damage taken)." % [int(d.get("bounces", 3)), float(d.get("toll_radius", 10.0)), int(round((float(d.get("mark_damage_mult", 1.25)) - 1.0) * 100.0))]
	return "One blast after a %.1f s fuse." % float(d.get("fuse", 1.6))


func get_summary() -> String:
	var lines := ["%s %s  |  %s  |  IP %d" % [rarity_name(), type_name(), manufacturer, item_power], effect_line()]
	for r in fitting_rows():
		lines.append("%s: %s" % [r.name, r.text])
	return "\n".join(lines)


## [glb path, scale] for the world pickup (Desi's grenades/<model or variant>.glb; ["", 1] if missing).
func world_model() -> Array:
	var b := base_data()
	var path := "res://assets/models/grenades/%s.glb" % str(b.get("model", b.get("variant", grenade_id)))
	return [path, 1.6] if ResourceLoader.exists(path) else ["", 1.0]


## Tint (#hex) of the type's effect (Band, trail, icon accent).
func effect_color() -> Color:
	return Color.from_string(str(base_data().get("color", "#FF8C33")), Color(1, 0.55, 0.2))


func to_dict() -> Dictionary:
	var d := super.to_dict()
	d["class"] = "grenade"
	d["grenade_id"] = grenade_id
	d["variant"] = variant()
	d["fittings"] = fittings.duplicate()
	return d


func apply_dict(d: Dictionary) -> void:
	super.apply_dict(d)
	slot = SLOT
	grenade_id = str(d.get("grenade_id", d.get("variant", grenade_id)))
	fittings = (d.get("fittings", {}) as Dictionary).duplicate() if d.get("fittings") is Dictionary else {}
	archetype = grenade_id
	var b := base_data()
	if not b.is_empty(): # rarity is the type's (Netz checks variant + rarity): a stale / edited dict can't disagree
		rarity = Rarity.from_id(str(b.get("rarity", "common")))
		color = rarity_color()
