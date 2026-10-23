extends "res://scripts/enemy.gd"
## Common boss machinery (Skillz, boss rework 2026-10-22; playtest #15 "bosses need to be WAY harder"):
## HP-threshold stages, Frenzy (soft enrage timer), summoned adds with a cap, lingering zones, threat shapes
## (telegraph + damage + sim bot share one definition) and the co-op event stream.
##
## Authority model (co-op, Netz): ONLY the host runs the fight (timers, RNG, damage). A puppet runs nothing but
## net_apply_boss_state(): it shows clips / telegraphs / zones from the host's state + event list. Every random pick
## (zone scatter, blink point, which player is targeted) is made on the host and travels as a position in an event,
## so there is no RNG to keep in sync. Boss scripts extend this and keep their own phase enum + net_boss_state() prefix.
##
## Event stream (appended to every boss's net_boss_state, see BOSS_REWORK.md): events are Dictionaries
##   {"s": seq, "k": kind, "id": attack/zone id, "p": Vector3, "d": Vector3, "a": float, "b": float, "c": Color, "sh": shape}
## kinds: "shape" (telegraph: sh + a = seconds to impact), "zone" (lingering hazard: p, a = radius, "arm"/"life" in
## b/"l", tick dmg "t"), "impact" (an attack landed: id, p), "cancel" (id: drop that telegraph), "stage", "frenzy_warn", "frenzy", "add" (a = count).
## The list keeps the last EVENT_KEEP events; a puppet replays every event with seq > the last it saw. The first
## state a puppet receives only primes the counter (late join must not replay old zones).

signal request_echo(host, count)
signal boss_event(kind, data)

const Catalog := preload("res://scripts/enemies/boss_catalog.gd")
const Common := preload("res://scripts/enemies/boss_common.gd")
const Telegraph := preload("res://scripts/enemies/boss_telegraph.gd")
const Art := preload("res://scripts/enemies/boss_art.gd")
const Kit := preload("res://scripts/enemies/boss_kit.gd")
const Zone := preload("res://scripts/enemies/boss_zone.gd")
const EVENT_KEEP := 8

var boss_id: String = ""
var round_n: int = 1
var difficulty_id: String = ""
var party: int = 1 ## co-op party size this boss was scaled for
var boss_n: int = 1 ## bosses spawned this round (HP split)
var stage: int = 0 ## 0-based HP stage (data stages[])
var frenzy: bool = false ## soft-enrage reached
var fight_t: float = 0.0 ## seconds since the boss first had a target
var adds_summoned: int = 0
var _cfg: Dictionary = {}
var _tg: Dictionary = {}
var _an: Dictionary = {}
var _fx: Dictionary = {}
var _clock: float = 0.0
var _threats: Array = []
var _later: Array = [] ## [due clock, Callable]
var _zones: Array = []
var _events: Array = []
var _ev_seq: int = 0
var _ev_seen: int = -1
var _frenzy_warned: bool = false
var _gate_seen_t: float = 0.0
var impacts: int = 0 ## damage events resolved (tests)
var _shape_nodes: Dictionary = {} ## attack id -> its newest telegraph node (an event "cancel" frees it)


func configure_boss(id: String, n: int, difficulty: String = "", players: int = -1) -> void:
	boss_id = id
	round_n = n
	difficulty_id = difficulty
	party = players if players >= 1 else Kit.party_size()
	boss_n = Catalog.count_for(n, difficulty)
	_cfg = Catalog.get_boss(id)
	_tg = Catalog.telegraph(id)
	_an = Catalog.anims(id)
	_fx = Catalog.fx(id)
	Common.apply_identity(self, id, n, difficulty, party, boss_n)
	contact_damage = hit_damage("melee")
	_configured()


func _configured() -> void:
	pass


func _ready() -> void:
	super._ready()
	if _an.is_empty() and boss_id != "":
		_cfg = Catalog.get_boss(boss_id)
		_tg = Catalog.telegraph(boss_id)
		_an = Catalog.anims(boss_id)
		_fx = Catalog.fx(boss_id)
	Art.setup_anims(self, _an)


