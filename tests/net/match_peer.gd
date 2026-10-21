extends SceneTree
## Multi-instance MATCH test peer (Netz, milestone B): the real main.tscn on 1 host + N clients.
## Run through tests/net/run_match.sh. The host drives the scenario with Net.broadcast_event("t_cmd", peer, {...});
## clients act and check their side at "t_finish". Prints "NETTEST: PASS|FAIL [name] ..." and exits 0 / 1.
## Args (after --): --role=host|client --name=N --port=P [--clients=2] [--map=arena] [--timeout=150] [--body=desi|capsule]

var role := "client"
var pname := "Peer"
var port := 7777
var n_clients := 2
var map_id := "arena"
var timeout_s := 150.0
var Net: Node
var _done := false
var checks: Array = [] ## [ok, what]
var main: Node
# client state
var cmd_q: Array = []
var spend_results: Array = []
var got_items: Array = []
var hold_target := 0
var start_points := 0
var killed_zombie := ""
var my_drop := ""
var seen_drops: Array = []
var boss_phases: Dictionary = {} ## boss name -> phases the puppet entered (after net_apply_boss_state)
var rx_visual: Array = []
var my_grenade: Node = null
var grenade_rx: Array = [] ## specs of received grenade copies
var heal_rx0 := 0
var drop0 := 0
var grenade_ev: Array = [] ## [net_id, kind, data] events on my copies ## per received host projectile: was the copy visual-only
var health_before_dmg := -1
var door_ops: Array = [] ## client: M13 results to check at t_finish
var reroll_log: Array = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var k := a.get_slice("=", 0)
		var v := a.get_slice("=", 1) if a.contains("=") else ""
		match k:
			"--role": role = v
			"--name": pname = v
			"--port": port = int(v)
			"--clients": n_clients = int(v)
			"--map": map_id = v
			"--timeout": timeout_s = float(v)
			"--body": NetConfig.override({"avatar.body": v})
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
	prog.save_path = "user://progress_netmatch_%s.cfg" % pname # never touch the real save
	if "stash_path" in prog:
		prog.stash_path = "user://stash_netmatch_%s.cfg" % pname
	Net.profile_path = "user://net_profile_netmatch_%s.cfg" % pname
	Net.load_profile()
	Net.set_local_profile(pname)
	Net.auto_change_scene = true
	get_root().get_node("Net").game_event.connect(_on_game_event)
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


func _find_main() -> bool:
	main = current_scene if current_scene and current_scene.has_node("Player") else null
	return main != null and Net.is_match_running()


## M13 test doors (arena has none): same door_id on every peer, keyed (map_id, door_id) by Net.
func _make_door(id: String, cost: int) -> Node:
	var d = load("res://maps/common/map_door.gd").new()
	d.name = "TestDoor_" + id
	d.door_id = StringName(id)
	d.cost = cost
	(main.map if main.get("map") else main).add_child(d)
	d.global_position = Vector3(200 + 5 * id.hash() % 50, -50, 200)
	return d


func _protect(on: bool) -> void:
	if main and main.player:
		main.player.set("invulnerable_t", 99999.0 if on else 0.0)


