class_name RunStatsTracker
extends Node
## Gooey: per-match stat tally for the game-over stats page (playtest #8).
## Listens to the GameEvents skill bus only (no gameplay code touched), filtered to the local player.
## Every number here comes from an event the game already emits:
##   shot_fired / shot_missed (hitscan rounds; projectiles excluded) -> accuracy
##   hit (damage, is_headshot, source) -> damage dealt, headshots
##   enemy_killed -> kills (fallback; match_ended "kills" from main.gd wins), melee/boss kills
##   points_gained -> points earned, damage_taken -> damage taken, healed, grenade_thrown, card_picked, door_opened
##   round_started / match_ended -> rounds, time survived. Gravemarks / XP come from Progress.
## Untracked (needs hooks, see G4M3N_HOOKS.md): co-op downs / revives (Net), points spent on chests/doors/merchant.

signal finished(stats: Dictionary)

var player: Node ## local player; events from other players (co-op avatars) are ignored once set
var started: bool = false
var ended: bool = false
var time_s: float = 0.0
var s: Dictionary = {}
var _xp_start: int = -1
var _last_hp: int = -1 ## player's HP after the last damage / heal (caps the killing blow)


func _sync_hp() -> void:
	if player != null and is_instance_valid(player) and player.get("health") != null:
		_last_hp = int(player.get("health"))


func _init() -> void:
	reset()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE # pauses / Field Card choosers don't count toward time survived
	var ge := get_node_or_null("/root/GameEvents")
	if ge and not ge.event.is_connected(on_event):
		ge.event.connect(on_event)
	var prog := get_node_or_null("/root/Progress")
	if prog:
		_xp_start = int(prog.get("xp"))


func reset() -> void:
	started = false
	ended = false
	time_s = 0.0
	s = {"kills": 0, "damage_dealt": 0.0, "headshots": 0, "hits": 0, "shots_fired": 0, "shots_missed": 0,
		"rounds": 0, "points_earned": 0, "damage_taken": 0, "healed": 0, "grenades": 0, "melee_kills": 0,
		"boss_kills": 0, "precision_kills": 0, "cards_picked": 0, "doors_opened": 0}


func _process(delta: float) -> void:
	if started and not ended:
		time_s += delta
	_sync_hp() # regen doesn't emit "healed", so the HP baseline is refreshed every frame


func _mine(ctx: Dictionary) -> bool:
	if player == null or not is_instance_valid(player):
		return true
	var p = ctx.get("player")
	return p == null or p == player


func on_event(name: StringName, ctx: Dictionary) -> void:
	if ended:
		return
	match name:
		&"round_started":
			started = true
			_sync_hp()
			s.rounds = maxi(int(s.rounds), int(ctx.get("round", 0)))
		&"shot_fired":
			if _mine(ctx):
				var w = ctx.get("weapon")
				if w == null or not (w.has_method("is_projectile") and w.is_projectile()):
					s.shots_fired += 1
		&"shot_missed":
			if _mine(ctx):
				s.shots_missed += 1
		&"hit":
			if _mine(ctx):
				s.damage_dealt += maxf(float(ctx.get("damage", 0.0)), 0.0)
				s.hits += 1
				if bool(ctx.get("is_headshot", false)) and str(ctx.get("source", "gun")) == "gun":
					s.headshots += 1
		&"enemy_killed":
			if _mine(ctx):
				s.kills += 1
				if str(ctx.get("source", "")) == "melee":
					s.melee_kills += 1
				if bool(ctx.get("is_headshot", false)):
					s.precision_kills += 1
				var t = ctx.get("target")
				if t is Node and is_instance_valid(t) and t.has_meta("is_boss") and t.get_meta("is_boss"):
					s.boss_kills += 1
		&"points_gained":
			if _mine(ctx):
				s.points_earned += maxi(int(ctx.get("amount", 0)), 0)
		&"damage_taken":
			if _mine(ctx):
				# health actually lost: a 1,000,000 killing blow counts as the HP that was left
				var dealt := maxi(int(ctx.get("dealt", 0)), 0)
				if _last_hp >= 0:
					dealt = mini(dealt, _last_hp)
				s.damage_taken += dealt
				_sync_hp()
		&"healed":
			if _mine(ctx):
				s.healed += maxi(int(ctx.get("amount", 0)), 0)
				_sync_hp()
		&"grenade_thrown":
			if _mine(ctx):
				s.grenades += 1
		&"card_picked":
			s.cards_picked += 1
		&"door_opened":
			if _mine(ctx):
				s.doors_opened += 1
		&"match_ended":
			if ctx.has("kills"):
				s.kills = int(ctx.kills) # main.gd's count is the authority (includes kills the bus missed)
			s.rounds = maxi(int(s.rounds), int(ctx.get("round", 0)))
			ended = true
			# Progress.record_match runs right after match_ended in the same frame: read Gravemarks / XP after it
			_finish.call_deferred()


## Accuracy over hitscan rounds fired (a shotgun round with any pellet on target counts as a hit). -1 = no shots.
static func accuracy_of(st: Dictionary) -> float:
	var fired := int(st.get("shots_fired", 0))
	if fired <= 0:
		return -1.0
	return clampf(float(fired - int(st.get("shots_missed", 0))) / float(fired), 0.0, 1.0)


func _finish() -> void:
	finished.emit(snapshot())


## Current tally plus Progress-side numbers (Gravemarks this match, XP earned, level, bests).
func snapshot() -> Dictionary:
	var out := s.duplicate()
	out["time_s"] = time_s
	out["accuracy"] = accuracy_of(s)
	var prog := get_node_or_null("/root/Progress")
	if prog:
		out["gravemarks"] = int(prog.get("last_match_gravemarks")) if ended else int(prog.get("match_gravemarks"))
		out["xp_earned"] = maxi(int(prog.get("xp")) - _xp_start, 0) if _xp_start >= 0 else 0
		out["best_round"] = int(prog.get("best_round"))
		out["level"] = int(prog.call("get_level")) if prog.has_method("get_level") else 0
	if player and is_instance_valid(player) and player.get("points") != null:
		out["points_end"] = int(player.get("points"))
	return out


static func format_time(t: float) -> String:
	var n := int(t)
	return "%d:%02d" % [n / 60, n % 60] if n < 3600 else "%d:%02d:%02d" % [n / 3600, (n / 60) % 60, n % 60]
