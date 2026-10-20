class_name NetDesiBody
extends NetAvatarBody
## Desi's rigged Gravecrew player body (assets/models/player/player.glb) driven per NETZ_NOTES.txt:
##   Locomotion  speed BlendSpace1D Idle/Walk/Run/Sprint + crouch Blend2 (Crouch/CrouchWalk), playback scaled by
##               speed / clip foot speed; ground <-> air Transition, Air = StateMachine Jump -> Fall, Land one-shot.
##   Upper body  StateMachine Hold_Rifle <-> ADS_Aim (xfade 0.12) + Fire / Reload / Throw one-shots, combined over
##               the locomotion with a bone filter from spine_02 up (arms, hands, fingers, neck, head).
##   Override    Transition alive / downed (Downed) / reviving (ReviveStart -> Revive -> ReviveEnd) / dead (Death,
##               holds its last frame). No upper-body layer in those.
## Sockets: WeaponR (gun, identity), NameTag (name tag), GrenadeR. Tint via player_rig.gd (TintBand = surface 1).

const RIG := preload("res://assets/models/player/player_rig.gd")

var model: Node3D
var anim: AnimationPlayer
var tree: AnimationTree
var weapon_socket: Node3D
var grenade_socket: Node3D
var name_socket: Node3D
var skeleton: Skeleton3D
var last_event := ""
var _gun: Node3D
var _revive_end_t := 0.0
var _track_root := "player_rig/Skeleton3D"


func _ready() -> void:
	var path := str(NetConfig.get_value("avatar.scene", "res://assets/models/player/player.glb"))
	if not ResourceLoader.exists(path):
		push_warning("NetDesiBody: %s missing" % path)
		return
	model = (load(path) as PackedScene).instantiate()
	add_child(model)
	RIG.setup_loops(model)
	anim = model.find_children("*", "AnimationPlayer", true, false).front()
	skeleton = model.find_children("*", "Skeleton3D", true, false).front()
	weapon_socket = model.find_child("WeaponR", true, false)
	grenade_socket = model.find_child("GrenadeR", true, false)
	name_socket = model.find_child("NameTag", true, false)
	if skeleton:
		_track_root = str(model.get_path_to(skeleton))
	_build_tree()
	set_slot(slot)
	if weapon_id != "":
		_apply_weapon(weapon_id)


func name_tag_anchor() -> Node3D:
	return name_socket if name_socket else self


# ------------------------------------------------------------------ tree
func _auto() -> AnimationNodeStateMachineTransition:
	var t := AnimationNodeStateMachineTransition.new()
	t.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	return t


func _clip(n: String) -> AnimationNodeAnimation:
	var a := AnimationNodeAnimation.new()
	a.animation = n
	return a