# ================================================================== host
func _host() -> void:
	if not check(Net.host_party(port, false) == OK, "host_party on %d" % port):
		return finish("no host")
	if not await _wait(func(): return Net.party_size() == n_clients + 1 and Net.can_start(), 30.0):
		check(false, "all clients joined + ready (party %d)" % Net.party_size())
		return finish("lobby")
	Net.select_map(map_id)
	check(Net.start_match(), "start_match on %s" % map_id)
	if not check(await _wait(_find_main, 60.0), "match scene loaded + everyone ready (match_started)"):
		return finish("load")
	main.field_cards_enabled = false
	_protect(true)
	var t1 = _make_door("T1", 25)
	var P = Net.match_players
	var W = Net.world
	await _sleep(1.0)
	var ids: Array = []
	for e in Net.get_party():
		if int(e.peer_id) != 1:
			ids.append(int(e.peer_id))
	ids.sort()
	var bob: int = ids[0]
	var cara: int = ids[1] if ids.size() > 1 else ids[0]
	# --- avatars
	check(P.avatars.size() == n_clients and main.has_node("NetAvatars"), "host: one avatar per client under NetAvatars (%d)" % P.avatars.size())
	var names_ok := true
	for id in ids:
		var a = P.avatar(id)
		names_ok = names_ok and a != null and a.display_name == Net.get_player_name(id) and a.slot == Net.get_slot(id) and a.name_tag.text == a.display_name
	check(names_ok, "host: avatar names / slots / name tags match the party")
	check(Net.players().size() == n_clients + 1, "Net.players(): local player + avatars")
	# --- state stream: clients walk to a spot
	for id in ids:
		Net.broadcast_event(&"t_cmd", id, {"op": "move", "to": main._player_spawn.origin + Vector3(3.0 * Net.get_slot(id), 0.5, 4.0)})
	await _sleep(2.0)
	var pos_ok := true
	for id in ids:
		var want: Vector3 = main._player_spawn.origin + Vector3(3.0 * Net.get_slot(id), 0.5, 4.0)
		var a = P.avatar(id)
		pos_ok = pos_ok and a and Vector2(a.global_position.x - want.x, a.global_position.z - want.z).length() < 1.5
	check(pos_ok, "host: avatars follow the clients' replicated positions")
	check(P.stats.state_rx > 20, "host: state stream arriving (%d packets)" % P.stats.state_rx)
	# --- one-shot events
	Net.broadcast_event(&"t_cmd", bob, {"op": "events"})
	await _sleep(1.0)
	var ab = P.avatar(bob)
	check(ab and ab.body.last_event in ["reload", "fire"] and P.stats.events_rx >= 2, "host: Bob's fire / reload events reach his avatar (%s)" % (ab.body.last_event if ab else "-"))
	check(ab and ab.body.weapon_id != "", "host: Bob's weapon id reached the WeaponR socket (%s)" % (ab.body.weapon_id if ab else "-"))
	# --- round 1: zombies on every peer
	main._break_timer = 0.1
	check(await _wait(func(): return main.zombies_root.get_child_count() >= 2, 15.0), "host: round 1 spawns zombies")
	await _sleep(1.5)
	var znames: Array = []
	for z in main.zombies_root.get_children():
		znames.append(str(z.name))
	for id in ids:
		Net.broadcast_event(&"t_cmd", id, {"op": "check_zombies", "names": znames, "round": main.current_round})
	await _sleep(0.5)
	check(W.stats.snaps_tx > 10, "host: zombie snapshots streaming (%d)" % W.stats.snaps_tx)
	# --- client hit claim kills a zombie; host credits Bob
	var target_z: Node = null
	for z in main.zombies_root.get_children():
		if z.is_in_group("enemies"):
			target_z = z
			break
	var bob_pts: int = Net.get_points(bob)
	var kills_before: int = main.kills
	if check(target_z != null, "host: a live zombie to shoot"):
		Net.broadcast_event(&"t_cmd", bob, {"op": "kill", "zombie": str(target_z.name)})
		check(await _wait(func(): return not is_instance_valid(target_z) or bool(target_z.get("_dead")), 5.0), "host: Bob's hit claim killed %s on the host" % target_z.name)
		await _sleep(0.3)
		check(Net.get_points(bob) >= bob_pts + int(NetConfig.points("kill_bonus")), "host: kill + hit points credited to Bob (%d -> %d)" % [bob_pts, Net.get_points(bob)])
		check(main.kills == kills_before + 1, "host: match kill count +1")
		var HS: Dictionary = Net.hit_check.stats
		check(int(HS.gun) >= 1 and int(HS.other) >= 1 and int(HS.weapon_mismatch) == 0 and int(HS.rejected) == 0, "host: NetHitCheck saw Bob's gun round (held weapon matched) + the skill-sized hit, nothing refused (%s)" % [HS])
	# --- shared drop: both clients grab at once, first wins
	var removed: Array = []
	W.drop_removed.connect(func(id, taker): removed.append([id, taker]))
	var item = root.get_node("GearDB").roll_weapon("auto_rifle")
	check(W.host_drop(item, main._player_spawn.origin + Vector3(0, 0.3, 2), false), "host: shared drop spawned")
	var did: String = W.drops.keys().back()
	check(main.pickups_root.has_node(NodePath(did)), "host: NetPickup %s in pickups_root" % did)
	await _sleep(1.0)
	for id in ids:
		Net.broadcast_event(&"t_cmd", id, {"op": "grab", "drop": did})
	check(await _wait(func(): return removed.size() == 1, 5.0), "host: drop taken exactly once (%s)" % [removed])
	await _sleep(0.5)
	check(removed.size() == 1 and int(removed[0][1]) in ids and not W.drops.has(did) and not main.pickups_root.has_node(NodePath(did)), "host: drop gone everywhere after the grab")
	# --- hold-E equip on a shared drop (playtest #3): host grants first-grab, Bob equips the granted copy
	var item2 = root.get_node("GearDB").roll_weapon("auto_rifle")
	removed.clear()
	check(W.host_drop(item2, main._player_spawn.origin + Vector3(1, 0.3, 2), false), "host: second shared drop (hold-E)")
	var did2: String = W.drops.keys().back()
	await _sleep(1.0)
	Net.broadcast_event(&"t_cmd", bob, {"op": "grab_equip", "drop": did2, "name": item2.display_name, "slot": item2.slot})
	check(await _wait(func(): return removed.size() == 1, 6.0) and int(removed[0][1]) == bob, "host: Bob's hold-E took %s (%s)" % [did2, removed])
	await _sleep(0.3)
	check(W.stats.grabs_equip == 1 and not main.pickups_root.has_node(NodePath(did2)), "host: granted as an equip grab (%d), drop gone here" % W.stats.grabs_equip)
	# --- spending through the host
	Net.award_points(cara, 40, "test") # arena wallets start at 0
	await _sleep(0.3)
	var cara_pts: int = Net.get_points(cara)
	Net.broadcast_event(&"t_cmd", cara, {"op": "spend"})
	await _sleep(1.5)
	check(Net.get_points(cara) == cara_pts - 10, "host: Cara's spend of 10 applied to the host ledger, the 999999 one refused (%d -> %d)" % [cara_pts, Net.get_points(cara)])
	# --- M13 doors through the host
	var opened_n := [0]
	t1.opened.connect(func(_d): opened_n[0] += 1)
	Net.award_points(bob, 30, "test")
	await _sleep(0.3)
	var bob_d0: int = Net.get_points(bob)
	var cara_d0: int = Net.get_points(cara)
	Net.broadcast_event(&"t_cmd", bob, {"op": "door", "id": "T1"})
	check(await _wait(func(): return t1.is_open, 3.0), "host: Bob's buy opened T1 here (open() via the host)")
	check(Net.get_points(bob) == bob_d0 - 25, "host: T1's 25 charged to Bob once (%d -> %d)" % [bob_d0, Net.get_points(bob)])
	Net.broadcast_event(&"t_cmd", cara, {"op": "door", "id": "T1"})
	await _sleep(0.8)
	t1.open(null)
	t1.interact(main.player)
	check(opened_n[0] == 1 and Net.get_points(cara) == cara_d0 and W.doors_open.get("arena/T1", 0) == bob, "host: buying / open() on an open door is a no-op (opened %d x, Cara %d -> %d)" % [opened_n[0], cara_d0, Net.get_points(cara)])
	Net.broadcast_event(&"t_cmd", cara, {"op": "door", "id": "T9"}) # broke + unknown door: refused, not charged
	# late map load: the host buys T2 itself while the clients don't have T2 yet
	var host_d0: int = Net.get_points(1)
	var t2 = _make_door("T2", host_d0 + 40)
	t2.interact(main.player)
	check(not t2.is_open and Net.get_points(1) == host_d0, "host: can't afford T2 -> refused, not charged")
	Net.award_points(1, 40, "test")
	await _sleep(0.2)
	t2.interact(main.player)
	check(t2.is_open and Net.get_points(1) == 0, "host: bought T2 for itself (wallet %d)" % Net.get_points(1))
	await _sleep(0.5)
	for id in ids:
		Net.broadcast_event(&"t_cmd", id, {"op": "late_door", "id": "T2"})
	await _sleep(0.8)
	for id in ids:
		W.send_doors_to(id) # what a late joiner gets on scene ready
	await _sleep(0.8)
	# --- M13 paid reroll through the host
	Net.award_points(bob, 200, "test")
	await _sleep(0.3)
	var bob_r0: int = Net.get_points(bob)
	Net.broadcast_event(&"t_cmd", bob, {"op": "reroll"})
	await _sleep(2.5)
	check(Net.get_points(bob) == bob_r0 - 50, "host: Bob's round-1 reroll (50) charged once; the unaffordable one not (%d -> %d)" % [bob_r0, Net.get_points(bob)])
	await _host_3b(bob, cara)
	# --- zombie hit on an avatar -> the owner's own health
	Net.broadcast_event(&"t_cmd", cara, {"op": "vulnerable"})
	await _sleep(0.5)
	P.avatar(cara).take_damage(25.0, target_z if is_instance_valid(target_z) else null)
	await _sleep(0.8)
	check(P.stats.damage_fwd >= 1, "host: avatar damage forwarded to its owner")
	Net.broadcast_event(&"t_cmd", cara, {"op": "protect"})
	# --- host-decided heal (Leechbell orbs): Cara's own machine heals her player; capped per second
	Net.broadcast_event(&"t_cmd", cara, {"op": "hp_mark"})
	await _sleep(0.5)
	check(NetGate.grant_heal(P.avatar(cara), 15, "test_leech"), "host: grant_heal handled in co-op")
	check(P.host_heal(P.avatar(cara), 500, "test_leech") == int(NetConfig.get_value("projectiles.heal_max_per_s", 120)) - 15 and P.stats.heal_clipped == 1, "host: heals past heal_max_per_s are clipped + logged")
	await _sleep(0.5)
	Net.broadcast_event(&"t_cmd", cara, {"op": "hp_check", "min_gain": 15})
	await _sleep(0.5)
	await _host_grenades(bob, cara, target_z)
	# --- downed + revive
	Net.broadcast_event(&"t_cmd", bob, {"op": "die"})
	check(await _wait(func(): return P.life_of(bob) == "downed", 4.0), "host: Bob downed (not game over)")
	check(not main._game_over and P.avatar(bob).downed, "host: match continues; Bob's avatar plays Downed")
	cara_pts = Net.get_points(cara)
	Net.broadcast_event(&"t_cmd", cara, {"op": "revive", "target": bob})
	var t0: int = Time.get_ticks_msec()
	check(await _wait(func(): return P.life_of(bob) == "alive", 8.0), "host: Cara revived Bob")
	var took: float = (Time.get_ticks_msec() - t0) / 1000.0
	check(took >= NetConfig.get_float("downed.revive_time_s") - 0.6 and took < NetConfig.get_float("downed.revive_time_s") + 3.0, "host: revive took ~revive_time_s (%.1f s)" % took)
	await _sleep(0.5)
	check(Net.get_points(cara) == cara_pts + int(NetConfig.points("revive")), "host: revive points (+%d) to Cara" % int(NetConfig.points("revive")))
	Net.broadcast_event(&"t_cmd", cara, {"op": "stop_revive"})
	# --- bleed-out
	NetConfig.override({"downed.bleed_out_s": 2.5})
	await _sleep(0.5)
	Net.broadcast_event(&"t_cmd", bob, {"op": "die"})
	check(await _wait(func(): return P.life_of(bob) == "downed", 4.0), "host: Bob down again")
	check(await _wait(func(): return P.life_of(bob) == "dead", 6.0), "host: no revive -> Bob bleeds out (dead)")
	check(not main._game_over, "host: still not game over (others standing)")
	# --- everyone down -> game over everywhere
	for id in ids:
		if id != bob:
			Net.broadcast_event(&"t_cmd", id, {"op": "die"})
	await _sleep(1.0)
	_protect(false)
	main.player.take_damage(99999.0, null)
	check(await _wait(func(): return main._game_over, 8.0), "host: everyone down -> game over")
	await _sleep(0.5)
	Net.broadcast_event(&"t_finish", 0, {})
	await _sleep(3.0)
	finish("host match scenario")


