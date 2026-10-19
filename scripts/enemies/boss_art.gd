extends RefCounted
## Boss art wiring (Skillz, art pass 2026-10-19): Desi's boss GLBs, clips, sockets and emissive materials.
## No class_name (preload it): boss scripts and BossCatalog use it before the global class cache is refreshed.
##   BossArt.model_scene(path)                 -> PackedScene or null (missing file = keep the scene's default walker)
##   BossArt.setup_anims(enemy, anims_cfg)     -> loops the cfg "loop" clips, registers every clip under its cfg key in enemy._anims
##   BossArt.play(enemy, key, blend, speed)    -> plays a registered clip (key from data/bosses.json -> anims)
##   BossArt.socket(enemy, name)               -> Node3D socket inside the spawned model (BoneAttachment3D children), or null
##   BossArt.set_emission(enemy, material, mult) -> per-instance emission multiplier on every surface using that material
## Sockets / clip names: /workspace/desi-models/bosses/NODE_INVENTORY.txt + CLIP_REMAP.txt.

const META_BASE := "boss_art_base_emission"


static func model_scene(path: String) -> PackedScene:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as PackedScene


## Point an enemy at a model before add_child (enemy._ready -> _spawn_model picks from `models`).
static func set_model(enemy: Node, path: String, height: float = -1.0, size_variety: float = -1.0) -> bool:
	var sc := model_scene(path)
	if sc == null:
		return false
	var arr: Array[PackedScene] = [sc]
	enemy.set("models", arr)
	if height > 0.0:
		enemy.set("model_height", height)
	if size_variety >= 0.0:
		enemy.set("size_variety", size_variety)
	enemy.set_meta("model_path", path)
	return true


static func anim_player(enemy: Node) -> AnimationPlayer:
	var a = enemy.get("_anim")
	return a as AnimationPlayer if a is AnimationPlayer else null


## Registers each clip named in `cfg` (string values) under its key in enemy._anims and loops cfg.loop.
## Returns the clip keys that were found.
static func setup_anims(enemy: Node, cfg: Dictionary) -> Array:
	var ap := anim_player(enemy)
	var found: Array = []
	if ap == null:
		return found
	var anims: Dictionary = enemy.get("_anims")
	for k in cfg:
		var v = cfg[k]
		if typeof(v) != TYPE_STRING or str(k).begins_with("_"):
			continue
		var clip := find_clip(ap, str(v))
		if clip != "":
			anims[str(k)] = clip
			found.append(str(k))
	for c in cfg.get("loop", []):
		var clip := find_clip(ap, str(c))
		if clip != "":
			ap.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	return found


## Exact name first, then the importer's "<lib>/<name>" or "...|<name>" forms.
static func find_clip(ap: AnimationPlayer, name: String) -> String:
	if ap == null or name == "":
		return ""
	if ap.has_animation(name):
		return name
	for n in ap.get_animation_list():
		if n.ends_with("/" + name) or n.ends_with("|" + name):
			return n
	return ""


static func has_clip(enemy: Node, key: String) -> bool:
	var anims: Dictionary = enemy.get("_anims")
	return anim_player(enemy) != null and anims.has(key)


## Plays a registered clip from the start (restarts it even if it is already current). speed <= 0 keeps the current speed_scale.
static func play(enemy: Node, key: String, blend: float = 0.15, speed: float = 1.0) -> bool:
	var ap := anim_player(enemy)
	var anims: Dictionary = enemy.get("_anims")
	if ap == null or not anims.has(key):
		return false
	if speed > 0.0:
		ap.speed_scale = speed
	var clip := str(anims[key])
	var again := ap.current_animation == clip
	ap.play(clip, blend)
	if again:
		ap.seek(0.0, true)
	return true


static func clip_length(enemy: Node, key: String, fallback: float = 0.0) -> float:
	var ap := anim_player(enemy)
	var anims: Dictionary = enemy.get("_anims")
	if ap == null or not anims.has(key):
		return fallback
	return ap.get_animation(str(anims[key])).length


static func model_node(enemy: Node) -> Node3D:
	var mr = enemy.get("model_root")
	if mr is Node3D and (mr as Node3D).get_child_count() > 0:
		return (mr as Node3D).get_child(0) as Node3D
	return null


static func socket(enemy: Node, name: String) -> Node3D:
	var m := model_node(enemy)
	if m == null or name == "":
		return null
	return m.find_child(name, true, false) as Node3D


## World position of a socket, or `fallback` when the model/socket is missing (old walker model, tests).
static func socket_pos(enemy: Node, name: String, fallback: Vector3) -> Vector3:
	var s := socket(enemy, name)
	return s.global_position if s and s.is_inside_tree() else fallback


## Multiplies the authored emission of `material_name` on this enemy only (materials are duplicated per instance,
## so other bosses sharing the imported resource are unaffected). Returns the number of surfaces changed.
static func set_emission(enemy: Node, material_name: String, mult: float) -> int:
	var m := model_node(enemy)
	if m == null:
		return 0
	var n := 0
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		var inst := mi as MeshInstance3D
		if inst.mesh == null:
			continue
		for i in inst.mesh.get_surface_count():
			var mat := inst.get_surface_override_material(i)
			if mat == null or not mat.has_meta(META_BASE):
				var src := inst.get_active_material(i)
				if not (src is StandardMaterial3D) or src.resource_name != material_name:
					continue
				mat = src.duplicate()
				mat.resource_name = material_name
				mat.set_meta(META_BASE, (src as StandardMaterial3D).emission_energy_multiplier)
				inst.set_surface_override_material(i, mat)
			if mat.resource_name != material_name:
				continue
			var sm := mat as StandardMaterial3D
			sm.emission_enabled = true
			sm.emission_energy_multiplier = float(sm.get_meta(META_BASE, 1.0)) * mult
			n += 1
	return n


## Current emission multiplier of the first surface using `material_name` (tests / debugging). -1 if not found.
static func emission(enemy: Node, material_name: String) -> float:
	var m := model_node(enemy)
	if m == null:
		return -1.0
	for mi in m.find_children("*", "MeshInstance3D", true, false):
		var inst := mi as MeshInstance3D
		if inst.mesh == null:
			continue
		for i in inst.mesh.get_surface_count():
			var mat := inst.get_active_material(i)
			if mat is StandardMaterial3D and mat.resource_name == material_name:
				return (mat as StandardMaterial3D).emission_energy_multiplier
	return -1.0