# ------------------------------------------------------------------ numbers
func hit_damage(key: String) -> int:
	return Catalog.hit_damage(boss_id, key, round_n, difficulty_id, frenzy)


## Attack cooldown multiplier right now (Difficulty x co-op x Frenzy). Multiply every cooldown by it.
func cd_scale() -> float:
	return Catalog.cooldown_mult(difficulty_id, party, frenzy, boss_id)


## Stage-indexed telegraph value: _tg[key] is an Array indexed by stage (clamped).
func tgs(key: String, fallback: float = 0.0) -> float:
	var a = _tg.get(key, null)
	if a is Array and (a as Array).size() > 0:
		return float(a[mini(stage, (a as Array).size() - 1)])
	return float(_tg.get(key, fallback))


func color_of(name: String, fallback: Color) -> Color:
	return Kit.color_of(_cfg.get("colors", {}).get(name, null), fallback)


func is_authority() -> bool:
	return is_multiplayer_authority()


# ------------------------------------------------------------------ per-frame (authority) bookkeeping
## Call once per physics frame from the boss's own _physics_process while it is the authority and alive.
func base_tick(delta: float) -> void:
	_clock += delta
	if target != null and is_instance_valid(target):
		fight_t += delta
	var s := Catalog.stage_for(boss_id, health / float(maxi(max_health, 1)))
	if s > stage:
		stage = s
		emit_event("stage", {"a": float(stage)})
		_supply_drop()
		_on_stage(stage)
	var ft := Catalog.enrage_time(boss_id, difficulty_id)
	if not _frenzy_warned and fight_t >= ft - float(Catalog.tuning().get("frenzy_warning", 12.0)):
		_frenzy_warned = true
		emit_event("frenzy_warn", {"a": ft - fight_t})
	if not frenzy and fight_t >= ft:
		frenzy = true
		emit_event("frenzy", {})
		_on_frenzy()
	if not _later.is_empty():
		var due: Array = []
		for item in _later:
			if _clock >= float(item[0]):
				due.append(item)
		for item in due:
			_later.erase(item)
			(item[1] as Callable).call()
	var keep: Array = []
	for t in _threats:
		if float(t.t_hit) + 0.3 > _clock:
			keep.append(t)
	_threats = keep


func _on_stage(_s: int) -> void:
	pass


## Host: a stage change drops `tuning.supply_drop.count_per_player` ammo boxes per player near a random player (a boss has
## far more HP than the loadout's reserve; main.spawn_pickup is Net-aware: shared first-grab world drop in co-op).
func _supply_drop() -> void:
	var sd: Dictionary = Catalog.tuning().get("supply_drop", {})
	if sd.is_empty() or not is_inside_tree():
		return
	var n := maxi(int(sd.get("count_per_player", 1)), 0) * maxi(party, 1)
	var main := get_tree().current_scene
	if n <= 0:
		return
	emit_event("supply", {"a": float(n)})
	if main == null or not main.has_method("spawn_pickup"):
		return
	var gdb := get_tree().root.get_node_or_null("GearDB")
	var it = gdb.consumable(str(sd.get("item", "ammo_box"))) if gdb != null and gdb.has_method("consumable") else null
	if it == null:
		return
	var who := random_player()
	var at: Vector3 = who.global_position if who != null else global_position
	for i in n:
		var ang := TAU * float(i) / float(n) + randf() * 0.5
		main.spawn_pickup(it, at + Vector3(cos(ang), 0.3, sin(ang)) * float(sd.get("scatter", 3.0)), false)


func _on_frenzy() -> void:
	pass


## Runs `fn` after `delay` seconds of boss time (host only; dropped if the boss dies).
func later(delay: float, fn: Callable) -> void:
	_later.append([_clock + delay, fn])


