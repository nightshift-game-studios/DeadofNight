extends SceneTree
## Boss fight simulator (Skillz, playtest #15 boss rework). Headless DPS-bot harness.
##   godot --headless --path . -s res://tests/boss_sim.gd -- --boss=bellwether --diff=easy --round=10 --players=1 \
##        [--bot=competent|sloppy|idle] [--runs=3] [--seed=1] [--limit=360] [--check]
## Builds a flat arena (baked navmesh), the real boss (same build order as main.make_zombie: set_script, setup,
## configure_boss(.., players), request_echo -> real echo zombies), and N bot players (group "player"). Each bot:
##   * shoots at ref_dps(round) x duty (adds first when the boss is gated / adds crowd it), standing or kiting,
##   * sees a threat only `react` s after it appears (BossBase.threat_shapes()), then sprints to the nearest safe point,
##   * kites away from the boss and adds (distance 8..16), regen 6 HP/s after 4 s without damage.
## One line per run:  SIM boss=.. diff=.. round=.. players=.. bot=.. result=win|wipe|dnf ttk=.. dmg=.. (worst player, raw)
## min_hp=.. deaths=.. adds=.. stage_t=a/b frenzy_t=..   With --check: exit code 1 if a competent run is outside budget
## (ttk_min..ttk_max, damage_max, no deaths) or a sloppy / idle run is inside it (the fight must punish bad play).

const ENEMY := preload("res://scenes/enemy.tscn")
const Cat := preload("res://scripts/enemies/boss_catalog.gd")
const Kit := preload("res://scripts/enemies/boss_kit.gd")
const DT := 1.0 / 60.0 ## 240 Hz physics x time_scale 4
const ARENA := 38.0
const SHOT := 0.1

const BOTS := {
	# react (+-jitter) = s before a telegraph is "seen", slip = chance a given telegraph is missed altogether (human
	# lapse), duty = shooting uptime factor, dodge_fire = dps factor while dodging, kite = bot starts retreating inside
	# this distance, margin = safety margin around shapes, speed = dodge sprint m/s
	"competent": {"react": 0.30, "jitter": 0.08, "slip": 0.10, "duty": 0.92, "dodge_fire": 0.45, "kite": 8.0, "margin": 0.9, "speed": 7.5},
	"sloppy": {"react": 0.62, "jitter": 0.2, "slip": 0.40, "duty": 0.62, "dodge_fire": 0.2, "kite": 3.5, "margin": 0.2, "speed": 6.5},
	"idle": {"react": 99.0, "jitter": 0.0, "slip": 1.0, "duty": 1.0, "dodge_fire": 1.0, "kite": 0.0, "margin": 0.0, "speed": 0.0},
}

class SimPlayer extends Node3D:
	var hp := 100.0
	var max_health := 100
	var dead := false
	var taken := 0.0
	var since := 99.0
	var min_hp := 100.0
	var trace := false
	var info := Callable()
	var velocity := Vector3.ZERO
	var health: int:
		get: return int(hp)

	func take_damage(amount: float, _attacker: Node = null) -> void:
		if dead:
			return
		hp -= amount
		taken += amount
		if trace:
			print("HIT %.0f from %s hp=%.0f" % [amount, str(_attacker.name if _attacker != null else "?") + ":" + str(_attacker.get_script().resource_path.get_file() if _attacker != null and _attacker.get_script() != null else ""), hp] + (" " + str(info.call()) if info.is_valid() else ""))
		since = 0.0
		min_hp = minf(min_hp, hp)
		if hp <= 0.0:
			dead = true

	func tick(dt: float) -> void:
		since += dt
		if not dead and since > 4.0 and hp < 100.0:
			hp = minf(hp + 6.0 * dt, 100.0)

class Bot:
	var sp: Node3D
	var cfg: Dictionary
	var seen: Dictionary = {}
	var shot_t := 0.0
	var dodging := false
	var phase := 0.0

var arena: Node3D
var boss: Node
var bots: Array = []
var adds_spawned := 0
var adds_killed := 0
var echo_hp := 100
var now := 0.0
var stage_t: Array = [-1.0, -1.0, -1.0]
var frenzy_t := -1.0
var boss_dead := false
var ref := 100.0
var dealt_total := 0.0
var rng := RandomNumberGenerator.new()
var _prev_stage := 0
var _prev_frenzy := false


func _initialize() -> void:
	_main.call_deferred()


func _arg(k: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % k):
			return a.substr(k.length() + 3)
	return d


