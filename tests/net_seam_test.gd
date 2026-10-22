extends SceneTree
## Zombie seam unit suite (Netz): the Net side of enemy.gd hooks E1-E5 without touching enemy.gd.
## Stub zombies / avatars stand in for enemy.gd and phase-B RemoteAvatars.
##   godot --headless --path . -s res://tests/net_seam_test.gd   (exit code = failures)

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


## Stand-in for enemy.gd: the members the seam reads / calls.
class StubZombie:
	extends Node3D
	var health := 50.0
	var speed := 2.4
	var _dead := false
	var dmg_mult := 1.0
	var taken: Array = []
	var statuses: Array = []
	var played: Array = []
	var death_visuals := 0
	var seen_hitter := -1
	var seen_crit := false
	var net: Node
	var _status_tick := false
	var _statuses: Dictionary = {}
	func damage_taken_mult() -> float:
		return dmg_mult
	func take_damage(amount: float, hit_pos: Vector3 = Vector3.ZERO, crit: bool = false, source: Node = null) -> bool:
		seen_hitter = net.last_hitter(self) # hit / died fire inside take_damage on the host
		seen_crit = net._last_hit_crit()
		taken.append([amount, hit_pos, crit, source])
		health -= amount * dmg_mult
		if health <= 0.0:
			_dead = true
			return true
		return false
	func apply_status(id: String, p: Dictionary) -> void:
		statuses.append([id, p])
	func _play(key: String, _blend: float = 0.2) -> void:
		played.append(key)
	func play_death_visual() -> void:
		death_visuals += 1


class StubBody:
	extends Node
	var weapon_id := ""


class StubPlayer:
	extends Node3D
	var body: Node = null
	var dead := false
	var downed := false
	var peer_id := 0
	var got: Array = []
	func add_points(amount: int, reason: String) -> void:
		got.append([amount, reason])


func _body(group: String, pos: Vector3, peer := 0) -> StubPlayer:
	var b := StubPlayer.new()
	b.peer_id = peer
	root.add_child(b)
	b.add_to_group(group)
	b.global_position = pos
	return b