# ------------------------------------------------------------------ threats (telegraph + damage)
## Registers a dangerous area that hits at now + windup, shows its telegraph (here and on puppets) and returns it.
## Resolve it with resolve(shape) at impact.
func telegraph(sh: Dictionary, windup: float, dmg: int, col: Color, show_extra: float = 0.0) -> Dictionary:
	sh["t_hit"] = _clock + windup
	sh["dmg"] = dmg
	_threats.append(sh)
	emit_event("shape", {"id": str(sh.get("id", "")), "sh": sh.duplicate(), "a": windup + show_extra, "c": col})
	return sh


## Drops a pending threat without damage (e.g. Crescendo when the shield breaks) and tells puppets to hide its telegraph.
func cancel_threat(sh: Dictionary) -> void:
	_threats.erase(sh)
	emit_event("cancel", {"id": str(sh.get("id", ""))})


## Hits every living player inside `sh` (co-op: all of them; solo: the player). Returns how many were hit.
func resolve(sh: Dictionary) -> int:
	var n := 0
	for p in Kit.players(self):
		if Kit.shape_hits(sh, (p as Node3D).global_position):
			p.call("take_damage", int(sh.dmg), self)
			n += 1
	_threats.erase(sh)
	impacts += n
	emit_event("impact", {"id": str(sh.get("id", "")), "p": sh.c})
	return n


## Everything dangerous right now: pending telegraphs ("eta" = s to impact) + zones (eta 0 = live).
func threat_shapes() -> Array:
	var out: Array = []
	for t in _threats:
		var c: Dictionary = t.duplicate()
		c["eta"] = float(t.t_hit) - _clock
		out.append(c)
	_zones = _zones.filter(func(z): return is_instance_valid(z))
	for z in _zones:
		var zs: Dictionary = z.shape()
		if float(zs.eta) >= 0.0:
			out.append(zs)
	return out


# ------------------------------------------------------------------ zones
func zone_count() -> int:
	_zones = _zones.filter(func(z): return is_instance_valid(z))
	return _zones.size()


## Lingering hazard (host decides, everyone sees it). Returns false at the zone cap.
func spawn_zone(zk: String, pos: Vector3, radius: float, arm: float, life: float, tick: int, tick_s: float, burst: int, col: Color) -> bool:
	if zone_count() >= int(_tg.get("max_zones", 6)):
		return false
	emit_event("zone", {"id": zk, "p": pos, "a": radius, "b": arm, "l": life, "t": tick, "ts": tick_s, "u": burst, "c": col})
	return true


func clear_zones() -> void:
	for z in _zones:
		if is_instance_valid(z):
			z.queue_free()
	_zones.clear()


# ------------------------------------------------------------------ adds
## Asks main to spawn `base` echo adds (scaled by Difficulty adds_mult and party, capped at adds_cap). Returns the count.
func summon(base: float) -> int:
	var want := Catalog.adds_count(base, difficulty_id, party)
	var room := Catalog.adds_cap(party) - (Kit.adds_alive(get_tree()) if is_inside_tree() else 0)
	var n := clampi(want, 0, maxi(room, 0))
	if n > 0:
		adds_summoned += n
		emit_event("add", {"a": float(n)})
		request_echo.emit(self, n)
	return n


## Damage multiplier on this boss from its own mechanics (armor gate, stagger window). Boss scripts override.
func _extra_taken_mult() -> float:
	return 1.0


func damage_taken_mult() -> float:
	return super.damage_taken_mult() * _extra_taken_mult()


# ------------------------------------------------------------------ events (host emits + plays; puppets replay)
func emit_event(kind: String, data: Dictionary = {}) -> void:
	_ev_seq += 1
	var ev := data.duplicate()
	ev["s"] = _ev_seq
	ev["k"] = kind
	_events.append(ev)
	while _events.size() > EVENT_KEEP:
		_events.pop_front()
	_play_event(ev, true)
	boss_event.emit(kind, ev)


func _parent3d() -> Node3D:
	return get_parent() as Node3D if get_parent() is Node3D else self


