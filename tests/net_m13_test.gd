extends SceneTree
## M13 unit suite (Netz): door buys (maps/common/map_door.gd) and paid Field Card rerolls (scripts/skills/run_state.gd)
## through the host. Solo: the patched files are driven side by side with the 5e201b3 originals
## (tests/net/baseline/*.gd.txt) through the same operations and must leave identical traces; plus the
## open()-on-open no-op, the token spend timeout + late refund, and the host refund guard.
##   godot --headless --path . -s res://tests/net_m13_test.gd   (exit code = failures)

var _fails := 0
var _passes := 0


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


class StubPlayer:
	extends Node3D
	var points := 0
	var nearby: Array = []
	var gained: Array = []
	signal points_changed(v: int)
	func spend_points(a: int) -> bool:
		if points < a:
			return false
		points -= a
		points_changed.emit(points)
		return true
	func add_points(a: int, reason: String = "") -> void:
		points += a
		gained.append([a, reason])
		points_changed.emit(points)
	func set_nearby_interactable(n: Node, on: bool) -> void:
		nearby.append([str(n.get("door_id")), on])


## The baseline file as a loadable script (class_name dropped so it doesn't clash with the patched one).
func _baseline(file: String) -> GDScript:
	var src := FileAccess.get_file_as_string("res://tests/net/baseline/%s.txt" % file)
	var lines := src.split("\n")
	for i in lines.size():
		if lines[i].begins_with("class_name "):
			lines[i] = ""
	var path := "user://m13_baseline_%s" % file
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	var s := GDScript.new()
	s.source_code = "\n".join(lines)
	s.resource_path = path
	check(s.reload() == OK, "baseline %s compiles" % file)
	return s


func _door_trace(script: Script) -> Array:
	var tr: Array = []
	var pl := StubPlayer.new()
	root.add_child(pl)
	var made: Array = []
	for spec in [["D1", 30], ["", 10], ["D3", 0]]:
		var d = script.new()
		d.door_id = StringName(spec[0])
		d.cost = spec[1]
		root.add_child(d)
		made.append(d)
		var n := [0]
		d.opened.connect(func(_x): n[0] += 1)
		pl.points = 20
		d.interact(pl) # D1: can't afford
		tr.append([spec[0], d.is_open, pl.points, n[0], d.can_interact(), d.get_prompt()])
		pl.points = 50
		d.interact(pl)
		tr.append([spec[0], d.is_open, pl.points, n[0], d.can_interact(), d.collision_layer])
		d.interact(pl) # open: nothing
		d.open(pl) # already open: no-op
		d.open(null)
		tr.append([spec[0], d.is_open, pl.points, n[0], pl.nearby.duplicate()])
	var scripted = script.new() # open() without charging (scripted events / replication)
	scripted.door_id = &"D9"
	root.add_child(scripted)
	pl.points = 7
	scripted.open(pl)
	tr.append(["D9", scripted.is_open, pl.points])
	made.append(scripted)
	for d in made:
		d.free()
	pl.free()
	return tr


func _reroll_trace(script: Script) -> Array:
	var tr: Array = []
	var rs = script.new()
	root.add_child(rs)
	var pl := StubPlayer.new()
	root.add_child(pl)
	rs.player = pl
	rs.rerolled.connect(func(c, f): tr.append(["rerolled", c, f]))
	rs.offer_ready.connect(func(e, m): tr.append(["offer", e.size(), m]))
	for round_n in [1, 5]:
		rs.rng.seed = 1234 + round_n
		rs.free_rerolls = 1
		pl.points = 120
		rs.open_offer(round_n)
		tr.append(["open", rs.offer.duplicate(), rs.reroll_cost()])
		for i in 4:
			var ok: bool = rs.reroll()
			tr.append(["reroll", ok, pl.points, rs.free_rerolls, rs.rerolls_paid_this_offer, rs.offer.duplicate(), rs.reroll_cost(), rs.can_reroll()])
		rs.offer_open = false
	rs.player = null
	rs.open_offer(2)
	tr.append(["no player", rs.reroll()])
	pl.free()
	rs.free()
	return tr


