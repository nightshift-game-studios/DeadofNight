extends SceneTree
## Remote-player body suite (Netz, milestone B): Desi's Gravecrew body through the NetAvatarBody adapter
## (AnimationTree layers, sockets, tint by slot, reload / throw marks), the capsule fallback, and NetRemoteAvatar
## interpolation / flags / name tag.
##   godot --headless --path . -s res://tests/net_avatar_test.gd   (exit code = failures)

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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _wait_s(s: float) -> void:
	var end := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


func _run() -> void:
	Engine.max_fps = 60
	var Desi = load("res://scripts/net/avatar/desi_body.gd")
	var Cap = load("res://scripts/net/avatar/capsule_body.gd")
	var RA = load("res://scripts/net/avatar/remote_avatar.gd")
	var Base = load("res://scripts/net/avatar/avatar_body.gd")
	var Rig = load("res://assets/models/player/player_rig.gd")

	# ------------------------------------------------------------ Desi body: model, sockets, loops, tint, weapon
	var b = Desi.new()
	b.slot = 2
	root.add_child(b)
	await _frames(2)
	check(b.model != null and b.anim != null and b.tree != null and b.tree.active, "Desi body: player.glb + AnimationTree active")
	check(b.weapon_socket != null and b.weapon_socket.name == "WeaponR" and b.name_socket != null and b.name_socket.name == "NameTag" and b.grenade_socket != null,
		"sockets: WeaponR (gun), NameTag (head), GrenadeR")
	# Desi gripfix 2026-10-19 (NODE_INVENTORY.txt): WeaponR rest transform local to hand_r
	var wr: Transform3D = b.weapon_socket.transform
	var q := wr.basis.get_rotation_quaternion()
	var qi := Quaternion(0.650819, 0.684029, 0.266699, 0.193421)
	check(wr.origin.is_equal_approx(Vector3(0.0215, 0.0788, 0.0516)) or wr.origin.distance_to(Vector3(0.0215, 0.0788, 0.0516)) < 0.0005, "WeaponR origin = gripfix (0.0215, 0.0788, 0.0516) (got %s)" % wr.origin)
	check(absf(q.dot(qi)) > 0.9999, "WeaponR rotation = gripfix quat (0.6508, 0.6840, 0.2667, 0.1934) (got %s)" % q)
	check(b.weapon_socket.get_parent() is BoneAttachment3D and (b.weapon_socket.get_parent() as BoneAttachment3D).bone_name == "hand_r", "WeaponR rides BoneAttachment3D hand_r")
	var loops_ok := true
	for n in Rig.LOOPS:
		var want: int = Animation.LOOP_LINEAR if Rig.LOOPS[n] else Animation.LOOP_NONE
		if not b.anim.has_animation(n) or b.anim.get_animation(n).loop_mode != want:
			loops_ok = false
	check(loops_ok, "all 20 clips present, loop flags from player_rig.gd (Death / one-shots don't loop)")
	var mi: MeshInstance3D = Rig.body(b.model)
	var tint_of := func() -> Color:
		var m := mi.get_surface_override_material(1) as StandardMaterial3D
		return m.albedo_color if m else Color.BLACK
	check(mi != null and tint_of.call().is_equal_approx(Color("#1E9FC8")), "slot 2 -> P3 Signal Cyan on TintBand (surface 1)")
	b.set_slot(1)
	check(tint_of.call().is_equal_approx(Color("#C9D12B")) and mi.get_surface_override_material(0) == null, "set_slot(1) -> P2 Hi-Vis Yellow; surface 0 never tinted")
	b.set_weapon("auto_rifle")
	await _frames(1)
	check(b.weapon_socket.get_child_count() == 1 and b.weapon_socket.get_child(0).transform.is_equal_approx(Transform3D()), "weapon id -> gun model under WeaponR with identity transform")
	b.set_weapon("")
	await _frames(1)
	check(b.weapon_socket.get_child_count() == 0, "weapon '' -> empty socket")
	b.set_weapon("auto_rifle")

	# ------------------------------------------------------------ filter: spine_02 up only
	var comb: AnimationNodeBlend2 = b.tree.tree_root.get_node("combine")
	var root_path: String = b._track_root
	check(comb.filter_enabled and comb.is_path_filtered(NodePath(root_path + ":spine_02")) and comb.is_path_filtered(NodePath(root_path + ":hand_r"))
		and comb.is_path_filtered(NodePath(root_path + ":Head")) and not comb.is_path_filtered(NodePath(root_path + ":spine_01"))
		and not comb.is_path_filtered(NodePath(root_path + ":pelvis")) and not comb.is_path_filtered(NodePath(root_path + ":thigh_l")),
		"upper-body filter: spine_02 and up (arms, head) in; spine_01 / pelvis / legs out")

	# ------------------------------------------------------------ locomotion
	b.apply_state({"speed": 5.0, "crouch": 0.0, "airborne": false, "ads": false})
	await _frames(2)
	check(is_equal_approx(float(b.tree.get("parameters/loco/blend_position")), 5.0) and is_equal_approx(float(b.tree.get("parameters/crouch/blend_amount")), 0.0),
		"speed -> locomotion BlendSpace1D, crouch blend 0")
	check(absf(Desi.loco_time_scale(2.0, false) - 2.0 / 1.16) < 0.01 and absf(Desi.loco_time_scale(5.0, false) - 5.0 / 6.2) < 0.01
		and absf(Desi.loco_time_scale(8.5, false) - 8.5 / 9.5) < 0.01 and Desi.loco_time_scale(0.0, false) == 1.0,
		"playback scale = game speed / clip foot speed (Walk 1.16, Run 6.2, Sprint 9.5)")
	b.apply_state({"speed": 2.0, "crouch": 1.0})
	await _frames(1)
	check(is_equal_approx(float(b.tree.get("parameters/crouch/blend_amount")), 1.0) and absf(float(b.tree.get("parameters/loco_ts/scale")) - minf(2.0 / 0.77, 3.0)) < 0.01,
		"crouch -> Crouch / CrouchWalk blend, scaled by CrouchWalk foot speed 0.77")
	b.apply_state({"speed": 0.0, "crouch": 0.0})

	# ------------------------------------------------------------ air: Jump > Fall > Land
	b.trigger("jump")
	b.apply_state({"airborne": true})
	await _frames(3)
	var air_pb: AnimationNodeStateMachinePlayback = b.tree.get("parameters/air/playback")
	check(str(b.tree.get("parameters/ground_air/current_state")) == "air" and str(air_pb.get_current_node()) == "Jump", "jump event -> air layer, Jump")
	await _wait_s(1.6)
	check(str(air_pb.get_current_node()) == "Fall", "Jump ends -> Fall loop")
	b.apply_state({"airborne": false})
	await _frames(2)
	check(str(b.tree.get("parameters/ground_air/current_state")) == "ground" and bool(b.tree.get("parameters/land/active")), "touch down -> ground + Land one-shot")
	b.last_event = ""
	b.apply_state({"airborne": true}) # walked off a ledge
	await _frames(3)
	check(str(air_pb.get_current_node()) == "Fall", "airborne without a jump -> straight to Fall")
	b.apply_state({"airborne": false})
	await _frames(2)

	# ------------------------------------------------------------ upper body: Hold_Rifle <> ADS_Aim + one-shots
	check(b.upper_state() == "Hold_Rifle", "upper body starts in Hold_Rifle")
	b.apply_state({"ads": true})
	await _wait_s(0.3)
	check(b.upper_state() == "ADS_Aim", "ads -> ADS_Aim")
	b.apply_state({"ads": false})
	await _wait_s(0.3)
	check(b.upper_state() == "Hold_Rifle", "ads off -> Hold_Rifle")
	b.trigger("fire")
	await _frames(2)
	check(bool(b.tree.get("parameters/fire/active")), "fire -> Fire one-shot")
	var marks: Array = []
	var clock := {"t0": Time.get_ticks_msec()} # lambdas capture locals by value: keep t0 in a dict
	b.marker.connect(func(n): marks.append([n, (Time.get_ticks_msec() - clock.t0) / 1000.0]))
	b.trigger("reload", {"time": 2.167})
	await _frames(2)
	check(bool(b.tree.get("parameters/reload/active")) and absf(float(b.tree.get("parameters/reload_ts/scale")) - 1.0) < 0.01, "reload -> Reload one-shot at clip speed for a 2.167 s reload")
	await _wait_s(2.0)
	var names := marks.map(func(m): return m[0])
	check(names == ["mag_out", "mag_out_done", "mag_in", "slap"], "reload marks in order: mag out -> mag in -> slap (%s)" % [names])
	var tm := {}
	for m in marks:
		tm[m[0]] = m[1]
	check(marks.size() == 4 and absf(tm.mag_out - 0.28) < 0.12 and absf(tm.mag_out_done - 0.65) < 0.12 and absf(tm.mag_in - 1.71) < 0.12 and absf(tm.slap - 1.82) < 0.12,
		"reload mark times ~0.28 / 0.65 / 1.71 / 1.82 s (%s)" % [tm])
	marks.clear()
	clock.t0 = Time.get_ticks_msec()
	b.trigger("reload", {"time": 1.0835})
	await _frames(1)
	check(absf(float(b.tree.get("parameters/reload_ts/scale")) - 2.0) < 0.01, "faster reload (1.08 s) -> Reload plays x2")
	await _wait_s(1.1)
	tm.clear()
	for m in marks:
		tm[m[0]] = m[1]
	check(tm.has("mag_in") and absf(tm.mag_in - 0.855) < 0.12, "marks scale with the reload time (mag in at %.2f s)" % float(tm.get("mag_in", -1.0)))
	marks.clear()
	clock.t0 = Time.get_ticks_msec()
	b.set_weapon("auto_rifle")
	await _frames(1)
	check(not b.weapon_stowed() and b.weapon_socket.visible, "rifle visible before the throw")
	b.trigger("throw")
	await _frames(2)
	check(bool(b.tree.get("parameters/throw/active")), "throw -> Throw one-shot (upper body)")
	check(b.weapon_stowed(), "Throw: rifle (WeaponR) stowed for the clip (no pop at the elbow)")
	await _wait_s(0.5)
	check(marks.size() == 1 and marks[0][0] == "throw_release" and absf(marks[0][1] - 0.33) < 0.12, "throw_release at ~0.33 s")
	b.set_weapon("sidearm") # swap mid-throw: stays hidden until the clip ends
	await _frames(1)
	check(b.weapon_stowed(), "weapon swap during Throw stays stowed")
	await _wait_s(1.0)
	check(marks.size() == 2 and marks[1][0] == "throw_done" and absf(marks[1][1] - 1.333) < 0.15 and not b.weapon_stowed(), "throw_done at ~1.33 s (clip end) -> rifle shown again (%s)" % [marks])
	marks.clear()

	# ------------------------------------------------------------ full-body overrides
	b.set_life("downed")
	await _frames(2)
	check(b.life_state() == "downed" and not bool(b.tree.get("parameters/fire/active")), "downed -> full-body Downed, one-shots aborted")
	b.trigger("fire")
	await _frames(2)
	check(not bool(b.tree.get("parameters/fire/active")), "no upper-body one-shots while downed")
	b.set_life("alive")
	await _frames(2)
	b.set_life("reviving")
	await _frames(3)
	var rev_pb: AnimationNodeStateMachinePlayback = b.tree.get("parameters/revive/playback")
	check(b.life_state() == "reviving" and str(rev_pb.get_current_node()) == "ReviveStart", "reviving -> ReviveStart")
	await _wait_s(1.9)
	check(str(rev_pb.get_current_node()) == "Revive", "ReviveStart -> Revive loop")
	b.set_life("alive")
	await _frames(3)
	check(str(rev_pb.get_current_node()) == "ReviveEnd" and b.life_state() == "reviving", "revive done -> ReviveEnd plays before standing")
	await _wait_s(1.8)
	check(b.life_state() == "alive", "after ReviveEnd -> alive layer")
	b.set_life("dead")
	await _wait_s(2.8)
	check(b.life_state() == "dead" and b.anim.get_animation("Death").loop_mode == Animation.LOOP_NONE, "dead -> Death (non-looping: holds its last frame)")
	b.queue_free()

	# ------------------------------------------------------------ capsule fallback
	var c = Cap.new()
	c.slot = 3
	root.add_child(c)
	await _frames(1)
	check((c.mesh.material_override as StandardMaterial3D).albedo_color.is_equal_approx(Color("#C2307A")) and c.name_tag_anchor() != c, "capsule: P4 magenta, own head anchor")
	c.set_life("downed")
	check(is_equal_approx(c.mesh.rotation_degrees.x, 90.0), "capsule: downed lies down")
	c.queue_free()

	# ------------------------------------------------------------ remote avatar
	var a = RA.create(5, 1, "Bob", "desi")
	root.add_child(a)
	await _frames(2)
	check(a.is_in_group("net_avatar") and a.peer_id == 5 and is_instance_of(a.body, Desi), "NetRemoteAvatar: group net_avatar, peer 5, Desi body")
	check(a.name_tag.text == "Bob" and a.name_tag.get_parent() == a.body.name_tag_anchor() and a.name_tag.get_parent().name == "NameTag", "name tag 'Bob' rides the NameTag head socket")
	check(a.collision_layer == 2 and a.collision_mask == 0, "avatar on the player layer, collides with nothing")
	var cap_a = RA.create(6, 0, "Cara", "capsule")
	root.add_child(cap_a)
	await _frames(1)
	check(is_instance_of(cap_a.body, Cap), "body kind 'capsule' -> placeholder (one-line swap)")
	a.push_state([1, Vector3(0, 0, 0), 0.0, 0.0, 0.0, 0.0, 0])
	check(a.global_position == Vector3.ZERO, "first state snaps")
	await _wait_s(0.1)
	a.push_state([2, Vector3(1, 0, 0), 0.0, 0.0, 3.0, 0.0, 0])
	a.push_state([1, Vector3(9, 9, 9), 0.0, 0.0, 0.0, 0.0, 0])
	await _wait_s(0.06)
	check(a.global_position.x > 0.0 and a.global_position.x < 1.0 and a.global_position.y == 0.0, "interpolates between states ~100 ms behind; stale seq ignored (x=%.2f)" % a.global_position.x)
	await _wait_s(0.25)
	check(a.global_position.is_equal_approx(Vector3(1, 0, 0)), "reaches the latest state")
	a.push_state([3, Vector3(50, 0, 0), 1.0, 0.0, 0.0, 0.0, RA.F_ADS | RA.F_AIR])
	await _frames(2)
	check(a.global_position.is_equal_approx(Vector3(50, 0, 0)) and a.body.ads and a.body.airborne, "teleport > 6 m snaps; ads / airborne flags reach the body")
	a.push_state([4, Vector3(50, 0, 0), 1.0, 0.0, 0.0, 0.0, RA.F_DEAD])
	await _wait_s(0.2)
	check(a.dead and a.body.life == "dead", "dead flag -> dead + Death")
	a.set_downed(false)
	var Net = root.get_node("Net")
	check(Net.players().has(a) and Net.players().has(cap_a), "Net.players() includes remote avatars")
	a.take_damage(10.0, null) # solo: no-op, no error
	# weapon + slot (G4M3N 2026-10-20: remote avatars carry Inventory.active_weapon_slot)
	Net.match_players.avatars[5] = a
	Net.match_players.receive_weapon(5, "sidearm", "secondary")
	await _frames(1)
	check(a.weapon_slot == "secondary" and a.body.weapon_socket.get_child_count() == 1, "_rpc_weapon_slot(arch, slot): avatar keeps slot 'secondary' + shows the gun")
	Net.match_players.receive_weapon(5, "auto_rifle", "")
	check(a.weapon_slot == "", "old archetype-only _rpc_weapon -> slot '' (still accepted)")
	Net.match_players.receive_weapon(5, "x".repeat(60), "primary")
	check(a.weapon_slot == "", "oversized weapon id ignored")
	Net.match_players.avatars.erase(5)
	check(Net.match_players.stats.damage_fwd == 0, "avatar damage in solo: ignored")
	a.queue_free()
	cap_a.queue_free()
	await _frames(2)
	print("NET AVATAR TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
