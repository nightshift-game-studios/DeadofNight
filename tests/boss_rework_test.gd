extends SceneTree
## Boss rework behaviour (Skillz, playtest #15): stages, Frenzy, adds + cap, co-op scaling, minimum telegraph windups,
## slam hits everyone in the circle, event stream / puppet priming, supply event.
##   godot --headless --path . -s res://tests/boss_rework_test.gd

const ENEMY := preload("res://scenes/enemy.tscn")
const Cat := preload("res://scripts/enemies/boss_catalog.gd")
const Kit := preload("res://scripts/enemies/boss_kit.gd")
const MIN_WINDUP := 0.45 ## s: the shortest readable telegraph before a hit

var _fails := 0
var _passes := 0
var arena: Node3D


class FakePlayer extends Node3D:
	var hp := 100.0
	var dead := false
	var hits := 0
	func take_damage(amount: float, _a: Node = null) -> void:
		hp -= amount
		hits += 1


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _wait(n: int) -> void:
	for i in n:
		await physics_frame


func _boss(bid: String, rnd: int, diff: String, players: int) -> Node:
	var z = ENEMY.instantiate()
	z.set_script(load(Cat.script_path(bid)))
	z.setup(90 + 35 * (rnd - 1), 3.0, 10 + 2 * (rnd - 1))
	z.configure_boss(bid, rnd, diff, players)
	arena.add_child(z)
	z.global_position = Vector3(0, 0, -12)
	return z


func _kinds(b: Node) -> Array:
	var out: Array = []
	for ev in b.net_boss_state().back():
		out.append(str(ev.k))
	return out


