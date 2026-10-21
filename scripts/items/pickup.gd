class_name Pickup
extends Area3D
## A world item. Gear shows as a glowing loot shard (faceted gem + light beam) in its rarity colour;
## consumables show their model. Walk up and press E (auto-use items like ammo
## are collected on touch).

@export var item: Item
## G4M3N's loot markers (STATS_API.md): the gear's Rarity tier (Rarity.COMMON..MYTHIC), -1 for consumables / empty.
var rarity: int:
	get:
		return (item as GearItem).rarity if item is GearItem else -1

var _t: float = 0.0
var _visual: Node3D
@onready var label: Label3D = $Label3D


func _ready() -> void:
	add_to_group("pickups")
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	if item == null:
		return
	var gear := item as GearItem
	var cons := item as ConsumableItem
	var c: Color = gear.rarity_color() if gear else item.color
	label.text = item.display_name
	label.modulate = c.lightened(0.35)
	var wm: Array = cons.world_model() if cons else ["", 1.0]
	if wm[0] != "":
		_visual = (load(wm[0]) as PackedScene).instantiate()
		_visual.scale = Vector3.ONE * float(wm[1])
		add_child(_visual)
		if cons.effect == ConsumableItem.Effect.HEAVY_AMMO:
			# Desi's heavy_ammo.glb: tint only its TintBand stripe; the old fallback mesh has none, so tint it all.
			var tb := _visual.find_child("TintBand", true, false)
			_tint(tb if tb else _visual, c)
		label.position.y = 0.8
	else:
		_visual = _make_loot_shard(c, gear != null and gear.rarity == Rarity.MYTHIC)
		add_child(_visual)
	# Light beam so drops are easy to spot (taller for better rarities).
	var tier: int = gear.rarity if gear else 0
	var beam := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.06
	cm.height = 2.0 + tier * 1.2
	beam.mesh = cm
	beam.position.y = cm.height * 0.5
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.albedo_color = Color(c.r, c.g, c.b, 0.35)
	beam.material_override = bm
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam)
	var light := OmniLight3D.new()
	light.light_color = c
	light.light_energy = 1.2
	light.omni_range = 2.5
	light.position.y = 0.7
	add_child(light)


func _make_loot_shard(c: Color, mythic: bool) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new() # low segment count = faceted crystal look
	sm.radius = 0.22
	sm.height = 0.44
	sm.radial_segments = 6
	sm.rings = 3
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.albedo_color = c.lightened(0.2)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = 2.5 if mythic else 1.6
	m.metallic = 0.3
	m.roughness = 0.2
	mi.material_override = m
	root.add_child(mi)
	var shell := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.32, 0.32, 0.32)
	shell.mesh = bm
	shell.rotation_degrees = Vector3(45, 0, 45)
	var sm2 := StandardMaterial3D.new()
	sm2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm2.albedo_color = Color(c.r, c.g, c.b, 0.25)
	shell.material_override = sm2
	root.add_child(shell)
	root.position.y = 0.7
	return root


func _tint(n: Node, c: Color) -> void:
	var meshes: Array = n.find_children("*", "MeshInstance3D", true, false)
	if n is MeshInstance3D:
		meshes.push_front(n) # TintBand itself is the mesh
	for mi in meshes:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 0.6
		mi.material_override = m


func _process(delta: float) -> void:
	_t += delta
	if _visual:
		_visual.rotation.y += delta * 1.5
		if item is GearItem:
			_visual.position.y = 0.7 + sin(_t * 2.5) * 0.1


func can_interact() -> bool:
	return item != null


func get_prompt() -> String:
	var gear := item as GearItem
	if gear:
		return "Pick up %s  (%s %s, IP %d)   hold: equip" % [gear.display_name, gear.rarity_name(), gear.type_name(), gear.item_power]
	if _is_grenade():
		return "Swap grenade: %s" % item.display_name
	return "Pick up " + item.display_name


func interact(player: Node) -> void:
	if _is_grenade(): # MAIN_HOOKS §24c: a grenade pickup replaces the thrown grenade (never goes to the backpack)
		if (item as ConsumableItem).give_grenade(player):
			if player.has_signal("loot_received"):
				player.emit_signal("loot_received", item)
			var bus := get_node_or_null("/root/GameEvents")
			if bus and bus.has_method("emit_event"):
				bus.emit_event(&"pickup_collected", {"player": player, "item": item})
			queue_free()
		return
	if player.receive_item(item):
		queue_free()


func _is_grenade() -> bool:
	return item is ConsumableItem and (item as ConsumableItem).effect == ConsumableItem.Effect.GRENADE


## Hold E (playtest #3): gear only. Tap E still runs interact() (pick up into the backpack).
func can_hold_interact() -> bool:
	return item is GearItem


func interact_hold(player: Node) -> void:
	if item is GearItem and player.has_method("equip_from_ground") and player.equip_from_ground(item, global_position):
		queue_free()


func _on_body_entered(body: Node) -> void:
	var cons := item as ConsumableItem
	if cons and cons.auto_use and body.has_method("receive_item"):
		if body.receive_item(item):
			queue_free()
		return
	if body.has_method("set_nearby_interactable"):
		body.set_nearby_interactable(self, true)


func _on_body_exited(body: Node) -> void:
	if body.has_method("set_nearby_interactable"):
		body.set_nearby_interactable(self, false)


## Same as `rarity` (-1 = not gear).
func get_rarity() -> int:
	return rarity


func is_gear() -> bool:
	return item is GearItem


## GearDB.is_upgrade(item, player) for this pickup.
func is_upgrade_for(player) -> bool:
	return load("res://scripts/autoload/gear_db.gd").is_upgrade(item, player)
