extends Node
## Autoload "GameEvents": the skill signal bus.
## Everything gameplay-relevant is emitted as event(name, ctx). Skill effects (scripts/skills/effects/*)
## subscribe through the player's SkillRunner. A few typed signals are mirrored for UI convenience.
## Event names and ctx keys: see /workspace/skillz/GOOEY_HANDOFF.md ("Events").

signal event(name: StringName, ctx: Dictionary)
signal round_started(round_number: int)
signal round_cleared(round_number: int)
signal match_ended(round_number: int, kills: int)

var record: bool = false ## tests: keep a history of emitted events
var history: Array = [] ## [[name, ctx], ...] while record is on


## Emits `name` with `ctx` (ctx gets "event" = name) and returns ctx, so emitters can read back
## anything effects wrote into it (e.g. damage_incoming.amount, lethal_damage.prevent).
func emit_event(name: StringName, ctx: Dictionary = {}) -> Dictionary:
	ctx["event"] = name
	if record:
		history.append([name, ctx])
	event.emit(name, ctx)
	match name:
		&"round_started":
			round_started.emit(int(ctx.get("round", 0)))
		&"round_cleared":
			round_cleared.emit(int(ctx.get("round", 0)))
		&"match_ended":
			match_ended.emit(int(ctx.get("round", 0)), int(ctx.get("kills", 0)))
	return ctx


func events_named(name: StringName) -> Array:
	return history.filter(func(h): return h[0] == name).map(func(h): return h[1])