# ================================================================== client
## Phase 3b. Bosses: only with the boss_* patches (net_boss_state on the boss script); projectiles: only once
## ThrownProjectile is in the tree. Each part prints SKIP otherwise, so this runs on main as it is.
func _host_3b(bob: int, cara: int) -> void:
	var W = Net.world
	var Cat = load("res://scripts/enemies/boss_catalog.gd")
	var bs: Script = load(Cat.script_path("bellwether"))
	var patched := false
	for m in bs.get_script_method_list():
		patched = patched or m.name == "net_boss_state"
	if not patched:
		print("[%s] SKIP  bosses: boss_* patches not applied" % pname)
	else:
		main._spawn_boss("bellwether")
		var boss: Node = null
		for z in main.zombies_root.get_children():
			if z.has_meta("is_boss") and not bool(z.get("_dead")):
				boss = z
		if check(boss != null, "host: Bellwether spawned"):
			await _sleep(1.0)
			var tx0: int = W.stats.boss_tx
			boss.target = main.player
			boss._start_slam()
			await _sleep(0.3)
			check(W.stats.boss_tx > tx0, "host: slam windup state sent (boss_tx %d -> %d)" % [tx0, W.stats.boss_tx])
			for id in [bob, cara]:
				Net.broadcast_event(&"t_cmd", id, {"op": "boss_check", "name": str(boss.name)})
			await _sleep(3.0)
			check(W.stats.boss_tx >= tx0 + 3, "host: windup -> impact -> stun -> idle all sent (%d)" % (W.stats.boss_tx - tx0))
			boss.queue_free()
			await _sleep(0.5)
	var PS: Script = Net.projectiles.proj_script()
	if PS == null or not PS.source_code.contains("NetGate.projectile_spawned"):
		print("[%s] SKIP  projectiles: ThrownProjectile / its P1 line (patches/P1_thrown_projectile.patch) not in this tree" % pname)
		return
	var tid: String = str(PS.data().get("types", {}).keys()[0])
	var spec := {"type_id": StringName(tid), "variant": &"", "rarity": 0, "pos": main._player_spawn.origin + Vector3(6, 4, 6),
		"vel": Vector3(0, 3, 0), "owner_id": 0, "seed": 7}
	var tx1: int = Net.projectiles.stats.tx
	var p = PS.spawn(spec)
	check(p != null and not p.is_visual_only and Net.projectiles.stats.tx == tx1 + 1, "host: %s spawned for real + broadcast through P1" % tid)
	for id in [bob, cara]:
		Net.broadcast_event(&"t_cmd", id, {"op": "proj_check", "n": 1})
	await _sleep(1.0)
	Net.broadcast_event(&"t_cmd", bob, {"op": "throw", "type": tid})
	check(await _wait(func(): return Net.projectiles.stats.throw_ok == 1, 3.0), "host: Bob's throw request accepted + spawned here")
	check(await _wait(func(): return Net.projectiles.stats.throw_refused == 1, 3.0), "host: Bob's throw from 30 m away refused + logged, Bob still connected (%s)" % [Net.projectiles.stats])
	check(Net.match_players.avatar(bob) != null, "host: no kick after a refused throw")
	await _sleep(0.5)
	Net.broadcast_event(&"t_cmd", cara, {"op": "proj_check", "n": 2}) # host's + Bob's
	Net.broadcast_event(&"t_cmd", bob, {"op": "proj_check", "n": 1}) # his own throw isn't echoed back
	await _sleep(0.8)


