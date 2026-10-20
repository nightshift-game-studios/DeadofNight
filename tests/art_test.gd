extends SceneTree
## Art wiring pass (Skillz, 2026-10-19): Desi's boss GLBs + clips + sockets, Echo Walker height, split-mesh guns per
## archetype, WeaponRig attachment show/hide, Mine Lamp light_energy, Armory.item_power_breakdown.
## Art pass 2 (Desi batch 2): revolver + rocket launcher + rocket_projectile, DefaultBarrel, 38/38 attachment GLBs,
## per-gun barrel scale, uniques (Gravesight / Heartbeat / Second Mouth / Lantern Rail / Bonesaw), ADS sight line,
## scout stock + revolver front-sight fixes, every referenced res://assets path exists, Gravemark pickup model.
##   godot --headless --path . -s res://tests/art_test.gd   (exit code = failures)
## Uses its own save file, never the real one.

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


const ZOMBIE := "res://scenes/enemy.tscn"


func _boss(B, id: String, parent: Node) -> Node:
	var z = (load(ZOMBIE) as PackedScene).instantiate()
	z.set_script(load(B.script_path(id)))
	z.setup(400, 3.2, 10)
	z.configure_boss(id, 10, "easy")
	parent.add_child(z)
	return z


func _model_scale(z: Node) -> float:
	var m: Node3D = z.model_root.get_child(0)
	return m.scale.x


