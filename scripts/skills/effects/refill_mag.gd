extends SkillEffect
## Ammo on an event. params.mode:
##  "amount"        +amount rounds into the magazine from nothing (capped at mag size)
##  "fraction"      moves ceil(mag * fraction) rounds from reserve into the magazine
##  "finish_reload" completes a reload in progress instantly
##  "full"          fills the magazine from reserve (cancels a reload)
## params: icd (cooldown seconds), per_weapon (cooldown per weapon instance).

var _ready_at: Dictionary = {} ## key -> runner time


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var w = ctx.get("weapon") if ctx.get("weapon") is WeaponItem else player.current_weapon()
	if w == null:
		return
	var key = w.get_instance_id() if params.get("per_weapon", false) else 0
	if now() < float(_ready_at.get(key, -INF)):
		return
	var mag: int = w.mag_size()
	var did := false
	match str(params.get("mode", "amount")):
		"amount":
			if w.ammo < mag:
				w.ammo = mini(w.ammo + int(p("amount", 1)), mag)
				did = true
		"fraction":
			var take: int = mini(mini(int(ceil(mag * float(p("fraction", 0.2)))), mag - w.ammo), w.reserve)
			if take > 0:
				w.ammo += take
				w.reserve -= take
				did = true
		"finish_reload":
			did = player.finish_reload_now()
		"full":
			var take2: int = mini(mag - w.ammo, w.reserve)
			if take2 > 0:
				player.cancel_reload_for_skill()
				w.ammo += take2
				w.reserve -= take2
				did = true
	if did:
		_ready_at[key] = now() + float(p("icd", 0.0))
		player.emit_ammo()