func _main() -> void:
	var bid := _arg("boss", "bellwether")
	var diff := _arg("diff", "easy")
	var rnd := int(_arg("round", "10"))
	var players := int(_arg("players", "1"))
	var bots_s := _arg("bot", "competent")
	var runs := int(_arg("runs", "1"))
	var seed0 := int(_arg("seed", "1"))
	var limit := float(_arg("limit", "360"))
	var check := OS.get_cmdline_user_args().has("--check")
	Engine.physics_ticks_per_second = 240
	Engine.max_physics_steps_per_frame = 16
	var bad := 0
	for bt in bots_s.split(","):
		for r in runs:
			var res: Dictionary = await _fight(bid, diff, rnd, players, bt, seed0 + r, limit)
			print(_line(bid, diff, rnd, players, bt, res))
			var bud := Cat.budgets(diff)
			# multi-boss rounds (hard 11 / 21): the sim fights ONE boss (HP x multi_boss_hp); the full round kills them one after
			# another (total = count x this), so this boss's TTK window scales by multi_boss_hp (damage budget is per boss: concurrent bosses are not simulated)
			var nb := Cat.count_for(rnd, diff)
			var tm := Cat.multi_hp_mult(nb)
			var ok_comp: bool = res.result == "win" and res.ttk >= float(bud.ttk_min) * tm and res.ttk <= float(bud.ttk_max) * tm \
				and res.dmg <= float(bud.damage_max) and int(res.deaths) == 0
			if check:
				if bt == "competent" and not ok_comp:
					bad += 1
				elif bt != "competent" and ok_comp:
					bad += 1
	quit(1 if bad > 0 else 0)


func _line(bid: String, diff: String, rnd: int, players: int, bt: String, r: Dictionary) -> String:
	return "SIM boss=%s diff=%s round=%d players=%d bot=%s result=%s ttk=%.1f dmg=%.0f min_hp=%.0f deaths=%d adds=%d stage_t=%.0f/%.0f frenzy_t=%.0f hp=%d dps_ratio=%.2f" % [
		bid, diff, rnd, players, bt, r.result, r.ttk, r.dmg, r.min_hp, r.deaths, r.adds, r.s1, r.s2, r.fz, r.hp, r.dps_ratio]


func _wait(n: int) -> void:
	for i in n:
		await physics_frame


func _build_arena() -> void:
	arena = Node3D.new()
	root.add_child(arena)
	var env := WorldEnvironment.new()
	arena.add_child(env)
	var region := NavigationRegion3D.new()
	var nm := NavigationMesh.new()
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nm.agent_radius = 0.5
	region.navigation_mesh = nm
	arena.add_child(region)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(ARENA * 2.0 + 10.0, 1.0, ARENA * 2.0 + 10.0)
	cs.shape = bs
	body.add_child(cs)
	body.position = Vector3(0, -0.5, 0)
	region.add_child(body)
	await _wait(2)
	region.bake_navigation_mesh(false)
	await _wait(4)


func _make_boss(bid: String, diff: String, rnd: int, players: int) -> Node:
	var z = ENEMY.instantiate()
	z.set_script(load(Cat.script_path(bid)))
	var hp0 := 90 + 35 * (rnd - 1)
	var spd := minf(2.4 + 0.3 * float(rnd - 1), 6.0)
	z.setup(hp0, spd, 10 + 2 * (rnd - 1))
	z.configure_boss(bid, rnd, diff, players)
	z.request_echo.connect(_on_echo)
	z.died.connect(func(_a = null): boss_dead = true)
	return z


func _on_echo(host: Node, count: int) -> void:
	var rnd: int = boss.round_n
	var ec: Dictionary = Cat.echo_cfg()
	var spd := minf(2.4 + 0.3 * float(rnd - 1), 6.0) * float(ec.get("speed_mult", 1.1))
	var dmg := maxi(int(round(float(10 + 2 * (rnd - 1)) * float(ec.get("damage_mult", 0.7)))), 1)
	for i in count:
		var e = ENEMY.instantiate()
		e.setup(echo_hp, spd, dmg)
		e.set_meta("boss_echo", true)
		e.died.connect(func(_a = null): adds_killed += 1)
		arena.add_child(e)
		var o: Vector3 = host.global_position if host is Node3D else Vector3.ZERO
		e.global_position = o + Vector3(rng.randf_range(-2, 2), 0, rng.randf_range(-2, 2))
		adds_spawned += 1


