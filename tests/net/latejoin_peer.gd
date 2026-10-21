extends SceneTree
## Multi-instance LATE JOIN test peer (Netz, phase 3a): the real main.tscn (rustwell_foundry by default; the door is the map's first door_id, or test door LJ1 on a doorless map such as arena).
## Run through tests/net/run_latejoin.sh: host Alice + Bob start a match; Alice opens that door, drops loot, starts round 1,
## Bob goes down; Dan joins mid-round (spectates from the full world snapshot, spectate camera cycles), the round
## clears (Dan comes in at the break); Eve joins in the break (straight in). Prints "NETTEST: PASS|FAIL [name] ...".
## Args (after --): --role=host|client --name=N --port=P [--map=rustwell_foundry] [--timeout=180]

var role := "client"
var pname := "Peer"
var port := 7777
var map_id := "rustwell_foundry"
var timeout_s := 330.0
var Net: Node
var _done := false
var checks: Array = []
var main: Node
var cmd_q: Array = []
var events: Array = [] ## [event_id, peer, data] from Net.game_event (Gooey ids)
var spect: Array = [] ## spectate_changed [peer, name]
var synced: Array = [] ## late_join_synced(spectating)
var snap_counts: Array = []
var party_states: Dictionary = {} ## name -> [states seen]
var door_id := "" ## the map's first buyable door (sorted door_ids); "LJ1" = a test door on a map without doors (arena)


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var k := a.get_slice("=", 0)
		var v := a.get_slice("=", 1) if a.contains("=") else ""
		match k:
			"--role": role = v
			"--name": pname = v
			"--port": port = int(v)
			"--map": map_id = v
			"--timeout": timeout_s = float(v)
	_run.call_deferred()


func check(ok: bool, what: String) -> bool:
	checks.append([ok, what])
	print("[%s] %s  %s" % [pname, "ok  " if ok else "FAIL", what])
	return ok


func finish(msg: String) -> void:
	if _done:
		return
	_done = true
	var bad := checks.filter(func(c): return not c[0])
	print("NETTEST: %s [%s] %s (%d checks, %d failed)%s" % ["PASS" if bad.is_empty() else "FAIL", pname, msg, checks.size(), bad.size(),
		"" if bad.is_empty() else " first failure: " + str(bad[0][1])])
	Net.leave_party()
	await _sleep(1.0)
	quit(0 if bad.is_empty() else 1)


