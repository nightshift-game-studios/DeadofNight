extends SkillEffect
## Time-scale skills. Real slow-mo only when ProjectSettings "skills/allow_time_scale" is true
## (RunState.time_scale_allowed()); the default fallback slows zombies around you instead (status
## "slow", same duration), so it stays co-op safe.
## params.mode:
##  "trigger"        on damage_taken below health_below: dur seconds of time_scale (or slow aura,
##                   radius/slow), plus dr damage reduction for the same window; icd cooldown.
##  "while_airborne" while airborne: time_scale, or (fallback) a slow aura of radius/slow plus fallback_dr
##                   damage reduction while airborne.

var _ready_at: float = -INF
var _active_until: float = -INF
var _aura_t: float = 0.0
var _scaling: bool = false


func default_hooks() -> Array:
	return ["damage_taken"] if str(params.get("mode", "trigger")) == "trigger" else []


func wants(_ctx: Dictionary) -> bool:
	return true


func stats() -> Array:
	return ["damage_in"] if params.has("dr") or params.has("fallback_dr") else []


func priority() -> int:
	return 10


func has_tick() -> bool:
	return true


func is_active() -> bool:
	if str(params.get("mode", "trigger")) == "while_airborne":
		return player != null and player.is_airborne()
	return now() < _active_until


func _rs() -> Node:
	return runner.get_node_or_null("/root/RunState")


func on_event(_name: StringName, ctx: Dictionary) -> void:
	if player.dead or float(ctx.get("health_frac", 1.0)) >= float(p("health_below", 0.3)) or now() < _ready_at:
		return
	_ready_at = now() + float(p("icd", 45.0))
	var dur := float(p("dur", 2.5))
	_active_until = now() + dur
	var rs := _rs()
	if rs and rs.time_scale_allowed():
		rs.request_time_scale(source_id, float(p("time_scale", 0.5)), dur)
	else:
		_slow_aura(dur)


func modify(_stat: String, value: float, _ctx: Dictionary) -> float:
	if str(params.get("mode", "trigger")) == "while_airborne":
		var rs := _rs()
		var fallback: bool = rs == null or not rs.time_scale_allowed()
		return value * (1.0 - float(p("fallback_dr", 0.0))) if fallback and is_active() else value
	return value * (1.0 - float(p("dr", 0.0))) if now() < _active_until else value


func tick(delta: float) -> void:
	var rs := _rs()
	var allowed: bool = rs != null and rs.time_scale_allowed()
	if str(params.get("mode", "trigger")) == "while_airborne":
		var air: bool = player != null and player.is_airborne() and not player.dead
		if allowed and air and not _scaling:
			rs.request_time_scale(source_id, float(p("time_scale", 0.75)))
			_scaling = true
		elif _scaling and (not air or not allowed):
			rs.release_time_scale(source_id)
			_scaling = false
		if air and not allowed:
			_aura_t -= delta
			if _aura_t <= 0.0:
				_aura_t = 0.2
				_slow_aura(0.3)
	elif now() < _active_until and not allowed:
		_aura_t -= delta
		if _aura_t <= 0.0:
			_aura_t = 0.25
			_slow_aura(minf(0.35, _active_until - now()))


func _slow_aura(dur: float) -> void:
	if player == null:
		return
	for e in runner.enemies_near(player.global_position, float(p("radius", 10.0))):
		if e.has_method("apply_status"):
			e.apply_status("slow", {"dur": dur, "amp": float(p("slow", 0.5))})


func detach() -> void:
	var rs := _rs()
	if rs and _scaling:
		rs.release_time_scale(source_id)
	_scaling = false
