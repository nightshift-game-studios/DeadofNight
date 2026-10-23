class_name MatchStats
extends RefCounted
## Per-match stats for Gooey's death-screen stats page (Skillz, Economy v2; /workspace/skillz/STATS_API.md "Match stats").
## Fed by the GameEvents bus (hit / enemy_killed / damage_taken / points_gained / shot_fired / shot_missed / healed /
## grenade_thrown / card_picked / door_opened / round_* / match_ended), the local
## Player's points_changed / died signals and Progress' gravemark_gained / scrap_gained. No main.gd edit needed:
## Progress.begin_match_gravemarks() (main.gd _ready) calls begin_deferred(); MAIN_HOOKS §21a may call begin(main).
##   MatchStats.summary() -> {kills, headshots, headshot_kills, hits, damage_dealt, damage_taken, rounds, round_reached,
##        points_earned, points_spent, points_by_reason, gravemarks, scrap, xp, time_s, time_text, cause_of_death,
##        boss_kills, kills_by_source, shots_fired, shots_missed, shots_hit, accuracy (0..1, hitscan), healed,
##        grenades_thrown, cards_picked, doors_opened, melee_kills, precision_kills, active, ended}
##   Co-op downs / revives are not tracked (no bus event yet; Netz).
##   MatchStats.begin(main = null) / end() / reset() / on_match_recorded(xp)

const GAME_EVENTS := "/root/GameEvents"
const PROGRESS := "/root/Progress"
const CAUSE_WINDOW_S := 6.0 ## damage older than this before death is not the cause

static var _s: Dictionary = {}
static var _player: WeakRef = null
static var _last_points: int = 0
static var _t0_ms: int = 0
static var _t1_ms: int = -1
static var _last_hit: Dictionary = {} ## {name, kind, id, at_ms}
static var _hooked: bool = false


static func _root() -> Node:
	var ml := Engine.get_main_loop()
	return (ml as SceneTree).root if ml is SceneTree else null


static func reset() -> void:
	_s = {"kills": 0, "headshots": 0, "headshot_kills": 0, "hits": 0, "damage_dealt": 0.0, "damage_taken": 0,
		"rounds": 0, "round_reached": 0, "points_earned": 0, "points_spent": 0, "points_by_reason": {},
		"gravemarks": 0, "scrap": 0, "xp": 0, "boss_kills": 0, "kills_by_source": {}, "cause_of_death": {},
		"shots_fired": 0, "shots_missed": 0, "healed": 0, "grenades_thrown": 0, "cards_picked": 0, "doors_opened": 0,
		"melee_kills": 0, "active": false, "ended": false}
	_t0_ms = Time.get_ticks_msec()
	_t1_ms = -1
	_last_hit = {}


## Starts a fresh match. main = the match scene (its "player" / Player child is the local player); null = current scene.
static func begin(main: Node = null) -> void:
	reset()
	_s.active = true
	_hook_buses()
	var r := _root()
	if main == null and r:
		main = (r.get_tree().current_scene if r.get_tree() else null)
	var p: Node = null
	if main:
		p = main.get("player") if "player" in main and main.get("player") is Node else main.get_node_or_null("Player")
	bind_player(p)


## Called by Progress.begin_match_gravemarks (main.gd _ready): binds on the next frame, when the Player is ready.
static func begin_deferred() -> void:
	var r := _root()
	if r == null:
		return
	var scr = load("res://scripts/stats/match_stats.gd")
	var cb := Callable(scr, "_begin_scene")
	if not r.get_tree().process_frame.is_connected(cb):
		r.get_tree().process_frame.connect(cb, CONNECT_ONE_SHOT)


static func _begin_scene() -> void:
	var r := _root()
	var scene := r.get_tree().current_scene if r else null
	if scene and (scene.has_node("Player") or "player" in scene):
		begin(scene)