## Name -> [new sfx id, fallback id] from data (bosses[id].sfx); plays at the boss.
func sfx(name: String, at: Vector3 = Vector3.INF) -> void:
	var e = _cfg.get("sfx", {}).get(name, null)
	if e is Array and (e as Array).size() >= 1 and is_inside_tree():
		Kit.sfx(global_position if at == Vector3.INF else at, str(e[0]), str(e[1]) if (e as Array).size() > 1 else "")


## Shared event visuals + SFX; boss scripts extend with super._play_event(ev, auth) first. `auth` = host (zones hurt).
func _play_event(ev: Dictionary, auth: bool) -> void:
	if not is_inside_tree():
		return
	match str(ev.k):
		"shape":
			_shape_nodes[str(ev.id)] = Kit.show_shape(_parent3d(), ev.sh, float(ev.a), ev.c if ev.c is Color else Color(1, 0.3, 0.1, 0.5))
			sfx(str(ev.id) + "_windup")
		"cancel":
			var n = _shape_nodes.get(str(ev.id), null)
			if n != null and is_instance_valid(n):
				n.queue_free()
			_shape_nodes.erase(str(ev.id))
			sfx(str(ev.id) + "_cancel")
		"zone":
			var z := Zone.spawn(_parent3d(), self, ev.p, float(ev.a), float(ev.b), float(ev.l), int(ev.t), float(ev.ts), int(ev.u),
				ev.c if ev.c is Color else Color(1, 0.4, 0.1, 0.5), auth, str(ev.id))
			if auth:
				_zones.append(z)
			sfx(str(ev.id) + "_arm", ev.p)
		"impact":
			sfx(str(ev.id) + "_hit", ev.p)
		"stage":
			sfx("stage")
		"frenzy_warn":
			sfx("frenzy_warn")
		"frenzy":
			sfx("frenzy")
		"add":
			sfx("summon")


## Puppet: replay unseen events. The first call only primes the counter (late join).
func net_apply_events(list: Variant) -> void:
	if not (list is Array):
		return
	var first := _ev_seen < 0
	var top := _ev_seen
	for ev in list:
		if not (ev is Dictionary):
			continue
		var s := int(ev.get("s", 0))
		top = maxi(top, s)
		if not first and s > _ev_seen:
			_play_event(ev, false)
	_ev_seen = maxi(top, 0)


## The back-compatible tail every boss appends to its net_boss_state: [stage, frenzy, events].
func net_common() -> Array:
	return [stage, frenzy, _events.duplicate()]


## Puppet: apply the tail that starts at index `i`.
func net_apply_common(st: Array, i: int) -> void:
	if st.size() < i + 3:
		return
	var s := int(st[i])
	if s != stage:
		stage = s
		_on_stage(stage)
	if bool(st[i + 1]) and not frenzy:
		frenzy = true
		_on_frenzy()
	net_apply_events(st[i + 2])


func _hold_still(delta: float) -> void:
	_attack_anim_t = maxf(_attack_anim_t, 0.1) # no random HitReact over a telegraphed clip (enemy.take_damage)
	velocity.x = 0.0
	velocity.z = 0.0
	if not is_on_floor():
		velocity.y -= _gravity * delta
	move_and_slide()


## Plays `key` stretched to last exactly `duration` seconds (telegraphed clips stay in sync with data timing).
func _play_fit(key: String, duration: float) -> void:
	_attack_anim_t = maxf(_attack_anim_t, 0.1)
	var clip_len := Art.clip_length(self, key, duration)
	Art.play(self, key, float(_an.get("blend", 0.15)), clip_len / maxf(duration, 0.05) if clip_len > 0.0 else 1.0)


## Random living player (host RNG); falls back to `target`.
func random_player() -> Node3D:
	var ps := Kit.players(self)
	if ps.is_empty():
		return target as Node3D
	return ps[randi() % ps.size()] as Node3D


func _die() -> void:
	clear_zones()
	super._die()
