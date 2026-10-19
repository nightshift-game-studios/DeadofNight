extends "res://scripts/enemy.gd"
## Riot (zombies.json "riot"): medium speed, heavy armour. Hits from inside the frontal `cone_deg` cone (attacker /
## blast position vs the zombie's facing) lose `reduction` (80%) of their damage, front helmet / visor headshots
## included. The armour has its own HP (`armor_frac` x max_health): every absorbed point comes off it, and when it
## breaks it plays Zombie_ArmorBreak, hides ArmorVest / Helmet / Visor and the reduction is gone. Back and side hits
## do full damage. Explosives and burn ticks ignore `pierce_explosive` / `pierce_burn` (half) of the reduction (burn
## isn't directional: it always meets half armour until the break). Hits below `leg_height` wear `leg_frac` of
## the armour HP off the legs separately and hide ArmorLegs when that's gone (cosmetic).
## Future armour-pierce skills: the attacker's mod_stat("armor_pierce", 0) (0..1) is subtracted from the reduction.

const VC := preload("res://scripts/enemies/variants/variant_common.gd")

signal armor_broken(riot: Node)

var b: Dictionary = {}
var armor_max: float = 0.0
var armor_hp: float = 0.0
var leg_hp: float = 0.0
var armor_intact: bool = true
var legs_intact: bool = true
var last_hit: Dictionary = {} ## {kind, frontal, reduction, absorbed, dealt}


func _ready() -> void:
	b = VC.behavior(self)
	VC.hook_bus(get_tree())
	super._ready()
	armor_max = float(max_health) * VC.num(b, "armor_frac", 0.75)
	armor_hp = armor_max
	leg_hp = armor_max * VC.num(b, "leg_frac", 0.25)


## True if `to_attacker` (from the zombie to whoever / whatever hit it) is inside the frontal cone around `forward`.
## Flat (XZ) test; a zero vector counts as frontal (point-blank / overhead).
static func is_frontal(forward: Vector3, to_attacker: Vector3, cone_deg: float) -> bool:
	var f := Vector2(forward.x, forward.z)
	var t := Vector2(to_attacker.x, to_attacker.z)
	if f.length() < 0.0001 or t.length() < 0.0001:
		return true
	return f.normalized().dot(t.normalized()) >= cos(deg_to_rad(cone_deg * 0.5)) - 0.000001


## Armour reduction (0..1) for a hit of this kind from this side, before the armour-HP cap.
static func reduction_for(kind: String, frontal: bool, beh: Dictionary, pierce: float = 0.0) -> float:
	var r := float(beh.get("reduction", 0.8))
	if kind == "burn":
		return maxf(r * (1.0 - float(beh.get("pierce_burn", 0.5))) - pierce, 0.0)
	if not frontal:
		return 0.0
	if kind == "explosive":
		r *= 1.0 - float(beh.get("pierce_explosive", 0.5))
	return clampf(r - pierce, 0.0, 1.0)


func forward() -> Vector3:
	return -global_transform.basis.z


func _attacker_pos(hit_pos: Vector3, source: Node) -> Vector3:
	if not Explosion.current.is_empty() and Explosion.current.get("pos") is Vector3:
		return Explosion.current.pos
	if source is Node3D and is_instance_valid(source):
		return (source as Node3D).global_position
	return hit_pos if hit_pos != Vector3.ZERO else global_position + forward()


func take_damage(amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, source: Node = null) -> bool:
	if _dead:
		return false
	var kind := VC.hit_kind(self, source)
	var frontal := is_frontal(forward(), _attacker_pos(hit_pos, source) - global_position, VC.num(b, "cone_deg", 100.0))
	var absorbed := 0.0
	var r := 0.0
	if armor_intact:
		var pierce := 0.0
		if source and source.has_method("mod_stat"):
			pierce = clampf(float(source.mod_stat("armor_pierce", 0.0, {"source": kind, "target": self})), 0.0, 1.0)
		r = reduction_for(kind, frontal, b, pierce)
		absorbed = minf(amount * r, armor_hp)
		armor_hp -= absorbed
		if armor_hp <= 0.001:
			break_armor()
	if legs_intact and hit_pos != Vector3.ZERO and kind != "burn" and hit_pos.y - global_position.y < VC.num(b, "leg_height", 0.6):
		leg_hp -= amount
		if leg_hp <= 0.0:
			break_legs()
	var dealt := amount - absorbed
	last_hit = {"kind": kind, "frontal": frontal, "reduction": r, "absorbed": absorbed, "dealt": dealt}
	return super.take_damage(dealt, hit_pos, crit, source)


func break_armor() -> void:
	if not armor_intact:
		return
	armor_intact = false
	armor_hp = 0.0
	for n in b.get("armor_nodes", ["ArmorVest", "Helmet", "Visor", "ArmorFront"]):
		var nd := VC.node(self, str(n))
		if nd:
			nd.visible = false
	if is_inside_tree() and get_parent():
		var af := VC.node(self, "ArmorFront")
		Explosion.spawn_vfx(get_parent(), af.global_position if af else global_position + Vector3(0, 1.2, 0), 0.4, Color(0.6, 0.65, 0.7))
	if not _dead:
		var l := VC.play_clip(self, "armor_break", str(b.get("break_clip", "Zombie_ArmorBreak")), 0.05)
		_attack_anim_t = maxf(_attack_anim_t, minf(l, 1.2))
	armor_broken.emit(self)


func break_legs() -> void:
	if not legs_intact:
		return
	legs_intact = false
	var nd := VC.node(self, "ArmorLegs")
	if nd:
		nd.visible = false
