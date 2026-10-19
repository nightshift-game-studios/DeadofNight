extends SceneTree
## Art wiring pass (Skillz, 2026-10-19): Desi's boss GLBs + clips + sockets, Echo Walker height, split-mesh guns per
## archetype, WeaponRig attachment show/hide, Mine Lamp light_energy, Armory.item_power_breakdown.
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
	DirAccess.remove_absolute(prog.save_path)
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
	var want := {"sidearm": "weapon_pistol", "hand_cannon": "weapon_pistol", "auto_rifle": "weapon_assault_rifle",
		"scout_rifle": "weapon_scout_rifle", "smg": "weapon_smg", "shotgun": "weapon_shotgun", "pulse_rifle": "weapon_lmg",
		"sniper_rifle": "weapon_sniper"}
	var wdata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/weapons.json"))
	var by_arch := {}
	for a in wdata.archetypes:
		by_arch[str(a.id)] = a
	for arch in want:
		var mp := str(by_arch[arch].model)
		check(mp == "res://assets/models/weapons/%s.glb" % want[arch] and ResourceLoader.exists(mp), "%s -> %s" % [arch, want[arch]])
	check(ResourceLoader.exists(str(by_arch.rocket_launcher.model)), "rocket launcher keeps its legacy model (no split gun yet)")
	var sockets_full := ["Muzzle", "SightPoint", "Rail", "Underbarrel", "MagWell", "Stock", "Barrel"]
	for g in ["weapon_assault_rifle", "weapon_scout_rifle", "weapon_sniper", "weapon_shotgun", "weapon_smg", "weapon_lmg", "weapon_pistol"]:
		var gm: Node3D = (load("res://assets/models/weapons/%s.glb" % g) as PackedScene).instantiate()
		var need: Array = ["Muzzle", "SightPoint", "Rail", "MagWell"] if g == "weapon_pistol" else sockets_full
		var miss := need.filter(func(s): return Rig.find_node(gm, s) == null)
		check(miss.is_empty() and Rig.find_node(gm, "Body") != null and Rig.find_node(gm, "IronSights") != null, "%s sockets + Body/IronSights (missing %s)" % [g, miss])
		gm.free()

	# ------------------------------------------------------------ attachments: models + show/hide
	var shipped := 0
	for a in A.data().attachments:
		if Rig.has_model(str(a.id)):
			shipped += 1
	check(shipped == 17, "17 attachment GLBs wired (16 + mine_lamp), got %d" % shipped)
	check(ResourceLoader.exists("res://assets/icons/att_mine_lamp.png"), "att_mine_lamp.png copied to assets/icons")
	check(Rig.hides_for("crows_eye_3x") == ["IronSights", "DefaultOptic"] and Rig.hides_for("hush_can") == ["DefaultMuzzle"]
		and Rig.hides_for("fence_post") == ["DefaultGrip"] and Rig.hides_for("mine_lamp") == [], "slot hides (Mine Lamp hides nothing)")
	var pl: Dictionary = Rig.plan({"optic": "crows_eye_3x", "muzzle": "hush_can", "grip": "mine_lamp", "mag": "fat_drum"})
	check(pl.attach.optic.socket == "Rail" and pl.attach.muzzle.socket == "Muzzle" and pl.attach.grip.socket == "Underbarrel"
		and pl.missing == ["fat_drum"] and not pl.hide.has("DefaultMag") and not pl.hide.has("DefaultGrip"),
		"plan: sockets Rail/Muzzle/Underbarrel; unshipped mag listed missing, DefaultMag kept")

	var holder := Node3D.new()
	world.add_child(holder)
	var ar: Node3D = (load("res://assets/models/weapons/weapon_assault_rifle.glb") as PackedScene).instantiate()
	holder.add_child(ar)
	ar.scale = Vector3.ONE * 0.6
	var rig: Dictionary = Rig.apply(ar, "auto_rifle", {"optic": "crows_eye_3x", "muzzle": "hush_can", "grip": "mine_lamp", "mag": "fat_drum"})
	check(rig.attached.optic.get_parent() == Rig.find_node(ar, "Rail") and rig.attached.muzzle.get_parent() == Rig.find_node(ar, "Muzzle")
		and rig.attached.grip.get_parent() == Rig.find_node(ar, "Underbarrel"), "attachments instanced on Rail / Muzzle / Underbarrel")
	check(not Rig.find_node(ar, "IronSights").visible and not Rig.find_node(ar, "DefaultMuzzle").visible, "optic hides IronSights, can hides DefaultMuzzle")
	check(Rig.find_node(ar, "DefaultMag").visible and Rig.find_node(ar, "DefaultStock").visible and Rig.find_node(ar, "Body").visible,
		"DefaultMag (no GLB yet), DefaultStock, Body stay visible")
	check(rig.muzzle != null and rig.attached.muzzle.is_ancestor_of(rig.muzzle) and rig.muzzle.global_position.x > Rig.find_node(ar, "Muzzle").global_position.x + 0.05,
		"effective muzzle = the can's front Muzzle (tracers start at the end of the can)")
	check(rig.sight != null and rig.attached.optic.is_ancestor_of(rig.sight), "ADS sight point = the optic's SightPoint")
	check(rig.lamp != null and Rig.find_node(rig.lamp, "Glass") != null, "Mine Lamp housing fitted (Glass child for the lens)")
	check(rig.attached.optic.scale.is_equal_approx(Vector3.ONE) and is_equal_approx(rig.attached.optic.global_transform.basis.get_scale().x, 0.6),
		"attachments inherit the gun's view scale (identity snap, real metres)")
	Rig.clear(ar)
	await process_frame
	check(Rig.visible_parts(ar) == ["Body", "IronSights", "DefaultMag", "DefaultMuzzle", "DefaultStock"] and Rig.find_node(ar, "Att_optic") == null,
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

	world.queue_free()
	DirAccess.remove_absolute(prog.save_path)
	print("ART TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)