func _fight(bid: String, diff: String, rnd: int, players: int, bot_kind: String, sd: int, limit: float) -> Dictionary:
	seed(sd)
	rng.seed = sd
	Engine.time_scale = 4.0
	if arena == null:
		await _build_arena()
	for n in get_nodes_in_group("player"):
		n.queue_free()
	for n in get_nodes_in_group("enemies"):
		n.queue_free()
	for n in get_nodes_in_group("boss_zone"):
		n.queue_free()
	await _wait(2)
	adds_spawned = 0
	adds_killed = 0
	boss_dead = false
	now = 0.0
	stage_t = [-1.0, -1.0, -1.0]
	frenzy_t = -1.0
	dealt_total = 0.0
	_prev_stage = 0
	_prev_frenzy = false
	echo_hp = Cat.echo_hp(rnd)
	ref = Cat.ref_dps(rnd)
	bots.clear()
	for i in players:
		var sp := SimPlayer.new()
		sp.add_to_group("player")
		sp.info = func() -> String:
			var ids: Array = []
			if is_instance_valid(boss) and boss.has_method("threat_shapes"):
				for t in boss.threat_shapes():
					ids.append("%s@%.2f" % [str(t.get("id", "")), float(t.get("eta", 0.0))])
			return "t=%.1f live=%s" % [now, str(ids)]
		sp.trace = OS.get_cmdline_user_args().has("--trace") or OS.get_cmdline_user_args().has("--hits")
		arena.add_child(sp)
		sp.global_position = Vector3(-6.0 + 4.0 * float(i) - 2.0 * float(players - 1), 0.0, 14.0)
		var b := Bot.new()
		b.sp = sp
		b.cfg = BOTS[bot_kind]
		b.phase = float(i) * 1.7
		bots.append(b)
	boss = _make_boss(bid, diff, rnd, players)
	arena.add_child(boss)
	boss.global_position = Vector3(0.0, 0.0, -12.0)
	var hp_max: int = boss.max_health
	await _wait(2)
	var result := "dnf"
	while now < limit:
		await physics_frame
		now += DT
		_step(rnd)
		if boss_dead or not is_instance_valid(boss):
			result = "win"
			break
		var alive := false
		for b in bots:
			if not b.sp.dead:
				alive = true
		if not alive:
			result = "wipe"
			break
	var worst := 0.0
	var minhp := 100.0
	var deaths := 0
	for b in bots:
		worst = maxf(worst, b.sp.taken)
		minhp = minf(minhp, b.sp.min_hp)
		if b.sp.dead:
			deaths += 1
	var out := {"result": result, "ttk": now, "dmg": worst, "min_hp": maxf(minhp, 0.0), "deaths": deaths, "adds": adds_spawned,
		"s1": stage_t[1], "s2": stage_t[2], "fz": frenzy_t, "hp": hp_max,
		"dps_ratio": dealt_total / maxf(now, 0.01) / (ref * float(players))}
	if is_instance_valid(boss):
		boss.queue_free()
	return out


var _trace_t := 0.0


func _step(rnd: int) -> void:
	if not is_instance_valid(boss):
		return
	if OS.get_cmdline_user_args().has("--trace") and now >= _trace_t:
		_trace_t = now + 1.0
		var b0: Bot = bots[0]
		var adds_n := 0
		for e in get_nodes_in_group("enemies"):
			if e != boss and bool(e.get("_dead")) == false:
				adds_n += 1
		print("T=%.0f phase=%s hp=%d/%d shield=%s adds=%d bot_hp=%.0f dodging=%s dist=%.1f threats=%d" % [now, str(boss.get("phase")), boss.health, boss.max_health,
			str(boss.get("shield_hp")), adds_n, b0.sp.hp, str(b0.dodging), flat(boss.global_position, b0.sp.global_position), boss.threat_shapes().size()])
	var tshapes: Array = boss.threat_shapes() if boss.has_method("threat_shapes") else []
	if boss.get("stage") != null:
		var st: int = boss.stage
		while _prev_stage < st:
			_prev_stage += 1
			stage_t[_prev_stage] = now
		if bool(boss.frenzy) and not _prev_frenzy:
			_prev_frenzy = true
			frenzy_t = now
	for b in bots:
		b.sp.tick(DT)
		if not b.sp.dead:
			_bot(b, tshapes)


func _key(sh: Dictionary) -> String:
	var c: Vector3 = sh.c
	return "%s|%d|%d|%s" % [str(sh.get("id", "")), int(c.x * 2.0), int(c.z * 2.0), str(sh.get("kind", ""))]


