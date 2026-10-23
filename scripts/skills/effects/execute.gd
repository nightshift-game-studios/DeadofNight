extends SkillEffect
## Execute: a gun hit that leaves a non-boss zombie under `threshold` of its max health finishes it (the kill counts
## as a normal skill kill). params: threshold, icd (s), sources (default ["gun"]). Bosses and elites are immune.


var _ready_at: float = -INF
var executed: int = 0


func default_hooks() -> Array:
	return ["hit"]


func wants(ctx: Dictionary) -> bool:
	return passes(ctx) and str(ctx.get("source", "gun")) in params.get("sources", ["gun"])


func on_event(_name: StringName, ctx: Dictionary) -> void:
	var t = ctx.get("target")
	if t == null or not is_instance_valid(t) or not ("health" in t) or now() < _ready_at:
		return
	if "_dead" in t and t._dead:
		return
	if runner.cond("target_boss", ctx, params):
		return
	if float(t.health) <= 0.0 or float(t.health) / maxf(float(t.max_health), 1.0) >= float(p("threshold", 0.2)):
		return
	_ready_at = now() + float(p("icd", 0.0))
	executed += 1
	runner.deal(t, float(t.health) + 1.0, "execute", ctx)