func _build_tree() -> void:
	var sp: Dictionary = NetConfig.get_value("avatar.loco_speeds", {})
	var bt := AnimationNodeBlendTree.new()
	# locomotion
	var loco := AnimationNodeBlendSpace1D.new()
	loco.min_space = 0.0
	loco.max_space = float(sp.get("sprint", 8.5)) + 1.0
	loco.add_blend_point(_clip("Idle"), 0.0, -1, &"Idle")
	loco.add_blend_point(_clip("Walk"), float(sp.get("walk", 2.0)), -1, &"Walk")
	loco.add_blend_point(_clip("Run"), float(sp.get("run", 5.0)), -1, &"Run")
	loco.add_blend_point(_clip("Sprint"), float(sp.get("sprint", 8.5)), -1, &"Sprint")
	bt.add_node("loco", loco)
	var cloco := AnimationNodeBlendSpace1D.new()
	cloco.min_space = 0.0
	cloco.max_space = float(sp.get("crouch_walk", 2.8)) + 1.0
	cloco.add_blend_point(_clip("Crouch"), 0.0, -1, &"Crouch")
	cloco.add_blend_point(_clip("CrouchWalk"), float(sp.get("crouch_walk", 2.8)), -1, &"CrouchWalk")
	bt.add_node("crouch_loco", cloco)
	bt.add_node("crouch", AnimationNodeBlend2.new())
	bt.connect_node("crouch", 0, "loco")
	bt.connect_node("crouch", 1, "crouch_loco")
	bt.add_node("loco_ts", AnimationNodeTimeScale.new())
	bt.connect_node("loco_ts", 0, "crouch")
	var land := AnimationNodeOneShot.new()
	land.fadein_time = 0.05
	land.fadeout_time = 0.2
	bt.add_node("land", land)
	bt.add_node("land_clip", _clip("Land"))
	bt.connect_node("land", 0, "loco_ts")
	bt.connect_node("land", 1, "land_clip")
	var air := AnimationNodeStateMachine.new()
	air.add_node("Jump", _clip("Jump"))
	air.add_node("Fall", _clip("Fall"))
	air.add_transition("Start", "Jump", _auto())
	var j2f := AnimationNodeStateMachineTransition.new()
	j2f.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	j2f.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	j2f.xfade_time = 0.1
	air.add_transition("Jump", "Fall", j2f)
	air.add_transition("Fall", "Jump", AnimationNodeStateMachineTransition.new())
	bt.add_node("air", air)
	var ga := AnimationNodeTransition.new()
	ga.xfade_time = 0.1
	ga.add_input("ground")
	ga.add_input("air")
	bt.add_node("ground_air", ga)
	bt.connect_node("ground_air", 0, "land")
	bt.connect_node("ground_air", 1, "air")
	# upper body
	var up := AnimationNodeStateMachine.new()
	up.add_node("Hold_Rifle", _clip("Hold_Rifle"))
	up.add_node("ADS_Aim", _clip("ADS_Aim"))
	up.add_transition("Start", "Hold_Rifle", _auto())
	for pair in [["Hold_Rifle", "ADS_Aim"], ["ADS_Aim", "Hold_Rifle"]]:
		var t := AnimationNodeStateMachineTransition.new()
		t.xfade_time = float(NetConfig.get_value("avatar.ads_xfade_s", 0.12))
		up.add_transition(pair[0], pair[1], t)
	bt.add_node("upper", up)
	var fire := AnimationNodeOneShot.new()
	fire.fadein_time = 0.0
	fire.fadeout_time = 0.05
	bt.add_node("fire", fire)
	bt.add_node("fire_clip", _clip("Fire"))
	bt.connect_node("fire", 0, "upper")
	bt.connect_node("fire", 1, "fire_clip")
	var reload := AnimationNodeOneShot.new()
	reload.fadein_time = 0.1
	reload.fadeout_time = 0.15
	bt.add_node("reload", reload)
	bt.add_node("reload_clip", _clip("Reload"))
	bt.add_node("reload_ts", AnimationNodeTimeScale.new())
	bt.connect_node("reload_ts", 0, "reload_clip")
	bt.connect_node("reload", 0, "fire")
	bt.connect_node("reload", 1, "reload_ts")
	var throw := AnimationNodeOneShot.new()
	throw.fadein_time = 0.1
	throw.fadeout_time = 0.2
	bt.add_node("throw", throw)
	bt.add_node("throw_clip", _clip("Throw"))
	bt.connect_node("throw", 0, "reload")
	bt.connect_node("throw", 1, "throw_clip")
	var comb := AnimationNodeBlend2.new()
	comb.filter_enabled = true
	for b in _upper_bones():
		comb.set_filter_path(NodePath("%s:%s" % [_track_root, b]), true)
	bt.add_node("combine", comb)
	bt.connect_node("combine", 0, "ground_air")
	bt.connect_node("combine", 1, "throw")
	# full-body override
	var rev := AnimationNodeStateMachine.new()
	rev.add_node("ReviveStart", _clip("ReviveStart"))
	rev.add_node("Revive", _clip("Revive"))
	rev.add_node("ReviveEnd", _clip("ReviveEnd"))
	rev.add_transition("Start", "ReviveStart", _auto())
	var s2l := AnimationNodeStateMachineTransition.new()
	s2l.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_AT_END
	s2l.advance_mode = AnimationNodeStateMachineTransition.ADVANCE_MODE_AUTO
	rev.add_transition("ReviveStart", "Revive", s2l)
	var l2e := AnimationNodeStateMachineTransition.new()
	l2e.xfade_time = 0.15
	rev.add_transition("Revive", "ReviveEnd", l2e)
	rev.add_transition("ReviveStart", "ReviveEnd", l2e)
	bt.add_node("revive", rev)
	var life_t := AnimationNodeTransition.new()
	life_t.xfade_time = 0.2
	for n in [LIFE_ALIVE, LIFE_DOWNED, LIFE_REVIVING, LIFE_DEAD]:
		life_t.add_input(n)
	bt.add_node("life", life_t)
	bt.add_node("downed_clip", _clip("Downed"))
	bt.add_node("death_clip", _clip("Death"))
	bt.connect_node("life", 0, "combine")
	bt.connect_node("life", 1, "downed_clip")
	bt.connect_node("life", 2, "revive")
	bt.connect_node("life", 3, "death_clip")
	bt.connect_node("output", 0, "life")

	tree = AnimationTree.new()
	tree.name = "AnimationTree"
	tree.anim_player = NodePath("../" + str(model.get_path_to(anim))) # set before it enters the tree
	tree.tree_root = bt
	model.add_child(tree)
	tree.set("parameters/life/transition_request", LIFE_ALIVE) # a Transition outputs nothing until it has a state
	tree.set("parameters/ground_air/transition_request", "ground")
	tree.set("parameters/combine/blend_amount", 1.0)
	tree.set("parameters/loco_ts/scale", 1.0)
	tree.set("parameters/reload_ts/scale", 1.0)
	tree.active = true


