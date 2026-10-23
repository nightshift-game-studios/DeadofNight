extends SceneTree
## Optics lineup (Skillz optics pass, DESIGN.md §19): data validity, pricing curve, ADS merge math (class profile x optic),
## the no-model fallback, WeaponRig sight alignment (synthetic optic GLB stand-in) and Gooey's Armory.optic_profile API.
##   godot --headless --path . -s res://tests/optics_test.gd   (exit code = failures)
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


func _near(a: float, b: float, eps: float = 0.001) -> bool:
	return absf(a - b) <= eps


func _reset(prog: Node) -> void:
	prog.gravemarks = 0
	prog.armory = {"upgrades": {}, "owned": [], "equipped": {}}
	prog.notify_armory("load", "", false)


func _gun(file: String) -> Node3D:
	return (load("res://assets/models/weapons/%s.glb" % file) as PackedScene).instantiate() as Node3D


## Stand-in for a Desi iron-sight GLB (DESI_OPTICS.md node layout): Mesh, SightPoint, Reticle, FrontPost/PostStem.
func _synthetic_optic(path: String) -> void:
	var r := Node3D.new()
	r.name = "wicket_ring"
	var nodes := {}
	for spec in [["Mesh", Vector3(0.0, 0.015, 0.0), true, null], ["SightPoint", Vector3(0.01, 0.034, 0.0), false, null],
			["Reticle", Vector3(0.01, 0.034, 0.0), true, null], ["FrontPost", Vector3(0.05, 0.034, 0.0), false, null],
			["PostStem", Vector3(0.0, -0.006, 0.0), true, "FrontPost"]]:
		var n: Node3D = MeshInstance3D.new() if spec[2] else Node3D.new()
		if n is MeshInstance3D:
			var bm := BoxMesh.new()
			bm.size = Vector3(0.004, 0.01, 0.004)
			(n as MeshInstance3D).mesh = bm
		n.name = spec[0]
		(nodes[spec[3]] if spec[3] else r).add_child(n)
		n.position = spec[1]
		n.owner = r
		nodes[spec[0]] = n
	var ps := PackedScene.new()
	ps.pack(r)
	ResourceSaver.save(ps, path)
	r.free()