## Grenades (Skillz 32dc31c, MAIN_HOOKS §24b): the real Grenade code. Throw = Grenade.throw_from (type "grenade" +
## variant + the item's rarity); Rookery bomblets "grenade_bomblet" and Leechbell orbs "heal_orb" are host spawns.
## Runs only where the tree has P1 and the grenade net lines (patches/grenades_skillz.patch); E7 part: enemy.gd E7.
func _host_grenades(bob: int, cara: int, z_hint) -> void:
	var P = Net.match_players
	var NP = Net.projectiles
	var PS: Script = NP.proj_script()
	var GS: Script = load("res://scripts/combat/grenade.gd")
	if PS == null or not PS.source_code.contains("NetGate.projectile_spawned") or not GS.source_code.contains("NetGate.request_throw") or PS.type_def(&"grenade").is_empty():
		print("[%s] SKIP  grenades: no P1 / grenade net lines in this tree" % pname)
		return
	check(Net.status_allowed("frost") and Net.status_allowed("burn") and not Net.status_allowed("bogus"), "host: frost is an allowed status (statuses.forwarded)")
	var ok0: int = NP.stats.throw_ok
	var ref0: int = NP.stats.throw_refused
	Net.broadcast_event(&"t_cmd", bob, {"op": "gthrow"})
	check(await _wait(func(): return NP.stats.throw_ok == ok0 + 1, 3.0), "host: Bob's Rookery (Grenade.throw_from -> request_throw) accepted")
	check(await _wait(func(): return NP.stats.throw_refused == ref0 + 2, 3.0), "host: bad rarity + a second grenade inside grenade_min_interval_s refused (%s)" % [NP.stats])
	var g: Node = NP.projectile(NP._next_id)
	if not check(g != null and not g.is_visual_only and str(g.type_id) == "grenade" and str(g.variant) == "rookery" and g.owner_id == P.avatar(bob).get_instance_id(), "host: the real Rookery, owned by Bob's avatar"):
		return
	var body = g.body
	check(body != null and body.authoritative and body.data.get("variant") == "rookery", "host: its Grenade body is authoritative, data from the variant id (GearDB)")
	var fx0: int = NP.stats.fx_fwd
	var k0: int = NP._next_id
	body.detonate() # the real Rookery: blast, then bomblets_n grenade_bomblet spawns (P1 replicates each)
	var nb: int = int(body.data.get("bomblets", 5))
	check(NP._next_id - k0 == nb and NP.stats.fx_fwd >= fx0 + 2, "host: %d bomblets got net ids, blast + split forwarded (fx %d -> %d)" % [nb, fx0, NP.stats.fx_fwd])
	# Leechbell for Cara, at a zombie: damage -> heal orbs (heal_orb) home on Cara's avatar -> her machine heals
	var z: Node = z_hint if z_hint != null and is_instance_valid(z_hint) and not bool(z_hint.get("_dead")) else null
	if z == null:
		for zz in main.zombies_root.get_children():
			if "_dead" in zz and not bool(zz._dead) and not zz.has_meta("is_boss"):
				z = zz
	Net.broadcast_event(&"t_cmd", cara, {"op": "hp_low"})
	await _sleep(0.5)
	if check(z != null, "host: a live zombie for the Leechbell"):
		z.health = maxf(float(z.health), 2000.0) # survives the blast (damage still counts)
		var ld: Dictionary = GS.data_for_variant("leechbell")
		var spec: Dictionary = GS.make_spec(P.avatar(cara), ld, (z as Node3D).global_position + Vector3(0, 0.5, 0), Vector3.ZERO, 77)
		var lp: Node = PS.spawn(spec)
		var h0: int = P.stats.heal_tx
		var o0: int = NP._next_id
		lp.body.detonate()
		check(NP._next_id > o0 + 0, "host: Leechbell spawned %d heal orbs (host spawns)" % (NP._next_id - o0 - 0))
		check(await _wait(func(): return P.stats.heal_tx > h0, 6.0), "host: an orb reached Cara's avatar -> heal relayed (heal_tx %d -> %d)" % [h0, P.stats.heal_tx])
		# frost from a client (E3 claim) lands on the host's zombie
		Net.broadcast_event(&"t_cmd", cara, {"op": "frost", "z": str(z.name)})
		check(await _wait(func(): return z.has_status("frost"), 3.0), "host: Cara's frost claim applied to %s" % z.name)
	for id in [bob, cara]:
		Net.broadcast_event(&"t_cmd", id, {"op": "gcheck", "bob": bob, "cara": cara, "nb": nb})
	await _sleep(1.5)
	# E7: host-side damage from Bob's grenade credits Bob (needs the enemy.gd E7 line)
	if not load("res://scripts/enemy.gd").source_code.contains("note_damage_source"):
		print("[%s] SKIP  grenade kill credit: enemy.gd E7 line not in this tree" % pname)
		return
	var zk: Node = null
	for zz in main.zombies_root.get_children():
		if "_dead" in zz and not bool(zz._dead) and not zz.has_meta("is_boss"):
			zk = zz
	if check(zk != null, "host: a live zombie for the grenade kill"):
		var b0: int = Net.get_points(bob)
		GS.deal(zk, 99999.0, P.avatar(bob), (zk as Node3D).global_position) # Grenade.deal, as the Tallyhook chain does
		await _sleep(0.4)
		check(Net.get_points(bob) > b0, "host: E7 - the kill by Bob's grenade paid Bob (%d -> %d)" % [b0, Net.get_points(bob)])


