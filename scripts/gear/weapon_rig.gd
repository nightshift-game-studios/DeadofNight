extends RefCounted
## Weapon art rig (Skillz, art pass 2026-10-19): fits Armory attachments onto Desi's split-mesh guns.
## No class_name (preload it), so player.gd / Gooey's Armory preview can use it before the class cache refreshes.
##
## Guns (assets/models/weapons/weapon_*.glb, picked per archetype by data/weapons.json -> model) carry socket empties
## Muzzle / SightPoint / Rail / Underbarrel / MagWell / Stock / Barrel and default part meshes Body / IronSights /
## DefaultMag / DefaultMuzzle / DefaultStock / DefaultGrip / DefaultOptic (NODE_INVENTORY.txt).
## data/attachments.json -> slots[] gives each slot its socket + the default parts it hides; an attachment may
## override with its own "hides" (Mine Lamp: [] = DefaultGrip stays).
##
##   var rig := WeaponRig.apply(model, arch)          # uses Armory.loadout(arch); or pass a {slot: att_id} loadout
##   rig.attached  {slot: Node3D}   instanced attachment GLBs (child of the socket, identity transform)
##   rig.hidden    [part names]     default meshes hidden by the fitted parts
##   rig.missing   [att ids]        equipped parts whose GLB isn't shipped yet (nothing shown, defaults stay)
##   rig.muzzle    Node3D | null    effective bore exit: muzzle device front Muzzle > barrel Muzzle > gun Muzzle
##   rig.sight     Node3D | null    ADS eye point: optic SightPoint > gun SightPoint
##   rig.lamp      Node3D | null    flashlight housing: Mine Lamp or Lantern Rail (flags.flashlight; Glass = lens, BeamHint = front)
##   rig.skipped   [slots]          equipped slots the gun has no socket for (revolver: grip/stock; launcher: barrel/stock)
##   rig.barrel_scale float         per-gun barrel X scale s = (Muzzle.x - Barrel.x) / BARREL_REF (applied to a fitted barrel)
##   rig.cylinder / rig.rocket / rig.launcher / rig.heartbeat / rig.glow   animated or data-driven parts (art pass 2)
## WeaponRig.clear(model) undoes it (frees the attachments, shows the defaults again) so the same model can be re-fitted.
##
## Art pass 2 (Desi batch 2, 2026-10-19): revolver (Cylinder spins 60 deg on local X per shot), rocket launcher (Rocket
## hidden on fire, shown on reload), DefaultBarrel on the rifle-class guns, per-gun barrel scale, uniques (Gravesight lens
## glow from flags.outline_elites, Heartbeat Counter Label3D on ScreenAnchor, Second Mouth LauncherMuzzle, Lantern Rail
## beam, Bonesaw blade reach), ADS sight line (sight_line / ads_offset, see AdsProfile.ads_gun_position).
## player.gd calls on_fire / on_reload / set_ads (MAIN_HOOKS §14); everything else happens inside apply().

const ARMORY := preload("res://scripts/armory/armory.gd")
const META_ATT := "weapon_rig_attachment"
const META_HIDDEN := "weapon_rig_hidden"
## Fitting order: barrel first (it can bring its own Muzzle), muzzle devices after it.
const ORDER := ["barrel", "muzzle", "optic", "grip", "mag", "stock"]
const DEFAULT_SOCKETS := {"optic": "Rail", "muzzle": "Muzzle", "barrel": "Barrel", "grip": "Underbarrel", "mag": "MagWell", "stock": "Stock"}
## Barrel attachments are authored for a 0.50 m bore run (Muzzle at x 0.50); each gun scales them to its own
## Barrel->Muzzle distance: s = (Muzzle.x - Barrel.x) / BARREL_REF (AR 1.00, SMG 0.68, revolver 0.31, sniper 1.68).
const BARREL_REF := 0.50
## Bonesaw Bayonet: blade tip stops this far behind the gun's Muzzle socket (Blade.x = Muzzle.x - Underbarrel.x - this).
const BAYONET_SETBACK := 0.10
const CYLINDER_STEP := deg_to_rad(60.0) ## 6-shot revolver: one chamber per shot
const META_REST := "weapon_rig_rest" ## original local transform of an animated part (so re-fits / clears start clean)
const GLOW_ON := 1.6 ## Gravesight Lens/Ocular emission multiplier while outline_elites is active
const GLOW_OFF := 0.15
const HEARTBEAT_SCRIPT := "res://scripts/gear/heartbeat_label.gd"
const META_ROCKET_SEQ := "weapon_rig_rocket_seq" ## bumped by every shot / reload / refit: a stale re-chamber timer does nothing
const META_ROCKET_AMMO := "weapon_rig_rocket_ammo" ## ammo_after of the last shot (fallback when no player is above the model)


