extends SkillEffect
## Every `every`th shot puts its round back and deals +bonus gun damage.

var count: int = 0
var phantom: bool = false


func default_hooks() -> Array:
	return ["shot_fired"]


func stats() -> Array:
	return ["damage_out"]


func priority() -> int:
	return 10


func on_event(_name: StringName, ctx: Dictionary) -> void:
	count += 1
	phantom = count % maxi(int(p("every", 6)), 1) == 0
	var w = ctx.get("weapon")
	if phantom and w is WeaponItem:
		w.ammo = mini(w.ammo + 1, w.mag_size())


func modify(_stat: String, value: float, ctx: Dictionary) -> float:
	if phantom and str(ctx.get("source", "gun")) == "gun":
		return value * (1.0 + float(p("bonus", 1.0)))
	return value
