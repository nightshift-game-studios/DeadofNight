extends SceneTree
## fp_arms v2 (Desi) wiring: clips, loop modes, identity attach, grips, reload part motions, tint, view offsets.
## godot --headless --path . -s res://tests/fp_arms_test.gd
const FP := preload("res://scripts/gear/fp_arms.gd")
var _p := 0
var _f := 0
func check(c: bool, m: String) -> void:
	if c:
		_p += 1
		print("PASS  ", m)
	else:
		_f += 1
		print("FAIL  ", m)
func frames(n: int) -> void:
	for i in n:
		await process_frame
func _initialize() -> void:
	_go.call_deferred()
func _go() -> void:
	var weapons: Dictionary = {}
	for a in (JSON.parse_string(FileAccess.get_file_as_string("res://data/weapons.json")) as Dictionary).archetypes:
		weapons[a.id] = a
	var offs: Dictionary = (JSON.parse_string(FileAccess.get_file_as_string(FP.OFFSETS)) as Dictionary).guns
	check(ResourceLoader.exists(FP.ARMS_SCENE), "fp_arms.glb imports")
	# --- motion parser (reload_parts.json text)
	check(FP.parse_motion("DefaultMag", "detach + drop 10 cm (gun -Y) while left hand holds it") == {"kind": "drop", "down": 0.1, "out": 0.0}, "parse: detach + drop 10 cm")
	check(FP.parse_motion("DefaultMag", "box: detach, down 12 cm + out 6 cm") == {"kind": "drop", "down": 0.12, "out": 0.06}, "parse: box down 12 + out 6")
	check(FP.parse_motion("DefaultMag", "hidden / new mag spawned in left hand").kind == "hide", "parse: hidden")
	check(FP.parse_motion("DefaultMag", "insert from -8 cm to seated") == {"kind": "insert", "from": 0.08, "push": 0.0}, "parse: insert from -8 cm")
	check(FP.parse_motion("DefaultMag", "seat from -8 cm, push +0.8 cm") == {"kind": "insert", "from": 0.08, "push": 0.008}, "parse: seat + push")
	check(FP.parse_motion("DefaultMag", "slap (+0.8 cm) then rest") == {"kind": "slap", "up": 0.008}, "parse: slap")
	check(FP.parse_motion("Cylinder", "swing out to gun-left ~80 deg about its crane axis (front-lower edge)") == {"kind": "swing", "deg": 80.0}, "parse: swing out 80")
	check(FP.parse_motion("pump", "pump rack NOT possible: pump is baked into Body (gap)").is_empty() and FP.parse_motion("(shell)", "second shell").is_empty(), "parse: gaps / spawned parts skipped")
	for arch in ["sidearm", "hand_cannon", "auto_rifle", "scout_rifle", "smg", "shotgun", "pulse_rifle", "sniper_rifle", "rocket_launcher"]:
		var w: Dictionary = weapons[arch]
		var po = FP.proposed_offset(arch)
		var vo: Array = w.view.offset
		check(po != null and Vector3(vo[0], vo[1], vo[2]).is_equal_approx(po) and str(offs[arch].weapon_file) == str(w.model).get_file(),
			"%s: weapons.json view.offset = Desi's proposed_offset %s" % [arch, po])
		var holder := Node3D.new()
		root.add_child(holder)
		var model: Node3D = (load(w.model) as PackedScene).instantiate()
		holder.add_child(model)
		model.scale = Vector3.ONE * 0.7
		var arms := FP.attach(model, arch, FP.TINTS.P3)
		check(arms != null and arms.get_parent() == model and arms.transform.is_equal_approx(Transform3D.IDENTITY), "%s: arms under the gun root, identity, scale 1" % arch)
		if arms == null:
			holder.free()
			continue
		var ap := FP.anim_player(arms)
		var ok_clips := ap != null
		for sfx in ["_Idle", "_Fire", "_ADS", "_Reload"]:
			ok_clips = ok_clips and ap.has_animation(arch + sfx)
		check(ok_clips, "%s: Idle / Fire / ADS / Reload clips" % arch)
		if not ok_clips:
			holder.free()
			continue
		check(ap.get_animation(arch + "_Idle").loop_mode == Animation.LOOP_LINEAR and ap.get_animation(arch + "_ADS").loop_mode == Animation.LOOP_LINEAR
			and ap.get_animation(arch + "_Fire").loop_mode == Animation.LOOP_NONE and ap.get_animation(arch + "_Reload").loop_mode == Animation.LOOP_NONE,
			"%s: Idle / ADS loop linear, Fire / Reload once" % arch)
		check(FP.current_clip(arms) == arch + "_Idle", "%s: starts on Idle" % arch)
		check(FP.tint_of(arms).is_equal_approx(FP.TINTS.P3), "%s: TintBand (surface 1) tinted P3" % arch)
		await frames(3)
		# grips: hand_r / hand_l bone frames on GripR / GripL (gun space, so the gun's view scale drops out)
		var sk := arms.find_child("*", true, false) as Skeleton3D
		for c in arms.find_children("*", "Skeleton3D", true, false):
			sk = c
		var gr := model.find_child("GripR", true, false) as Node3D
		var gl := model.find_child("GripL", true, false) as Node3D
		if sk and gr and gl:
			var hr: Vector3 = (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("hand_r"))).origin
			var hl: Vector3 = (sk.global_transform * sk.get_bone_global_pose(sk.find_bone("hand_l"))).origin
			var s: float = model.global_basis.get_scale().x
			var er: float = hr.distance_to(gr.global_position) / s * 1000.0
			var el: float = hl.distance_to(gl.global_position) / s * 1000.0
			check(er < 5.0 and el < 5.0, "%s: Idle hands on the grips (right %.1f mm, left %.1f mm, gun space)" % [arch, er, el])
		else:
			check(false, "%s: skeleton + GripR / GripL present" % arch)
		FP.on_fire(arms)
		check(FP.current_clip(arms) == arch + "_Fire", "%s: Fire one-shot" % arch)
		FP.set_ads(arms, true)
		await create_timer(ap.get_animation(arch + "_Fire").length + 0.15).timeout
		check(FP.current_clip(arms) == arch + "_ADS", "%s: back to the ADS loop after Fire while aiming" % arch)
		FP.set_ads(arms, false)
		check(FP.current_clip(arms) == arch + "_Idle", "%s: ADS off -> Idle" % arch)
		var t := 0.9
		var mag := model.find_child("DefaultMag", true, false) as Node3D
		var rest: Vector3 = mag.position if mag else Vector3.ZERO
		FP.on_reload(arms, model, t)
		var len: float = ap.get_animation(arch + "_Reload").length
		check(FP.current_clip(arms) == arch + "_Reload" and absf(ap.speed_scale - len / t) < 0.001, "%s: Reload at speed %.2f = clip %.2f s / reload %.2f s" % [arch, ap.speed_scale, len, t])
		var cfg := FP.reload_parts(arch)
		var moved := false
		var uses_mag := false
		for p in cfg.parts:
			uses_mag = uses_mag or str(p.node) == "DefaultMag"
		if uses_mag and mag:
			var t1: float = 0.0
			for p in cfg.parts:
				if str(p.node) == "DefaultMag":
					t1 = float(p.t1) * t
					break
			await create_timer(t1 + 0.02).timeout
			moved = mag.position.distance_to(rest) > 0.01
			check(moved, "%s: DefaultMag moved by reload_parts.json (%.1f cm at %.2f s)" % [arch, mag.position.distance_to(rest) * 100.0, t1])
		await create_timer(t + 0.2).timeout
		if mag:
			check(mag.position.is_equal_approx(rest) and mag.visible and not mag.has_meta(FP.META_REST), "%s: parts back at rest after the reload" % arch)
		check(FP.current_clip(arms) == arch + "_Idle" and absf(ap.speed_scale - 1.0) < 0.001, "%s: Idle again after the reload" % arch)
		holder.free()
	print("fp_arms_test: %d passed, %d failed" % [_p, _f])
	quit(_f)