func _sleep(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


func _wait(cond: Callable, s: float) -> bool:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _run() -> void:
	Engine.max_fps = 60
	Net = root.get_node("Net")
	var prog = root.get_node("Progress")
	prog.save_path = "user://progress_netlate_%s.cfg" % pname
	if "stash_path" in prog:
		prog.stash_path = "user://stash_netlate_%s.cfg" % pname
	Net.profile_path = "user://net_profile_netlate_%s.cfg" % pname
	Net.load_profile()
	Net.set_local_profile(pname)
	Net.auto_change_scene = true
	Net.game_event.connect(_on_game_event)
	Net.match_starting.connect(func(_m, _d): _load_t0 = Time.get_ticks_msec())
	Net.late_join_synced.connect(func(sp): synced.append(sp))
	Net.world.snapshot_applied.connect(func(nz, nd): snap_counts.append([nz, nd]))
	Net.match_players.spectate_changed.connect(func(p, n): spect.append([p, n]))
	Net.party_changed.connect(func(party):
		for e in party:
			var arr: Array = party_states.get_or_add(str(e.name), [])
			if arr.is_empty() or arr.back() != str(e.get("state", "")):
				arr.append(str(e.get("state", ""))))
	_watchdog()
	if role == "host":
		await _host()
	else:
		await _client()


func _watchdog() -> void:
	await _sleep(timeout_s)
	if not _done:
		check(false, "timeout after %.0f s" % timeout_s)
		finish("timeout")


var _load_t0 := 0
func _find_main() -> bool:
	main = current_scene if current_scene and current_scene.has_node("Player") else null
	if main != null and Net.is_match_running() and _load_t0 >= 0:
		print("[%s] match running after %.1f s" % [pname, (Time.get_ticks_msec() - _load_t0) / 1000.0])
		_load_t0 = -1
	return main != null and Net.is_match_running()


func _protect(on: bool) -> void:
	if main and main.player:
		main.player.set("invulnerable_t", 99999.0 if on else 0.0)


## Every peer, right after load: the door this test buys. The map's own door_ids (rustwell D1..D6, lockout D1);
## a map without MapDoors (the arena in main.tscn) gets the same test door "LJ1" on every peer, and the late-map-piece
## path (apply_doors) opens it if the host's door state is already in.
func _setup_door() -> Node:
	var ids: Array = []
	for d in get_root().get_tree().get_nodes_in_group("map_doors"):
		if str(d.door_id) != "":
			ids.append(str(d.door_id))
	ids.sort()
	if not ids.is_empty():
		door_id = str(ids[0])
		print("[%s] door: %s (map door_ids %s)" % [pname, door_id, ids])
		return _door(door_id)
	door_id = "LJ1"
	var d = load("res://maps/common/map_door.gd").new()
	d.name = "TestDoor_LJ1"
	d.door_id = &"LJ1"
	d.cost = 10
	(main.map if main.get("map") else main).add_child(d)
	d.global_position = Vector3(220, -50, 220)
	print("[%s] door: %s (map %s has no MapDoors: test door)" % [pname, door_id, map_id])
	Net.world.apply_doors()
	return d


func _door(id: String) -> Node:
	for d in get_root().get_tree().get_nodes_in_group("map_doors"):
		if str(d.door_id) == id:
			return d
	return null


func _peer(n: String) -> int:
	for e in Net.get_party():
		if str(e.name) == n:
			return int(e.peer_id)
	return 0


func _entry(n: String) -> Dictionary:
	for e in Net.get_party():
		if str(e.name) == n:
			return e
	return {}


func _evs(id: String, peer: int = -1) -> Array:
	return events.filter(func(e): return str(e[0]) == id and (peer < 0 or int(e[1]) == peer))


func _on_game_event(ev: StringName, peer_id: int, data: Dictionary) -> void:
	events.append([str(ev), peer_id, data])
	if role == "host":
		return
	if ev == &"t_finish":
		cmd_q.append({"op": "finish"})
	elif ev == &"t_cmd" and (peer_id == Net.local_peer_id() or peer_id == 0):
		cmd_q.append(data)


# ================================================================== host
func _host() -> void:
	NetConfig.override({"downed.bleed_out_s": 120.0}) # Bob stays down while Dan loads
	if not check(Net.host_party(port, false) == OK, "host_party on %d" % port):
		return finish("no host")
	if not await _wait(func(): return Net.party_size() == 2 and Net.can_start(), 30.0):
		check(false, "Bob joined + ready")
		return finish("lobby")
	Net.select_map(map_id)
	check(Net.start_match(), "start_match on %s" % map_id)
	if not check(await _wait(_find_main, 90.0), "match scene loaded (match_started)"):
		return finish("load")
	main.field_cards_enabled = false
	_protect(true)
	var P = Net.match_players
	var W = Net.world
	var bob := _peer("Bob")
	await _sleep(1.0)
	# --- world before the late join: D1 bought, a drop on the floor, round 1 running, Bob down
	var d1 := _setup_door()
	if check(d1 != null, "host: door %s on %s" % [door_id, map_id]):
		Net.award_points(1, int(d1.cost), "test")
		await _sleep(0.3)
		d1.interact(main.player)
		check(d1.is_open and W.doors_open.has("%s/%s" % [map_id, door_id]), "host: bought %s (key %s/%s)" % [door_id, map_id, door_id])
	var item = root.get_node("GearDB").roll_weapon("auto_rifle")
	W.host_drop(item, main._player_spawn.origin + Vector3(0, 0.3, 2), false)
	var drop_id: String = W.drops.keys().back()
	main._break_timer = 0.1
	check(await _wait(func(): return main.zombies_root.get_child_count() >= 3 and Net.round_phase == "combat", 20.0), "host: round 1 on, zombies up")
	main._to_spawn = 0 # no more spawns: the round ends when we kill these
	Net.broadcast_event(&"t_cmd", bob, {"op": "die"})
	check(await _wait(func(): return P.life_of(bob) == "downed", 5.0), "host: Bob downed before the late join")
	check(_evs("player_downed", bob).size() == 1 and float(_evs("player_downed", bob)[0][2].get("bleed_out_s", 0)) > 0.0, "host: game_event player_downed (Bob, bleed_out_s)")
	check(str(_entry("Bob").get("state")) == "downed" and str(_entry("Bob").get("life")) == "downed", "host: Bob's party entry state / life = downed")
	await _sleep(0.5)
	# --- Dan joins mid-round
	print("LATE_DAN")
	if not check(await _wait(func(): return _peer("Dan") != 0 and P.life_of(_peer("Dan")) == "dead", 150.0), "host: Dan joined mid-match and spectates (life dead)"):
		return finish("dan")
	var dan := _peer("Dan")
	await _sleep(0.5)
	var e_dan := _entry("Dan")
	check(str(e_dan.get("state")) == "spectating" and bool(e_dan.get("late_join", false)) and P.late_spectators.has(dan), "host: Dan's entry state spectating, late_join (%s)" % [e_dan])
	check(P.avatar(dan) != null, "host: an avatar for Dan")
	check(_evs("player_joined_late", dan).size() == 1 and bool(_evs("player_joined_late", dan)[0][2].get("spectating")), "host: game_event player_joined_late (spectating)")
	check(Net.get_points(dan) == int(NetConfig.get_value("points.late_join_start")), "host: Dan's ledger = points.late_join_start (%d)" % Net.get_points(dan))
	var znames: Array = []
	var zhp: Dictionary = {}
	for z in main.zombies_root.get_children():
		if not bool(z.get("_dead")):
			znames.append(str(z.name))
			zhp[str(z.name)] = float(z.health)
	Net.broadcast_event(&"t_cmd", dan, {"op": "check_world", "zombies": znames, "hp": zhp, "drop": drop_id, "round": main.current_round,
		"host_points": Net.get_points(1), "bob": bob})
	Net.broadcast_event(&"t_cmd", bob, {"op": "check_dan", "dan": dan})
	await _sleep(1.5)
	# --- revive Bob (host stands on him) -> Dan's spectate can cycle between Alice and Bob
	main.player.global_position = P.avatar(bob).global_position + Vector3(0.6, 0, 0)
	P.set_revive_hold(bob, true)
	check(await _wait(func(): return P.life_of(bob) == "alive", 8.0), "host: revived Bob")
	P.set_revive_hold(bob, false)
	check(_evs("player_revived", bob).size() == 1 and int(_evs("player_revived", bob)[0][2].get("reviver")) == 1, "host: game_event player_revived (reviver 1)")
	var prog := _evs("revive_progress", bob)
	check(prog.size() >= 3 and bool(prog[0][2].active) and not bool(prog[-1][2].active) and is_equal_approx(float(prog[-1][2].progress), 1.0)
		and prog.any(func(e): return float(e[2].progress) > 0.0 and float(e[2].progress) < 1.0), "host: revive_progress start / mid / done (%d events)" % prog.size())
	await _sleep(0.5)
	Net.broadcast_event(&"t_cmd", dan, {"op": "cycle", "bob": bob})
	await _sleep(1.5)
	# --- clear the round -> break -> Dan comes in
	for z in main.zombies_root.get_children():
		if z.has_method("take_damage") and not bool(z.get("_dead")):
			z.take_damage(999999.0, z.global_position, false, main.player)
	check(await _wait(func(): return Net.round_phase == "break", 10.0), "host: round 1 cleared -> break")
	main._break_timer = 9999.0 # hold the break for Eve
	check(await _wait(func(): return P.life_of(dan) == "alive", 5.0), "host: Dan in at the break (alive)")
	check(_evs("player_respawned", dan).size() == 1 and bool(_evs("player_respawned", dan)[0][2].get("late_join")), "host: game_event player_respawned (late_join)")
	await _sleep(0.3)
	check(str(_entry("Dan").get("state")) == "in_match" and not _entry("Dan").has("late_join") and P.late_spectators.is_empty(), "host: Dan's entry in_match, late_join cleared")
	Net.broadcast_event(&"t_cmd", dan, {"op": "check_in"})
	await _sleep(1.0)
	# --- Eve joins in the break: straight in
	print("LATE_EVE")
	if not check(await _wait(func(): return _peer("Eve") != 0 and Net._loaded.has(_peer("Eve")) and not Net._late.has(_peer("Eve")), 150.0), "host: Eve joined in the break"):
		return finish("eve")
	var eve := _peer("Eve")
	await _sleep(0.5)
	check(P.life_of(eve) == "alive" and not P.late_spectators.has(eve) and str(_entry("Eve").get("state")) == "in_match", "host: Eve alive straight away (break join)")
	check(_evs("player_joined_late", eve).size() == 1 and not bool(_evs("player_joined_late", eve)[0][2].get("spectating")), "host: player_joined_late (not spectating)")
	check(Net.match_players.avatars.size() == 3, "host: avatars for Bob, Dan, Eve (%d)" % Net.match_players.avatars.size())
	check(not Net._offers_closed.is_empty() and Net._offers_closed.has(dan) and Net._offers_closed.has(eve), "host: late joiners never block Field Card rounds")
	await _sleep(1.0)
	Net.broadcast_event(&"t_finish", 0, {})
	await _sleep(3.0)
	finish("host late-join scenario")


# ================================================================== clients
func _client() -> void:
	if not check(Net.join_by_address("127.0.0.1", port) == OK, "join"):
		return finish("join")
	if pname == "Bob":
		if not await _wait(func(): return Net.state == Net.State.IN_LOBBY, 15.0):
			check(false, "in lobby")
			return finish("lobby")
		Net.set_ready(true)
	if not check(await _wait(_find_main, 150.0), "match scene loaded + match_started"):
		return finish("load")
	_protect(true)
	_setup_door()
	while not _done:
		if not cmd_q.is_empty():
			await _do(cmd_q.pop_front())
		await process_frame


func _do(c: Dictionary) -> void:
	var P = Net.match_players
	var me: int = Net.local_peer_id()
	match str(c.op):
		"die":
			_protect(false)
			main.player.take_damage(99999.0, null)
			await _sleep(0.3)
			_protect(true)
		"check_world": # Dan, right after joining mid-round
			check(synced == [true], "dan: late_join_synced(spectating = true) (%s)" % [synced])
			check(snap_counts.size() == 1 and int(snap_counts[0][0]) >= c.zombies.size(), "dan: world snapshot applied (%s)" % [snap_counts])
			var mine: Array = []
			var hp_ok := true
			for z in main.zombies_root.get_children():
				mine.append(str(z.name))
				if c.hp.has(str(z.name)):
					hp_ok = hp_ok and absf(float(z.health) - float(c.hp[str(z.name)])) < 1.0
			check(c.zombies.all(func(n): return n in mine), "dan: the host's live zombies are here (%s)" % [c.zombies])
			var z0 = main.zombies_root.get_node_or_null(NodePath(str(c.zombies[0]))) if c.zombies.size() else null
			check(z0 != null and z0.has_meta("net_puppet") and hp_ok, "dan: snapshot zombies are puppets with the host's hp")
			var d1 := _door(door_id)
			check(d1 != null and d1.is_open and Net.world.doors_open.has("%s/%s" % [map_id, door_id]), "dan: %s open from the M13 door state (key %s/%s)" % [door_id, map_id, door_id])
			check(Net.world.drops.has(str(c.drop)) and main.pickups_root.has_node(NodePath(str(c.drop))), "dan: the untaken drop %s is on the floor" % c.drop)
			check(main.current_round == int(c.round) and Net.round_phase == "combat" and Net.current_round == int(c.round), "dan: round %d, phase combat" % int(c.round))
			check(Net.get_points(1) == int(c.host_points) and int(main.player.points) == int(NetConfig.get_value("points.late_join_start")), "dan: everyone's points + own wallet %d (late_join_start)" % int(main.player.points))
			check(P.life_of(int(c.bob)) == "downed" and P.avatar(int(c.bob)) != null and P.avatar(int(c.bob)).downed, "dan: Bob is down here too (life sync)")
			check(P.life_of(me) == "dead" and bool(main.player.dead) and not bool(main.player.input_enabled), "dan: I'm parked (dead, no input) until the break")
			check(P.avatars.size() == 2 and P.avatars.has(1), "dan: avatars for Alice + Bob")
			await _wait(func(): return P.spectate.active, 5.0)
			await _sleep(0.3)
			var cam: Camera3D = main.get_viewport().get_camera_3d()
			check(P.spectate.active and cam == P.spectate.camera and P.spectate.target_peer == 1, "dan: spectate camera on, watching Alice (the only one standing)")
			check(spect.size() >= 1 and spect[-1] == [1, "Alice"], "dan: spectate_changed(1, Alice) (%s)" % [spect])
			check(P.spectate.camera.global_position.distance_to(P.avatar(1).global_position) < 6.0, "dan: the camera sits behind Alice")
			check(_evs("player_joined_late", me).size() == 1, "dan: player_joined_late about me")
			check(str(_entry("Dan").get("state")) == "spectating" and str(_entry("Bob").get("state")) == "downed", "dan: party states spectating (me) / downed (Bob)")
		"check_dan": # Bob
			var dan := int(c.dan)
			check(P.avatar(dan) != null and P.life_of(dan) == "dead", "bob: Dan's avatar appeared, Dan spectating")
			check(str(_entry("Dan").get("state")) == "spectating", "bob: Dan's party entry spectating")
			check(_evs("player_joined_late", dan).size() == 1 and _evs("player_downed", me).size() == 1, "bob: player_joined_late + player_downed events")
			var cam: Camera3D = main.get_viewport().get_camera_3d()
			check(P.spectate.active and cam == P.spectate.camera and P.spectate.target_peer == 1, "bob: downed -> spectate camera (spectate.when_downed) on Alice")
		"cycle": # Dan, after Bob's revive
			var bob := int(c.bob)
			var a: int = P.spectate.cycle(1)
			var b: int = P.spectate.cycle(1)
			var back: int = P.spectate.cycle(-1)
			check(P.spectate.candidates() == [1, bob] and a != b and [a, b].has(1) and [a, b].has(bob) and back == a, "dan: cycle through Alice / Bob (%d, %d, back %d)" % [a, b, back])
			check(spect.any(func(s): return s[0] == bob and s[1] == "Bob"), "dan: spectate_changed named Bob")
		"check_in": # Dan, at the break
			check(P.life_of(me) == "alive" and not bool(main.player.dead) and bool(main.player.input_enabled) and int(main.player.health) == int(main.player.max_health), "dan: in at the break, full HP")
			await _sleep(0.3)
			var cam: Camera3D = main.get_viewport().get_camera_3d()
			check(not P.spectate.active and cam == main.player.camera and spect.back() == [0, ""], "dan: spectate off, my own camera back")
			check(_evs("player_respawned", me).size() == 1 and str(_entry("Dan").get("state")) == "in_match", "dan: player_respawned, entry in_match")
			check(party_states.get("Dan", []).has("spectating") and party_states.get("Bob", []).has("downed"), "dan: party_changed carried spectating / downed (%s)" % [party_states])
		"finish":
			await _client_final()


func _client_final() -> void:
	var P = Net.match_players
	if pname == "Eve":
		check(synced == [false], "eve: late_join_synced(spectating = false)")
		check(P.life_of(Net.local_peer_id()) == "alive" and not bool(main.player.dead) and not P.spectate.active, "eve: straight in during the break, no spectate")
		check(Net.round_phase == "break" and main.current_round == 1, "eve: round 1 break")
		check(_door(door_id) != null and _door(door_id).is_open, "eve: %s open" % door_id)
		check(P.avatars.size() == 3, "eve: avatars for Alice, Bob, Dan (%d)" % P.avatars.size())
	if pname == "Bob":
		check(P.avatars.size() == 3 and P.avatars.has(_peer("Eve")), "bob: avatars for Alice, Dan, Eve")
		check(not P.spectate.active, "bob: spectate off after the revive")
	if pname == "Dan":
		check(P.avatars.has(_peer("Eve")), "dan: Eve's avatar appeared")
	finish("%s late-join checks" % pname)
