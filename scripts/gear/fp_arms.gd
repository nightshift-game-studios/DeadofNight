extends Node
## First-person arms (Desi fp_arms v2, NOTES.txt "V2 REWORK"). No class_name: preload it (like weapon_rig.gd).
## attach() instances fp_arms.glb as a child of the weapon model root (the node scaled by s and offset by -c*s) with an
## identity transform at scale 1; the per-gun clips put hand_r / hand_l on the gun's GripR / GripL anchors.
## Clips: <archetype>_Idle / _ADS loop (LOOP_LINEAR, not stored in the GLB), _Fire / _Reload play once; Reload runs at
## speed_scale = clip length / actual reload time. Gun-side reload part motions come from reload_parts.json.
## The arms node is this script's instance (a Node child of the arms scene root is not needed: we keep state here).

const ARMS_SCENE := "res://assets/models/fp_arms/fp_arms.glb"
const RELOAD_PARTS := "res://assets/models/fp_arms/reload_parts.json"
const OFFSETS := "res://assets/models/fp_arms/viewmodel_offsets.json"
const ARMS_NAME := "FPArms"
const META_ARMS := "fp_arms" ## on the arms instance (WeaponRig / previews can skip it)
const META_REST := "fp_arms_rest" ## a gun part's rest transform before a reload motion
const TINT_SURFACE := 1 ## mesh FPArms surface 1 "TintBand"
const TINTS := {"P1": Color("#D9601F"), "P2": Color("#C9D12B"), "P3": Color("#1E9FC8"), "P4": Color("#C2307A")}

static var _parts_cache: Dictionary = {}
static var _offsets_cache: Dictionary = {}


static func _json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


static func reload_parts(arch: String) -> Dictionary:
	if _parts_cache.is_empty():
		_parts_cache = _json(RELOAD_PARTS).get("guns", {})
	return _parts_cache.get(arch, {})


## Desi's solved hip view.offset for this archetype (camera space), or null when there is none.
static func proposed_offset(arch: String):
	if _offsets_cache.is_empty():
		_offsets_cache = _json(OFFSETS).get("guns", {})
	var g: Dictionary = _offsets_cache.get(arch, {})
	var o = g.get("proposed_offset", null)
	if o is Array and o.size() == 3:
		return Vector3(float(o[0]), float(o[1]), float(o[2]))
	return null


static func has_arms_for(arch: String) -> bool:
	return arch != "" and not reload_parts(arch).is_empty() and ResourceLoader.exists(ARMS_SCENE)


## Instances the arms under `model` (identity, scale 1) and starts <arch>_Idle. Returns the arms root or null.
static func attach(model: Node3D, arch: String, tint: Color = TINTS.P1) -> Node3D:
	if model == null or not has_arms_for(arch):
		return null
	var old := model.get_node_or_null(ARMS_NAME)
	if old:
		model.remove_child(old)
		old.queue_free()
	var arms: Node3D = (load(ARMS_SCENE) as PackedScene).instantiate()
	arms.name = ARMS_NAME
	arms.set_meta(META_ARMS, arch)
	model.add_child(arms)
	arms.transform = Transform3D.IDENTITY
	for mi in arms.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var ap := anim_player(arms)
	if ap:
		for suffix in ["_Idle", "_ADS"]:
			var a: Animation = ap.get_animation(arch + suffix) if ap.has_animation(arch + suffix) else null
			if a:
				a.loop_mode = Animation.LOOP_LINEAR
		for suffix in ["_Fire", "_Reload"]:
			var a2: Animation = ap.get_animation(arch + suffix) if ap.has_animation(arch + suffix) else null
			if a2:
				a2.loop_mode = Animation.LOOP_NONE
		ap.animation_finished.connect(_on_clip_finished.bind(arms))
	arms.set_meta("fp_ads", false)
	set_tint(arms, tint)
	_play(arms, "_Idle")
	return arms


static func anim_player(arms: Node) -> AnimationPlayer:
	if arms == null:
		return null
	return arms.find_child("AnimationPlayer", true, false) as AnimationPlayer


static func mesh(arms: Node) -> MeshInstance3D:
	if arms == null:
		return null
	var m := arms.find_child("FPArms", true, false)
	if m is MeshInstance3D:
		return m
	for c in arms.find_children("*", "MeshInstance3D", true, false):
		return c
	return null


static func current_clip(arms: Node) -> String:
	var ap := anim_player(arms)
	return str(ap.current_animation) if ap else ""


