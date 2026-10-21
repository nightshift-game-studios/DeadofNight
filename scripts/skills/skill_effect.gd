class_name SkillEffect
extends RefCounted
## Base class for one effect entry of a skill node or Field Card:
##   {"script": "<id in EffectRegistry>", "on": [events], "if": {ctx filters}, "params": {...}}
## Rank-indexed params are arrays (index = rank-1); scalars apply to every rank (see p()).
## Override what you need:
##   default_hooks()  events to subscribe to when the JSON has no "on"
##   stats()          stat names this effect answers in modify()
##   priority()       fold order for modify(): 0 = additive (default), 10 = multiplicative
##   wants(ctx)       gate before on_event (default: the JSON "if" filter, see passes(); "@<name>" keys ask
##                    SkillRunner.cond(name), e.g. {"@target_burning": true})
##   on_event(name, ctx), modify(stat, value, ctx) -> float, tick(delta), attach(), detach()

var script_id: String = ""
var params: Dictionary = {}
var rank: int = 1
var source_id: String = "" ## node or card id
var source_kind: String = "" ## "meta", "card", "armory" or "class_item"
var weapon_arch: String = "" ## armory effects: only active while a weapon of this archetype is in hand (SkillRunner gates it)
var on: Array = []
var cond: Dictionary = {}
var runner ## SkillRunner (untyped so effects can call its helpers)


func setup(def: Dictionary, r: int, src: String, kind: String) -> void:
	script_id = str(def.get("script", ""))
	params = def.get("params", {})
	on = def.get("on", [])
	cond = def.get("if", {})
	rank = maxi(r, 1)
	source_id = src
	source_kind = kind


var player:
	get:
		return runner.player if runner else null


func hooks() -> Array:
	return on if not on.is_empty() else default_hooks()


func default_hooks() -> Array:
	return []


func stats() -> Array:
	return []


func priority() -> int:
	return 0


func wants(ctx: Dictionary) -> bool:
	return passes(ctx)


func on_event(_name: StringName, _ctx: Dictionary) -> void:
	pass


func modify(_stat: String, value: float, _ctx: Dictionary) -> float:
	return value


func tick(_delta: float) -> void:
	pass


func has_tick() -> bool:
	return false


func attach() -> void:
	pass


func detach() -> void:
	pass


## Param resolved for this rank.
func p(key: String, default = null):
	if not params.has(key):
		return default
	var v = params[key]
	if typeof(v) == TYPE_ARRAY:
		if v.is_empty():
			return default
		return v[clampi(rank - 1, 0, v.size() - 1)]
	return v


## JSON "if": every key must match ctx. Array value = any of; bool compares truthiness.
func passes(ctx: Dictionary) -> bool:
	for k in cond:
		var want = cond[k]
		if str(k).begins_with("@"): # named SkillRunner condition (DESIGN §23.4): {"@target_marked": true}
			if runner == null or runner.cond(str(k).substr(1), ctx, params) != truthy(want):
				return false
			continue
		var have = ctx.get(k)
		if typeof(want) == TYPE_ARRAY:
			if not (have in want):
				return false
		elif typeof(want) == TYPE_BOOL:
			if truthy(have) != want:
				return false
		elif str(have) != str(want):
			return false
	return true


func now() -> float:
	return runner.now() if runner else 0.0


static func truthy(v) -> bool:
	match typeof(v):
		TYPE_NIL:
			return false
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING, TYPE_STRING_NAME:
			return str(v) != ""
		TYPE_OBJECT:
			return is_instance_valid(v)
	return true