## spine_02 and everything above it (Desi's filter list): spine_02/03, neck, head, clavicles, arms, hands, fingers.
func _upper_bones() -> Array:
	var out: Array = []
	if skeleton == null:
		return out
	var root_b := skeleton.find_bone("spine_02")
	for i in skeleton.get_bone_count():
		var b := i
		while b != -1 and b != root_b:
			b = skeleton.get_bone_parent(b)
		if b == root_b:
			out.append(skeleton.get_bone_name(i))
	return out


# ------------------------------------------------------------------ adapter
func _apply_tint(c: Color) -> void:
	if model:
		RIG.apply_tint(model, c)


func _apply_weapon(arch_id: String) -> void:
	if weapon_socket == null:
		return
	for ch in weapon_socket.get_children():
		ch.queue_free()
	_gun = weapon_model(arch_id)
	if _gun:
		weapon_socket.add_child(_gun) # identity: WeaponR already seats the grip (+X fwd, +Y up)


func _apply_state() -> void:
	if tree == null:
		return
	tree.set("parameters/loco/blend_position", speed)
	tree.set("parameters/crouch_loco/blend_position", speed)
	tree.set("parameters/crouch/blend_amount", clampf(crouch, 0.0, 1.0))
	tree.set("parameters/loco_ts/scale", loco_time_scale(speed, crouch > 0.5))
	tree.set("parameters/ground_air/transition_request", "air" if airborne else "ground")
	var pb: AnimationNodeStateMachinePlayback = tree.get("parameters/upper/playback")
	if pb:
		pb.travel("ADS_Aim" if ads else "Hold_Rifle")


## Foot-slide fix: playback speed = game speed / the clip's measured foot speed, blended between the clips.
static func loco_time_scale(spd: float, crouched: bool) -> float:
	if spd <= 0.3:
		return 1.0
	var sp: Dictionary = NetConfig.get_value("avatar.loco_speeds", {})
	var fs: Dictionary = NetConfig.get_value("avatar.clip_foot_speeds", {})
	if crouched:
		return clampf(spd / float(fs.get("crouch_walk", 0.77)), 0.3, 3.0)
	# [blend position (game m/s), clip foot speed]; between two clips the scale blends like the clips do.
	var pts := [[float(sp.get("walk", 2.0)), float(fs.get("walk", 1.16))], [float(sp.get("run", 5.0)), float(fs.get("run", 6.2))],
		[float(sp.get("sprint", 8.5)), float(fs.get("sprint", 9.5))]]
	var k: float = spd / pts[0][1]
	for i in range(1, pts.size()):
		if spd >= pts[i][0]:
			k = spd / pts[i][1]
		elif spd > pts[i - 1][0]:
			var f: float = (spd - pts[i - 1][0]) / (pts[i][0] - pts[i - 1][0])
			k = lerpf(spd / pts[i - 1][1], spd / pts[i][1], f)
	return clampf(k, 0.3, 3.0)