static func bind_player(p: Node) -> void:
	var scr = load("res://scripts/stats/match_stats.gd")
	if _player and _player.get_ref():
		var old: Node = _player.get_ref()
		if old.has_signal("points_changed") and old.points_changed.is_connected(Callable(scr, "_on_points")):
			old.points_changed.disconnect(Callable(scr, "_on_points"))
		if old.has_signal("died") and old.died.is_connected(Callable(scr, "_on_died")):
			old.died.disconnect(Callable(scr, "_on_died"))
	_player = weakref(p) if p else null
	if p == null:
		return
	_last_points = int(p.get("points")) if "points" in p else 0
	if p.has_signal("points_changed"):
		p.points_changed.connect(Callable(scr, "_on_points"))
	if p.has_signal("died"):
		p.died.connect(Callable(scr, "_on_died"))


static func _hook_buses() -> void:
	if _hooked:
		return
	var r := _root()
	if r == null:
		return
	var scr = load("res://scripts/stats/match_stats.gd")
	var ge := r.get_node_or_null(GAME_EVENTS)
	if ge and ge.has_signal("event"):
		ge.event.connect(Callable(scr, "_on_event"))
	var pr := r.get_node_or_null(PROGRESS)
	if pr:
		if pr.has_signal("gravemark_gained"):
			pr.gravemark_gained.connect(Callable(scr, "_on_gm"))
		if pr.has_signal("scrap_gained"):
			pr.scrap_gained.connect(Callable(scr, "_on_scrap"))
	_hooked = true


static func _mine(ctx: Dictionary) -> bool:
	var p = ctx.get("player")
	if _player == null or _player.get_ref() == null:
		return p == null
	return p == null or p == _player.get_ref()


static func _on_event(name: StringName, ctx: Dictionary) -> void:
	if _s.is_empty() or not bool(_s.active):
		return
	match name:
		&"hit":
			if not _mine(ctx):
				return
			_s.hits += 1
			_s.damage_dealt += float(ctx.get("damage", 0.0))
			if bool(ctx.get("is_headshot", false)):
				_s.headshots += 1
		&"enemy_killed":
			if not _mine(ctx):
				return
			_s.kills += 1
			var src := str(ctx.get("source", "gun"))
			_s.kills_by_source[src] = int(_s.kills_by_source.get(src, 0)) + 1
			if src == "melee":
				_s.melee_kills += 1
			if bool(ctx.get("is_headshot", false)):
				_s.headshot_kills += 1
			var t = ctx.get("target")
			if t is Object and is_instance_valid(t) and t.has_meta("is_boss") and t.get_meta("is_boss"):
				_s.boss_kills += 1
		&"damage_taken":
			if not _mine(ctx):
				return
			var dealt := damage_counted(ctx)
			_s.damage_taken += dealt
			if int(ctx.get("dealt", 0)) > 0:
				_last_hit = describe_attacker(ctx.get("attacker"), ctx.get("player"))
				_last_hit["at_ms"] = Time.get_ticks_msec()
		&"points_gained":
			if not _mine(ctx):
				return
			var reason := str(ctx.get("reason", ""))
			_s.points_by_reason[reason] = int(_s.points_by_reason.get(reason, 0)) + int(ctx.get("amount", 0))
		&"shot_fired":
			# hitscan rounds only (rockets / thrown projectiles never "miss"), so accuracy = 1 - missed / fired
			var w = ctx.get("weapon")
			if _mine(ctx) and not (w is Object and is_instance_valid(w) and w.has_method("is_projectile") and w.is_projectile()):
				_s.shots_fired += 1
		&"shot_missed":
			if _mine(ctx):
				_s.shots_missed += 1
		&"healed":
			if _mine(ctx):
				_s.healed += maxi(int(ctx.get("amount", 0)), 0)
		&"grenade_thrown":
			if _mine(ctx):
				_s.grenades_thrown += 1
		&"card_picked":
			_s.cards_picked += 1
		&"door_opened":
			if _mine(ctx):
				_s.doors_opened += 1
		&"round_started":
			_s.round_reached = maxi(int(_s.round_reached), int(ctx.get("round", 0)))
		&"round_cleared":
			_s.rounds = maxi(int(_s.rounds), int(ctx.get("round", 0)))
		&"match_ended":
			_s.round_reached = maxi(int(_s.round_reached), int(ctx.get("round", 0)))
			end()