func _run() -> void:
	var prog: Node = root.get_node("Progress")
	var A = load("res://scripts/armory/armory.gd")
	var Ads = load("res://scripts/combat/ads_profile.gd")
	var Rig = load("res://scripts/gear/weapon_rig.gd")
	A.reload()
	var test_dir := OS.get_user_data_dir().path_join("optics_test")
	DirAccess.make_dir_recursive_absolute(test_dir)
	prog.save_path = test_dir.path_join("progress_optics_test.cfg")
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)
	_reset(prog)

	# ------------------------------------------------------------ data validity
	var oc: Dictionary = A.optics_cfg()
	var lineup: Array = oc.get("lineup", [])
	var core := lineup.filter(func(id): return not bool(A.attachment(id).get("unique", false)))
	check(lineup.size() == 13 and core.size() == 11, "optics lineup: 11 core optics + 2 uniques (got %d / %d)" % [core.size(), lineup.size()])
	check(core.size() + 1 >= 10 and core.size() + 1 <= 12, "10-12 optic choices with the factory sights (%d)" % (core.size() + 1))
	var types := {}
	for id in core:
		var t := str(A.attachment(id).optic.type)
		types[t] = int(types.get(t, 0)) + 1
	check(int(types.get("irons", 0)) == 4 and int(types.get("dot", 0)) == 2 and int(types.get("holo", 0)) == 1
		and int(types.get("prism", 0)) == 2 and int(types.get("scope", 0)) == 2, "coverage: 4 irons, 2 dots, 1 holo, 2x/3x prisms, 6x/8x scopes %s" % types)
	for keep in ["pinhole", "lamplight_reflex", "tallow_holo", "crows_eye_3x", "longwatch_6x"]:
		check(keep in core, "existing optic reused: %s" % keep)
	var rids := {}
	var ok_block := true
	var ok_flavor := true
	for id in lineup:
		var a: Dictionary = A.attachment(id)
		var o: Dictionary = a.get("optic", {})
		ok_block = ok_block and o.has_all(["type", "label", "magnification", "reticle_id", "reticle", "overlay", "glow", "night",
			"replaces_irons", "rarity", "tradeoff"]) and str(a.slot) == "optic"
		ok_flavor = ok_flavor and str(a.summary).length() <= 60 and str(a.name) != "" and not A.compatible_archetypes(id).is_empty()
		rids[str(o.get("reticle_id", ""))] = true
		check(bool(o.get("overlay")) == (float(o.get("magnification", 0)) >= float(oc.overlay_min_mag)),
			"%s: overlay only from %sx (mag %s, overlay %s)" % [id, oc.overlay_min_mag, o.get("magnification"), o.get("overlay")])
	check(ok_block, "every lineup optic has a full optic block (type, reticle, overlay, glow, night, rarity, tradeoff)")
	check(ok_flavor, "every optic has a name, a <= 60 char flavour line and at least one class")
	check(rids.size() == lineup.size(), "every optic has its own reticle id (%d)" % rids.size())
	check(not (A.factory_optic("auto_rifle").is_empty() or A.factory_optic("sniper_rifle").is_empty())
		and A.factory_optic("sniper_rifle").optic.overlay and not A.factory_optic("auto_rifle").optic.overlay,
		"factory sights: irons (3D) and the sniper's built-in scope (overlay)")
	# hides lists: replacing iron sets hide IronSights (+ the sniper's DefaultOptic); paint and the Heartbeat box keep them
	check(Rig.hides_for("wicket_ring") == ["IronSights", "DefaultOptic"] and Rig.hides_for("mason_notch") == ["IronSights", "DefaultOptic"]
		and Rig.hides_for("foxfire_post") == ["IronSights", "DefaultOptic"], "iron variants that replace the irons hide IronSights + DefaultOptic")
	check(Rig.hides_for("witchlight_dabs") == [] and Rig.hides_for("heartbeat_counter") == [], "Witchlight Dabs / Heartbeat Counter keep the factory irons (hides [])")
	check(not A.is_compatible("witchlight_dabs", "sniper_rifle") and A.is_compatible("wicket_ring", "sniper_rifle"),
		"no paint on the sniper (its factory sight is the scope); iron sets can replace the scope")
	check(A.compatible_archetypes("belfry_8x") == ["sniper_rifle"] and A.compatible_archetypes("longwatch_6x").size() == 2
		and A.is_compatible("kilnglass_2x", "auto_rifle") and not A.is_compatible("kilnglass_2x", "smg"),
		"classes: Belfry sniper only, Longwatch sniper + scout, Kilnglass mid-cap guns")
	check(lineup.all(func(id): return str(A.attachment(id).get("summary", "")).length() > 0), "flavour lines present")

	# ------------------------------------------------------------ pricing curve (Gravemark: ~5/7/14 per match, Rework 3/6/11/20/36)
	var mean := func(ts: Array) -> float:
		var c := core.filter(func(id): return str(A.attachment(id).optic.type) in ts)
		var s := 0.0
		for id in c:
			s += float(A.cost_of(id, "gravemark"))
		return s / maxf(1.0, c.size())
	var bands: Dictionary = oc.price_bands
	var in_band := true
	for id in lineup:
		var b: Array = bands[str(A.attachment(id).optic.type)]
		in_band = in_band and A.cost_of(id, "gravemark") >= int(b[0]) and A.cost_of(id, "gravemark") <= int(b[1])
	check(in_band, "every optic priced inside its type's band %s" % bands)
	check(core.filter(func(id): return A.attachment(id).optic.type == "irons").all(func(id): return A.cost_of(id, "gravemark") >= 2 and A.cost_of(id, "gravemark") <= 4),
		"cheap irons cost 2-4")
	check(mean.call(["irons"]) <= mean.call(["dot", "holo"]) and mean.call(["dot", "holo"]) <= mean.call(["prism"])
		and mean.call(["prism"]) <= mean.call(["scope"]),
		"price rises irons %.1f <= dots/holo %.1f <= prisms %.1f <= scopes %.1f" % [mean.call(["irons"]), mean.call(["dot", "holo"]), mean.call(["prism"]), mean.call(["scope"])])
	check(A.cost_of("belfry_8x", "gravemark") == 8 and A.tier_requirement("belfry_8x") == 4 and A.tier_requirement("longwatch_6x") == 4,
		"Belfry 8x: 8 Gravemarks behind Rework IV, like Longwatch")
	var med = A.expected_match_income("medium", 13)
	var per: float = float(med.get("total", med.get("expected", 7.0))) if med is Dictionary else 7.0
	check(A.cost_of("belfry_8x", "gravemark") <= ceili(per * 1.5) and A.cost_of("wicket_ring", "gravemark") <= ceili(per * 0.5),
		"8x costs about one Medium match (%.1f / match), an iron set about half of one" % per)
	check(core.filter(func(id): return A.attachment(id).optic.type == "scope").all(func(id): return int(A.attachment(id).tier) == 3)
		and core.filter(func(id): return A.attachment(id).optic.type in ["irons", "dot", "holo"]).all(func(id): return int(A.attachment(id).tier) == 1),
		"gates: irons / dots / holo tier 1, high zoom tier 3 (Rework IV)")

	# ------------------------------------------------------------ ADS merge math (no loadout: pure dicts)
	check(_near(Ads.true_magnification(Ads.merge_fov("auto_rifle", A.attachment("crows_eye_3x").ads)), 3.0, 0.01)
		and _near(Ads.true_magnification(Ads.merge_fov("scout_rifle", A.attachment("longwatch_6x").ads)), 6.0, 0.02)
		and _near(Ads.true_magnification(Ads.merge_fov("sniper_rifle", A.attachment("belfry_8x").ads)), 8.0, 0.05)
		and _near(Ads.true_magnification(Ads.merge_fov("auto_rifle", A.attachment("kilnglass_2x").ads)), 2.0, 0.01),
		"glass FOV = its true magnification vs the 75 deg hip (2x 42.0, 3x 28.7, 6x 14.6, 8x 11.0)")
	check(_near(Ads.merge_fov("auto_rifle", {}), 55.0) and _near(Ads.merge_fov("auto_rifle", A.attachment("wicket_ring").ads), 55.0 * 1.06)
		and _near(Ads.merge_fov("auto_rifle", A.attachment("mason_notch").ads), 55.0 * 0.94)
		and _near(Ads.merge_fov("sidearm", A.attachment("wicket_ring").ads), 65.0 * 1.06),
		"iron variants: class iron FOV x fov_mult (AR 55 -> 58.3 Wicket / 51.7 Mason; sidearm 68.9)")
	check(_near(Ads.merge_fov("auto_rifle", A.attachment("lamplight_reflex").ads), 55.0) and _near(Ads.merge_fov("smg", A.attachment("lamplight_reflex").ads), 60.0),
		"dots: the narrowest of class FOV and optic FOV (Lamplight AR 55, SMG 60)")
	var desc: Dictionary = (A.attachment("wicket_ring").ads as Dictionary).duplicate()
	desc["scope_replaced"] = true
	check(_near(Ads.merge_fov("sniper_rifle", {}), 35.0) and _near(Ads.merge_fov("sniper_rifle", desc), 55.0 * 1.06),
		"sniper: built-in scope 35; irons replacing it aim from the rifle irons FOV 55 (x1.06 Wicket)")
	check(_near(Ads.ads_time_for("auto_rifle", {}), 0.25) and _near(Ads.ads_time_for("auto_rifle", A.attachment("wicket_ring").ads), 0.2)
		and _near(Ads.ads_time_for("scout_rifle", A.attachment("longwatch_6x").ads), 0.3625) and _near(Ads.ads_time_for("sniper_rifle", A.attachment("belfry_8x").ads), 0.48)
		and _near(Ads.ads_time_for("sidearm", {}), 0.18),
		"ADS time = class base x ads_time_mult (AR 0.25, Wicket 0.20, scout Longwatch 0.36, sniper Belfry 0.48, sidearm 0.18)")
	check(_near(Ads.move_mult_for({"move_mult": 0.75}), 1.0 - 0.3 / 0.75) and _near(Ads.move_mult_for({}), 0.7), "ADS move speed formula shared with move_speed_mult")

	# ------------------------------------------------------------ live merge through the Armory loadout
	prog.gravemarks = 300
	prog.armory.upgrades = {"sniper_rifle": 4, "scout_rifle": 4, "auto_rifle": 4}
	prog.notify_armory("upgrade", "", false)
	for id in lineup:
		A.buy_attachment(id, "gravemark")
	check(lineup.all(func(id): return A.owned(id)), "every optic buyable with Rework IV on the long guns (%d owned)" % prog.armory.owned.size())
	check(A.equip("auto_rifle", "crows_eye_3x") and _near(Ads.ads_fov("auto_rifle"), 28.7) and not Ads.wants_scope_overlay("auto_rifle")
		and _near(Ads.ads_time("auto_rifle"), 0.3125) and _near(Ads.sway_mult("auto_rifle"), 1.3), "AR + Crow's Eye 3x: FOV 28.7, ADS 0.31 s, sway x1.3, 3D sight picture")
	check(A.buy_attachment("lean_grip", "gravemark") or A.owned("lean_grip"), "Lean Grip owned")
	A.equip("auto_rifle", "lean_grip")
	check(_near(Ads.spread_mult(true, "auto_rifle"), 0.45 * 0.9) and _near(Ads.aim_spread_mult(1.0, "auto_rifle", 0.0), 0.45 * 0.9)
		and _near(Ads.aim_spread_mult(1.0, "auto_rifle", 1.0), 0.45 * 0.9 * (1.0 + 0.6 * 0.3))
		and _near(Ads.aim_spread_mult(0.0, "auto_rifle", 1.0), Ads.spread_mult(false, "auto_rifle")),
		"spread blend: hip at 0, ADS at 1; moving x(1 + 0.6 x (sway - 1)) = x1.18 with Crow's Eye")
	A.equip("auto_rifle", "wicket_ring")
	check(_near(Ads.sway_spread_mult("auto_rifle", 1.0), 1.0 - 0.6 * 0.15) and _near(Ads.sway_spread_mult("auto_rifle", 0.0), 1.0)
		and _near(Ads.aim_spread_mult(1.0, "auto_rifle", 0.0), 0.45 * 0.9 * 1.12),
		"Wicket Ring: steadier on the move (x0.91), coarser standing (ADS spread x1.12)")
	check(_near(Ads.step_blend(0.0, true, 0.1, "auto_rifle"), 0.5) and _near(Ads.step_blend(1.0, false, 0.08, "auto_rifle"), 0.5)
		and _near(Ads.blend_fov(0.0, "auto_rifle", 75.0), 75.0) and _near(Ads.blend_fov(1.0, "auto_rifle", 75.0), 58.3)
		and _near(Ads.view_lerp_rate("auto_rifle"), 25.0),
		"blend: Wicket aims in 0.20 s (half at 0.1 s), out x0.8; FOV hip -> 58.3; gun pose lerp 25/s")
	A.unequip_slot("auto_rifle", "optic")
	A.unequip_slot("auto_rifle", "grip")
	check(_near(Ads.view_lerp_rate("auto_rifle"), 20.0) and _near(Ads.ads_time("auto_rifle"), 0.25) and _near(Ads.ads_fov("auto_rifle"), 55.0),
		"factory irons on the AR: the old feel (0.25 s, pose lerp 20/s, FOV 55)")
	# sniper: the overlay follows the sight
	check(Ads.wants_scope_overlay("sniper_rifle") and _near(Ads.ads_fov("sniper_rifle"), 35.0), "sniper factory scope: overlay, FOV 35")
	A.equip("sniper_rifle", "wicket_ring")
	check(not Ads.wants_scope_overlay("sniper_rifle") and _near(Ads.ads_fov("sniper_rifle"), 58.3), "sniper + Wicket Ring: no overlay, irons FOV 58.3")
	A.equip("sniper_rifle", "kilnglass_2x")
	check(not Ads.wants_scope_overlay("sniper_rifle") and _near(Ads.ads_fov("sniper_rifle"), 42.0), "sniper + Kilnglass 2x: 3D picture, FOV 42 (wider than the factory scope)")
	A.equip("sniper_rifle", "belfry_8x")
	check(Ads.wants_scope_overlay("sniper_rifle") and _near(Ads.ads_fov("sniper_rifle"), 11.0) and _near(Ads.overlay_sway("sniper_rifle"), 0.006 * 1.8),
		"sniper + Belfry 8x: overlay, FOV 11.0, overlay sway x1.8 (%s %.2f %.4f)" % [Ads.wants_scope_overlay("sniper_rifle"), Ads.ads_fov("sniper_rifle"), Ads.overlay_sway("sniper_rifle")])
	A.equip("sniper_rifle", "heartbeat_counter")
	check(Ads.wants_scope_overlay("sniper_rifle") and _near(Ads.ads_fov("sniper_rifle"), 35.0), "sniper + Heartbeat Counter: keeps the built-in scope (hides [])")
	A.equip("scout_rifle", "longwatch_6x")
	check(Ads.wants_scope_overlay("scout_rifle") and _near(Ads.ads_fov("scout_rifle"), 14.6), "scout + Longwatch 6x: overlay, FOV 14.6")

	# ------------------------------------------------------------ no strictly-better optic (same class, price counts)
	var night_rank := {"poor": 0, "fair": 1, "good": 2}
	var dominated: Array = []
	for arch in ["sidearm", "hand_cannon", "auto_rifle", "smg", "shotgun", "sniper_rifle", "scout_rifle", "rocket_launcher", "pulse_rifle"]:
		var ps: Array = A.optic_choices(arch).filter(func(p): return p.optic_id != "")
		for x in ps:
			for y in ps:
				if x.optic_id == y.optic_id:
					continue
				var hx := float(A.attachment(x.optic_id).mods.get("headshot_add", 0.0))
				var hy := float(A.attachment(y.optic_id).mods.get("headshot_add", 0.0))
				var px := float(A.attachment(x.optic_id).mods.get("hip_spread_mult", 1.0))
				var py := float(A.attachment(y.optic_id).mods.get("hip_spread_mult", 1.0))
				var ge: Array = [x.true_magnification >= y.true_magnification - 1e-3, x.ads_time <= y.ads_time + 1e-4, x.sway_mult <= y.sway_mult + 1e-4,
					x.ads_spread_mult <= y.ads_spread_mult + 1e-4, x.ads_move_mult >= y.ads_move_mult - 1e-4,
					night_rank[x.night] >= night_rank[y.night], x.cost <= y.cost, hx >= hy, px <= py,
					A.attachment(x.optic_id).effects.size() >= A.attachment(y.optic_id).effects.size(),
					A.attachment(x.optic_id).flags.size() >= A.attachment(y.optic_id).flags.size()]
				if ge.all(func(v): return v):
					dominated.append("%s>%s on %s" % [x.optic_id, y.optic_id, arch])
	check(dominated.is_empty(), "no optic is strictly better than another on any class (zoom, ADS time, sway, spread, move, night, price, crits) %s" % [dominated])

	# ------------------------------------------------------------ Gooey's API: optic_profile / optic_choices / list_attachments
	_reset(prog)
	var fp: Dictionary = A.optic_profile("auto_rifle")
	var keys := ["weapon_id", "arch", "optic_id", "name", "type", "label", "magnification", "true_magnification", "ads_fov", "class_fov",
		"fov_mult", "ads_time", "ads_time_mult", "sway_mult", "ads_spread_mult", "ads_move_mult", "overlay", "sight_picture", "reticle_id",
		"reticle", "glow", "night", "replaces_irons", "hides", "rarity", "tier", "cost", "owned", "equipped", "compatible", "art_status",
		"fallback", "tradeoff", "summary", "description", "drawback", "icon"]
	check(fp.has_all(keys), "optic_profile has every documented key (%d)" % keys.size())
	check(fp.optic_id == "" and fp.name == "Factory Irons" and not fp.overlay and fp.reticle_id == "factory_irons" and fp.sight_picture == "3d"
		and _near(fp.ads_fov, 55.0) and _near(fp.ads_time, 0.25) and fp.equipped, "AR, nothing fitted: Factory Irons, 3D, FOV 55, 0.25 s")
	var sp: Dictionary = A.optic_profile("sniper_rifle")
	check(sp.name == "Factory Scope" and sp.overlay and sp.reticle_id == "factory_scope" and _near(sp.ads_fov, 35.0), "sniper, nothing fitted: Factory Scope overlay")
	var cp: Dictionary = A.optic_profile("auto_rifle", "crows_eye_3x")
	check(cp.optic_id == "crows_eye_3x" and cp.label == "3x" and _near(cp.true_magnification, 3.0, 0.01) and not cp.overlay
		and cp.reticle_id == "crow_foot" and cp.art_status == "shipped" and not cp.fallback and not cp.owned and not cp.equipped,
		"preview Crow's Eye on the AR (not owned): 3x, crow_foot reticle, shipped GLB")
	check(A.optic_profile("auto_rifle").optic_id == "", "a preview doesn't change the loadout")
	# art5: every optic GLB has shipped, so "pending" is simulated (model path not delivered) for the fallback checks
	var dpend: Dictionary = A.data().duplicate(true)
	for a in dpend.attachments:
		if a.id in ["kilnglass_2x", "wicket_ring"]:
			a.model = "res://assets/models/attachments/optic/__not_delivered_%s__.glb" % a.id
	A.reload(dpend)
	var kp: Dictionary = A.optic_profile("auto_rifle", "kilnglass_2x")
	check(kp.art_status == "pending" and kp.fallback and _near(kp.ads_fov, 42.0) and kp.glow.mode == "lit",
		"Kilnglass 2x: GLB pending -> fallback flag (default sight picture), stats still apply")
	A.reload()
	check(A.optic_profile("smg", "witchlight_dabs").art_status == "procedural" and not A.optic_profile("smg", "witchlight_dabs").fallback,
		"Witchlight Dabs: procedural (no GLB by design)")
	var bp: Dictionary = A.optic_profile("sniper_rifle", "belfry_8x")
	check(bp.overlay and bp.sight_picture == "overlay" and bp.reticle_id == "belfry_post" and bp.magnification == 8.0 and bp.rarity == "rare",
		"Belfry 8x preview: overlay, belfry_post reticle")
	check(A.optic_profile("sniper_rifle", "heartbeat_counter").reticle_id == "factory_scope" and A.optic_profile("sniper_rifle", "heartbeat_counter").overlay,
		"Heartbeat Counter on the sniper reports the factory scope reticle")
	var fx: Dictionary = A.optic_profile("smg", "foxfire_post")
	check(fx.night == "good" and fx.glow.mode == "tritium" and fx.replaces_irons and fx.hides == ["IronSights", "DefaultOptic"], "Foxfire Post: tritium glow, replaces the irons")
	check(A.optic_profile("auto_rifle", "hush_can").optic_id == "", "a non-optic id previews as the factory sights")
	var ch: Array = A.optic_choices("sniper_rifle")
	check(ch[0].optic_id == "" and ch[0].state == "equipped" and ch.any(func(p): return p.optic_id == "belfry_8x")
		and not ch.any(func(p): return p.optic_id == "witchlight_dabs") and ch.all(func(p): return p.has_all(["state", "requirements", "can_afford"])),
		"optic_choices(sniper): factory first + Belfry, no paint; Armory state on each row (%d rows)" % ch.size())
	check(A.optic_choices("sidearm").map(func(p): return p.optic_id) == ["", "witchlight_dabs", "wicket_ring", "mason_notch", "foxfire_post", "pinhole", "heartbeat_counter"],
		"sidearm lineup: factory, 4 irons, Pinhole, Heartbeat Counter")
	var belfry_row: Dictionary = ch.filter(func(p): return p.optic_id == "belfry_8x")[0]
	check(belfry_row.state == "locked" and not belfry_row.requirements.is_empty() and not belfry_row.can_afford, "Belfry locked below Rework IV (%s)" % [belfry_row.requirements])
	var api = A.new()
	var la: Array = api.list_attachments("auto_rifle", "optic")
	check(la.all(func(e): return e.optic is Dictionary and str(e.optic.get("reticle_id", "")) != "") and api.list_optics("auto_rifle").size() == A.optic_choices("auto_rifle").size(),
		"list_attachments(optic rows) carry an optic preview; instance list_optics() works")
	prog.gravemarks = 10
	check(api.purchase_with("wicket_ring", "gravemark") and api.equip_attachment("auto_rifle", "optic", "wicket_ring")
		and A.optic_profile("auto_rifle").optic_id == "wicket_ring" and A.optic_profile("auto_rifle").equipped and A.optic_id("auto_rifle") == "wicket_ring",
		"buy + equip Wicket Ring: optic_profile follows the loadout")

	# ------------------------------------------------------------ WeaponRig: fallback (no GLB yet) + Witchlight dots
	var ar := _gun("weapon_assault_rifle")
	var base_line: Vector3 = Rig.sight_line(Rig.apply(ar, "auto_rifle", {"muzzle": "hush_can"}))
	# art5: every optic GLB has shipped, so "pending" is simulated (model path not delivered) for the fallback checks
	dpend = A.data().duplicate(true)
	for a in dpend.attachments:
		if a.id in ["kilnglass_2x", "wicket_ring"]:
			a.model = "res://assets/models/attachments/optic/__not_delivered_%s__.glb" % a.id
	A.reload(dpend)
	var pr: Dictionary = Rig.apply(ar, "auto_rifle", {"optic": "wicket_ring"})
	check(pr.optic.status == "pending" and pr.missing.has("wicket_ring") and not pr.attached.has("optic") and Rig.find_node(ar, "IronSights").visible
		and pr.sight == Rig.find_node(ar, "SightPoint") and Rig.sight_line(pr).is_equal_approx(base_line) and pr.optic.sight == "irons",
		"pending GLB: nothing fitted, factory IronSights stay, ADS through the gun's SightPoint")
	var sn := _gun("weapon_sniper")
	var spr: Dictionary = Rig.apply(sn, "sniper_rifle", {"optic": "kilnglass_2x"})
	check(spr.optic.status == "pending" and Rig.find_node(sn, "DefaultOptic").visible and spr.optic.sight == "builtin_scope",
		"pending GLB on the sniper: the built-in scope stays as the sight picture")
	A.reload()
	var wr: Dictionary = Rig.apply(ar, "auto_rifle", {"optic": "witchlight_dabs"})
	var irons: Node3D = Rig.find_node(ar, "IronSights")
	var dot_mat := (wr.glow_dots[0] as MeshInstance3D).material_override as StandardMaterial3D if wr.glow_dots.size() > 0 else null
	check(wr.optic.status == "procedural" and wr.glow_dots.size() == 3 and irons.visible and wr.missing.is_empty()
		and dot_mat != null and dot_mat.emission_enabled and _near(dot_mat.emission_energy_multiplier, 1.2),
		"Witchlight Dabs: 3 emissive dots on the factory irons, nothing hidden, not 'missing'")
	var front_dot: Vector3 = Rig.gun_point(ar, wr.glow_dots[2])
	check(_near(front_dot.y, Rig.sight_line(wr).y, 0.0005) and _near(front_dot.x, Rig.front_sight_x(ar) - 0.003, 0.0005),
		"front dot sits on the sight line at the front post (x %.3f)" % front_dot.x)
	Rig.clear(ar)
	check(ar.find_children("GlowDot*", "", true, false).is_empty(), "clear() removes the dots")
	var sg := _gun("weapon_shotgun")
	var sgr: Dictionary = Rig.apply(sg, "shotgun", {"optic": "witchlight_dabs", "barrel": "sawn_stub"})
	check(sgr.optic.status == "procedural_skipped" and sgr.glow_dots.is_empty(), "shotgun + Sawn Stub (irons hidden): no paint to show")

	# ------------------------------------------------------------ WeaponRig: a shipped iron set (synthetic GLB stand-in)
	var syn := "user://optics_test/wicket_test.tscn"
	_synthetic_optic(syn)
	var d: Dictionary = A.data().duplicate(true)
	for a in d.attachments:
		if a.id == "wicket_ring":
			a.model = syn
	A.reload(d)
	check(Rig.has_model("wicket_ring") and A.optic_art_status("wicket_ring") == "shipped", "synthetic Wicket Ring GLB registered")
	var fr: Dictionary = Rig.apply(ar, "auto_rifle", {"optic": "wicket_ring"})
	check(fr.optic.status == "fitted" and fr.optic.sight == "optic" and not Rig.find_node(ar, "IronSights").visible
		and fr.attached.optic.is_ancestor_of(fr.sight), "fitted iron set: IronSights hidden, ADS through its own SightPoint")
	# art5 railfix3: the AR Rail sits 1.4 mm higher (0.1134), so the stand-in's line is Rail + 0.034 = 0.1474 (factory irons 0.146)
	var ar_line: float = Rig.gun_point(ar, Rig.find_node(ar, "Rail")).y + 0.034
	check(_near(Rig.sight_line(fr).y, ar_line, 0.0005), "its SightPoint lands on Rail + 34 mm (y %.4f, want %.4f)" % [Rig.sight_line(fr).y, ar_line])
	var fpx: Vector3 = Rig.gun_point(ar, fr.front_post)
	check(fr.front_post != null and _near(fpx.x, 0.532, 0.002) and _near(fpx.y, ar_line, 0.0005),
		"FrontPost slid to the factory front sight (x %.3f, y %.3f)" % [fpx.x, fpx.y])
	var stem: Node3D = Rig.find_node(fr.front_post, "PostStem")
	var stem_bottom: float = Rig.gun_point(ar, stem).y - 0.01 * stem.scale.y
	check(_near(stem_bottom, 0.055 + 0.012, 0.001), "PostStem stretched to the bore top (bottom y %.4f)" % stem_bottom)
	check(fr.reticle is MeshInstance3D and ((fr.reticle as MeshInstance3D).get_surface_override_material(0) == null),
		"Wicket Ring has no glow (mode none): reticle left unlit")
	var sgf: Dictionary = Rig.apply(sg, "shotgun", {"optic": "wicket_ring", "barrel": "sawn_stub"})
	var sgx: float = Rig.gun_point(sg, sgf.front_post).x
	check(sgx <= Rig.gun_point(sg, sgf.muzzle).x - 0.015 + 1e-4 and sgx < 0.69, "shotgun + Sawn Stub: front post stays behind the cut bore (x %.3f, bore %.3f)" % [sgx, Rig.gun_point(sg, sgf.muzzle).x])
	# glow: same stand-in as Foxfire Post (tritium) lights its Reticle
	for a in d.attachments:
		if a.id == "foxfire_post":
			a.model = syn
	A.reload(d)
	var ff: Dictionary = Rig.apply(ar, "auto_rifle", {"optic": "foxfire_post"})
	var rm := (ff.reticle as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D if ff.reticle else null
	check(rm != null and rm.emission_enabled and _near(rm.emission_energy_multiplier, 2.5) and rm.emission.is_equal_approx(Color.html("#9CFF7A")),
		"Foxfire Post: Reticle surface emissive (tritium 2.5, foxfire green)")
	# ADS pose with the fitted optic: SightPoint on the screen centre
	var cam := Camera3D.new()
	root.add_child(cam)
	var gun := Node3D.new()
	cam.add_child(gun)
	var ar2 := _gun("weapon_assault_rifle")
	gun.add_child(ar2)
	ar2.rotation_degrees = Vector3(0, 90, 0)
	ar2.scale = Vector3.ONE * 0.6
	var r2: Dictionary = Rig.apply(ar2, "auto_rifle", {"optic": "wicket_ring"})
	gun.position = Ads.ads_gun_position(Rig.ads_offset(r2, gun), "auto_rifle")
	var eye: float = Ads.ads_eye_distance("auto_rifle")
	check(cam.to_local((r2.sight as Node3D).global_position).distance_to(Vector3(0, 0, -eye)) < 1e-4, "ADS pose puts the optic's SightPoint on the screen centre")
	cam.queue_free()
	A.reload()
	for n in [ar, sn, sg]:
		n.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(syn))
	load("res://scripts/autoload/progress.gd").delete_save_files(prog.save_path)

	# ------------------------------------------------------------ art5 (Gravecrew): FOV rule, pending-art sniper fallback, glass
	prog.armory = {"upgrades": {"sniper_rifle": 4, "auto_rifle": 4, "smg": 4}, "owned": A.attachment_ids(), "equipped": {}}
	prog.notify_armory("load", "", false)
	A.reload()
	var lp: Dictionary = A.optic_profile("sniper_rifle", "lamplight_reflex")
	check(_near(lp.ads_fov, 55.0) and _near(lp.class_fov, 55.0) and _near(lp.fov_cap, 60.0) and lp.fov_source == "class",
		"FOV rule: Lamplight on the sniper = min(class 55, cap 60) = 55, reported as the effective FOV (source class)")
	var ls: Dictionary = A.optic_profile("smg", "lamplight_reflex")
	check(_near(ls.ads_fov, 60.0) and ls.fov_source == "optic" and _near(A.optic_profile("auto_rifle", "lamplight_reflex").ads_fov, 55.0),
		"same rule on every class: SMG 65 -> capped 60 (source optic), AR stays 55")
	check(A.optic_profile("sniper_rifle", "kilnglass_2x").fov_source == "optic" and A.optic_profile("auto_rifle", "wicket_ring").fov_source == "class",
		"fov_source: Kilnglass's 42 wins on the sniper; iron sets are class x fov_mult")
	for oid in ["pinhole", "lamplight_reflex", "tallow_holo"]:
		check(str(A.attachment(oid).description).begins_with("ADS FOV capped at"), "%s card text says cap, not zoom" % oid)
	# pending art on the sniper: the factory scope stays on the gun, so its overlay + FOV stay too
	var d5: Dictionary = A.data().duplicate(true)
	for a in d5.attachments:
		if a.id == "kilnglass_2x":
			a.model = "res://assets/models/attachments/optic/__not_delivered__.glb"
	A.reload(d5)
	A.equip("sniper_rifle", "kilnglass_2x")
	var kp5: Dictionary = A.optic_profile("sniper_rifle")
	check(kp5.art_status == "pending" and kp5.fallback and kp5.overlay and not A.ads_mods("sniper_rifle").scope_replaced and _near(kp5.ads_fov, 35.0),
		"sniper + Kilnglass without its GLB: factory scope kept -> overlay on, FOV 35 (was: no overlay = aiming into the scope housing)")
	A.reload()
	A.equip("sniper_rifle", "kilnglass_2x")
	check(A.ads_mods("sniper_rifle").scope_replaced and not A.optic_profile("sniper_rifle").overlay and _near(Ads.ads_fov("sniper_rifle"), 42.0),
		"sniper + Kilnglass with its GLB: scope replaced, 3D picture, FOV 42")
	# glass: shipped lenses forced see-through; Gravesight's screen left as authored; Crow's Eye reticle glow from data
	var sn5 := _gun("weapon_sniper")
	var kr: Dictionary = Rig.apply(sn5, "sniper_rifle", {"optic": "kilnglass_2x"})
	var kl: Array = kr.get("lenses", [])
	var glass_ok := not kl.is_empty()
	for ln in kl:
		var lm := (ln as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
		glass_ok = glass_ok and lm != null and lm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and lm.albedo_color.a <= Rig.GLASS_MAX_ALPHA + 1e-4 \
			and lm.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED
	check(glass_ok, "Kilnglass Lens: alpha-blended glass, alpha <= %.2f, no depth write" % Rig.GLASS_MAX_ALPHA)
	var ar5 := _gun("weapon_assault_rifle")
	var ce: Dictionary = Rig.apply(ar5, "auto_rifle", {"optic": "crows_eye_3x"})
	var cg: Dictionary = A.attachment("crows_eye_3x").optic.glow
	var crm := (ce.reticle as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D if ce.reticle is MeshInstance3D else null
	check(not (ce.get("lenses", []) as Array).is_empty() and crm != null and crm.emission_enabled and _near(crm.emission_energy_multiplier, float(cg.energy))
		and crm.emission.is_equal_approx(Color.html(str(cg.color))),
		"Crow's Eye (lensfix): Lens is glass, Reticle glow from data (%s %.1f %s)" % [cg.mode, cg.energy, cg.color])
	var gr: Dictionary = Rig.apply(ar5, "auto_rifle", {"optic": "gravesight"})
	var g_ok: bool = A.attachment("gravesight").optic.lens == "glass" and (gr.get("lenses", []) as Array).size() >= 2
	for gn in gr.get("lenses", []):
		var gm := (gn as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
		g_ok = g_ok and gm != null and gm.has_meta("optic_glass") and gm.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA \
			and gm.albedo_color.a <= Rig.GLASS_MAX_ALPHA + 1e-4 and gm.emission_enabled and gm.emission.g > gm.emission.r
	var grm := (gr.reticle as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D if gr.reticle is MeshInstance3D else null
	check(g_ok and grm != null and grm.emission.is_equal_approx(Color.html("#7CFFB2")),
		"Gravesight (art5b): lens 'glass' -> Lens + Ocular see-through, green tint kept, #7CFFB2 cross Reticle glows")
	var peep: Dictionary = Rig.apply(ar5, "auto_rifle", {"optic": "pinhole"})
	var peep_mm := float(A.attachment("pinhole").optic.get("aperture_mm", 0.0))
	check(peep.optic.status == "fitted" and peep.reticle is MeshInstance3D and peep_mm >= 2.0 and peep_mm <= 3.5,
		"Pinhole 3 mm peep (art5b, G4M3N): fitted, pin-dot Reticle, aperture_mm %.1f in data" % peep_mm)
	sn5.free()
	ar5.free()

	print("optics_test: %d passed, %d failed" % [_passes, _fails])
	quit(_fails)
