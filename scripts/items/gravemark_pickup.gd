extends Node3D
## Gravemark world token (Skillz art pass 2): Desi's gravemark.glb (data/armory.json -> currency.pickup_model) pops out
## where a Gravemark dropped (zombie / boss / chest), spins for a moment, then flies into the player and is gone.
## Cosmetic: the currency is already paid by Armory.award() (no pickup to miss, economy unchanged), so this is safe
## to skip anywhere (tests, no scene). Armory.on_zombie_died / chest.gd call spawn().

const FALLBACK_MODEL := "res://assets/models/pickups/gravemark.glb"
const HOLD_TIME := 0.55
const FLY_TIME := 0.35
const SPIN := 5.0 # rad/s
const MODEL_SCALE := 2.2 ## Desi's coin is a real 9 cm; x2.2 so it reads at a few metres

var amount: int = 1
var model_path: String = ""
var model: Node3D
var _t: float = 0.0
var _start: Vector3


## Spawns a token at `pos` under `parent` (the current scene). Returns it, or null when there's nowhere to put it.
static func spawn(parent: Node, pos: Vector3, amount_paid: int = 1, path: String = "") -> Node3D:
	if parent == null or not parent.is_inside_tree() or amount_paid <= 0:
		return null
	var s = load("res://scripts/items/gravemark_pickup.gd")
	var g: Node3D = s.new()
	g.name = "GravemarkPickup"
	g.set("amount", amount_paid)
	g.set("model_path", path)
	parent.add_child(g)
	g.global_position = pos + Vector3(0, 0.9, 0)
	return g


static func pickup_model_path() -> String:
	var A = load("res://scripts/armory/armory.gd")
	var p := str(A.cfg().get("currency", {}).get("pickup_model", "")) if A else ""
	return p if p != "" else FALLBACK_MODEL


func _ready() -> void:
	var p := model_path if model_path != "" else pickup_model_path()
	if ResourceLoader.exists(p):
		model = (load(p) as PackedScene).instantiate() as Node3D
	else:
		model = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.06
		cm.bottom_radius = 0.06
		cm.height = 0.015
		(model as MeshInstance3D).mesh = cm
	model.name = "Model"
	add_child(model)
	model.rotation_degrees.x = 90.0 # coin stands up, face toward the player while it spins on Y
	model.scale = Vector3.ONE * MODEL_SCALE
	var glow := OmniLight3D.new()
	glow.name = "Glow"
	glow.light_color = Color(1.0, 0.55, 0.25)
	glow.light_energy = 0.8
	glow.omni_range = 1.6
	add_child(glow)
	for gi in find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_start = global_position


func _process(delta: float) -> void:
	_t += delta
	rotation.y += SPIN * delta
	if _t < HOLD_TIME:
		global_position = _start + Vector3(0, 0.25 * sin(_t / HOLD_TIME * PI * 0.5), 0)
		return
	var pl := get_tree().get_first_node_in_group("player") as Node3D
	var k := clampf((_t - HOLD_TIME) / FLY_TIME, 0.0, 1.0)
	if pl:
		var a := _start + Vector3(0, 0.25, 0)
		global_position = a.lerp(pl.global_position + Vector3(0, 1.2, 0), k * k)
		scale = Vector3.ONE * lerpf(1.0, 0.4, k)
	if k >= 1.0 or _t > 3.0:
		queue_free()