func _run() -> void:
	var B = load("res://scripts/enemies/boss_catalog.gd")
	var Art = load("res://scripts/enemies/boss_art.gd")
	var D = load("res://scripts/world/difficulty.gd")
	var A = load("res://scripts/armory/armory.gd")
	var Rig = load("res://scripts/gear/weapon_rig.gd")
	var prog: Node = root.get_node("Progress")
	B.reload()
	A.reload()
	D.set_active("")
	var test_dir := OS.get_user_data_dir().path_join("art_test")
	DirAccess.make_dir_recursive_absolute(test_dir)
	prog.save_path = test_dir.path_join("progress_art_test.cfg")
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	prog.gravemarks = 0
	prog.armory = {"upgrades": {}, "owned": [], "equipped": {}}
	prog.stash = {}
	prog.bind_inventory(null)
	prog.notify_armory("load", "", false)

	var world := Node3D.new()
	world.name = "ArtWorld"
	root.add_child(world)

	# ------------------------------------------------------------ boss data -> models
	var heights := {"bellwether": 2.4, "choir_host": 2.1, "lantern_stalker": 1.95}
	for id in heights:
		var mp: String = B.model_path(id)
		check(mp == "res://assets/models/bosses/%s.glb" % id and ResourceLoader.exists(mp), "%s model path set + shipped (%s)" % [id, mp])
		var b: Dictionary = B.get_boss(id)
		check(is_equal_approx(float(b.model_height), heights[id]) and is_equal_approx(float(b.size_variety), 0.0),
			"%s model_height %.2f, size_variety 0 (auto-scale 1.0)" % [id, heights[id]])
		check(ResourceLoader.exists(B.icon_path(id)), "%s icon copied (%s)" % [id, B.icon_path(id)])
	check(B.echo_model_path() == "res://assets/models/bosses/echo_walker.glb" and ResourceLoader.exists(B.echo_model_path()),
		"echo add model = echo_walker.glb")
	check(is_equal_approx(B.echo_model_height(), 1.526), "echo add model_height 1.526 (not the 1.795 walker default)")
	check(is_equal_approx(float(B.anims("bellwether").slam_hit_time), 0.17), "Bellwether SlamImpact hit at 0.17 s (data)")
	check(B.anims("bellwether").loop == ["ChargeRun"] and B.anims("choir_host").loop == ["Channel"]
		and B.anims("lantern_stalker").loop == ["DarkSneak"], "loop lists: ChargeRun / Channel / DarkSneak")
	check(is_equal_approx(float(B.telegraph("lantern_stalker").sidestep_distance), 2.4), "Lantern sidestep distance 2.4 m")

	# ------------------------------------------------------------ Bellwether instance
	var bw = _boss(B, "bellwether", world)
	await process_frame
	check(str(bw.get_meta("model_path", "")) == B.model_path("bellwether"), "Bellwether spawns bellwether.glb, not the walker")
	check(absf(_model_scale(bw) - 1.0) < 0.02, "Bellwether auto-scale = 1.0 (got %.3f)" % _model_scale(bw))
	var ap: AnimationPlayer = Art.anim_player(bw)
	check(ap != null and Art.has_clip(bw, "slam_windup") and Art.has_clip(bw, "slam_impact") and Art.has_clip(bw, "stun")
		and Art.has_clip(bw, "charge_windup") and Art.has_clip(bw, "charge_run"), "Bellwether clips registered")
	check(ap != null and ap.get_animation(bw._anims.charge_run).loop_mode == Animation.LOOP_LINEAR, "ChargeRun loops (set in code)")
	check(ap != null and ap.get_animation(bw._anims.walk).loop_mode == Animation.LOOP_LINEAR and bw._anims.walk == "Zombie_Walk",
		"base walk still found by suffix (Zombie_Walk, looped)")
	check(Art.socket(bw, "SlamFx") != null and Art.socket(bw, "Bell") != null, "Bellwether sockets SlamFx / Bell found")
	var e0: float = Art.emission(bw, "Bellwether_Bell")
	var bw2 = _boss(B, "bellwether", world)
	await process_frame
	bw._set_enraged()
	check(e0 > 0.0 and is_equal_approx(Art.emission(bw, "Bellwether_Bell"), e0 * 4.0), "enrage boosts bell emission x4 (%.2f -> %.2f)" % [e0, Art.emission(bw, "Bellwether_Bell")])
	check(is_equal_approx(Art.emission(bw2, "Bellwether_Bell"), e0), "emission boost is per instance (second Bellwether unchanged)")
	# Slam timeline: windup 1.2 s -> SlamImpact -> damage 0.17 s (x enrage speed) later -> stun.
	bw2._start_slam()
	check(bw2.phase == bw2.Phase.SLAM_WINDUP and ap != null and Art.anim_player(bw2).current_animation == "SlamWindup", "slam starts SlamWindup")
	for i in 20:
		bw2.take_damage(1.0)
	check(Art.anim_player(bw2).current_animation == "SlamWindup", "hits during the windup never swap in HitReact")
	for i in 73: # 1.2167 s
		bw2._physics_process(1.0 / 60.0)
	check(bw2.phase == bw2.Phase.SLAM_IMPACT and Art.anim_player(bw2).current_animation == "SlamImpact", "after the windup: SlamImpact, damage not yet")
	for i in 11: # +0.183 s
		bw2._physics_process(1.0 / 60.0)
	check(bw2.phase == bw2.Phase.STUNNED, "smash resolves ~0.17 s into SlamImpact, then stun")
	var stun_total: float = bw2._phase_t
	check(stun_total > 1.0 and stun_total < 1.6, "stun = SlamImpact follow-through + slam_stun (%.2f s)" % stun_total)
	for i in 40:
		bw2._physics_process(1.0 / 60.0)
	check(Art.anim_player(bw2).current_animation == "Stun", "Stun clip follows SlamImpact")

	# ------------------------------------------------------------ Choir Host instance
	var ch = _boss(B, "choir_host", world)
	await process_frame
	check(str(ch.get_meta("model_path", "")) == B.model_path("choir_host") and absf(_model_scale(ch) - 1.0) < 0.02, "Choir Host model + scale 1.0")
	var cap: AnimationPlayer = Art.anim_player(ch)
	check(cap != null and cap.get_animation(ch._anims.channel).loop_mode == Animation.LOOP_LINEAR, "Channel loops (set in code)")
	var c0: float = Art.emission(ch, "ChoirHost_Cavity")
	ch._begin_channel()
	check(cap.current_animation == "Channel" and is_equal_approx(Art.emission(ch, "ChoirHost_Cavity"), c0 * 2.5), "channel plays Channel + cavity glows x2.5")
	ch.take_damage(ch.shield_hp + 5.0)
	check(not ch.channeling and ch.phase == ch.Phase.STAGGER and cap.current_animation == "ChannelHit", "shield break -> ChannelHit stagger")
	check(is_equal_approx(Art.emission(ch, "ChoirHost_Cavity"), c0 * 0.2), "shield break dims the cavity (x0.2)")
	check(Art.socket(ch, "ShieldProxy") != null and Art.socket(ch, "SummonMouth") != null, "Choir sockets ShieldProxy / SummonMouth found")

	# ------------------------------------------------------------ Lantern Stalker instance
	var ls = _boss(B, "lantern_stalker", world)
	await process_frame
	check(str(ls.get_meta("model_path", "")) == B.model_path("lantern_stalker") and absf(_model_scale(ls) - 1.0) < 0.02, "Lantern Stalker model + scale 1.0")
	var lsock: Node3D = Art.socket(ls, "Lantern")
	check(ls.lantern_light != null and lsock != null and ls.lantern_light.get_parent() == lsock, "OmniLight3D sits on the Lantern socket")
	check(Art.socket(ls, "BeamOrigin") != null and Art.socket(ls, "SpitMuzzle") != null, "BeamOrigin / SpitMuzzle sockets found")
	var lap: AnimationPlayer = Art.anim_player(ls)
	check(lap.get_animation(ls._anims.dark).loop_mode == Animation.LOOP_LINEAR, "DarkSneak loops (set in code)")
	check(is_equal_approx(ls.sidestep_speed() * 0.5, 2.4), "sidestep moves the root 2.4 m over the 0.5 s clip")
	ls._set_dark(true)
	check(ls._anims.walk == "DarkSneak" and ls._anims.run == "DarkSneak" and is_equal_approx(ls.lantern_light.light_energy, 0.15),
		"dark phase: DarkSneak replaces walk/run, lantern dims")
	ls._set_dark(false)
	check(ls._anims.walk == "Zombie_Walk" and ls._anims.run == "Zombie_Run", "leaving dark restores walk/run")
	ls._begin_sidestep()
	check(lap.current_animation in ["SidestepL", "SidestepR"], "sidestep plays SidestepL/R (%s)" % lap.current_animation)

	# ------------------------------------------------------------ Echo add
	var ez = (load(ZOMBIE) as PackedScene).instantiate()
	ez.setup(100, 3.5, 7)
	check(B.apply_echo_model(ez) and is_equal_approx(ez.model_height, 1.526), "apply_echo_model: echo_walker.glb + 1.526 m")
	world.add_child(ez)
	await process_frame
	var em: Node3D = ez.model_root.get_child(0)
	var ea: AABB = ModelUtil.get_aabb(em)
	check(absf(ea.size.y * em.scale.y - 1.526) < 0.1 and ez.has_meta("boss_echo"), "echo stands ~1.526 m (%.3f), tagged boss_echo" % (ea.size.y * em.scale.y))

	# ------------------------------------------------------------ guns per archetype
	var want := {"sidearm": "weapon_pistol", "hand_cannon": "weapon_hand_cannon", "auto_rifle": "weapon_assault_rifle",
		"scout_rifle": "weapon_scout_rifle", "smg": "weapon_smg", "shotgun": "weapon_shotgun", "pulse_rifle": "weapon_lmg",
		"sniper_rifle": "weapon_sniper", "rocket_launcher": "weapon_rocket_launcher"}
	var wdata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/weapons.json"))
	var by_arch := {}
	for a in wdata.archetypes:
		by_arch[str(a.id)] = a
	for arch in want:
		var mp := str(by_arch[arch].model)
		check(mp == "res://assets/models/weapons/%s.glb" % want[arch] and ResourceLoader.exists(mp), "%s -> %s" % [arch, want[arch]])
	check(str(by_arch.rocket_launcher.get("model_legacy", "")) == "res://assets/models/guns/rocket_launcher.glb"
		and str(by_arch.hand_cannon.get("model_legacy", "")) == "res://assets/models/guns/hand_cannon.glb", "old gun paths kept as model_legacy (launcher + hand cannon)")
	check(str(by_arch.rocket_launcher.projectile.get("model", "")) == "res://assets/models/weapons/rocket_projectile.glb"
		and ResourceLoader.exists(str(by_arch.rocket_launcher.projectile.model)), "rocket_launcher.projectile.model = rocket_projectile.glb")
	var sockets_full := ["Muzzle", "SightPoint", "Rail", "Underbarrel", "MagWell", "Stock", "Barrel"]
	var need_by := {"weapon_pistol": ["Muzzle", "SightPoint", "Rail", "MagWell"],
		"weapon_hand_cannon": ["Muzzle", "SightPoint", "Rail", "MagWell", "Barrel"],
		"weapon_rocket_launcher": ["Muzzle", "SightPoint", "Rail", "MagWell", "Underbarrel"]}
	for g in ["weapon_assault_rifle", "weapon_scout_rifle", "weapon_sniper", "weapon_shotgun", "weapon_smg", "weapon_lmg", "weapon_pistol",
			"weapon_hand_cannon", "weapon_rocket_launcher"]:
		var gm: Node3D = (load("res://assets/models/weapons/%s.glb" % g) as PackedScene).instantiate()
		var need: Array = need_by.get(g, sockets_full)
		var miss := need.filter(func(s): return Rig.find_node(gm, s) == null)
		check(miss.is_empty() and Rig.find_node(gm, "Body") != null and Rig.find_node(gm, "IronSights") != null, "%s sockets + Body/IronSights (missing %s)" % [g, miss])
		gm.free()

	# ------------------------------------------------------------ attachments: models + show/hide
	var shipped := 0
	var expect := 0 # optics pass: new optics flagged art_pending ["model", ...] (GLB not delivered) or without a model by design
	for a in A.data().attachments:
		if Rig.has_model(str(a.id)):
			shipped += 1
		if str(a.get("model", "")) != "" and not (a.get("art_pending", []) as Array).has("model"):
			expect += 1
	check(shipped == expect and shipped >= 38, "%d/%d attachment GLBs wired (38 from batch 2 + optics as they land), got %d" % [expect, A.data().attachments.size(), shipped])
	check(ResourceLoader.exists("res://assets/icons/att_mine_lamp.png"), "att_mine_lamp.png copied to assets/icons")
	check(Rig.hides_for("crows_eye_3x") == ["IronSights", "DefaultOptic"] and Rig.hides_for("hush_can") == ["DefaultMuzzle"]
		and Rig.hides_for("fence_post") == ["DefaultGrip"] and Rig.hides_for("mine_lamp") == [], "slot hides (Mine Lamp hides nothing)")
	var pl: Dictionary = Rig.plan({"optic": "crows_eye_3x", "muzzle": "hush_can", "grip": "mine_lamp", "mag": "fat_drum"})
	check(pl.attach.optic.socket == "Rail" and pl.attach.muzzle.socket == "Muzzle" and pl.attach.grip.socket == "Underbarrel"
		and pl.attach.mag.socket == "MagWell" and pl.missing.is_empty() and pl.hide.has("DefaultMag") and not pl.hide.has("DefaultGrip"),
		"plan: sockets Rail/Muzzle/Underbarrel/MagWell; nothing missing, fat_drum hides DefaultMag, lamp keeps DefaultGrip")

	var holder := Node3D.new()
	world.add_child(holder)
	var ar: Node3D = (load("res://assets/models/weapons/weapon_assault_rifle.glb") as PackedScene).instantiate()
	holder.add_child(ar)
	ar.scale = Vector3.ONE * 0.6
	var rig: Dictionary = Rig.apply(ar, "auto_rifle", {"optic": "crows_eye_3x", "muzzle": "hush_can", "grip": "mine_lamp", "mag": "fat_drum"})
	check(rig.attached.optic.get_parent() == Rig.find_node(ar, "Rail") and rig.attached.muzzle.get_parent() == Rig.find_node(ar, "Muzzle")
		and rig.attached.grip.get_parent() == Rig.find_node(ar, "Underbarrel"), "attachments instanced on Rail / Muzzle / Underbarrel")
	check(not Rig.find_node(ar, "IronSights").visible and not Rig.find_node(ar, "DefaultMuzzle").visible, "optic hides IronSights, can hides DefaultMuzzle")
	check(not Rig.find_node(ar, "DefaultMag").visible and rig.attached.mag.get_parent() == Rig.find_node(ar, "MagWell")
		and Rig.find_node(ar, "DefaultStock").visible and Rig.find_node(ar, "Body").visible and Rig.find_node(ar, "DefaultBarrel").visible,
		"Fat Drum on MagWell hides DefaultMag; DefaultStock, DefaultBarrel, Body stay visible")
	check(rig.muzzle != null and rig.attached.muzzle.is_ancestor_of(rig.muzzle) and rig.muzzle.global_position.x > Rig.find_node(ar, "Muzzle").global_position.x + 0.05,
		"effective muzzle = the can's front Muzzle (tracers start at the end of the can)")
	check(rig.sight != null and rig.attached.optic.is_ancestor_of(rig.sight), "ADS sight point = the optic's SightPoint")
	check(rig.lamp != null and Rig.find_node(rig.lamp, "Glass") != null, "Mine Lamp housing fitted (Glass child for the lens)")
	check(rig.attached.optic.scale.is_equal_approx(Vector3.ONE) and is_equal_approx(rig.attached.optic.global_transform.basis.get_scale().x, 0.6),
		"attachments inherit the gun's view scale (identity snap, real metres)")
	Rig.clear(ar)
	await process_frame
	check(Rig.visible_parts(ar) == ["Body", "IronSights", "DefaultMag", "DefaultMuzzle", "DefaultStock", "DefaultBarrel"] and Rig.find_node(ar, "Att_optic") == null,
		"clear() removes parts and shows every default again")
	var sn: Node3D = (load("res://assets/models/weapons/weapon_sniper.glb") as PackedScene).instantiate()
	holder.add_child(sn)
	var srig: Dictionary = Rig.apply(sn, "sniper_rifle", {"optic": "longwatch_6x", "grip": "crutch_bipod"})
	check(not Rig.find_node(sn, "DefaultOptic").visible and not Rig.find_node(sn, "IronSights").visible and not Rig.find_node(sn, "DefaultGrip").visible,
		"sniper: optic hides DefaultOptic + IronSights, bipod hides DefaultGrip")
	var pi: Node3D = (load("res://assets/models/weapons/weapon_pistol.glb") as PackedScene).instantiate()
	holder.add_child(pi)
	var prig: Dictionary = Rig.apply(pi, "sidearm", {"optic": "pinhole", "grip": "fence_post"})
	check(prig.attached.has("optic") and not prig.attached.has("grip") and Rig.find_node(pi, "IronSights").visible == false,
		"pistol: optic fits, no Underbarrel socket so a grip is skipped")
	# Armory loadout path (no explicit loadout): buy + equip, then apply reads Armory.loadout(arch).
	prog.gravemarks = 999
	A.buy_upgrade("auto_rifle")
	A.buy_upgrade("auto_rifle")
	A.buy_attachment("mine_lamp")
	A.buy_attachment("hush_can")
	A.equip("auto_rifle", "mine_lamp")
	A.equip("auto_rifle", "hush_can")
	var ar2: Node3D = (load("res://assets/models/weapons/weapon_assault_rifle.glb") as PackedScene).instantiate()
	holder.add_child(ar2)
	var rig2: Dictionary = Rig.apply(ar2, "auto_rifle")
	check(rig2.attached.has("grip") and rig2.attached.has("muzzle") and rig2.lamp != null, "apply() with no loadout reads Armory.loadout (lamp + can)")

	# ------------------------------------------------------------ Mine Lamp light
	var ml: Dictionary = A.attachment("mine_lamp")
	check(ml.has("light_energy") and float(ml.light_energy) >= 6.0 and float(ml.light_energy) <= 8.0, "mine_lamp light_energy in data (%.1f, was 2.4)" % float(ml.get("light_energy", 0)))
	var fc: Dictionary = A.flashlight_config("auto_rifle")
	check(is_equal_approx(float(fc.get("light_energy", 0)), float(ml.light_energy)) and is_equal_approx(float(fc.light_range), 22.0)
		and is_equal_approx(float(fc.light_angle), 28.0) and fc.color is Color, "Armory.flashlight_config(arch) returns the data values")
	check(A.flashlight_config("smg").is_empty(), "flashlight_config is {} without a Mine Lamp on that archetype")

	# ------------------------------------------------------------ Item Power breakdown
	var gdb = root.get_node("GearDB")
	var w = gdb.roll_weapon("auto_rifle", 2, 1, "primary")
	w.item_power = 131
	prog.stash = {"version": 1, "equipped": {"primary": w.to_dict()}, "backpack": {}}
	var bonus: int = A.power_bonus("auto_rifle")
	var bd: Dictionary = A.item_power_breakdown(w.item_id)
	check(bd.base_rolled == 131 and bd.rework_bonus == bonus and bonus == 16 and bd.total == 147 and bd.source == "item",
		"item_power_breakdown(item_id): 131 rolled + 16 Rework II = 147 (%s)" % str(bd))
	check(bd.total == w.effective_item_power(), "breakdown total == WeaponItem.effective_item_power()")
	var ba: Dictionary = A.item_power_breakdown("auto_rifle")
	check(ba.base_rolled == 131 and ba.source == "best_owned" and ba.item_id == w.item_id, "archetype id -> best owned weapon of that archetype")
	var bs: Dictionary = A.item_power_breakdown("sniper_rifle")
	check(bs.base_rolled == 100 and bs.rework_bonus == 0 and bs.total == 100 and bs.source == "baseline", "no sniper owned -> baseline 100 + 0")
	var api = A.new()
	check(api.item_power_breakdown("auto_rifle").total == 147, "also callable on Gooey's Armory instance")

	await _art_pass2(A, Rig, prog, world, holder, by_arch)
	await _art_pass2b(A, Rig, world, holder, by_arch)
	_art_pass3(A, Rig, holder)

	world.queue_free()
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	print("ART TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


# ================================================================== art pass 2 (Desi batch 2)

const GUN := "res://assets/models/weapons/%s.glb"


func _gun(holder: Node3D, g: String) -> Node3D:
	var m: Node3D = (load(GUN % g) as PackedScene).instantiate()
	holder.add_child(m)
	return m


## Same fit as player._build_view_model: Camera3D > Gun (hip offset) > Model > holder (yaw 90) > model scaled to view.length.
func _view_gun(world: Node3D, g: String, length: float) -> Dictionary:
	var cam := Camera3D.new()
	world.add_child(cam)
	var gun := Node3D.new()
	cam.add_child(gun)
	gun.position = Vector3(0.2, -0.2, -0.45)
	var mr := Node3D.new()
	gun.add_child(mr)
	var model: Node3D = (load(GUN % g) as PackedScene).instantiate()
	var a := ModelUtil.get_aabb(model)
	var s := length / maxf(a.size.x, 0.001)
	var h := Node3D.new()
	h.rotation_degrees.y = 90.0
	mr.add_child(h)
	h.add_child(model)
	model.scale = Vector3.ONE * s
	model.position = -a.get_center() * s
	return {"cam": cam, "gun": gun, "model": model, "scale": s}


func _scan_asset_refs() -> Dictionary:
	var files: Array = []
	for f in DirAccess.get_files_at("res://data"):
		if f.ends_with(".json"):
			files.append("res://data/" + f)
	_walk_gd("res://scripts", files)
	var rx := RegEx.new()
	rx.compile("res://assets/[A-Za-z0-9_./%-]+")
	var refs := {}
	for f in files:
		var txt := FileAccess.get_file_as_string(f)
		for m in rx.search_all(txt):
			var pth := m.get_string().rstrip(".")
			if "%" in pth or pth.ends_with("/") or pth.ends_with("_"): # format strings / dirs / prefixes ("att_")
				continue
			if not refs.has(pth):
				refs[pth] = f
	return refs


func _walk_gd(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for d in DirAccess.get_directories_at(dir):
		_walk_gd(dir + "/" + d, out)


func _wait(sec: float) -> void:
	await create_timer(sec).timeout


func _art_pass2(A, Rig, prog: Node, world: Node3D, holder: Node3D, by_arch: Dictionary) -> void:
	var Ads = load("res://scripts/combat/ads_profile.gd")
	# ------------------------------------------------------------ every referenced asset path exists
	var refs := _scan_asset_refs()
	var missing: Array = []
	var pending := {} # optics pass: model paths of attachments whose GLB is still art_pending (WeaponRig fallback)
	for a in A.data().attachments:
		if (a.get("art_pending", []) as Array).has("model"):
			pending[str(a.get("model", ""))] = true
	for pth in refs:
		if not FileAccess.file_exists(pth) and not ResourceLoader.exists(pth) and not pending.has(pth):
			missing.append("%s (%s)" % [pth, refs[pth]])
	check(refs.size() >= 80 and missing.is_empty(), "every res://assets path in data/*.json + scripts exists (%d refs, missing %s)" % [refs.size(), missing])
	var no_import: Array = []
	for a in A.data().attachments:
		var mp := str(a.model)
		if (mp == "" and str(a.get("procedural", "")) != "") or (a.get("art_pending", []) as Array).has("model"):
			continue # optics pass: no GLB by design (Witchlight Dabs) / GLB not delivered yet (checked again once it lands)
		if mp != "res://assets/models/attachments/%s/%s.glb" % [a.slot, a.id] or not FileAccess.file_exists(mp + ".import"):
			no_import.append(a.id)
	for g in ["weapon_hand_cannon", "weapon_rocket_launcher", "rocket_projectile"]:
		if not FileAccess.file_exists((GUN % g) + ".import"):
			no_import.append(g)
	check(no_import.is_empty(), "attachments/<slot>/<id>.glb + new guns all imported (.import present; bad %s)" % [no_import])

	# ------------------------------------------------------------ DefaultBarrel on the 6 rifle-class guns
	var exp_s := {"weapon_assault_rifle": 1.00, "weapon_scout_rifle": 1.16, "weapon_shotgun": 1.16, "weapon_lmg": 1.36,
		"weapon_sniper": 1.68, "weapon_smg": 0.68, "weapon_hand_cannon": 0.31}
	for g in ["weapon_assault_rifle", "weapon_scout_rifle", "weapon_shotgun", "weapon_lmg", "weapon_sniper", "weapon_smg"]:
		var m := _gun(holder, g)
		var db: Node3D = Rig.find_node(m, "DefaultBarrel")
		var r: Dictionary = Rig.apply(m, "auto_rifle", {"barrel": "gutter_ported_barrel"})
		check(db is MeshInstance3D and not db.visible and not Rig.find_node(m, "DefaultMuzzle").visible and Rig.find_node(m, "Body").visible
			and r.hidden.has("DefaultBarrel"), "%s: DefaultBarrel split out, a barrel hides it + DefaultMuzzle, Body stays" % g)
		Rig.clear(m)
		check(db.visible, "%s: clear() shows DefaultBarrel again" % g)

	# ------------------------------------------------------------ barrel scale per gun + muzzle on the scaled muzzle
	for g in exp_s:
		var m := _gun(holder, g)
		m.scale = Vector3.ONE * 0.6
		var s: float = Rig.barrel_scale(m)
		check(absf(s - float(exp_s[g])) < 0.006, "%s barrel scale %.3f ~ %.2f ((Muzzle.x - Barrel.x) / 0.50)" % [g, s, exp_s[g]])
		var r: Dictionary = Rig.apply(m, "auto_rifle", {"barrel": "fluted_cooler", "muzzle": "flare_cage"})
		var b: Node3D = r.attached.barrel
		var bmesh: Node3D = Rig.find_node(b, "Mesh")
		var bm: Node3D = Rig.find_node(b, "Muzzle")
		check(is_equal_approx(r.barrel_scale, s) and absf(bmesh.scale.x - s) < 1e-4 and is_equal_approx(b.scale.x, 1.0)
			and absf(bm.position.x - 0.5 * s) < 1e-4, "%s: barrel Mesh.scale.x = %.3f and Muzzle.x = 0.50 x s, root unscaled" % [g, s])
		var gun_mz: Node3D = Rig.find_node(m, "Muzzle")
		var dev: Node3D = r.attached.muzzle
		check(dev.get_parent() == bm and dev.global_position.distance_to(gun_mz.global_position) < 0.002,
			"%s: muzzle device on the barrel's scaled Muzzle = the gun's Muzzle socket (%.4f m off)" % [g, dev.global_position.distance_to(gun_mz.global_position)])
		check(r.muzzle != null and dev.is_ancestor_of(r.muzzle) or r.muzzle == dev, "%s: tracer muzzle = the device on the scaled barrel" % g)
		var r2: Dictionary = Rig.apply(m, "auto_rifle", {"barrel": "long_spine_barrel"})
		var lm: Node3D = Rig.find_node(r2.attached.barrel, "Muzzle")
		check(absf(Rig.gun_point(m, lm).x - (Rig.gun_point(m, Rig.find_node(m, "Barrel")).x + 0.62 * s)) < 1e-4 and r2.muzzle == lm,
			"%s: Long Spine (0.62) muzzle = Barrel.x + 0.62 x s; tracers start there" % g)

	# ------------------------------------------------------------ revolver
	var hc := _gun(holder, "weapon_hand_cannon")
	var cyl: Node3D = Rig.find_node(hc, "Cylinder")
	check(cyl is MeshInstance3D and Rig.find_node(hc, "MagWell").get_parent() == cyl and Rig.find_node(hc, "DefaultMag").get_parent() == cyl,
		"revolver: Cylinder mesh, MagWell + DefaultMag ride on it")
	var hr: Dictionary = Rig.apply(hc, "hand_cannon", {"optic": "pinhole", "barrel": "fluted_cooler", "mag": "speedloader_ring",
		"grip": "fence_post", "stock": "padded_stock"})
	check(hr.skipped.has("grip") and hr.skipped.has("stock") and not hr.attached.has("grip") and not hr.attached.has("stock")
		and Rig.find_node(hc, "Att_grip") == null and hr.missing.is_empty(), "revolver: no Underbarrel/Stock socket -> grip + stock skipped cleanly (%s)" % [hr.skipped])
	check(hr.attached.mag.get_parent() == Rig.find_node(hc, "MagWell") and cyl.is_ancestor_of(hr.attached.mag), "speedloader sits in the cylinder (spins with it)")
	Rig.apply(hc, "hand_cannon", {"barrel": "fluted_cooler"})
	var irons: Node3D = Rig.find_node(hc, "IronSights") as MeshInstance3D
	var ia: AABB = Rig.gun_xform(hc, irons) * irons.get_aabb()
	check(irons.visible and not Rig.find_node(hc, "DefaultBarrel").visible and ia.end.x > 0.19,
		"revolver front sight is in IronSights and stays visible with a barrel fitted (IronSights to x %.3f)" % ia.end.x)
	Rig.apply(hc, "hand_cannon", {"barrel": "sawn_stub"})
	check(irons.visible and not A.is_compatible("sawn_stub", "hand_cannon"),
		"revolver + Sawn Stub (rig only; Armory blocks this fit since 2b) keeps IronSights")
	var hr2: Dictionary = Rig.apply(hc, "hand_cannon", {})
	hr2 = Rig.apply(hc, "hand_cannon", {"muzzle": "flare_cage"})
	var c0: float = cyl.rotation.x
	Rig.on_fire(hr2, 5)
	await _wait(0.15)
	check(absf(cyl.rotation.x - c0 - deg_to_rad(60.0)) < 0.01, "on_fire: cylinder turns one chamber (60 deg on local X)")
	Rig.on_fire(hr2, 4)
	await _wait(0.15)
	check(absf(cyl.rotation.x - c0 - deg_to_rad(120.0)) < 0.01, "second shot: 120 deg")
	Rig.on_reload(hr2, 0.2)
	await _wait(0.3)
	check(absf(cyl.rotation.x - c0 - deg_to_rad(120.0) - TAU) < 0.02, "on_reload: one full cylinder spin")
	Rig.clear(hc)
	check(is_equal_approx(cyl.rotation.x, 0.0), "clear() restores the cylinder rest pose")
	# Revolver ADS sight line through AdsProfile.
	var v := _view_gun(world, "weapon_hand_cannon", float(by_arch.hand_cannon.view.length))
	var vr: Dictionary = Rig.apply(v.model, "hand_cannon", {})
	var sl: Vector3 = Rig.sight_line(vr)
	check(sl.is_equal_approx(Vector3(-0.0035, 0.0793, 0.0)), "revolver sight line = its SightPoint (y 0.0793, real notch line, not bore 0.055)")
	var ads_pos: Vector3 = Ads.ads_gun_position(Rig.ads_offset(vr, v.gun), "hand_cannon")
	v.gun.position = ads_pos
	var eye: float = Ads.ads_eye_distance("hand_cannon")
	var sp_cam: Vector3 = v.cam.to_local((vr.sight as Node3D).global_position)
	check(sp_cam.distance_to(Vector3(0, 0, -eye)) < 1e-4, "ADS pose puts the revolver SightPoint on the screen centre (%s, eye %.2f)" % [sp_cam, eye])
	# Front blade top = highest IronSights vertex ahead of x 0.15 (the rear sight's ears are taller than the notch line).
	var fb := Vector3(0, -INF, 0)
	var arr: Array = irons.mesh.surface_get_arrays(0)
	for vtx in arr[Mesh.ARRAY_VERTEX]:
		var gp: Vector3 = Rig.gun_xform(hc, irons) * vtx
		if gp.x > 0.15 and gp.y > fb.y:
			fb = gp
	var front_top: Vector3 = v.cam.to_local((v.model as Node3D).global_transform * fb)
	check(absf(front_top.y) < 0.0015 and front_top.z < sp_cam.z, "front blade top sits on the sight line too (y %.4f m in camera space)" % front_top.y)
	var bore_cam: Vector3 = v.cam.to_local(Rig.find_node(v.model, "Muzzle").global_position)
	check(bore_cam.y < -0.003, "bore sits below the eye line (%.4f): revolver ADS is 'slightly higher', as Desi noted" % bore_cam.y)
	check(is_equal_approx(Ads.ads_fov("hand_cannon"), 65.0) and Ads.family_for_archetype("hand_cannon") == "sidearm", "hand cannon keeps the sidearm ADS FOV 65")
	var vr2: Dictionary = Rig.apply(v.model, "hand_cannon", {"optic": "pinhole"})
	v.gun.position = Ads.ads_gun_position(Rig.ads_offset(vr2, v.gun), "hand_cannon")
	check(v.cam.to_local((vr2.sight as Node3D).global_position).distance_to(Vector3(0, 0, -eye)) < 1e-4 and vr2.attached.optic.is_ancestor_of(vr2.sight),
		"with a Pinhole the optic's SightPoint takes the screen centre")
	# AR irons (bore-height SightPoint): top of IronSights on the centre line.
	var va := _view_gun(world, "weapon_assault_rifle", float(by_arch.auto_rifle.view.length))
	var var_: Dictionary = Rig.apply(va.model, "auto_rifle", {})
	va.gun.position = Ads.ads_gun_position(Rig.ads_offset(var_, va.gun), "auto_rifle")
	var ai: Node3D = Rig.find_node(va.model, "IronSights") as MeshInstance3D
	var aa: AABB = Rig.gun_xform(va.model, ai) * ai.get_aabb()
	check(absf(Rig.sight_line(var_).y - aa.end.y) < 1e-4 and absf(va.cam.to_local((va.model as Node3D).global_transform * Rig.sight_line(var_)).y) < 1e-4,
		"bore-height SightPoint guns (AR) align the IronSights top on the centre line")

	# ------------------------------------------------------------ scout stock fix
	var sc := _gun(holder, "weapon_scout_rifle")
	var body: Node3D = Rig.find_node(sc, "Body") as MeshInstance3D
	var body_rear: float = (Rig.gun_xform(sc, body) * body.get_aabb()).position.x
	var ssock: Node3D = Rig.find_node(sc, "Stock")
	check(absf(ssock.position.x - (-0.06)) < 0.001 and absf(ssock.position.x - body_rear) < 0.002,
		"scout Stock socket moved to x -0.060 = the receiver's rear face (%.3f)" % body_rear)
	for st in ["wire_stock", "padded_stock", "ratchet_stock"]:
		var sr: Dictionary = Rig.apply(sc, "scout_rifle", {"stock": st})
		var front := -INF
		for mi in (sr.attached.stock as Node3D).find_children("*", "MeshInstance3D", true, false):
			front = maxf(front, (Rig.gun_xform(sc, mi) * (mi as MeshInstance3D).get_aabb()).end.x)
		check(absf(front - body_rear) < 0.012, "scout + %s seats flush on the receiver (gap %.3f m)" % [st, body_rear - front])

	# ------------------------------------------------------------ rocket launcher + projectile
	var rl := _gun(holder, "weapon_rocket_launcher")
	var rr: Dictionary = Rig.apply(rl, "rocket_launcher", {"optic": "crows_eye_3x", "mag": "quickpull_clip", "barrel": "sawn_stub", "stock": "wire_stock"})
	check(rr.rocket != null and rr.rocket.visible and rr.skipped.has("barrel") and rr.skipped.has("stock") and rr.attached.has("mag"),
		"launcher: Rocket found, no Barrel/Stock socket -> skipped; mag on MagWell")
	Rig.on_fire(rr, 0)
	check(not rr.rocket.visible, "on_fire hides the loaded Rocket")
	Rig.on_reload(rr, 0.2)
	check(rr.rocket.visible, "on_reload shows it again")
	Rig.on_fire(rr, 1, 0.1)
	check(not rr.rocket.visible, "fire with rounds left: hidden...")
	await _wait(0.2)
	check(rr.rocket.visible, "...and re-chambered after the fire interval")
	Rig.on_fire(rr, 0)
	Rig.on_reload(rr, 0.0)
	check(rr.rocket.visible, "on_reload(time 0) (reload finished early) shows it")
	var RocketScr = load("res://scripts/combat/rocket.gd")
	var rk = RocketScr.new()
	rk.model_path = str(by_arch.rocket_launcher.projectile.model)
	world.add_child(rk)
	check(rk.visual != null and rk.visual.find_child("Rocket", true, false) is MeshInstance3D and rk.exhaust != null
		and rk.find_children("*", "CylinderMesh", true, false).is_empty(), "rocket.gd instances rocket_projectile.glb (Exhaust found, no CylinderMesh)")
	var nose: Node3D = rk.visual.find_child("Nose", true, false)
	rk.look_at(rk.global_position + Vector3(1, 0, 0), Vector3.UP)
	check(nose != null and (nose.global_position - rk.global_position).normalized().dot(Vector3(1, 0, 0)) > 0.99,
		"projectile nose points along the flight direction (-Z = look_at forward, no extra rotation)")
	rk.queue_free()
	var rk2 = RocketScr.new()
	world.add_child(rk2)
	check(rk2.visual == null and rk2.get_child_count() >= 2, "rocket.gd without a model path keeps the procedural cylinder")
	rk2.queue_free()

	# ------------------------------------------------------------ uniques
	var g1 := _gun(holder, "weapon_assault_rifle")
	var gr: Dictionary = Rig.apply(g1, "auto_rifle", {"optic": "gravesight", "grip": "second_mouth"})
	var lens: Node3D = Rig.find_node(gr.attached.optic, "Lens") as MeshInstance3D
	var base_e: float = (lens.mesh.surface_get_material(0) as StandardMaterial3D).emission_energy_multiplier if lens.mesh.surface_get_material(0) else (lens.get_active_material(0) as StandardMaterial3D).emission_energy_multiplier
	check(bool(A.attachment("gravesight").flags.outline_elites) and gr.glow.size() == 2 and absf(Rig.glow_energy(gr) - base_e * Rig.GLOW_ON) < 0.01,
		"Gravesight: outline_elites drives the Lens glow (%.2f -> %.2f)" % [base_e, Rig.glow_energy(gr)])
	Rig.set_glow(gr, 0.0)
	var g2 := _gun(holder, "weapon_assault_rifle")
	var gr2: Dictionary = Rig.apply(g2, "auto_rifle", {"optic": "gravesight"})
	check(absf(Rig.glow_energy(gr) - base_e * Rig.GLOW_OFF) < 0.01 and absf(Rig.glow_energy(gr2) - base_e * Rig.GLOW_ON) < 0.01,
		"glow is per instance (dimming one Gravesight leaves the other lit)")
	check(gr.launcher != null and str(gr.launcher.name) == "LauncherMuzzle" and str(gr.launcher.get_parent().name) == "Tube",
		"Second Mouth: rig.launcher = Tube/LauncherMuzzle")
	var se: Dictionary = A.attachment("second_mouth").effects[0]
	check(str(se.params.get("from", "")) == "LauncherMuzzle", "second_mouth effect fires from LauncherMuzzle (data)")
	var stub_src := GDScript.new()
	stub_src.source_code = "extends Node3D\nvar _gun_rig: Dictionary = {}\nvar player\n"
	stub_src.reload()
	var stub: Node3D = stub_src.new()
	world.add_child(stub)
	stub.set("_gun_rig", gr)
	stub.set("player", stub) # doubles as the SkillRunner (effect.player = runner.player)
	var eff = load("res://scripts/skills/effects/on_event_explode.gd").new()
	eff.params = se.params
	eff.runner = stub
	var lp = eff.launch_point()
	check(lp is Vector3 and (lp as Vector3).distance_to(gr.launcher.global_position) < 1e-5, "on_event_explode.launch_point() = LauncherMuzzle world position")
	var tube: Node3D = gr.anim.get("tube")
	var t0: Vector3 = tube.position
	Rig.on_reload(gr, 0.4)
	var tmax := -INF
	for i in 40:
		await process_frame
		tmax = maxf(tmax, tube.position.x)
	await _wait(0.3)
	check(tmax > t0.x + 0.01, "Second Mouth tube racks +X on reload (peak +%.3f)" % (tmax - t0.x))
	check(tube.position.distance_to(t0) < 0.002, "...and returns")
	# Heartbeat Counter
	check(Rig.hides_for("heartbeat_counter") == [] and A.attachment("heartbeat_counter").hides == [], "Heartbeat Counter hides [] (data)")
	var hb_g := _gun(holder, "weapon_smg")
	var hbr: Dictionary = Rig.apply(hb_g, "smg", {"optic": "heartbeat_counter"})
	check(Rig.find_node(hb_g, "IronSights").visible and hbr.hidden.is_empty() and hbr.sight == Rig.find_node(hb_g, "SightPoint"),
		"Heartbeat keeps the iron sights + iron ADS sight point")
	var lbl: Label3D = hbr.heartbeat
	check(lbl != null and str(lbl.get_parent().name) == "ScreenAnchor", "Heartbeat Label3D sits on ScreenAnchor")
	var foes: Array = []
	for i in 4:
		var e := Node3D.new()
		e.add_to_group("enemies")
		world.add_child(e)
		e.global_position = hb_g.global_position + Vector3(2.0 + i, 0, 0) if i < 3 else hb_g.global_position + Vector3(25, 0, 0)
		foes.append(e)
	check(lbl.refresh() == 3 and lbl.text == "3", "Heartbeat counts enemies within 10 m (3 near, 1 at 25 m)")
	for e in foes:
		e.queue_free()
	# Lantern Rail beam (same Glass / BeamHint as the Mine Lamp)
	var lr_g := _gun(holder, "weapon_shotgun")
	var lrr: Dictionary = Rig.apply(lr_g, "shotgun", {"grip": "lantern_rail"})
	check(lrr.lamp != null and lrr.lamp == lrr.attached.grip and Rig.find_node(lrr.lamp, "Glass") != null and Rig.find_node(lrr.lamp, "BeamHint") != null,
		"Lantern Rail sets rig.lamp (Glass + BeamHint)")
	prog.gravemarks = 999
	A.buy_attachment("lantern_rail")
	A.equip("auto_rifle", "lantern_rail")
	var lfc: Dictionary = A.flashlight_config("auto_rifle")
	check(A.has_flashlight("auto_rifle") and A.has_mine_lamp("auto_rifle") and lfc.color is Color
		and lfc.color.is_equal_approx(Color(1.0, 0.86, 0.62)) and is_equal_approx(float(lfc.light_angle), 24.0),
		"Lantern Rail equipped: F beam enabled (has_mine_lamp) with its own warm light values")
	A.equip("auto_rifle", "mine_lamp")
	check(is_equal_approx(float(A.flashlight_config("auto_rifle").light_angle), 28.0), "Mine Lamp back: its own beam values")
	# Bonesaw reach
	var bexp := {"weapon_assault_rifle": 0.26, "weapon_smg": 0.18, "weapon_shotgun": 0.28, "weapon_lmg": 0.46, "weapon_scout_rifle": 0.38}
	for g in bexp:
		var bg := _gun(holder, g)
		var br: Dictionary = Rig.apply(bg, "auto_rifle", {"grip": "bonesaw_bayonet"})
		var blade: Node3D = Rig.find_node(br.attached.grip, "Blade")
		var want: float = Rig.find_node(bg, "Muzzle").position.x - Rig.find_node(bg, "Underbarrel").position.x - 0.10
		check(absf(blade.position.x - want) < 1e-4 and absf(want - float(bexp[g])) < 1e-4, "%s Bonesaw Blade.x = Muzzle.x - Underbarrel.x - 0.10 = %.2f" % [g, want])

	# ------------------------------------------------------------ decisions
	var sg := _gun(holder, "weapon_shotgun")
	var sgr: Dictionary = Rig.apply(sg, "shotgun", {"barrel": "sawn_stub"})
	check(not Rig.find_node(sg, "IronSights").visible and sgr.hidden.has("IronSights") and not Rig.find_node(sg, "DefaultBarrel").visible
		and Rig.hides_for("sawn_stub", "barrel", "shotgun") == ["DefaultBarrel", "DefaultMuzzle", "IronSights", "DefaultMag"], "shotgun + Sawn Stub hides the bead + mag tube (hides_by_class)")
	var ss2 := _gun(holder, "weapon_smg")
	Rig.apply(ss2, "smg", {"barrel": "sawn_stub"})
	check(Rig.find_node(ss2, "IronSights").visible and Rig.hides_for("sawn_stub") == ["DefaultBarrel", "DefaultMuzzle"], "Sawn Stub on other guns keeps IronSights")
	check(not A.is_compatible("ember_window_mag", "hand_cannon") and A.is_compatible("ember_window_mag", "sidearm")
		and A.is_compatible("ember_window_mag", "auto_rifle"), "Ember Window Mag: hand_cannon dropped from its classes")

	# ------------------------------------------------------------ optional part animations
	var ed := _gun(holder, "weapon_assault_rifle")
	var edr: Dictionary = Rig.apply(ed, "auto_rifle", {"mag": "echo_drum", "stock": "ratchet_stock"})
	var dial: Node3D = edr.anim.get("dial")
	var d0: float = dial.rotation.z
	Rig.on_fire(edr, 10)
	var slider: Node3D = edr.anim.get("slider")
	var s0: Vector3 = slider.position
	Rig.set_ads(edr, true)
	await _wait(0.2)
	check(absf(dial.rotation.z - d0) > 0.3 and slider.position.x < s0.x - 0.015, "Echo Drum dial ticks on fire, Ratchet Stock slider extends on ADS")
	Rig.set_ads(edr, false)
	var spr: Dictionary = Rig.apply(hc, "hand_cannon", {"mag": "speedloader_ring"})
	var spl: Node3D = spr.anim.get("speedloader")
	Rig.on_reload(spr, 0.2)
	var mid_x: float = spl.position.x
	await _wait(0.2)
	check(mid_x < -0.02 and absf(spl.position.x) < 1e-3, "speedloader seats from 3 cm behind on reload")

	# ------------------------------------------------------------ Gravemark pickup model
	var GP = load("res://scripts/items/gravemark_pickup.gd")
	var pm := str(A.cfg().currency.pickup_model)
	check(pm == "res://assets/models/pickups/gravemark.glb" and ResourceLoader.exists(pm) and GP.pickup_model_path() == pm,
		"armory.json pickup_model = gravemark.glb (copied + imported)")
	var tok: Node3D = GP.spawn(world, Vector3(3, 0, 3), 2)
	await process_frame
	check(tok != null and tok.get_node_or_null("Model") != null and tok.get_node("Model").find_child("StampGlow", true, false) != null,
		"Gravemark token spawns Desi's gravemark.glb (StampGlow inlay)")
	check(GP.spawn(null, Vector3.ZERO, 1) == null, "spawn() is a no-op without a scene (tests / headless)")
	var old_scene = current_scene
	current_scene = world
	var boss := Node3D.new()
	boss.set_meta("is_boss", true)
	boss.set_meta("boss_id", "bellwether")
	world.add_child(boss)
	prog.match_gravemarks = 0
	var before := world.get_children().filter(func(c): return c.get_script() == GP).size()
	var paid: int = A.on_zombie_died(boss, 7)
	var after := world.get_children().filter(func(c): return c.get_script() == GP).size()
	check(paid > 0 and after > before, "boss kill pays %d and pops a Gravemark token in the scene" % paid)
	current_scene = old_scene


# ================================================================== art pass 2b (G4M3N follow-up)

const PENDING_LOG := "user://art_test_pending.txt"
var _pending: Array = []


func _pend(what: String) -> void:
	_pending.append(what)
	print("PENDING  " + what)


## Highest IronSights vertex in the front half (gun root space): the front post / bead, not the rear sight.
func _front_post_top(Rig, model: Node3D) -> Vector3:
	var irons := Rig.find_node(model, "IronSights") as MeshInstance3D
	if irons == null or irons.mesh == null:
		return Vector3(0, -INF, 0)
	var xf: Transform3D = Rig.gun_xform(model, irons)
	var mid: float = (xf * irons.get_aabb()).get_center().x
	var best := Vector3(0, -INF, 0)
	for si in irons.mesh.get_surface_count():
		for vtx in irons.mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
			var gp: Vector3 = xf * vtx
			if gp.x > mid and gp.y > best.y:
				best = gp
	return best


## Built-in scope axis in gun space: centre (y, z) of the DefaultOptic vertices in the eyepiece ring (within 1 cm of
## OpticSightPoint's x), so the mount below the tube doesn't drag it down.
func _scope_axis(Rig, model: Node3D, dopt: Node3D) -> Vector3:
	var osp: Vector3 = Rig.gun_point(model, Rig.find_node(model, "OpticSightPoint"))
	var lo := Vector3(INF, INF, INF)
	var hi := -lo
	for mi in ([dopt] if dopt is MeshInstance3D else []) + dopt.find_children("*", "MeshInstance3D", true, false):
		var xf: Transform3D = Rig.gun_xform(model, mi)
		for si in (mi as MeshInstance3D).mesh.get_surface_count():
			for vtx in (mi as MeshInstance3D).mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]:
				var gp: Vector3 = xf * vtx
				if absf(gp.x - osp.x) <= 0.01:
					lo = lo.min(gp)
					hi = hi.max(gp)
	if lo.x == INF:
		return osp
	return Vector3(osp.x, (lo.y + hi.y) * 0.5, (lo.z + hi.z) * 0.5)


func _art_pass2b(A, Rig, world: Node3D, holder: Node3D, by_arch: Dictionary) -> void:
	var Ads = load("res://scripts/combat/ads_profile.gd")
	var gdb = root.get_node("GearDB")
	# ------------------------------------------------------------ rocket re-chamber only with a round left (mag 1 / mag 3)
	var PlayerStub := GDScript.new()
	PlayerStub.source_code = "extends Node3D\nvar w\nfunc current_weapon():\n\treturn w\n"
	PlayerStub.reload()
	var pl: Node3D = PlayerStub.new()
	holder.add_child(pl)
	var w = gdb.roll_weapon("rocket_launcher", 0, 1)
	pl.w = w
	var meta_key = w.MAG_BONUS_META
	var old_bonus = Engine.get_meta(meta_key, 0.0)
	Engine.set_meta(meta_key, 0.0)
	check(w.archetype == "rocket_launcher" and w.mag_size() == 1, "launcher base mag = 1")
	var lm := _gun(pl, "weapon_rocket_launcher")
	var rig: Dictionary = Rig.apply(lm, "rocket_launcher", {})
	var rkt: Node3D = rig.rocket
	var iv := 0.12
	w.ammo = w.mag_size()
	check(Rig.live_ammo(lm, "rocket_launcher") == 1 and Rig.live_ammo(lm, "smg") == -1 and Rig.live_ammo(holder) == -1,
		"live_ammo reads player.current_weapon().ammo (only for the matching archetype)")
	w.ammo -= 1
	Rig.on_fire(rig, w.ammo, iv)
	await _wait(iv + 0.15)
	check(not rkt.visible, "mag 1: after the fire interval the empty launcher stays empty")
	rig = Rig.apply(lm, "rocket_launcher", {})
	check(not rig.rocket.visible, "mag 1: refit / swap back to an empty launcher keeps the Rocket hidden")
	Rig.on_reload(rig, 0.2)
	check(rkt.visible, "mag 1: reload shows the Rocket")
	w.ammo = 1
	Rig.on_reload(rig, 0.0)
	check(rkt.visible, "mag 1: reload finish keeps it shown")
	# skill-boosted magazine of 3 (Engine meta = Deep Pockets / Field Card bonus, same as player.recalc_stats)
	var bonus := 0.0
	while w.mag_size() < 3 and bonus < 10.0:
		bonus += 0.05
		Engine.set_meta(meta_key, bonus)
	check(w.mag_size() == 3, "skill bonus %.2f -> launcher mag 3" % bonus)
	w.ammo = w.mag_size()
	w.ammo -= 1
	Rig.on_fire(rig, w.ammo, iv)
	check(not rkt.visible, "mag 3, shot 1: Rocket hidden")
	await _wait(iv + 0.1)
	check(rkt.visible, "mag 3, shot 1: 2 left -> re-chambered after the fire interval")
	w.ammo -= 1
	Rig.on_fire(rig, w.ammo, iv)
	await _wait(iv * 0.4)
	w.ammo -= 1
	Rig.on_fire(rig, w.ammo, iv)  # last round fired before shot 2's re-chamber timer runs out
	await _wait(iv + 0.15)
	check(not rkt.visible and w.ammo == 0, "mag 3, shot 3: shot 2's late timer doesn't re-show it; empty until reload")
	Rig.on_reload(rig, 0.0)
	w.ammo = w.mag_size()
	check(rkt.visible, "mag 3: reload shows it")
	w.ammo -= 1
	Rig.on_fire(rig, 2, iv)
	w.ammo = 0  # mag drained some other way before the timer (live ammo beats the stale hook arg)
	await _wait(iv + 0.15)
	check(not rkt.visible, "the timer checks the live magazine, not the ammo passed at fire time")
	Engine.set_meta(meta_key, old_bonus)
	# no player above the model (Armory preview / tests): the hook's ammo_after decides, newest call wins
	var lm2 := _gun(holder, "weapon_rocket_launcher")
	var rig2: Dictionary = Rig.apply(lm2, "rocket_launcher", {})
	Rig.on_fire(rig2, 1, iv)
	Rig.on_fire(rig2, 0, iv)
	await _wait(iv + 0.15)
	check(not rig2.rocket.visible, "no player: a stale timer after the last round does nothing")
	Rig.on_reload(rig2, 0.0)
	Rig.on_fire(rig2, 2, iv)
	await _wait(iv + 0.15)
	check(rig2.rocket.visible, "no player: ammo_after > 0 re-chambers")
	pl.w = null
	w = null
	pl.free()
	lm2.free()
	PlayerStub = null

	# ------------------------------------------------------------ Sawn Stub fits (Armory side is in armory_test)
	check(not A.is_compatible("sawn_stub", "hand_cannon") and not A.is_compatible("sawn_stub", "pulse_rifle")
		and A.is_compatible("sawn_stub", "shotgun") and A.exclusion_reason("bonesaw_bayonet", "smg",
		{"barrel": "sawn_stub"}) != "", "data: no Sawn Stub on revolver/LMG; SMG Sawn Stub x Bonesaw excluded")

	# ------------------------------------------------------------ shotgun barrel band (Desi bandsplit 12:28: band merged into DefaultBarrel)
	var sg := _gun(holder, "weapon_shotgun")
	var db: Node3D = Rig.find_node(sg, "DefaultBarrel")
	var sbody := Rig.find_node(sg, "Body") as MeshInstance3D
	var body_end: float = (Rig.gun_xform(sg, sbody) * sbody.get_aabb()).end.x
	var sgr: Dictionary = Rig.apply(sg, "shotgun", {"barrel": "sawn_stub"})
	var stub_aabb := AABB()
	var first := true
	for mi in (sgr.attached.barrel as Node).find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = Rig.gun_xform(sg, mi) * (mi as MeshInstance3D).get_aabb()
		stub_aabb = bb if first else stub_aabb.merge(bb)
		first = false
	var stub_end: float = stub_aabb.end.x
	var past: Array = []
	var mag_past := 0.0
	for mi in sg.find_children("*", "MeshInstance3D", true, false):
		if not (mi as MeshInstance3D).is_visible_in_tree() or Rig._inside_attachment(mi, sg):
			continue
		var e: float = (Rig.gun_xform(sg, mi) * (mi as MeshInstance3D).get_aabb()).end.x
		if str(mi.name) == "DefaultMag":
			mag_past = e - stub_end
		elif e > stub_end + 0.005:
			past.append("%s %.3f" % [mi.name, e])
	var all_hidden := true
	for n in db.find_children("*", "Node3D", true, false) + sg.find_children("DefaultBarrel_*", "Node3D", true, false):
		all_hidden = all_hidden and not (n as Node3D).is_visible_in_tree()
	if body_end > stub_end + 0.005:
		_pend("shotgun barrel band: Body still reaches x %.3f (> Sawn Stub end %.3f); hides automatically once it moves into DefaultBarrel" % [body_end, stub_end])
	else:
		check(not db.visible and all_hidden and sbody.visible and past.is_empty(),
			"shotgun bandsplit landed: Body ends at x %.3f (band in DefaultBarrel), Sawn Stub (to %.3f) hides it; nothing but the mag tube past the stub %s" % [body_end, stub_end, past])
	# Art pass 2c (G4M3N approved): the under-barrel tube (its own DefaultMag mesh) hides with Sawn Stub on the shotgun only.
	var stube := Rig.find_node(sg, "DefaultMag") as MeshInstance3D
	var tube_end: float = (Rig.gun_xform(sg, stube) * stube.get_aabb()).end.x
	check(stube != null and not stube.visible and sgr.hidden.has("DefaultMag") and mag_past == 0.0 and tube_end > stub_end + 0.005,
		"shotgun + Sawn Stub hides the DefaultMag tube (it ran to x %.3f, %.0f mm past the stub end %.3f)" % [tube_end, (tube_end - stub_end) * 1000.0, stub_end])
	var sg_mag: Dictionary = Rig.apply(sg, "shotgun", {"barrel": "long_spine_barrel"})
	check(stube.visible and not sg_mag.hidden.has("DefaultMag"), "shotgun with another barrel keeps its tube")
	var smg_t := _gun(holder, "weapon_smg")
	var smg_r: Dictionary = Rig.apply(smg_t, "smg", {"barrel": "sawn_stub"})
	check(Rig.find_node(smg_t, "DefaultMag").visible and not smg_r.hidden.has("DefaultMag"), "Sawn Stub on the SMG keeps its DefaultMag (shotgun-only rule)")
	smg_t.queue_free()
	Rig.apply(sg, "shotgun", {})
	check(db.visible and sbody.visible, "shotgun default barrel (with band) back without a barrel part")
	# synthetic split nodes (a band under DefaultBarrel, or a DefaultBarrel_* sibling) hide with it too
	var fake_band := MeshInstance3D.new()
	fake_band.name = "Band"
	db.add_child(fake_band)
	var fake_sib := MeshInstance3D.new()
	fake_sib.name = "DefaultBarrel_Band"
	db.get_parent().add_child(fake_sib)
	sgr = Rig.apply(sg, "shotgun", {"barrel": "sawn_stub"})
	check(not fake_band.is_visible_in_tree() and not fake_sib.visible and sgr.hidden.has("DefaultBarrel_Band"),
		"a band under DefaultBarrel or named DefaultBarrel_* hides with the barrel")
	Rig.apply(sg, "shotgun", {})
	check(fake_band.is_visible_in_tree() and fake_sib.visible, "...and is restored without a barrel part")
	sg.queue_free()

	# ------------------------------------------------------------ ADS table, every gun (art pass 3: Desi's notch pass 12:57)
	# SightPoint = front post / bead tip on every gun now (scout 0.1165, LMG 0.1550, sniper 0.0895, shotgun 0.0830).
	# Aim: the front post top < 2 mm off the eye line at ADS. The sniper is measured on its backup irons (DefaultOptic
	# hidden) and, with the default scope on, from OpticSightPoint (child of DefaultOptic) against the scope axis.
	var ads_rows: Array = []
	var archs: Array = by_arch.keys()
	archs.sort()
	for arch in archs:
		var mp := str(by_arch[arch].get("model", ""))
		if not mp.begins_with(GUN.get_slice("%s", 0)):
			continue
		var g := mp.get_file().get_basename()
		var v := _view_gun(world, g, float(by_arch[arch].view.length))
		var r: Dictionary = Rig.apply(v.model, arch, {})
		var irons: Node3D = Rig.find_node(v.model, "IronSights")
		if r.get("sight") == null or irons == null:
			ads_rows.append("%s (%s): no SightPoint / IronSights" % [g, arch])
			(v.cam as Node).queue_free()
			continue
		var dopt: Node3D = Rig.find_node(v.model, "DefaultOptic")
		var osp: Node3D = Rig.find_node(v.model, "OpticSightPoint")
		if dopt:
			dopt.visible = false # irons first (the sniper's backup irons)
		var sp: Vector3 = Rig.gun_point(v.model, r.sight)
		v.gun.position = Ads.ads_gun_position(Rig.ads_offset(r, v.gun), arch)
		var eye: float = Ads.ads_eye_distance(arch)
		var line: Vector3 = v.cam.to_local((v.model as Node3D).global_transform * Rig.sight_line(r))
		var ft: Vector3 = _front_post_top(Rig, v.model)
		var front_mm: float = v.cam.to_local((v.model as Node3D).global_transform * ft).y * 1000.0
		var gun_mm: float = (ft.y - sp.y) * 1000.0
		check(Rig.sight_line(r).is_equal_approx(sp) and line.distance_to(Vector3(0, 0, -eye)) < 1e-4,
			"%s: SightPoint (y %.4f) is the sight line, on the screen centre at ADS" % [g, sp.y])
		# art4: Desi's 14:47 launcher (sight fix + finish) brought it from +2.71 mm to +0.45 mm, so every gun is a hard check now.
		check(absf(front_mm) < 2.0, "%s ADS: front post %.2f mm off the eye line (< 2 mm)" % [g, front_mm])
		var row := "%-22s %-13s SightPoint y %.4f  front post %+.2f mm on screen (%+.2f mm in gun)" % [g, arch, sp.y, front_mm, gun_mm]
		if dopt and osp:
			dopt.visible = true
			check(Rig.sight_line(r).is_equal_approx(Rig.gun_point(v.model, osp)), "%s: OpticSightPoint is the sight line while DefaultOptic shows" % g)
			v.gun.position = Ads.ads_gun_position(Rig.ads_offset(r, v.gun), arch)
			var oline: Vector3 = v.cam.to_local((v.model as Node3D).global_transform * Rig.sight_line(r))
			var axis := _scope_axis(Rig, v.model, dopt)
			var axis_cam: Vector3 = v.cam.to_local((v.model as Node3D).global_transform * axis)
			var axis_mm := Vector2(axis_cam.x, axis_cam.y).length() * 1000.0
			check(oline.distance_to(Vector3(0, 0, -eye)) < 1e-4 and axis_mm < 2.0,
				"%s scope: OpticSightPoint on the screen centre, scope axis %.2f mm off it (< 2 mm)" % [g, axis_mm])
			row += " | scope: OpticSightPoint y %.4f, scope axis %.2f mm off centre" % [Rig.gun_point(v.model, osp).y, axis_mm]
		ads_rows.append(row)
		(v.cam as Node).queue_free()
	print("ADS_TABLE\n  " + "\n  ".join(ads_rows))
	# a fitted optic's SightPoint still wins over the built-in scope
	var vs := _view_gun(world, "weapon_sniper", float(by_arch.sniper_rifle.view.length))
	var rs: Dictionary = Rig.apply(vs.model, "sniper_rifle", {"optic": "crows_eye_3x"})
	check(rs.attached.has("optic") and (rs.attached.optic as Node3D).is_ancestor_of(rs.sight)
		and Rig.sight_line(rs).is_equal_approx(Rig.gun_point(vs.model, rs.sight)), "sniper: a fitted optic's SightPoint still wins over OpticSightPoint")
	check(Rig.find_node(vs.model, "OpticSightPoint") != null and Rig.find_node(vs.model, "OpticSightPoint").get_parent().name == "DefaultOptic",
		"weapon_sniper.glb: OpticSightPoint is a child of DefaultOptic")
	(vs.cam as Node).queue_free()
	var f := FileAccess.open(PENDING_LOG, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(_pending) + "\n")



# ================================================================== art pass 3 (sawn_stub MagTubeStub, Shell Saddle clash)

func _mesh_box(Rig, model: Node3D, n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in ([n] if n is MeshInstance3D else []) + n.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = Rig.gun_xform(model, mi) * (mi as MeshInstance3D).get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	return box


func _art_pass3(A, Rig, holder: Node3D) -> void:
	# Sawn Stub's MagTubeStub (Desi 12:54): shown on the shotgun only, hidden on every other host
	var hosts := {"weapon_shotgun": "shotgun", "weapon_smg": "smg", "weapon_assault_rifle": "auto_rifle",
		"weapon_scout_rifle": "scout_rifle", "weapon_sniper": "sniper_rifle"}
	check(A.is_compatible("sawn_stub", "shotgun") and Rig.inner_hides_for("sawn_stub", "shotgun").is_empty()
		and Rig.inner_hides_for("sawn_stub", "smg") == ["MagTubeStub"], "inner_hides: MagTubeStub hidden everywhere but the shotgun")
	for g in hosts:
		var arch: String = hosts[g]
		var m := _gun(holder, g)
		var r: Dictionary = Rig.apply(m, arch, {"barrel": "sawn_stub"})
		var stub: Node3D = r.attached.get("barrel")
		var mts: Node3D = Rig.find_node(stub, "MagTubeStub") if stub else null
		if arch == "shotgun":
			var mb := _mesh_box(Rig, m, mts) if mts else AABB()
			var stub_end: float = _mesh_box(Rig, m, Rig.find_node(stub, "Mesh")).end.x
			var dm := Rig.find_node(m, "DefaultMag") as Node3D
			check(mts != null and mts.is_visible_in_tree() and dm != null and not dm.visible and r.hidden.has("DefaultMag"),
				"shotgun + Sawn Stub: MagTubeStub shows, DefaultMag still hidden")
			check(mts != null and mb.end.x <= stub_end + 0.003, "shotgun MagTubeStub ends at x %.3f, inside the stub (end %.3f)" % [mb.end.x, stub_end])
			# Shell Saddle on top: its TubeMag runs past the stub and overlaps MagTubeStub -> the exclusion rule
			var r2: Dictionary = Rig.apply(m, arch, {"barrel": "sawn_stub", "mag": "shell_saddle"})
			var sad: Node3D = r2.attached.get("mag")
			var tube: Node3D = Rig.find_node(sad, "TubeMag") if sad else null
			var tb := _mesh_box(Rig, m, tube) if tube else AABB()
			var mts2: Node3D = Rig.find_node(r2.attached.barrel, "MagTubeStub")
			var mb2 := _mesh_box(Rig, m, mts2)
			check(tube != null and tb.end.x > stub_end + 0.03 and tb.intersects(mb2),
				"clash proof: Shell Saddle TubeMag reaches x %.3f (%.0f mm past the stub) and overlaps MagTubeStub" % [tb.end.x, (tb.end.x - stub_end) * 1000.0])
			check(not A.exclusion_reason("shell_saddle", "shotgun", {"barrel": "sawn_stub"}).is_empty(), "...so the pair is an Armory exclusion")
		else:
			check(stub != null and mts != null and not mts.visible, "%s + Sawn Stub: MagTubeStub hidden" % arch)
		m.queue_free()