static func slot_def(slot: String) -> Dictionary:
	for s in ARMORY.slots():
		if str(s.get("id", "")) == slot:
			return s
	return {}


static func socket_name(slot: String) -> String:
	return str(slot_def(slot).get("socket", DEFAULT_SOCKETS.get(slot, "")))


## Default part names a fitted attachment hides: the attachment's hides_by_class[arch] if present (Sawn Stub on the
## shotgun also hides the bead), else its own "hides", else its slot's.
static func hides_for(att_id: String, slot: String = "", arch: String = "") -> Array:
	var a: Dictionary = ARMORY.attachment(att_id)
	if slot == "":
		slot = str(a.get("slot", ""))
	var h = a.get("hides", slot_def(slot).get("hides", []))
	var by_class = a.get("hides_by_class", {})
	if arch != "" and by_class is Dictionary and (by_class as Dictionary).has(arch):
		h = by_class[arch]
	if typeof(h) == TYPE_STRING:
		return [h] if str(h) != "" else []
	return Array(h)


## Nodes inside the attachment itself hidden on this host: inner_hides[arch] if present, else inner_hides["*"]
## (art pass 3: Sawn Stub's MagTubeStub shows on the shotgun only).
static func inner_hides_for(att_id: String, arch: String = "") -> Array:
	var ih = ARMORY.attachment(att_id).get("inner_hides", {})
	if not (ih is Dictionary):
		return []
	return Array((ih as Dictionary).get(arch, (ih as Dictionary).get("*", [])))


static func model_path(att_id: String) -> String:
	return str(ARMORY.attachment(att_id).get("model", ""))


static func has_model(att_id: String) -> bool:
	var p := model_path(att_id)
	return p != "" and ResourceLoader.exists(p)


## Pure plan (no nodes): which socket each part goes on and what it hides, for a loadout {slot: att_id}.
## Used by tests and by Gooey's Armory preview text. Skips empty slots.
static func plan(loadout: Dictionary, arch: String = "") -> Dictionary:
	var attach := {}
	var hide: Array = []
	var missing: Array = []
	for slot in ORDER:
		var id := str(loadout.get(slot, ""))
		if id == "":
			continue
		if not has_model(id):
			missing.append(id)
			continue
		attach[slot] = {"id": id, "socket": socket_name(slot), "model": model_path(id)}
		for h in hides_for(id, slot, arch):
			if not hide.has(h):
				hide.append(h)
	return {"attach": attach, "hide": hide, "missing": missing}


static func find_node(root: Node, name: String) -> Node3D:
	if root == null or name == "":
		return null
	return root.find_child(name, true, false) as Node3D


static func clear(model: Node3D) -> void:
	if model == null:
		return
	for n in model.find_children("*", "Node3D", true, false):
		if n.has_meta(META_ATT):
			n.get_parent().remove_child(n)
			n.queue_free()
	for n in model.find_children("*", "Node3D", true, false):
		if n.has_meta(META_HIDDEN):
			(n as Node3D).visible = true
			n.remove_meta(META_HIDDEN)
		if n.has_meta(META_REST):
			(n as Node3D).transform = n.get_meta(META_REST)
			(n as Node3D).visible = true