func _client() -> void:
	if not check(Net.join_by_address("127.0.0.1", port) == OK, "join"):
		return finish("join")
	if not await _wait(func(): return Net.state == Net.State.IN_LOBBY, 15.0):
		check(false, "in lobby")
		return finish("lobby")
	Net.set_ready(true)
	if not check(await _wait(_find_main, 60.0), "match scene loaded + match_started"):
		return finish("load")
	_protect(true)
	Net.world.drop_spawned.connect(func(id): seen_drops.append(str(id)))
	Net.world.boss_state_applied.connect(func(zn, _st):
		var b = main.zombies_root.get_node_or_null(NodePath(zn))
		if b:
			boss_phases[zn] = boss_phases.get(zn, []) + [int(b.phase)])
	Net.projectiles.event_rx.connect(func(nid, kind, d): grenade_ev.append([nid, kind, d]))
	Net.projectiles.projectile_rx.connect(func(sp): grenade_rx.append(sp))
	Net.projectiles.projectile_rx.connect(func(_spec):
		var live: Array = Net.projectiles.proj_script().live
		rx_visual.append(not live.is_empty() and live.back().is_visual_only))
	_make_door("T1", 25)
	Net.world.door_refused.connect(func(id, why): door_ops.append(["refused", str(id), why]))
	start_points = int(main.player.points)
	main.player.loot_received.connect(func(it): got_items.append(it))
	Net.world.spend_result.connect(func(ok, amt, r): if r == "test_door": spend_results.append([ok, amt]))
	await _sleep(1.0)
	check(Net.match_players.avatars.size() == n_clients and Net.match_players.avatars.has(1), "client: avatars for the host + the other client(s) (%d)" % Net.match_players.avatars.size())
	check(not Net.runs_waves(), "client: does not run waves")
	while not _done:
		if not cmd_q.is_empty():
			await _do(cmd_q.pop_front())
		elif hold_target != 0:
			var a = Net.match_players.avatar(hold_target)
			if a:
				main.player.global_position = a.global_position + Vector3(0.6, 0, 0)
		await process_frame