func _run() -> void:
	var Net = root.get_node("Net")
	var DoorScr: Script = load("res://maps/common/map_door.gd")
	var RunScr: Script = load("res://scripts/skills/run_state.gd")
	check(not Net.is_networked() and not NetGate.is_networked(), "solo: Net offline")

	# --- solo: patched == baseline
	var a := _door_trace(DoorScr)
	var b := _door_trace(_baseline("map_door.gd"))
	check(a == b, "solo map_door: patched trace == 5e201b3 trace (%d steps)" % a.size())
	if a != b:
		print("  patched  ", a, "\n  baseline ", b)
	check(a[1][1] and a[1][2] == 20 and a[1][3] == 1 and a[2][3] == 1, "solo map_door: buy charges once, opened once; interact / open() on an open door are no-ops")
	check(a[0][1] == false and a[0][2] == 20, "solo map_door: can't afford -> stays closed, not charged")
	check(a[9] == ["D9", true, 7], "solo map_door: open() never charges")
	var c := _reroll_trace(RunScr)
	var d := _reroll_trace(_baseline("run_state.gd"))
	check(c == d, "solo run_state: patched reroll trace == 5e201b3 trace (%d steps)" % c.size())
	if c != d:
		print("  patched  ", c, "\n  baseline ", d)
	var rs = RunScr.new()
	root.add_child(rs)
	var pl := StubPlayer.new()
	root.add_child(pl)
	rs.player = pl
	rs.free_rerolls = 0
	pl.points = 500
	rs.open_offer(1)
	var got := []
	rs.rerolled.connect(func(cc, ff): got.append([cc, ff]))
	check(rs.reroll() and got == [[50, false]] and pl.points == 450 and not rs.reroll_pending and rs.last_refusal_reason == "", "solo reroll: instant + local (charged, rerolled before reroll() returns)")

	# --- solo: Net side is inert
	var door = DoorScr.new()
	door.door_id = &"D1"
	root.add_child(door)
	check(Net.world.door_interact(door, pl) == false and NetGate.door_interact(door, pl) == false, "solo: door_interact hook returns false (door handles itself)")
	check(Net.world.door_key("rustwell_foundry", "D1") == "rustwell_foundry/D1", "door key = map_id/door_id")

	# --- token spend: timeout -> refused; a late yes is refunded; refunds need a real charge
	var W = Net.world
	var answers: Array = []
	W._pending_spends[77] = {"cb": func(ok, why): answers.append([ok, why]); return true, "amount": 50, "reason": "reroll", "deadline_ms": Time.get_ticks_msec() - 1}
	W._process(0.016)
	check(answers == [[false, "timeout"]], "token spend: no answer within timeout_s -> cb(false, \"timeout\")")
	Net._points[1] = 0
	W._charged[1] = {77: 50} # the host did charge it (late)
	var r0: int = W.stats.refunds
	W._spend_answer(77, true)
	check(answers.size() == 1 and W.stats.refunds == r0 + 1 and Net.get_points(1) == 50, "token spend: late yes after the timeout is refunded, callback not called again")
	check(not W.host_refund(1, 77) and Net.get_points(1) == 50, "host refund: a token refunds once")
	check(not W.host_refund(1, 999) and not W.host_refund(5, 77), "host refund: unknown token / other peer -> ignored (no minting)")
	Net._points[1] = 100
	check(W.host_spend_token(1, 5, 60, "reroll") and Net.get_points(1) == 40 and W._charged[1].has(5), "host_spend_token charges + records the token")
	check(not W.host_spend_token(1, 6, 60, "reroll") and Net.get_points(1) == 40, "host_spend_token refuses an unaffordable charge")
	W._pending_spends[8] = {"cb": func(_ok, _why): return false, "amount": 30, "reason": "reroll", "deadline_ms": Time.get_ticks_msec() + 10000}
	W._charged[1][8] = 30
	W._spend_answer(8, true)
	check(Net.get_points(1) == 70, "token spend: a yes the caller didn't take (offer closed) is refunded")
	W.clear()
	Net._points.clear()
	check(W._pending_spends.is_empty() and W.doors_open.is_empty(), "world.clear drops pending spends + door state")

	# --- real maps: every MapDoor has its own explicit door_id (replication key; never the node path)
	for mp in ["res://maps/rustwell_foundry/rustwell_foundry.tscn", "res://maps/drowned_cannery/drowned_cannery.tscn"]:
		var inst = (load(mp) as PackedScene).instantiate()
		var ids: Array = []
		for n in inst.find_children("*", "", true, false):
			if n.get_script() == DoorScr:
				ids.append(str(n.door_id))
		var uniq := {}
		for i in ids:
			uniq[i] = true
		check(ids.size() > 0 and not ids.has("") and uniq.size() == ids.size(), "%s: doors %s all have unique door_ids" % [mp.get_file(), ids])
		inst.free()
	door.free()
	rs.free()
	pl.free()
	print("NET M13 TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