func _run() -> void:
	Cat.reload()
	arena = Node3D.new()
	root.add_child(arena)
	var pl := FakePlayer.new()
	pl.add_to_group("player")
	arena.add_child(pl)
	pl.global_position = Vector3(0, 0, 10)
	await _wait(2)

	for bid in Cat.ids():
		var tg: Dictionary = Cat.telegraph(bid)
		# ------------------------------------------------ minimum readable windups (data)
		var low := ""
		for k in tg:
			if str(k).contains("windup"):
				var v = tg[k]
				var arr: Array = v if v is Array else [v]
				for x in arr:
					if float(x) < MIN_WINDUP:
						low = "%s=%s" % [k, str(x)]
		check(low == "", "%s: every telegraph windup (incl. stage / enraged variants) >= %.2f s %s" % [bid, MIN_WINDUP, low])

		# ------------------------------------------------ co-op HP scaling at the instance level
		var b1 = _boss(bid, 10, "medium", 1)
		var b4 = _boss(bid, 10, "medium", 4)
		await _wait(1)
		var ratio := float(b4.max_health) / float(b1.max_health)
		check(absf(ratio - Cat.party_hp_mult(4)) < 0.02, "%s: 4-player HP = %.2fx solo (%.3f)" % [bid, Cat.party_hp_mult(4), ratio])
		check(b1.max_health == Cat.boss_hp(bid, 10, 90, 35, "medium", 1), "%s: instance HP == catalog boss_hp" % bid)
		b4.queue_free()

		# ------------------------------------------------ stages -> stage event + supply event, once each
		var stages: Array = Cat.get_boss(bid).stages
		var b = b1
		var seen_stage := []
		b.boss_event.connect(func(kind, ev): if kind == "stage": seen_stage.append(int(ev.a)))
		b.health = int(float(b.max_health) * (float(stages[0]) - 0.02))
		b.base_tick(0.016)
		check(b.stage == 1 and seen_stage == [1], "%s: crossing %.0f%% HP enters stage 1 (event emitted once)" % [bid, float(stages[0]) * 100.0])
		b.base_tick(0.016)
		check(seen_stage == [1], "%s: no repeated stage event" % bid)
		b.health = int(float(b.max_health) * (float(stages[1]) - 0.02))
		b.base_tick(0.016)
		check(b.stage == 2 and seen_stage == [1, 2], "%s: crossing %.0f%% HP enters stage 2" % [bid, float(stages[1]) * 100.0])
		check(_kinds(b).count("supply") == 2, "%s: each stage change emits a supply event" % bid)
		check(Cat.hit_damage(bid, "melee", 10, "medium", true) > Cat.hit_damage(bid, "melee", 10, "medium", false), "%s: Frenzy raises damage" % bid)

		# ------------------------------------------------ Frenzy: warning, then on
		var et := Cat.enrage_time(bid, "medium")
		check(et < 200.0 and et > 100.0 and Cat.enrage_time(bid, "hard") < Cat.enrage_time(bid, "easy"), "%s: enrage timer %.0f s, shorter on hard" % [bid, et])
		b.fight_t = et - 6.0
		b.base_tick(0.016)
		check(_kinds(b).has("frenzy_warn") and not b.frenzy, "%s: Frenzy warning event before Frenzy" % bid)
		b.fight_t = et
		b.base_tick(0.016)
		check(b.frenzy and _kinds(b).has("frenzy"), "%s: Frenzy starts at the enrage timer" % bid)
		var cd1: float = Cat.cooldown_mult("medium", 1, false, bid)
		var cdf: float = Cat.cooldown_mult("medium", 1, true, bid)
		check(cdf < cd1, "%s: Frenzy cuts cooldowns (%.2f -> %.2f)" % [bid, cd1, cdf])

		# ------------------------------------------------ puppet priming (late join does not replay), then replays new events
		var pup = _boss(bid, 10, "medium", 1)
		pup.net_apply_events(b.net_boss_state().back())
		var before: int = pup._ev_seen
		check(before == b._ev_seq and pup.zone_count() == 0, "%s: first state primes the event counter, nothing replayed" % bid)
		b.emit_event("add", {"a": 1.0})
		pup.net_apply_events(b.net_boss_state().back())
		check(pup._ev_seen == b._ev_seq, "%s: puppet advances to the newest event" % bid)
		pup.queue_free()
		b.queue_free()

	# ------------------------------------------------ adds: co-op count + cap
	var h = _boss("choir_host", 10, "hard", 1)
	var counts := {"n": 0}
	h.request_echo.connect(func(_h, c): counts.n += c)
	var n1: int = h.summon(2)
	h.queue_free()
	var h4 = _boss("choir_host", 10, "hard", 4)
	var n4: int = h4.summon(2)
	check(n4 > n1, "co-op summons more adds (%d solo -> %d at 4 players)" % [n1, n4])
	var fillers: Array = []
	for i in 40:
		var e := Node3D.new()
		e.add_to_group("enemies")
		e.set_meta("boss_echo", true)
		arena.add_child(e)
		fillers.append(e)
	check(h4.summon(5) == 0, "adds cap: no summon while the cap is full")
	check(Cat.adds_cap(1) == 6 and Cat.adds_cap(2) == 8 and Cat.adds_cap(4) == 12, "add cap 6 / 8 / 12 for 1 / 2 / 4 players")
	for e in fillers:
		e.queue_free()
	h4.queue_free()

	# ------------------------------------------------ Bellwether slam: every player inside the circle in co-op, target only solo
	var bw = _boss("bellwether", 6, "easy", 2)
	var a := FakePlayer.new()
	a.add_to_group("player")
	arena.add_child(a)
	a.global_position = Vector3(1, 0, 0)
	var sh: Dictionary = bw.telegraph({"id": "slam", "kind": "circle", "c": Vector3(0, 0, 0), "r": 3.5}, 1.2, 30, Color.RED)
	check(bw.resolve(sh) == 1 and a.hits == 1 and pl.hits == 0, "slam resolves on every living player inside the circle only (player outside is untouched)")
	pl.global_position = Vector3(0.5, 0, 1)
	var sh2: Dictionary = bw.telegraph({"id": "slam", "kind": "circle", "c": Vector3(0, 0, 0), "r": 3.5}, 1.2, 30, Color.RED)
	check(bw.resolve(sh2) == 2, "co-op slam hits both players standing in the circle")
	bw.queue_free()
	a.queue_free()

	print("boss_rework_test: %d passed, %d failed" % [_passes, _fails])
	quit(1 if _fails > 0 else 0)