func _bot(b: Bot, tshapes: Array) -> void:
	var cfg: Dictionary = b.cfg
	var pos: Vector3 = b.sp.global_position
	var move := Vector3.ZERO
	var spd := float(cfg.speed)
	b.dodging = false
	# threats the bot has noticed
	var worst_eta := 1.0e9
	var worst: Dictionary = {}
	var live_keys: Dictionary = {}
	var alerted: bool = b.sp.since < 0.1 ## just got hit: a human notices everything that is still coming (no more lapses)
	for sh in tshapes:
		var k := _key(sh)
		live_keys[k] = true
		if alerted and b.seen.has(k) and float(b.seen[k]) > now:
			b.seen[k] = now
		if not b.seen.has(k):
			var slip := rng.randf() < float(cfg.slip)
			b.seen[k] = now + (999.0 if slip else rng.randf_range(-1.0, 1.0) * float(cfg.jitter))
		if now - float(b.seen[k]) < float(cfg.react):
			continue
		if float(sh.eta) > 2.2:
			continue
		if Kit.shape_hits(Kit._grown(sh, float(cfg.margin)), pos) and float(sh.eta) < worst_eta:
			worst_eta = float(sh.eta)
			worst = sh
	for k in b.seen.keys():
		if not live_keys.has(k):
			b.seen.erase(k)
	if not worst.is_empty() and spd > 0.0:
		var esc := Kit.escape_point(worst, pos, float(cfg.margin) + 0.4)
		esc.x = clampf(esc.x, -ARENA, ARENA)
		esc.z = clampf(esc.z, -ARENA, ARENA)
		var d := esc - pos
		d.y = 0.0
		if d.length() > 0.05:
			move = d.normalized()
			b.dodging = true
	else:
		# kite
		var away := Vector3.ZERO
		for e in get_nodes_in_group("enemies"):
			if not (e is Node3D) or not is_instance_valid(e) or bool(e.get("_dead")):
				continue
			var off: Vector3 = pos - e.global_position
			off.y = 0.0
			var dist := off.length()
			var lim := float(cfg.kite) if e == boss else 3.5
			if dist < lim and dist > 0.01:
				away += off.normalized() * (lim - dist) / lim
		if away.length() > 0.01:
			var perp := Vector3(-away.z, 0.0, away.x).normalized() * (1.0 if sin(b.phase + now * 0.35) > 0.0 else -1.0)
			var to_c := Vector3(-pos.x, 0.0, -pos.z)
			var bias := to_c.normalized() * clampf(to_c.length() / ARENA - 0.5, 0.0, 1.0) * 1.5 if to_c.length() > 1.0 else Vector3.ZERO
			move = (away.normalized() + perp * 0.7 + bias).normalized()
	if move != Vector3.ZERO and spd > 0.0:
		var np := pos + move * spd * DT
		np.x = clampf(np.x, -ARENA, ARENA)
		np.z = clampf(np.z, -ARENA, ARENA)
		b.sp.global_position = np
		pos = np
	# shooting
	b.shot_t += DT
	if b.shot_t >= SHOT:
		b.shot_t -= SHOT
		var f := float(cfg.duty) * (float(cfg.dodge_fire) if b.dodging else 1.0)
		var dmg := ref * f * SHOT
		var tgt := _pick_target(pos)
		if tgt != null:
			var hp_before: float = float(tgt.health) if tgt == boss else 0.0
			tgt.take_damage(dmg, tgt.global_position + Vector3(0, 1.0, 0), false, b.sp)
			if tgt == boss:
				dealt_total += maxf(hp_before - float(tgt.health), 0.0) / maxf(boss.damage_taken_mult(), 0.01) * 1.0


func _pick_target(pos: Vector3) -> Node:
	var gated: bool = boss.damage_taken_mult() < 0.9
	var ch = boss.get("channeling")
	var shp = boss.get("shield_hp")
	var shielded: bool = ch == true and shp != null and float(shp) > 0.0 ## Choir: break the shield
	var near_add: Node = null
	var near_d := 1.0e9
	var adds := 0
	for e in get_nodes_in_group("enemies"):
		if e == boss or not is_instance_valid(e) or bool(e.get("_dead")) or not e.has_meta("boss_echo"):
			continue
		adds += 1
		var d: float = flat(e.global_position, pos)
		if d < near_d:
			near_d = d
			near_add = e
	if near_add != null and ((gated and not shielded) or near_d < (3.5 if shielded else 7.0) or (adds >= 4 and not shielded)):
		return near_add
	if flat(boss.global_position, pos) > 55.0:
		return null
	return boss


func flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