## Fits the loadout onto an instanced gun model. `loadout` null/empty dict = Armory.loadout(arch).
## Attachments are authored in real metres like the guns, so they inherit the gun's view scale as socket children.
static func apply(model: Node3D, arch: String, loadout = null, shadows: bool = false) -> Dictionary:
	var out := {"attached": {}, "hidden": [], "missing": [], "muzzle": null, "sight": null, "lamp": null,
		"skipped": [], "barrel_scale": 1.0, "model": model, "arch": arch, "cylinder": null, "rocket": null,
		"launcher": null, "heartbeat": null, "glow": [], "anim": {}}
	if model == null:
		return out
	clear(model)
	var lo: Dictionary = loadout if loadout is Dictionary and not (loadout as Dictionary).is_empty() else ARMORY.loadout(arch)
	var p := plan(lo, arch)
	out.missing = p.missing
	out.barrel_scale = barrel_scale(model)
	out.cylinder = _rest(find_node(model, "Cylinder"))
	out.rocket = _rest(find_node(model, "Rocket"))
	if out.rocket != null:
		_bump_rocket(out.rocket, -1)  # refit cancels pending re-chambers
		if live_ammo(model, arch) == 0:
			out.rocket.visible = false  # swapped back to an empty launcher: no Rocket until reload (art pass 2b)
	var gun_muzzle: Node3D = find_node(model, socket_name("muzzle"))
	var muzzle_parent: Node3D = gun_muzzle
	for slot in ORDER:
		if not p.attach.has(slot):
			continue
		var e: Dictionary = p.attach[slot]
		var sock: Node3D = muzzle_parent if slot == "muzzle" else find_node(model, str(e.socket))
		if sock == null or (slot != "muzzle" and _inside_attachment(sock, model)):
			# gun without that socket (revolver: no Underbarrel/Stock; launcher: no Barrel/Stock; pistol: no
			# Underbarrel/Stock/Barrel; old Quaternius guns: none). Skipped cleanly: nothing instanced, nothing hidden.
			if not out.skipped.has(slot):
				out.skipped.append(slot)
			continue
		var sc := load(str(e.model)) as PackedScene
		if sc == null:
			out.missing.append(e.id)
			continue
		var inst := sc.instantiate() as Node3D
		inst.name = "Att_" + slot
		inst.set_meta(META_ATT, str(e.id))
		sock.add_child(inst)
		inst.transform = Transform3D.IDENTITY
		if not shadows:
			for gi in inst.find_children("*", "GeometryInstance3D", true, false):
				(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		out.attached[slot] = inst
		for ih in inner_hides_for(str(e.id), arch):
			var hn := find_node(inst, str(ih))
			if hn:
				hn.visible = false
		var a: Dictionary = ARMORY.attachment(str(e.id))
		var fl: Dictionary = a.get("flags", {})
		if slot == "barrel":
			_scale_barrel(inst, out.barrel_scale)
			var bm := find_node(inst, "Muzzle")
			if bm:
				muzzle_parent = bm
		if bool(fl.get("flashlight", false)) and find_node(inst, "Glass") != null:
			out.lamp = inst # Mine Lamp + Lantern Rail (same Glass / BeamHint names)
		if fl.has("outline_elites"):
			for lens_name in ["Lens", "Ocular"]:
				var ln := find_node(inst, lens_name)
				if ln is MeshInstance3D:
					out.glow.append(ln)
			set_glow(out, 1.0 if bool(fl.outline_elites) else 0.0)
		if bool(fl.get("heartbeat_counter", false)):
			out.heartbeat = _add_heartbeat(inst, float(fl.get("heartbeat_radius", 10.0)))
		var lm := find_node(inst, "LauncherMuzzle")
		if lm:
			out.launcher = lm
			out.anim["tube"] = _rest(find_node(inst, "Tube"))
		var blade := find_node(inst, "Blade")
		if blade and gun_muzzle and slot == "grip":
			blade.position.x = (gun_point(model, gun_muzzle).x - gun_point(model, sock).x) - BAYONET_SETBACK
		for an in ["Dial", "Slider"]:
			var nd := find_node(inst, an)
			if nd:
				out.anim[an.to_lower()] = _rest(nd)
		if str(e.id) == "speedloader_ring":
			out.anim["speedloader"] = _rest(inst)
	# Hide the default parts the fitted parts replace (only for parts that actually got fitted).
	for slot in out.attached:
		for h in hides_for(str(p.attach[slot].id), slot, arch):
			# The named part (its children go with it, e.g. Desi's shotgun barrel band once it sits under DefaultBarrel)
			# plus split-off siblings named "<part>_*" (e.g. DefaultBarrel_Band), never anything inside an attachment.
			var targets: Array = [find_node(model, str(h))]
			targets.append_array(model.find_children(str(h) + "_*", "Node3D", true, false))
			for n in targets:
				if n and (n as Node3D).visible and not n.has_meta(META_ATT) and not _inside_attachment(n, model):
					(n as Node3D).visible = false
					n.set_meta(META_HIDDEN, true)
					if not out.hidden.has(str(n.name)):
						out.hidden.append(str(n.name))
	# Effective points.
	var mz: Node3D = null
	if out.attached.has("muzzle"):
		mz = find_node(out.attached.muzzle, "Muzzle")
		if mz == null:
			mz = out.attached.muzzle # short devices (brake, cage, choke): origin = their rear; front is close enough
	if mz == null:
		mz = muzzle_parent
	out.muzzle = mz
	var sp: Node3D = find_node(out.attached.optic, "SightPoint") if out.attached.has("optic") else null
	out.sight = sp if sp else find_node(model, "SightPoint")
	return out


# ------------------------------------------------------------------ geometry helpers (root = gun model space)

## Position of `node` in the gun model's root space (real metres, before the view scale). Works out of the tree.
static func gun_point(model: Node3D, node: Node3D) -> Vector3:
	return gun_xform(model, node).origin


static func gun_xform(model: Node3D, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != model:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


static func _inside_attachment(n: Node, model: Node3D) -> bool:
	while n != null and n != model:
		if n.has_meta(META_ATT):
			return true
		n = n.get_parent()
	return false


## Per-gun barrel X scale: (Muzzle.x - Barrel.x) / BARREL_REF from the gun's own sockets; 1.0 if it has no Barrel socket.
static func barrel_scale(model: Node3D) -> float:
	var b := find_node(model, socket_name("barrel"))
	var m := find_node(model, socket_name("muzzle"))
	if b == null or m == null or _inside_attachment(b, model):
		return 1.0
	return maxf((gun_point(model, m).x - gun_point(model, b).x) / BARREL_REF, 0.05)


## Scales a fitted barrel along its bore (X): every mesh child's scale.x and every socket child's (Muzzle) position.x.
## The attachment root keeps scale 1, so a muzzle device on the barrel's Muzzle is not stretched.
static func _scale_barrel(inst: Node3D, s: float) -> void:
	# The imported GLB wraps its nodes in a scene root (Att_barrel > <id> > Mesh, Muzzle): scale where they live.
	var mesh := find_node(inst, "Mesh")
	var holder: Node = mesh.get_parent() if mesh else inst
	for c in holder.get_children():
		if c is MeshInstance3D:
			(c as Node3D).scale.x = s
		elif c is Node3D:
			(c as Node3D).position.x *= s


static func _rest(n: Node3D) -> Node3D:
	if n and not n.has_meta(META_REST):
		n.set_meta(META_REST, n.transform)
	return n


## Root-space ADS sight line point: optic SightPoint, else OpticSightPoint while the built-in DefaultOptic shows, else the
## gun's SightPoint (since Desi's 12:27 sightline pass: the rear-sight top on all guns). Guns whose SightPoint sits at bore
## height (the 8 pre-revolver guns, |SightPoint.y - Muzzle.y| < 2 mm) use the top of the visible IronSights instead,
## so the iron sights line up on the screen centre rather than the bore. The revolver's SightPoint (y 0.0793) is
## already on the real sight line and is used as is.
static func sight_line(rig: Dictionary) -> Vector3:
	var model: Node3D = rig.get("model")
	var sp: Node3D = rig.get("sight")
	if model == null or sp == null:
		return Vector3.ZERO
	var p := gun_point(model, sp)
	if rig.get("attached", {}).has("optic") and (rig.attached.optic as Node3D).is_ancestor_of(sp):
		return p
	# Built-in scope (sniper DefaultOptic): an OpticSightPoint node on the scope axis wins while DefaultOptic shows
	# (Desi notch pass 12:57: weapon_sniper.glb DefaultOptic/OpticSightPoint at y 0.140; SightPoint = backup irons).
	var osp := find_node(model, "OpticSightPoint")
	var dopt := find_node(model, "DefaultOptic")
	if osp and dopt and dopt.visible and not _inside_attachment(osp, model):
		return gun_point(model, osp)
	var mz := find_node(model, "Muzzle")
	var irons := find_node(model, "IronSights")
	if mz and irons is MeshInstance3D and irons.visible and absf(p.y - gun_point(model, mz).y) < 0.002:
		var top := (gun_xform(model, irons) * (irons as MeshInstance3D).get_aabb()).end.y
		p.y = maxf(p.y, top)
	return p


## Sight line in `space` (player.gd's Gun node) coordinates; AdsProfile.ads_gun_position() turns it into the gun pose.
static func ads_offset(rig: Dictionary, space: Node3D) -> Vector3:
	var model: Node3D = rig.get("model")
	if model == null or space == null or not model.is_inside_tree() or not space.is_inside_tree():
		return Vector3.ZERO
	var wp: Vector3 = model.global_transform * sight_line(rig)
	return space.global_transform.affine_inverse() * wp


# ------------------------------------------------------------------ animated / data-driven parts (MAIN_HOOKS §14)

static func _ok(n) -> bool:
	return n != null and is_instance_valid(n) and (n as Node).is_inside_tree()


static func _tw(n: Node3D) -> Tween:
	return n.create_tween() if _ok(n) else null


## Per shot: revolver Cylinder turns one chamber (60 deg on local X); launcher Rocket hidden (shown again on reload,
## or after `rechamber` s only if the magazine still has a round then; see _rechamber); Echo Drum dial ticks. Safe on any rig ({} included).
static func on_fire(rig: Dictionary, ammo_after: int = 0, rechamber: float = 0.4) -> void:
	var cyl = rig.get("cylinder")
	if _ok(cyl):
		var c := cyl as Node3D
		var t := _tw(c)
		var to := c.rotation.x + CYLINDER_STEP
		t.tween_property(c, "rotation:x", to, 0.06)
	var rk = rig.get("rocket")
	if rk != null and is_instance_valid(rk):
		var r := rk as Node3D
		r.visible = false
		var seq := _bump_rocket(r, ammo_after)
		if ammo_after > 0 and _ok(r):
			r.get_tree().create_timer(rechamber).timeout.connect(func(): _rechamber(rig, r, seq))
	var dial = rig.get("anim", {}).get("dial")
	if _ok(dial):
		_tw(dial).tween_property(dial, "rotation:z", (dial as Node3D).rotation.z - deg_to_rad(30.0), 0.05)


## Rounds left in the live magazine of the weapon this model belongs to: the nearest ancestor with current_weapon()
## (player.gd's public API) whose weapon archetype is `arch`. -1 = unknown (no player above the model, or another gun).
static func live_ammo(model: Node, arch: String = "") -> int:
	var n: Node = model
	while n != null:
		if n.has_method("current_weapon"):
			var w = n.current_weapon()
			if w != null and is_instance_valid(w) and (arch == "" or str(w.get("archetype")) == arch):
				return int(w.get("ammo"))
			return -1
		n = n.get_parent()
	return -1


static func _bump_rocket(r: Node3D, ammo_after: int) -> int:
	var seq := int(r.get_meta(META_ROCKET_SEQ, 0)) + 1
	r.set_meta(META_ROCKET_SEQ, seq)
	r.set_meta(META_ROCKET_AMMO, ammo_after)
	return seq


## Re-chamber timer (art pass 2b): show the Rocket only if no later shot/reload/refit happened and the magazine still
## has a round (live player ammo when available, else the ammo_after passed to on_fire).
static func _rechamber(rig: Dictionary, r: Node3D, seq: int) -> void:
	if not is_instance_valid(r) or int(r.get_meta(META_ROCKET_SEQ, 0)) != seq:
		return
	var left := live_ammo(rig.get("model"), str(rig.get("arch", "")))
	if left < 0:
		left = int(r.get_meta(META_ROCKET_AMMO, 0))
	if left > 0:
		r.visible = true


## Reload: Rocket shown; Cylinder spins a full turn; speedloader seats from 3 cm behind; Second Mouth tube racks
## +0.05 on X and back.
## time <= 0: only re-show the Rocket (reload completed instantly, e.g. Slide Loader / player._finish_reload).
static func on_reload(rig: Dictionary, time: float = 0.6) -> void:
	var rk = rig.get("rocket")
	if rk != null and is_instance_valid(rk):
		_bump_rocket(rk, -1)
		(rk as Node3D).visible = true
	if time <= 0.0:
		return
	var cyl = rig.get("cylinder")
	if _ok(cyl):
		var c := cyl as Node3D
		_tw(c).tween_property(c, "rotation:x", c.rotation.x + TAU, maxf(time, 0.1)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	var an: Dictionary = rig.get("anim", {})
	var sl = an.get("speedloader")
	if _ok(sl):
		var rest: Transform3D = (sl as Node3D).get_meta(META_REST, Transform3D.IDENTITY)
		(sl as Node3D).position = rest.origin - Vector3(0.03, 0, 0)
		_tw(sl).tween_property(sl, "position", rest.origin, maxf(time * 0.5, 0.05))
	var tube = an.get("tube")
	if _ok(tube):
		var r2: Transform3D = (tube as Node3D).get_meta(META_REST, Transform3D.IDENTITY)
		var t := _tw(tube)
		t.tween_property(tube, "position", r2.origin + Vector3(0.05, 0, 0), maxf(time * 0.25, 0.05))
		t.tween_property(tube, "position", r2.origin, maxf(time * 0.25, 0.05))


## ADS on/off: Ratchet Stock slider extends 2 cm (cheek weld) while aiming.
static func set_ads(rig: Dictionary, on: bool) -> void:
	var sl = rig.get("anim", {}).get("slider")
	if _ok(sl):
		var rest: Transform3D = (sl as Node3D).get_meta(META_REST, Transform3D.IDENTITY)
		_tw(sl).tween_property(sl, "position", rest.origin - (Vector3(0.02, 0, 0) if on else Vector3.ZERO), 0.12)


## Gravesight lens glow: 1 = outline_elites active (GLOW_ON), 0 = dim (GLOW_OFF). Per instance (material duplicated).
static func set_glow(rig: Dictionary, strength: float) -> void:
	for n in rig.get("glow", []):
		if n == null or not is_instance_valid(n):
			continue
		var mi := n as MeshInstance3D
		var nsurf: int = mi.mesh.get_surface_count() if mi.mesh else 0
		for i in nsurf:
			var m := mi.get_surface_override_material(i) as StandardMaterial3D
			if m == null:
				var base := mi.get_active_material(i) as StandardMaterial3D
				if base == null:
					continue
				m = base.duplicate() as StandardMaterial3D
				m.set_meta("base_emission", m.emission_energy_multiplier if m.emission_enabled else 1.0)
				mi.set_surface_override_material(i, m)
			m.emission_enabled = true
			m.emission_energy_multiplier = float(m.get_meta("base_emission", 1.0)) * lerpf(GLOW_OFF, GLOW_ON, clampf(strength, 0.0, 1.0))


static func glow_energy(rig: Dictionary) -> float:
	for n in rig.get("glow", []):
		if n is MeshInstance3D and (n as MeshInstance3D).get_surface_override_material(0) is StandardMaterial3D:
			return ((n as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D).emission_energy_multiplier
	return 0.0


## Heartbeat Counter: Label3D on ScreenAnchor (scripts/gear/heartbeat_label.gd counts "enemies" within radius,
## sweeps the Needle and blinks Pulse). The 2D HUD readout is Gooey's (ARMORY_HANDOFF.md).
static func _add_heartbeat(inst: Node3D, radius: float) -> Label3D:
	var anchor := find_node(inst, "ScreenAnchor")
	if anchor == null:
		return null
	var l := Label3D.new()
	l.name = "HeartbeatLabel"
	var scr = load(HEARTBEAT_SCRIPT)
	if scr:
		l.set_script(scr)
	l.set("radius", radius)
	l.set("needle", find_node(inst, "Needle"))
	l.set("pulse", find_node(inst, "Pulse"))
	anchor.add_child(l)
	return l


## Visible default part names on a gun (tests / debug).
static func visible_parts(model: Node3D) -> Array:
	var out: Array = []
	for n in ["Body", "IronSights", "DefaultMag", "DefaultMuzzle", "DefaultStock", "DefaultGrip", "DefaultOptic", "DefaultBarrel"]:
		var node := find_node(model, n)
		if node and node.visible:
			out.append(n)
	return out