static func _on_points(p: int) -> void:
	if _s.is_empty() or not bool(_s.active):
		_last_points = p
		return
	var d := p - _last_points
	if d > 0:
		_s.points_earned += d
	elif d < 0:
		_s.points_spent += -d
	_last_points = p


static func _on_died() -> void:
	if _s.is_empty():
		return
	if not _last_hit.is_empty() and Time.get_ticks_msec() - int(_last_hit.get("at_ms", 0)) <= int(CAUSE_WINDOW_S * 1000.0):
		var c := _last_hit.duplicate()
		c.erase("at_ms")
		_s.cause_of_death = c
	else:
		_s.cause_of_death = {"kind": "unknown", "id": "", "name": "Unknown"}


static func _on_gm(n: int, _source: String) -> void:
	if not _s.is_empty() and bool(_s.active):
		_s.gravemarks += n


static func _on_scrap(n: int, _source: String) -> void:
	if not _s.is_empty() and bool(_s.active):
		_s.scrap += n


## HP a damage_taken hit counts for: `dealt`, capped at the HP the player had (ctx.hp_before, added by Player.take_damage), so a
## 40-damage hit on 10 HP is 10 (no overkill). A ctx without hp_before (older emitters) counts the whole `dealt`.
static func damage_counted(ctx: Dictionary) -> int:
	var dealt := maxi(int(ctx.get("dealt", 0)), 0)
	if ctx.has("hp_before"):
		dealt = mini(dealt, maxi(int(ctx.hp_before), 0))
	return dealt


## {kind: "boss" | "zombie" | "self" | "hazard" | "unknown", id, name} for a damage_taken attacker.
static func describe_attacker(a, player = null) -> Dictionary:
	if a == null or not (a is Object) or not is_instance_valid(a):
		return {"kind": "hazard", "id": "", "name": "Hazard"}
	if player != null and a == player:
		return {"kind": "self", "id": "self", "name": "Your own blast"}
	if a.has_meta("is_boss") and a.get_meta("is_boss"):
		var bid := str(a.get_meta("boss_id", ""))
		var B = load("res://scripts/enemies/boss_catalog.gd")
		return {"kind": "boss", "id": bid, "name": str(B.display_name(bid)) if B and bid != "" else "Boss"}
	var vid := str(a.get("variant_id")) if "variant_id" in a and a.get("variant_id") != null else ""
	var nm := "Zombie"
	if vid != "":
		var z = JSON.parse_string(FileAccess.get_file_as_string("res://data/zombies.json"))
		if typeof(z) == TYPE_DICTIONARY:
			nm = str(z.get("variants", {}).get(vid, {}).get("display_name", vid.capitalize()))
		if a.has_meta("boss_echo"):
			nm += " (echo)"
	return {"kind": "zombie", "id": vid, "name": nm}


## Freezes the clock (match_ended). Further events are ignored until the next begin().
static func end() -> void:
	if _s.is_empty():
		return
	if _t1_ms < 0:
		_t1_ms = Time.get_ticks_msec()
	_s.active = false
	_s.ended = true


## Progress.record_match: the XP the match paid (after difficulty scaling).
static func on_match_recorded(xp: int) -> void:
	if _s.is_empty():
		reset()
	_s.xp = xp


static func time_s() -> float:
	if _s.is_empty():
		return 0.0
	return float((_t1_ms if _t1_ms >= 0 else Time.get_ticks_msec()) - _t0_ms) / 1000.0


static func summary() -> Dictionary:
	if _s.is_empty():
		reset()
	var out := _s.duplicate(true)
	out.damage_dealt = int(round(float(_s.damage_dealt)))
	out["precision_kills"] = int(_s.headshot_kills)
	var fired := int(_s.shots_fired)
	out["shots_hit"] = maxi(fired - int(_s.shots_missed), 0)
	out["accuracy"] = float(out.shots_hit) / float(fired) if fired > 0 else 0.0
	out["time_s"] = time_s()
	var t := int(time_s())
	out["time_text"] = "%d:%02d" % [t / 60, t % 60]
	if out.cause_of_death.is_empty():
		out.cause_of_death = {"kind": "none", "id": "", "name": ""}
	return out
