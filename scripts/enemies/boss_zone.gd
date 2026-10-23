extends Node3D
## Lingering boss hazard zone (Skillz, boss rework 2026-10-22). Arming telegraph -> active hazard -> fade.
##   ARM  (`arm` s): outline + fill growing to the full disc = "this will hurt"; harmless.
##   LIVE (`life` s): pulses solid; every `tick_every` s every living player inside takes `tick_dmg`.
##   `burst_dmg` is dealt once to everyone inside the moment it goes live (life 0 = a pure delayed blast, e.g. Lantern bombs).
## Damage is host-authoritative: a co-op client's copy is `damage_enabled = false` (visual only), built from the boss
## event stream (BossBase.net_boss_state). Never use class_name here (preloaded by BossKit before the class cache refreshes).

const FLASH := 0.35

var host: Node = null
var kind: String = "zone"
var radius: float = 2.4
var arm: float = 1.1
var life: float = 5.5
var tick_dmg: int = 0
var tick_every: float = 0.5
var burst_dmg: int = 0
var color: Color = Color(1.0, 0.45, 0.1, 0.5)
var damage_enabled: bool = true
var _t: float = 0.0
var _tick: float = 0.0
var _live: bool = false
var _outline: MeshInstance3D
var _fill: MeshInstance3D
var _fill_mat: StandardMaterial3D
var _out_mat: StandardMaterial3D
var hits: int = 0 ## damage events delivered (tests)


static func spawn(parent: Node, boss: Node, pos: Vector3, rad: float, arm_s: float, life_s: float, tick: int, tick_s: float, burst: int, col: Color, dmg_on: bool, zone_kind: String = "zone") -> Node3D:
	var z: Node3D = (load("res://scripts/enemies/boss_zone.gd") as GDScript).new()
	z.host = boss
	z.kind = zone_kind
	z.radius = rad
	z.arm = maxf(arm_s, 0.05)
	z.life = life_s
	z.tick_dmg = tick
	z.tick_every = maxf(tick_s, 0.1)
	z.burst_dmg = burst
	z.color = col
	z.damage_enabled = dmg_on
	parent.add_child(z)
	z.global_position = Vector3(pos.x, pos.y + 0.04, pos.z)
	return z


func _ready() -> void:
	add_to_group("boss_zone")
	var Tg = load("res://scripts/enemies/boss_telegraph.gd")
	_out_mat = _mat(Color(color.r, color.g, color.b, color.a * 0.45))
	_fill_mat = _mat(color)
	_outline = MeshInstance3D.new()
	_outline.mesh = Tg._flat_mesh(0.0, radius, 0.0, TAU, 28)
	_outline.material_override = _out_mat
	add_child(_outline)
	_fill = MeshInstance3D.new()
	_fill.mesh = Tg._flat_mesh(0.0, radius, 0.0, TAU, 28)
	_fill.material_override = _fill_mat
	_fill.position.y = 0.01
	_fill.scale = Vector3(0.001, 1.0, 0.001)
	add_child(_fill)


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func is_live() -> bool:
	return _live


## Seconds until it hurts (0 once live); < 0 when expired.
func eta() -> float:
	return maxf(arm - _t, 0.0) if _t < arm + life + FLASH else -1.0


## Threat shape for the sim bot / tests (same format as BossBase.threat_shapes()).
func shape() -> Dictionary:
	return {"id": kind, "kind": "circle", "c": global_position, "r": radius, "eta": eta(), "dmg": tick_dmg, "zone": true, "live": _live}


func _physics_process(delta: float) -> void:
	_t += delta
	if _t < arm:
		var p := _t / arm
		_fill.scale = Vector3(maxf(p, 0.001), 1.0, maxf(p, 0.001))
		_out_mat.albedo_color.a = color.a * (0.35 + 0.4 * p)
		return
	if not _live:
		_live = true
		_tick = 0.0
		_fill.scale = Vector3.ONE
		_apply(burst_dmg)
	var end := arm + life
	if _t >= end + FLASH:
		queue_free()
		return
	var a := color.a
	if _t < end:
		a = minf(color.a * (1.25 + 0.25 * sin(_t * 9.0)), 0.95)
		_tick += delta
		while _tick >= tick_every:
			_tick -= tick_every
			_apply(tick_dmg)
	else:
		a = color.a * (1.0 - (_t - end) / FLASH)
	_fill_mat.albedo_color.a = a
	_out_mat.albedo_color.a = a * 0.6
	if host != null and is_instance_valid(host) and bool(host.get("_dead")) and _t < end:
		life = maxf(_t - arm, 0.0) # boss died: the zone fades at once


func _apply(dmg: int) -> void:
	if dmg <= 0 or not damage_enabled:
		return
	var Kit = load("res://scripts/enemies/boss_kit.gd")
	var src: Node = host if host != null and is_instance_valid(host) else null
	for p in Kit.players(self):
		if Kit.in_circle(global_position, radius, (p as Node3D).global_position):
			p.call("take_damage", dmg, src)
			hits += 1
