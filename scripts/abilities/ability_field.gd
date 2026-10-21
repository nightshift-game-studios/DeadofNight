class_name AbilityField
extends Node3D
## A placed ability object (DESIGN §23.2): Rally Banner, Headstone, Vigil Candle, and the invisible watchers behind Chalk
## Mark / Ember Brand. Lives in the match scene for `life` seconds, pulses every `pulse_every` seconds over the zombies
## within `radius`, then frees itself. Subclasses override _pulse() (and optionally _on_game_event()).
## Damage goes through the owner's damage_out (source "ability") and SkillRunner.deal(), so kills raise the normal
## hit / enemy_killed events (source "ability") that skill nodes, cards and class items can hook.

const GROUP := "ability_fields"

var player: Node ## the owner
var ability_id: String = ""
var life: float = 8.0
var radius: float = 5.0
var pulse_every: float = 0.5
var pulses: int = 0 ## tests / debugging
var _acc: float = 0.0
var _listen: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	set_meta("ability_id", ability_id)
	if _listen:
		var bus := get_node_or_null("/root/GameEvents")
		if bus and not bus.event.is_connected(_on_bus):
			bus.event.connect(_on_bus)


## Spawns `f` at `pos` in the player's current scene (or under the player when there is none). Returns it.
static func place(f: AbilityField, owner_player: Node, pos: Vector3) -> AbilityField:
	f.player = owner_player
	var scene: Node = owner_player.get_tree().current_scene if owner_player and owner_player.is_inside_tree() else null
	var parent: Node = scene if scene else owner_player
	parent.add_child(f)
	f.global_position = pos
	return f


## Every live field of `ability_id` owned by `owner_player` (oldest first).
static func live(owner_player: Node, id: String) -> Array:
	if owner_player == null or not owner_player.is_inside_tree():
		return []
	return owner_player.get_tree().get_nodes_in_group(GROUP).filter(
		func(n): return is_instance_valid(n) and n.player == owner_player and n.ability_id == id and not n.is_queued_for_deletion())


func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		queue_free()
		return
	life -= delta
	_acc += delta
	while _acc >= pulse_every and life > -pulse_every:
		_acc -= pulse_every
		pulses += 1
		_pulse()
	if life <= 0.0:
		queue_free()


func _pulse() -> void:
	pass


func _on_game_event(_name: StringName, _ctx: Dictionary) -> void:
	pass


func _on_bus(name: StringName, ctx: Dictionary) -> void:
	if ctx.has("player") and ctx.player != player:
		return
	_on_game_event(name, ctx)


func enemies() -> Array:
	return AbilityField.enemies_around(player, global_position + Vector3(0, 0.9, 0), radius)


static func enemies_around(owner_player: Node, pos: Vector3, r: float) -> Array:
	if owner_player == null or not owner_player.is_inside_tree():
		return []
	var runner = owner_player.get("skill_runner")
	if runner:
		return runner.enemies_near(pos, r)
	return owner_player.get_tree().get_nodes_in_group("enemies").filter(
		func(e): return is_instance_valid(e) and (e.global_position + Vector3(0, 0.9, 0)).distance_to(pos) <= r)


## Ability damage to one zombie (damage_out with source "ability", then SkillRunner.deal). Returns true on a kill.
static func hurt(owner_player: Node, e: Node, base: float, id: String) -> bool:
	if owner_player == null or e == null or not is_instance_valid(e):
		return false
	var ctx := {"source": "ability", "target": e, "ability": id, "player": owner_player}
	var dmg: float = owner_player.mod_stat("damage_out", base, ctx) if owner_player.has_method("mod_stat") else base
	var runner = owner_player.get("skill_runner")
	if runner:
		return runner.deal(e, dmg, "ability", {"depth": -1}, {"ability": id}) # depth 0: a primary hit, like a gun hit
	return e.take_damage(dmg, e.global_position, false, owner_player)


static func status(e: Node, id: String, dur: float, amp := 0.0, dps := 0.0, src: Node = null) -> void:
	if e and is_instance_valid(e) and e.has_method("apply_status"):
		e.apply_status(id, {"dur": dur, "amp": amp, "dps": dps, "source": src})


## A plain glowing post (placeholder art until Desi's models: banner pole / headstone / candle).
func build_post(color: Color, height: float, width: float, light_range: float) -> void:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = Vector3(width, height, width)
	mi.mesh = m
	mi.position.y = height * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color.darkened(0.4)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.2
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = color
	l.omni_range = light_range
	l.light_energy = 1.2
	l.position.y = height
	add_child(l)
