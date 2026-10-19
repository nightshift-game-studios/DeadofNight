extends RefCounted
## Player movement statuses applied by zombie variants (Skillz, art pass 3). No class_name: preload it.
## State lives in player metadata, so player.gd needs no new vars; it reads it through two MAIN_HOOKS §15b lines:
##   speed *= PlayerStatusScr.move_mult(self)      (walk / sprint / crouch speed; 0 while rooted)
##   PlayerStatusScr.pin(self)                     (just before move_and_slide: rooted = no horizontal velocity,
##                                                  so slides / momentum stop too; jumping still works)
## Without §15b the statuses are still tracked (tests, HUD) but don't change movement.
##   root(player, dur, source)   Crawler ankle grab (refresh every frame while held; release(player, source) ends it)
##   slow(player, amp, dur, src) Bloater bile puddle (strongest active amp wins)

const META := "skillz_player_status"


static func now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _st(p: Object) -> Dictionary:
	if p == null or not is_instance_valid(p):
		return {}
	if not p.has_meta(META):
		p.set_meta(META, {"roots": {}, "slows": {}})
	return p.get_meta(META)


static func root(p: Object, dur: float, source: Object = null) -> void:
	var st := _st(p)
	if st.is_empty():
		return
	var key := source.get_instance_id() if source else 0
	st.roots[key] = maxf(float(st.roots.get(key, 0.0)), now() + dur)


static func release(p: Object, source: Object = null) -> void:
	var st := _st(p)
	if not st.is_empty():
		st.roots.erase(source.get_instance_id() if source else 0)


static func is_rooted(p: Object) -> bool:
	var st := _st(p)
	if st.is_empty():
		return false
	var t := now()
	for k in st.roots.keys():
		if float(st.roots[k]) <= t:
			st.roots.erase(k)
	return not st.roots.is_empty()


## One slow per source (re-applying refreshes it); the strongest active one wins.
static func slow(p: Object, amp: float, dur: float, source: Object = null) -> void:
	var st := _st(p)
	if not st.is_empty():
		st.slows[source.get_instance_id() if source else 0] = {"amp": clampf(amp, 0.0, 0.95), "until": now() + dur}


static func slow_amp(p: Object) -> float:
	var st := _st(p)
	if st.is_empty():
		return 0.0
	var t := now()
	var best := 0.0
	for k in st.slows.keys():
		var e: Dictionary = st.slows[k]
		if float(e.until) <= t:
			st.slows.erase(k)
		else:
			best = maxf(best, float(e.amp))
	return best


## Multiplier for the player's ground speed: 0 while rooted, 1 - strongest slow otherwise.
static func move_mult(p: Object) -> float:
	if is_rooted(p):
		return 0.0
	return 1.0 - slow_amp(p)


## Rooted: zero the horizontal velocity (call right before move_and_slide). Returns true if it pinned.
static func pin(p: Object) -> bool:
	if not is_rooted(p) or not (p is CharacterBody3D):
		return false
	var b := p as CharacterBody3D
	b.velocity.x = 0.0
	b.velocity.z = 0.0
	return true


static func clear(p: Object) -> void:
	if p and is_instance_valid(p) and p.has_meta(META):
		p.remove_meta(META)