static func _arch(arms: Node) -> String:
	return str(arms.get_meta(META_ARMS, "")) if arms else ""


static func _play(arms: Node, suffix: String, speed: float = 1.0) -> bool:
	var ap := anim_player(arms)
	var clip := _arch(arms) + suffix
	if ap == null or not ap.has_animation(clip):
		return false
	ap.speed_scale = speed
	ap.play(clip)
	if suffix == "_Fire" or suffix == "_Reload":
		ap.seek(0.0, true)
	return true


## Back to the looping pose after a one-shot (Fire / Reload).
static func _on_clip_finished(clip: StringName, arms: Node) -> void:
	if not is_instance_valid(arms):
		return
	var s := str(clip)
	if s.ends_with("_Fire") or s.ends_with("_Reload"):
		_play(arms, "_ADS" if bool(arms.get_meta("fp_ads", false)) else "_Idle")


static func set_ads(arms: Node, on: bool) -> void:
	if arms == null or not is_instance_valid(arms):
		return
	var was := bool(arms.get_meta("fp_ads", false))
	arms.set_meta("fp_ads", on)
	if was == on:
		return
	var cur := current_clip(arms)
	if cur.ends_with("_Fire") or cur.ends_with("_Reload"):
		return # the one-shot finishes first, then _on_clip_finished picks the loop
	_play(arms, "_ADS" if on else "_Idle")


static func on_fire(arms: Node) -> void:
	if arms and is_instance_valid(arms) and not current_clip(arms).ends_with("_Reload"):
		_play(arms, "_Fire")


## Reload: arms clip at speed = clip length / reload time, plus the gun-side part motions of reload_parts.json.
static func on_reload(arms: Node, model: Node3D, time: float) -> void:
	if arms == null or not is_instance_valid(arms) or time <= 0.0:
		return
	var ap := anim_player(arms)
	var clip := _arch(arms) + "_Reload"
	if ap and ap.has_animation(clip):
		var length := ap.get_animation(clip).length
		_play(arms, "_Reload", length / time)
	drive_parts(model, _arch(arms), time)


## Puts every part moved by a reload back at rest (reload cancelled / finished early / gun swapped).
static func reset_parts(model: Node3D) -> void:
	if model == null or not is_instance_valid(model):
		return
	for n in model.find_children("*", "Node3D", true, false):
		if n.has_meta(META_REST):
			(n as Node3D).transform = n.get_meta(META_REST)
			(n as Node3D).visible = true
			n.remove_meta(META_REST)
		if n.has_meta("fp_swing"):
			n.remove_meta("fp_swing")
	if model.has_meta("fp_parts_tween"):
		var tw = model.get_meta("fp_parts_tween")
		if tw is Tween and tw.is_valid():
			tw.kill()
		model.remove_meta("fp_parts_tween")


## One step of a reload_parts.json motion, parsed from Desi's text: returns {kind, ...} or {} (no node / not possible).
static func parse_motion(node: String, motion: String) -> Dictionary:
	var m := motion.to_lower()
	if node.begins_with("(") or m.contains("not possible"):
		return {}
	var cm := RegEx.create_from_string("([+-]?[0-9.]+)\\s*cm")
	var nums: Array = []
	for r in cm.search_all(m):
		nums.append(float(r.get_string(1)) / 100.0)
	if m.contains("swing out"):
		var deg := RegEx.create_from_string("([0-9.]+)\\s*deg").search(m)
		return {"kind": "swing", "deg": float(deg.get_string(1)) if deg else 80.0}
	if m.contains("swing closed"):
		return {"kind": "swing", "deg": 0.0}
	if m.contains("hidden") or m.contains("swap"):
		return {"kind": "hide"}
	if m.contains("slap"):
		return {"kind": "slap", "up": nums[0] if nums.size() > 0 else 0.008}
	if m.contains("insert") or m.contains("seat") or m.contains("in from"):
		var from: float = absf(nums[0]) if nums.size() > 0 else 0.08
		var push: float = nums[1] if nums.size() > 1 else 0.0
		return {"kind": "insert", "from": from, "push": push}
	if m.contains("detach") or m.contains("drop") or m.contains("pull down") or m.contains("down"):
		var down: float = absf(nums[0]) if nums.size() > 0 else 0.1
		var out: float = absf(nums[1]) if nums.size() > 1 else 0.0
		return {"kind": "drop", "down": down, "out": out}
	return {}