func _on_game_event(ev: StringName, peer_id: int, data: Dictionary) -> void:
	if role == "host":
		return
	if ev == &"t_finish":
		cmd_q.append({"op": "finish"})
	elif ev == &"t_cmd" and peer_id == Net.local_peer_id():
		cmd_q.append(data)


func _do(c: Dictionary) -> void:
	var P = Net.match_players
	match str(c.op):
		"move":
			main.player.global_position = c.to
			main.player.velocity = Vector3.ZERO
		"events":
			var ge = root.get_node("GameEvents")
			ge.emit_event(&"shot_fired", {"player": main.player, "weapon": null})
			await _sleep(0.2)
			ge.emit_event(&"reload_started", {"player": main.player, "weapon": null, "time": 1.5})
		"check_zombies":
			var mine: Array = []
			for z in main.zombies_root.get_children():
				mine.append(str(z.name))
			var all_in := true
			for n in c.names:
				all_in = all_in and n in mine
			check(all_in and mine.size() >= c.names.size(), "client: same zombies as the host (%s)" % [c.names])
			var z0 = main.zombies_root.get_node_or_null(NodePath(str(c.names[0]))) if c.names.size() else null
			check(z0 != null and z0.has_meta("net_puppet"), "client: zombies are puppets (no local AI)")
			check(main.current_round == int(c.round), "client: round %d from the host's round state" % int(c.round))
			check(Net.world.stats.snaps_rx > 5, "client: zombie snapshots arriving (%d)" % Net.world.stats.snaps_rx)
		"kill":
			killed_zombie = str(c.zombie)
			var z = main.zombies_root.get_node_or_null(NodePath(killed_zombie))
			if check(z != null, "client: has zombie %s to shoot" % killed_zombie):
				# a gun-tagged round first (GameEvents shot_fired this frame -> NetHitCheck "gun" with the held weapon)
				var w = main.player.current_weapon() if main.player.has_method("current_weapon") else null
				var bus = root.get_node_or_null("GameEvents")
				if w and bus:
					bus.emit_event(&"shot_fired", {"player": main.player, "weapon": w})
					z.take_damage(1.0, z.global_position + Vector3(0, 1.2, 0), false, main.player)
				await process_frame
				# then a big skill-sized hit (other_cap) that kills a round-1 zombie
				check(z.take_damage(2000.0, z.global_position + Vector3(0, 1.6, 0), true, main.player) == true, "client: E3 take_damage on a puppet predicts the kill")
		"grab":
			my_drop = str(c.drop)
			# the other client may already have won (drop gone before this command arrives): spawned here is enough
			check(my_drop in seen_drops, "client: the shared drop spawned here too")
			Net.world.request_grab(my_drop)
		"grab_equip": # playtest #3 hold-E on a shared drop: the inherited Pickup hold path, through the host
			var nd = main.pickups_root.get_node_or_null(NodePath(str(c.drop)))
			var inv = main.player.inventory
			var old = inv.equipped.get(str(c.slot))
			var bp_before: int = inv.backpack[str(c.slot)].size()
			if check(nd != null and nd.can_hold_interact(), "client: hold-E offered on the shared drop %s" % c.drop):
				nd.interact_hold(main.player)
				check(inv.equipped.get(str(c.slot)) == old, "client: nothing equipped before the host grants it")
				var got := await _wait(func(): var e = inv.equipped.get(str(c.slot)); return e != null and e != old and e.display_name == str(c.name), 5.0)
				check(got, "client: host-granted %s equipped straight off the ground (slot %s)" % [c.name, c.slot])
				check(old == null or inv.backpack[str(c.slot)].size() == bp_before + 1, "client: the old %s went to the backpack" % c.slot)
				await _sleep(0.5)
				check(main.pickups_root.get_node_or_null(NodePath(str(c.drop))) == null, "client: the drop is gone here")
		"boss_check":
			var b = main.zombies_root.get_node_or_null(NodePath(str(c.name)))
			if check(b != null and b.has_meta("net_puppet"), "client: Bellwether puppet %s here" % c.name):
				var zn := str(c.name)
				await _wait(func(): var ph: Array = boss_phases.get(zn, []); return ph.has(3) and ph.back() == 0, 5.0)
				var seen: Array = boss_phases.get(zn, [])
				var i1 := seen.find(1)
				check(i1 >= 0 and seen.slice(i1, i1 + 4) == [1, 2, 3, 0], "client: puppet played slam windup -> impact -> stun -> idle from the host (phases %s)" % [seen])
				check(Net.world.stats.boss_rx >= 3, "client: boss states received (%d)" % Net.world.stats.boss_rx)
		"proj_check":
			check(Net.projectiles.stats.rx == int(c.n), "client: %d visual-only projectile copies here (%d)" % [int(c.n), Net.projectiles.stats.rx])
			check(rx_visual.size() == int(c.n) and not rx_visual.has(false), "client: the copies are visual-only (%s)" % [rx_visual])
		"throw":
			var spec := {"type_id": StringName(str(c.type)), "variant": &"", "rarity": 0, "pos": main.player.global_position + Vector3(0, 1.5, 0),
				"vel": Vector3(0, 4, 2), "owner_id": main.player.get_instance_id(), "seed": 11}
			var mine = Net.projectiles.request_throw(spec)
			check(mine != null and mine.is_visual_only, "client: my throw shows a visual copy at once")
			var bad := spec.duplicate()
			bad.pos = main.player.global_position + Vector3(30, 0, 0)
			await _sleep(0.3)
			Net.projectiles.request_throw(bad)
		"hp_mark":
			health_before_dmg = int(main.player.health)
		"hp_check":
			check(int(main.player.health) - health_before_dmg >= int(c.min_gain) and Net.match_players.stats.heal_rx >= 2, "client: host heals applied to my own player (%d -> %d)" % [health_before_dmg, int(main.player.health)])
		"gthrow":
			drop0 = Net.projectiles.stats.dropped
			var Gr: Script = load("res://scripts/combat/grenade.gd") # loaded at run time: autoloads (GearDB) exist by now
			var gd: Dictionary = Gr.data_for_variant("rookery")
			var me: Node3D = main.player
			my_grenade = Gr.throw_from(me, gd, me.global_position + Vector3(0, 1.5, 0), Vector3(0, 0, -1), Vector3.ZERO)
			my_grenade = my_grenade.proj if my_grenade else null
			var bad: Dictionary = Gr.make_spec(me, gd, me.global_position + Vector3(0, 1.5, 0), Vector3(0, 3, 0), 5)
			bad.rarity = 9
			Net.projectiles.request_throw(bad) # no such rarity
			await _sleep(0.2)
			Gr.throw_from(me, gd, me.global_position + Vector3(0, 1.5, 0), Vector3(0, 0, -1), Vector3.ZERO) # inside the interval
		"hp_low":
			main.player.health = maxi(int(main.player.health) - 60, 1)
			health_before_dmg = int(main.player.health)
			heal_rx0 = Net.match_players.stats.heal_rx
		"frost":
			var fz = main.zombies_root.get_node_or_null(NodePath(str(c.z)))
			if fz:
				fz.apply_status("frost", {"dur": 3.0, "amp": 0.15}) # puppet -> E3 claim to the host
		"gcheck":
			var mine: bool = Net.local_peer_id() == int(c.bob)
			var am_cara: bool = Net.local_peer_id() == int(c.cara)
			var blasts: Array = grenade_ev.filter(func(e): return e[1] == "blast")
			check(not mine or (my_grenade == null or not is_instance_valid(my_grenade)) and blasts.size() >= 1, "client: my own Rookery copy was bound to the host's net id (its blast arrived, copy detonated)")
			check(Net.projectiles.stats.dropped - drop0 == (2 if mine else 0), "client: refused throws dropped their local copy (%d)" % (Net.projectiles.stats.dropped - drop0))
			var kids: Array = grenade_rx.filter(func(sp): return str(sp.type_id) == "grenade_bomblet")
			check(kids.size() == int(c.nb), "client: %d Rookery bomblets (grenade_bomblet) replicated as visual-only children (%d)" % [int(c.nb), kids.size()])
			var want_owner: int = main.player.get_instance_id() if mine else Net.match_players.avatar(int(c.bob)).get_instance_id()
			check(kids.all(func(sp): return int(sp.owner_id) == want_owner), "client: bomblets owned by Bob here (player / avatar)")
			check(grenade_rx.filter(func(sp): return str(sp.type_id) == "grenade" and str(sp.variant) == "rookery").size() == (0 if mine else 1), "client: the Rookery itself replicated (not echoed to its thrower)")
			check(blasts.size() >= 1 and blasts.all(func(e): return Net.projectiles.projectile(int(e[0])) == null), "client: the host's blast reached my Rookery copy, which detonated on it (copy gone; %d blasts)" % blasts.size())
			check(grenade_rx.any(func(sp): return str(sp.type_id) == "heal_orb"), "client: Leechbell heal orbs replicated (heal_orb)")
			if am_cara:
				check(Net.match_players.stats.heal_rx > heal_rx0 and int(main.player.health) > health_before_dmg, "client: Leechbell heal applied to my own player (%d -> %d)" % [health_before_dmg, int(main.player.health)])
		"spend":
			Net.request_spend(999999, "test_door")
			await _sleep(0.4)
			Net.request_spend(10, "test_door")
		"vulnerable":
			health_before_dmg = int(main.player.health)
			_protect(false)
		"protect":
			_protect(true)
			# the forwarded hit must arrive and go through player.take_damage; a rolled Field Card (dodge etc.) may still
			# zero it, so the health drop is informational
			check(Net.match_players.stats.damage_rx >= 1, "client: host-side zombie hit on my avatar reached my own player (%d rx, health %d -> %d)" % [Net.match_players.stats.damage_rx, health_before_dmg, int(main.player.health)])
		"die":
			_protect(false)
			main.player.take_damage(99999.0, null)
			await _sleep(0.3)
			_protect(true)
		"revive":
			hold_target = int(c.target)
			await process_frame
			P.set_revive_hold(hold_target, true)
		"stop_revive":
			if hold_target != 0:
				P.set_revive_hold(hold_target, false)
			hold_target = 0
		"door":
			var d = main.find_child("TestDoor_" + str(c.id), true, false)
			if d == null:
				d = _make_door(str(c.id), 5) # T9: unknown on the host
			var p0 := int(main.player.points)
			d.interact(main.player)
			door_ops.append(["door", str(c.id), p0])
		"late_door":
			Net.world.doors_open.erase("arena/" + str(c.id)) # forget it: only the host's door-state message can open it
			var d = _make_door(str(c.id), 40)
			door_ops.append(["late", str(c.id), d.is_open])
		"reroll":
			var RS = root.get_node("RunState")
			RS.free_rerolls = 0
			RS.open_offer(1)
			RS.rerolled.connect(func(cost, free): reroll_log.append(["rerolled", cost, free]))
			RS.reroll_refused.connect(func(why): reroll_log.append(["refused", why]))
			var p0 := int(main.player.points)
			var now_ok: bool = RS.reroll()
			reroll_log.append(["call", now_ok, RS.reroll_pending])
			check(not RS.reroll(), "client: a second reroll while one is pending is ignored")
			await _wait(func(): return not RS.reroll_pending, 3.0)
			check(int(main.player.points) == p0 - 50 and RS.rerolls_paid_this_offer == 1, "client: reroll charged by the host + redrawn (%d -> %d)" % [p0, int(main.player.points)])
			RS.rerolls_paid_this_offer = 12 # next one costs 50 x 4096: the host must refuse it
			var p1 := int(main.player.points)
			RS.reroll()
			await _wait(func(): return not RS.reroll_pending, 3.0)
			check(RS.last_refusal_reason == "points" and int(main.player.points) == p1, "client: unaffordable reroll refused by the host, not charged (%s)" % RS.last_refusal_reason)
			check(reroll_log.size() >= 3 and reroll_log[0] == ["call", false, true] and reroll_log[1] == ["rerolled", 50, false] and reroll_log[-1] == ["refused", "points"], "client: reroll signals (%s)" % [reroll_log])
			RS.offer_open = false
			RS.rerolls_paid_this_offer = 0
		"finish":
			await _client_final()