func _apply_life(prev: String, state: String) -> void:
	if tree == null:
		return
	if prev == LIFE_REVIVING and state == LIFE_ALIVE:
		var pb: AnimationNodeStateMachinePlayback = tree.get("parameters/revive/playback")
		if pb:
			pb.travel("ReviveEnd")
		_revive_end_t = float(anim.get_animation("ReviveEnd").length) if anim and anim.has_animation("ReviveEnd") else 0.0
		life = LIFE_REVIVING # stay in the override until ReviveEnd finishes (see _process)
		_pending_alive = true
		return
	_pending_alive = false
	if state == LIFE_REVIVING:
		var pb2: AnimationNodeStateMachinePlayback = tree.get("parameters/revive/playback")
		if pb2:
			pb2.start("ReviveStart")
	tree.set("parameters/life/transition_request", state)
	if state != LIFE_ALIVE: # no one-shots under a full-body override
		for os in ["fire", "reload", "throw", "land"]:
			tree.set("parameters/%s/request" % os, AnimationNodeOneShot.ONE_SHOT_REQUEST_ABORT)


var _pending_alive := false


func _process(delta: float) -> void:
	super(delta)
	if _pending_alive:
		_revive_end_t -= delta
		if _revive_end_t <= 0.0:
			_pending_alive = false
			life = LIFE_ALIVE
			if tree:
				tree.set("parameters/life/transition_request", LIFE_ALIVE)


func _on_air_start() -> void:
	if tree == null:
		return
	# Walked off a ledge (no jump event this frame): straight to Fall.
	var pb: AnimationNodeStateMachinePlayback = tree.get("parameters/air/playback")
	if pb and last_event != "jump":
		pb.start("Fall")


func _trigger(event_id: String, data: Dictionary) -> void:
	last_event = event_id
	if tree == null or life != LIFE_ALIVE and event_id != "hit":
		return
	var fire := AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE
	match event_id:
		"fire":
			tree.set("parameters/fire/request", fire) # restarts on each shot (auto fire)
		"reload":
			var t := maxf(float(data.get("time", reload_clip_len())), 0.1)
			tree.set("parameters/reload_ts/scale", reload_clip_len() / t)
			tree.set("parameters/reload/request", fire)
		"throw":
			tree.set("parameters/throw/request", fire)
			stow_weapon(true) # Throw (UAL2 OverhandThrow) has no gun in the hands: the rifle would pop at the elbow
		"jump":
			var pb: AnimationNodeStateMachinePlayback = tree.get("parameters/air/playback")
			if pb:
				pb.start("Jump")
			tree.set("parameters/ground_air/transition_request", "air")
		"land":
			tree.set("parameters/land/request", fire)


## Reload marks: hide the gun's magazine between mag out and mag in (if the gun model has a *Mag* node).
func _on_marker(n: String) -> void:
	if n == "throw_done":
		stow_weapon(false)
	if _gun == null:
		return
	var mag := _gun.find_child("*Mag*", true, false) as Node3D
	if mag == null:
		return
	if n == "mag_out_done":
		mag.visible = false
	elif n == "mag_in":
		mag.visible = true


## Hide the WeaponR socket (gun + anything parented there) for the Throw clip; shown again at "throw_done".
## Weapon swaps while stowed stay hidden until then.
func stow_weapon(on: bool) -> void:
	if weapon_socket:
		weapon_socket.visible = not on


func weapon_stowed() -> bool:
	return weapon_socket != null and not weapon_socket.visible


## Tests / debug.
func upper_state() -> String:
	var pb: AnimationNodeStateMachinePlayback = tree.get("parameters/upper/playback") if tree else null
	return str(pb.get_current_node()) if pb else super()


func life_state() -> String:
	return str(tree.get("parameters/life/current_state")) if tree else life