## Tween the named gun parts (gun glTF space: x fwd, y up, z right) over the reload. t0 / t1 are clip fractions.
static func drive_parts(model: Node3D, arch: String, time: float) -> Tween:
	reset_parts(model)
	var cfg := reload_parts(arch)
	if model == null or cfg.is_empty() or time <= 0.0:
		return null
	var steps: Array = []
	for p in cfg.get("parts", []):
		var mo := parse_motion(str(p.get("node", "")), str(p.get("motion", "")))
		if mo.is_empty():
			continue
		var n := model.find_child(str(p.node), true, false) as Node3D
		if n == null:
			continue
		if not n.has_meta(META_REST):
			n.set_meta(META_REST, n.transform)
		mo["node"] = n
		mo["t0"] = clampf(float(p.get("t0", 0.0)), 0.0, 1.0) * time
		mo["t1"] = clampf(float(p.get("t1", 0.0)), 0.0, 1.0) * time
		steps.append(mo)
	if steps.is_empty():
		return null
	var tw := model.create_tween().set_parallel(true)
	model.set_meta("fp_parts_tween", tw)
	for st in steps:
		var n: Node3D = st.node
		var rest: Transform3D = n.get_meta(META_REST)
		var dur: float = maxf(float(st.t1) - float(st.t0), 0.01)
		var at: float = float(st.t0)
		match str(st.kind):
			"drop":
				var to: Vector3 = rest.origin + Vector3(0.0, -float(st.down), float(st.out))
				tw.tween_property(n, "position", to, dur).set_delay(at)
			"hide":
				tw.tween_callback(_set_visible.bind(n, false)).set_delay(at)
			"insert":
				var start: Vector3 = rest.origin + Vector3(0.0, -float(st.from), 0.0)
				tw.tween_callback(_place.bind(n, start)).set_delay(at)
				tw.tween_property(n, "position", rest.origin + Vector3(0.0, float(st.push), 0.0), dur).set_delay(at)
				if float(st.push) != 0.0:
					tw.tween_property(n, "position", rest.origin, 0.06).set_delay(at + dur)
			"slap":
				tw.tween_property(n, "position", rest.origin + Vector3(0.0, float(st.up), 0.0), dur * 0.4).set_delay(at)
				tw.tween_property(n, "position", rest.origin, dur * 0.6).set_delay(at + dur * 0.4)
			"swing":
				# Revolver crane: orbit the cylinder about an axis parallel to the barrel at its front-lower edge
				# (pivot 2 cm below its centre); position only, so WeaponRig's chamber spin keeps rotation.x.
				var pivot: Vector3 = rest.origin + Vector3(0.0, -0.02, 0.0)
				var deg: float = float(st.deg)
				tw.tween_method(_orbit.bind(n, pivot, rest.origin), float(n.get_meta("fp_swing", 0.0)), deg, dur).set_delay(at)
				n.set_meta("fp_swing", deg) # the next swing step starts from here
	tw.chain().tween_callback(reset_parts.bind(model))
	return tw


static func _set_visible(n: Node3D, v: bool) -> void:
	if is_instance_valid(n):
		n.visible = v


static func _place(n: Node3D, pos: Vector3) -> void:
	if is_instance_valid(n):
		n.position = pos
		n.visible = true


static func _orbit(a: float, n: Node3D, pivot: Vector3, rest: Vector3) -> void:
	if is_instance_valid(n):
		n.position = pivot + (rest - pivot).rotated(Vector3.RIGHT, deg_to_rad(-a))


## Tint the forearm band (surface 1) with a player colour (P1..P4 or any Color).
static func set_tint(arms: Node, c) -> void:
	var col: Color = TINTS.get(c, TINTS.P1) if c is String else (c as Color)
	var mi := mesh(arms)
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() <= TINT_SURFACE:
		return
	var base := mi.get_active_material(TINT_SURFACE)
	var mat: StandardMaterial3D = (base.duplicate() if base is StandardMaterial3D else StandardMaterial3D.new())
	mat.albedo_color = col
	mi.set_surface_override_material(TINT_SURFACE, mat)


static func tint_of(arms: Node) -> Color:
	var mi := mesh(arms)
	if mi == null:
		return Color.BLACK
	var m := mi.get_surface_override_material(TINT_SURFACE)
	return (m as StandardMaterial3D).albedo_color if m is StandardMaterial3D else Color.BLACK