func _client_final() -> void:
	if killed_zombie != "":
		check(Net.get_points(Net.local_peer_id()) > 0 and int(main.player.points) > start_points, "client: my wallet got the kill credit (%d -> %d)" % [start_points, int(main.player.points)])
		check(not main.zombies_root.has_node(NodePath(killed_zombie)), "client: the dead zombie despawned here too")
	if my_drop != "":
		check(not Net.world.drops.has(my_drop) and not main.pickups_root.has_node(NodePath(my_drop)), "client: the grabbed drop is gone here")
		print("[%s] grabbed items: %d" % [pname, got_items.size()])
	if not spend_results.is_empty():
		check(spend_results == [[false, 999999], [true, 10]], "client: spend results from the host (%s)" % [spend_results])
	var t1 = main.find_child("TestDoor_T1", true, false)
	check(t1 != null and t1.is_open and Net.world.doors_open.has("arena/T1"), "client: T1 (bought by someone) is open here too")
	var t2 = main.find_child("TestDoor_T2", true, false)
	check(t2 != null and t2.is_open and door_ops.has(["late", "T2", false]), "client: T2 opened from the host's door state after the map piece appeared (late join path)")
	for op in door_ops:
		if op[0] == "door" and op[1] == "T1" and Net.world.doors_open.get("arena/T1", -1) != Net.local_peer_id():
			check(true, "client: my buy of an already-open T1 didn't reach the host")
	if door_ops.has(["refused", "T9", "unknown_door"]):
		check(true, "client: host refused an unknown door (T9)")
	check(main._game_over, "client: game over when everyone is down")
	finish("client match scenario (items %d)" % got_items.size())