func _run() -> void:
	var Net = root.get_node("Net")
	Engine.max_fps = 60
	var me := _body("player", Vector3.ZERO)
	var zroot := Node.new()
	zroot.name = "Zombies"
	root.add_child(zroot)
	var z := StubZombie.new()
	z.name = "Z7"
	z.net = Net
	zroot.add_child(z)
	z.global_position = Vector3(10, 0, 0)

	# ------------------------------------------------------------ E4: rng_for
	check(Net.rng_for(null) == null and Net.rng_for(z) == null, "rng_for: null without net_seed (solo keeps the global RNG)")
	z.set_meta("net_seed", 12345)
	var a = Net.rng_for(z)
	var b = Net.rng_for(z)
	var sa := [a.randi(), a.randf_range(0.9, 1.1), a.randi_range(0, 5)]
	var sb := [b.randi(), b.randf_range(0.9, 1.1), b.randi_range(0, 5)]
	check(sa == sb, "rng_for: same net_seed -> same sequence on every peer")
	z.set_meta("net_seed", 54321)
	check(Net.rng_for(z).randi() != sa[0], "rng_for: different seed -> different sequence")
	z.remove_meta("net_seed")
	var before := randi()
	seed(99)
	var g1 := randi()
	seed(99)
	Net.rng_for(z)
	z.set_meta("net_seed", 1)
	Net.rng_for(z).randi()
	check(randi() == g1, "rng_for never consumes the global RNG (solo trace unaffected)")
	z.remove_meta("net_seed")
	seed(before)

	# ------------------------------------------------------------ E3: client-side prediction (solo: nothing sent)
	check(Net.forward_zombie_damage(z, 40.0) == false and z.taken.is_empty(), "forward_zombie_damage: 40 of 50 hp -> no kill predicted, puppet hp untouched")
	check(Net.forward_zombie_damage(z, 50.0) == true, "forward_zombie_damage: lethal amount -> predicted kill")
	z.dmg_mult = 2.0
	check(Net.forward_zombie_damage(z, 26.0) == true and Net.forward_zombie_damage(z, 24.0) == false, "prediction uses damage_taken_mult (x2: 26 kills, 24 doesn't)")
	z.dmg_mult = 1.0
	check(Net.forward_zombie_damage(z, 0.0) == false and Net.forward_zombie_damage(z, -5.0) == false and Net.forward_zombie_damage(null, 99.0) == false,
		"forward_zombie_damage: zero / negative / null -> false")
	z._dead = true
	check(Net.forward_zombie_damage(z, 999.0) == false, "forward_zombie_damage: already-dead puppet -> false")
	z._dead = false
	Net.forward_zombie_status(z, "burn", {"dur": 3.0, "dps": 5.0})
	check(z.statuses.is_empty(), "forward_zombie_status: solo / host no-op (authority applies statuses itself)")

	# ------------------------------------------------------------ E2: puppet tick
	z.global_position = Vector3(10, 0, 0)
	Net.zombie_puppet_tick(z, 1.0 / 60.0)
	check(z.played.back() == "idle", "puppet tick: not moving -> idle")
	z.global_position += Vector3(0.05, 0, 0) # 3 m/s
	Net.zombie_puppet_tick(z, 1.0 / 60.0)
	check(z.played.back() == "walk", "puppet tick: moving at a walker's speed -> walk")
	z.speed = 5.0
	z.global_position += Vector3(0.1, 0, 0)
	Net.zombie_puppet_tick(z, 1.0 / 60.0)
	check(z.played.back() == "run", "puppet tick: runner (speed > 4.2) -> run")
	z.set_meta("net_anim", "attack")
	Net.zombie_puppet_tick(z, 1.0 / 60.0)
	check(z.played.back() == "attack", "puppet tick: replicated net_anim overrides (attack)")
	z.remove_meta("net_anim")
	z._dead = true
	var n_played := z.played.size()
	Net.zombie_puppet_tick(z, 1.0 / 60.0)
	Net.zombie_puppet_tick(z, 1.0 / 60.0)
	check(z.death_visuals == 1 and z.played.size() == n_played, "puppet tick: replicated _dead -> play_death_visual exactly once, no more anims")
	z._dead = false
	z.remove_meta("net_death_shown")
	z.speed = 2.4

	# ------------------------------------------------------------ E1 / M4 in solo
	var av := _body("net_avatar", Vector3(9, 0, 0), 5)
	check(Net.players().size() == 2 and Net.players()[0] == me, "players(): local player first, then net_avatar bodies")
	check(Net.pick_target(z) == me, "pick_target solo: the local player even with a closer body around")
	check(Net.min_distance_to_players(Vector3(10, 0, 0), me) == 10.0, "min_distance_to_players solo == distance to the local player")
	check(Net.last_hitter(z) == 1 and not Net._last_hit_crit(), "last_hitter solo: peer 1")

	# ------------------------------------------------------------ hosting: targeting + hit claims + points
	var NP = Net.projectiles
	var gtx0: int = NP.stats.gitem_tx
	NP.send_grenade_item({})
	check(NP.stats.gitem_tx == gtx0 and NP.grenade_item(1) == null, "grenade item: solo send is a no-op (nothing stored)")
	var port := 30000 + randi() % 20000
	check(Net.host_party(port, false) == OK and Net.is_networked() and Net.is_host(), "host_party on %d" % port)
	Net._party[5] = {"peer_id": 5, "name": "Bob", "class_id": "soldier", "ready": true, "is_leader": false, "ping_ms": 0, "slot": 1, "state": "in_match"} # test-only fake client entry
	_grenade_items(Net, NP)
	var av2 := _body("net_avatar", Vector3(30, 0, 0), 6)
	check(Net.pick_target(z) == av, "pick_target host: nearest player body (avatar at 1 m beats local at 10 m)")
	av.downed = true
	check(Net.pick_target(z) == me, "pick_target: downed players are skipped")
	av.downed = false
	av.dead = true
	me.dead = true
	check(Net.pick_target(z) == av2, "pick_target: dead players are skipped")
	av2.dead = true
	check(Net.pick_target(z) != null, "pick_target: everyone down -> still a target (no null deref)")
	me.dead = false
	av.dead = false
	av2.dead = false
	check(is_equal_approx(Net.min_distance_to_players(Vector3(10, 0, 0), me), 1.0), "min_distance_to_players host: nearest of all players (spawn filter)")

	var stub_main := Node.new()
	stub_main.set_script(_main_stub_script())
	root.add_child(stub_main)
	stub_main.zombies_root = zroot
	Net._match = stub_main
	check(Net.handle_hit_claim(9, "Z7", 10.0, Vector3.ZERO, false) == false and z.taken.is_empty(), "hit claim from a non-party peer: refused")
	check(Net.handle_hit_claim(5, "Z7", NAN, Vector3.ZERO, false) == false and Net.handle_hit_claim(5, "Z7", INF, Vector3.ZERO, false) == false
		and Net.handle_hit_claim(5, "Z7", 0.0, Vector3.ZERO, false) == false and z.taken.is_empty(), "hit claim NaN / inf / 0: refused")
	check(Net.handle_hit_claim(5, "Nope", 10.0, Vector3.ZERO, false) == false, "hit claim on an unknown zombie: refused")
	z.health = 99999.0
	check(Net.handle_hit_claim(5, "Z7", 20.0, Vector3(1, 2, 3), true) == true and z.taken.size() == 1, "valid hit claim: applied once")
	var t: Array = z.taken[0]
	check(t[0] == 20.0 and t[1] == Vector3(1, 2, 3) and t[2] == true and t[3] == av, "claim -> take_damage(amount, hit_pos, crit, shooter's avatar)")
	check(z.seen_hitter == 5 and z.seen_crit, "inside take_damage the hit / kill is credited to the claiming peer")
	check(Net.last_hitter(z) == 1 and not Net._last_hit_crit(), "after the claim, the host's own hits are the host's again")
	Net.handle_hit_claim(5, "Z7", 4000.0, Vector3.ZERO, false, "aoe")
	check(z.taken[1][0] == 4000.0, "aoe claim under max_hit_damage: applied as is")
	check(Net.handle_hit_claim(5, "Z7", 1.0e9, Vector3.ZERO, false, "aoe") == false and z.taken.size() == 2, "hit claim past validation.max_hit_damage (aoe cap): refused")
	z._dead = true
	check(Net.handle_hit_claim(5, "Z7", 10.0, Vector3.ZERO, false) == false, "hit claim on a dead zombie: refused")
	z._dead = false

	# ------------------------------------------------------------ 3d: host hit claim checks (NetHitCheck)
	var HC = Net.hit_check
	HC.clear()
	var wbody := StubBody.new()
	wbody.weapon_id = "auto_rifle"
	av.add_child(wbody)
	av.body = wbody
	var zpos0: Vector3 = z.global_position
	z.global_position = Vector3(20, 0, 0)
	z.health = 1.0e9
	var ar: Dictionary = NetHitCheck.weapon_def("auto_rifle")
	var sn: Dictionary = NetHitCheck.weapon_def("sniper_rifle")
	check(not ar.is_empty() and not sn.is_empty() and NetHitCheck.gun_cap(ar) == float(ar.base_damage) * 2.0 * 12.0, "weapon numbers from data/weapons.json (auto_rifle cap %.0f, sniper cap %.0f)" % [NetHitCheck.gun_cap(ar), NetHitCheck.gun_cap(sn)])
	var hp := Vector3(20, 1.2, 0)
	var n0: int = z.taken.size()
	check(Net.handle_hit_claim(5, "Z7", 30.0, hp, true, "gun", "auto_rifle") and z.taken.size() == n0 + 1, "gun claim with the held auto_rifle: applied")
	check(not Net.handle_hit_claim(5, "Z7", NetHitCheck.gun_cap(ar) + 1.0, hp, false, "gun", "auto_rifle") and HC.stats.damage == 1, "gun claim past the auto_rifle cap: refused (damage)")
	check(not Net.handle_hit_claim(5, "Z7", 2600.0, hp, false, "other") and HC.stats.damage == 2, "skill / melee claim past other_cap: refused")
	check(not Net.handle_hit_claim(5, "Z7", 3000.0, hp, false, "gun", "sniper_rifle") and HC.stats.weapon_mismatch == 1, "claiming the sniper while holding the auto_rifle: counted as other (refused at 3000)")
	wbody.weapon_id = "sniper_rifle"
	check(Net.handle_hit_claim(5, "Z7", 3000.0, hp, true, "gun", "sniper_rifle"), "after the swap: a 3000 sniper headshot is fine (cap %.0f)" % NetHitCheck.gun_cap(sn))
	check(Net.handle_hit_claim(5, "Z7", 30.0, hp, false, "gun", "auto_rifle") and HC.stats.weapon_mismatch == 1, "the previous weapon still counts within weapon_grace_s (swap latency)")
	var far := Vector3(9.0 + NetHitCheck.gun_range(ar) + 5.0, 1.2, 0)
	wbody.weapon_id = "auto_rifle"
	z.global_position = far - Vector3(0, 1.2, 0)
	check(not Net.handle_hit_claim(5, "Z7", 20.0, far, false, "gun", "auto_rifle") and HC.stats.range == 1, "auto_rifle claim beyond base_range x 4 x range_mult + slack (%.0f m): refused (range)" % NetHitCheck.gun_range(ar))
	z.global_position = Vector3(20, 0, 0)
	HC.clear()
	wbody.weapon_id = "smg"
	var smg: Dictionary = NetHitCheck.weapon_def("smg")
	var lim := int(ceil(NetHitCheck.gun_rate(smg)))
	var acc := 0
	for i in lim + 10:
		if Net.handle_hit_claim(5, "Z7", 5.0, hp, false, "gun", "smg"):
			acc += 1
	check(acc == lim and HC.stats.rate == 10, "smg: %d claims/s accepted (rpm %d x margin), the next 10 refused (rate)" % [lim, int(smg.rpm)])
	HC.clear()
	wbody.weapon_id = "auto_rifle"
	var wall := StaticBody3D.new()
	var wcs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 12.0, 12.0)
	wcs.shape = box
	wall.add_child(wcs)
	wall.collision_layer = 1
	root.add_child(wall)
	wall.global_position = Vector3(14.5, 0, 0)
	await physics_frame
	await physics_frame
	check(not Net.handle_hit_claim(5, "Z7", 20.0, hp, false, "gun", "auto_rifle") and HC.stats.los == 1, "gun claim through a wall (every LOS ray blocked): refused (los)")
	check(Net.handle_hit_claim(5, "Z7", 20.0, hp, false, "aoe"), "an explosion's splash through the same wall: no LOS check, applied")
	wall.global_position = Vector3(14.5, 0, 6.8) # wall beside the line: one offset ray is enough
	await physics_frame
	await physics_frame
	check(Net.handle_hit_claim(5, "Z7", 20.0, hp, false, "gun", "auto_rifle"), "wall off the line of fire: applied")
	wall.queue_free()
	check(Net._party.has(5) and HC.per_peer.get(5, {}).get("los", 0) == 1, "refusals are counted per peer, nobody is kicked")
	z.global_position = zpos0

	# ------------------------------------------------------------ 3e: DoT kill credit to the peer who applied it
	av.set_meta("net_owner_peer", 5) # a stub, not a NetRemoteAvatar: owned by peer 5
	if not Net.match_players.avatars.has(5):
		Net.match_players.avatars[5] = av
	z._statuses = {"burn": {"t": 2.0, "dps": 10.0, "source": av}, "mark": {"t": 2.0, "amp": 0.25, "source": me}}
	z._status_tick = true
	check(Net.last_hitter(z) == 5, "burn tick: kill credit to the peer whose avatar applied the burn")
	z._statuses.burn.source = me
	check(Net.last_hitter(z) == 1, "burn applied by the host's player: the host")
	z._statuses = {"rot": {"t": 2.0, "amp": 0.2, "source": av}}
	check(Net.last_hitter(z) == 1, "no ticking status (rot / mark / frost only amplify): the hitter, not the applier")
	z._status_tick = false
	z._statuses = {}
	if Net.match_players.avatars.get(5) == av:
		Net.match_players.avatars.erase(5)
	av.remove_meta("net_owner_peer")

	var changes: Array = []
	Net.points_changed.connect(func(p, tot): changes.append([p, tot]))
	Net._points.clear()
	Net.award_points(5, 10, "hit")
	Net.award_points(5, 50, "kill")
	check(Net.get_points(5) == 60 and changes.back() == [5, 60] and me.got.is_empty(), "award_points: host total for peer 5, replicated, local wallet untouched")
	Net.award_points(1, 10, "hit")
	await process_frame
	check(Net.get_points(1) == 10 and me.got == [[10, "hit"]], "award_points to the host: host total + local wallet mirrors it")
	Net._claim_peer = 5
	Net.on_zombie_hit_points(z, 10)
	Net._claim_peer = 0
	check(Net.get_points(5) == 60 + int(load("res://scripts/net/net_config.gd").points("per_hit")), "on_zombie_hit_points credits the claiming peer net.json per_hit (economy = solo value)")

	Net._match = null
	Net._party.erase(5)
	Net.leave_party()
	check(not Net.is_networked(), "leave_party: back to solo")
	for n in [me, av, av2, zroot, stub_main]:
		n.queue_free()
	await process_frame
	print("NET SEAM TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


## Grenade items (playtest #5, Skillz 41bd224): host store + checks, throw check against the stored item, host-built
## data, {} = class grenade, P1 copies carry the host data, peer leave clears. Runs on a real GearDB.
func _grenade_items(Net: Node, NP: Node) -> void:
	var GDB: Node = root.get_node_or_null("GearDB")
	if GDB == null or not GDB.has_method("roll_grenade"):
		print("SKIP  grenade items: no GearDB.roll_grenade in this tree")
		return
	var S = NP
	var it = GDB.roll_grenade("rookery", 3, 140, null, 2)
	var d: Dictionary = S.item_dict_of(it)
	check(d.get("class") == "grenade" and d.get("grenade_id") == "rookery" and d.has("fittings") and not d.has("stats"), "item_dict_of: the to_dict keys the host uses (%s)" % [d.keys()])
	check(S.item_dict_of(null) == {}, "item_dict_of(null) = {} (class grenade)")
	var r: Dictionary = S.sanitize_grenade_item(d)
	check(r.why == "" and r.item.grenade_id == "rookery" and int(r.item.item_power) == 140 and r.item.fittings.size() == d.fittings.size(), "sanitize: a rolled Rookery passes as is")
	check(S.sanitize_grenade_item({}).why == "" and S.sanitize_grenade_item({}).item == {}, "sanitize: {} = class grenade")
	var bad := d.duplicate(true)
	bad.rarity = int(d.rarity) + 1
	check(S.sanitize_grenade_item(bad).why == "item_rarity", "sanitize: rarity not the type's -> item_rarity")
	bad = d.duplicate(true)
	bad.variant = "frag"
	check(S.sanitize_grenade_item(bad).why == "wrong_variant", "sanitize: variant not the type's -> wrong_variant")
	bad = d.duplicate(true)
	bad.grenade_id = "nuke"
	check(S.sanitize_grenade_item(bad).why == "unknown_grenade", "sanitize: unknown grenade_id")
	bad = d.duplicate(true)
	bad.item_power = 99999
	check(S.sanitize_grenade_item(bad).why == "item_power", "sanitize: Item Power past item_power.max")
	bad = d.duplicate(true)
	bad.fittings = {"heavy_packing": 9.0}
	check(S.sanitize_grenade_item(bad).why == "bad_fitting", "sanitize: a Fitting outside its range")
	bad.fittings = {"short_wick": 0.8, "heavy_packing": 1.1, "wide_casing": 1.1}
	check(S.sanitize_grenade_item(bad).why == "too_many_fittings", "sanitize: more Fittings than the rarity rolls")
	bad = d.duplicate(true)
	bad.class = "weapon"
	check(S.sanitize_grenade_item(bad).why == "not_grenade", "sanitize: not a grenade item")
	# host store (peer 5 = the fake Bob, class soldier)
	NP._gitem_t.clear()
	check(NP.host_grenade_item(5, d) == "" and NP.grenade_item(5).grenade_id == "rookery", "host: Bob's equipped Rookery stored")
	var huge := d.duplicate(true)
	huge["flavor"] = "x".repeat(5000)
	check(NP.host_grenade_item(5, huge) == "item_too_big" and NP.grenade_item(5).grenade_id == "rookery", "host: an oversized item dict refused, the old one kept")
	NP._gitem_t.clear()
	var rates := []
	for i in 10:
		rates.append(NP.host_grenade_item(7, {}))
	check(rates.count("") == 8 and rates.back() == "item_rate", "host: grenade item updates past grenade_item_max_per_s refused (%s)" % [rates])
	NP._gitem_t.clear()
	NP.send_grenade_item(S.item_dict_of(GDB.roll_grenade("frag", 1, 100, null, 0)))
	check(NP.grenade_item(1) != null and NP.grenade_item(1).grenade_id == "frag", "host: its own equipped grenade is tracked too (peer 1)")
	# throw checks against the stored item
	var GS: Script = load("res://scripts/combat/grenade.gd")
	var tampered: Dictionary = it.throw_data().duplicate(true)
	tampered.damage = 99999.0
	tampered.radius = 50.0
	var spec: Dictionary = GS.make_spec(null, tampered, Vector3.ZERO, Vector3(0, 3, -10), 9)
	var ck: Dictionary = NP.grenade_throw_check(5, spec)
	var want: Dictionary = load("res://scripts/items/grenade_item.gd").throw_data_from_dict(NP.grenade_item(5))
	check(ck.why == "" and is_equal_approx(float(ck.data.damage), float(want.damage)) and float(ck.data.damage) < 99999.0 and is_equal_approx(float(ck.data.radius), float(want.radius)), "throw check: host data = throw_data_from_dict(stored item), not the client's numbers (dmg %s)" % [ck.get("data", {}).get("damage")])
	check(ck.data.fittings == NP.grenade_item(5).fittings and int(ck.data.item_power) == 140, "throw check: the item's Fittings + Item Power are in the host data")
	var fs: Dictionary = GS.make_spec(null, GS.data_for_variant("frag"), Vector3.ZERO, Vector3(0, 3, -10), 9)
	check(NP.grenade_throw_check(5, fs).why == "wrong_grenade", "throw check: a frag while a Rookery is equipped -> wrong_grenade")
	var rs := spec.duplicate()
	rs.rarity = 0
	check(NP.grenade_throw_check(5, rs).why == "item_rarity", "throw check: rarity not the item's -> item_rarity")
	check(NP.grenade_throw_check(6, spec).why == "no_grenade_item", "throw check: no item synced -> no_grenade_item")
	# {} = class grenade (soldier)
	NP.host_grenade_item(5, {})
	var cid: String = load("res://scripts/classes/class_roster.gd").template("soldier").grenade_id
	var cs: Dictionary = GS.make_spec(null, GS.data_for_variant(cid), Vector3.ZERO, Vector3(0, 3, -10), 9)
	var cc: Dictionary = NP.grenade_throw_check(5, cs)
	check(NP.grenade_item(5) == {} and cc.why == "" and str(cc.data.get("variant", cid)) == str(GS.data_for_variant(cid).get("variant", cid)), "throw check: {} -> the class grenade (%s) at its base numbers" % cid)
	var other := "rookery" if cid != "rookery" else "frag"
	check(NP.grenade_throw_check(5, GS.make_spec(null, GS.data_for_variant(other), Vector3.ZERO, Vector3(0, 3, -10), 9)).why == "wrong_grenade", "throw check: {} + another type -> wrong_grenade")
	# P1 broadcast form: data only with_data (host -> copies), never in a client's request
	var sp: Dictionary = spec.duplicate()
	sp.data = ck.data
	check(not NP.spec_tx(sp).has("data") and NP.spec_tx(sp, true).get("data", {}).get("color") == ck.data.get("color"), "spec_tx: a throw request carries no data; the host broadcast carries the host data (+ color)")
	NP.drop_peer(5)
	check(NP.grenade_item(5) == null, "peer left: its grenade item cleared")
	NP._gitem_t.clear()


func _main_stub_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nvar zombies_root: Node\nvar first_round_zombies := 6\nvar zombies_per_round := 3\nvar max_alive := 16\n"
	s.reload()
	return s
