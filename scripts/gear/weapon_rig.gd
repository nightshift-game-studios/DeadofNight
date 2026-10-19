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
##   rig.lamp      Node3D | null    Mine Lamp housing (Glass child = emissive lens, BeamHint = front)
## WeaponRig.clear(model) undoes it (frees the attachments, shows the defaults again) so the same model can be re-fitted.

const ARMORY := preload("res://scripts/armory/armory.gd")
const META_ATT := "weapon_rig_attachment"
const META_HIDDEN := "weapon_rig_hidden"
## Fitting order: barrel first (it can bring its own Muzzle), muzzle devices after it.
const ORDER := ["barrel", "muzzle", "optic", "grip", "mag", "stock"]
const DEFAULT_SOCKETS := {"optic": "Rail", "muzzle": "Muzzle", "barrel": "Barrel", "grip": "Underbarrel", "mag": "MagWell", "stock": "Stock"}


static func slot_def(slot: String) -> Dictionary:
	for s in ARMORY.slots():
		if str(s.get("id", "")) == slot:
			return s
	return {}


static func socket_name(slot: String) -> String:
	return str(slot_def(slot).get("socket", DEFAULT_SOCKETS.get(slot, "")))


## Default part names a fitted attachment hides: the attachment's own "hides" if present, else its slot's.
static func hides_for(att_id: String, slot: String = "") -> Array:
	var a: Dictionary = ARMORY.attachment(att_id)
	if slot == "":
		slot = str(a.get("slot", ""))
	var h = a.get("hides", slot_def(slot).get("hides", []))
	if typeof(h) == TYPE_STRING:
		return [h] if str(h) != "" else []
	return Array(h)


static func model_path(att_id: String) -> String:
	return str(ARMORY.attachment(att_id).get("model", ""))


static func has_model(att_id: String) -> bool:
	var p := model_path(att_id)
	return p != "" and ResourceLoader.exists(p)


## Pure plan (no nodes): which socket each part goes on and what it hides, for a loadout {slot: att_id}.
## Used by tests and by Gooey's Armory preview text. Skips empty slots.
static func plan(loadout: Dictionary) -> Dictionary:
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
		for h in hides_for(id, slot):
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


## Fits the loadout onto an instanced gun model. `loadout` null/empty dict = Armory.loadout(arch).
## Attachments are authored in real metres like the guns, so they inherit the gun's view scale as socket children.
static func apply(model: Node3D, arch: String, loadout = null, shadows: bool = false) -> Dictionary:
	var out := {"attached": {}, "hidden": [], "missing": [], "muzzle": null, "sight": null, "lamp": null}
	if model == null:
		return out
	clear(model)
	var lo: Dictionary = loadout if loadout is Dictionary and not (loadout as Dictionary).is_empty() else ARMORY.loadout(arch)
	var p := plan(lo)
	out.missing = p.missing
	var muzzle_parent: Node3D = find_node(model, socket_name("muzzle"))
	for slot in ORDER:
		if not p.attach.has(slot):
			continue
		var e: Dictionary = p.attach[slot]
		var sock: Node3D = muzzle_parent if slot == "muzzle" else find_node(model, str(e.socket))
		if sock == null: # gun without that socket (old Quaternius gun, pistol has no Underbarrel/Stock/Barrel)
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
		if slot == "barrel":
			var bm := find_node(inst, "Muzzle")
			if bm:
				muzzle_parent = bm
		if slot == "grip" and str(e.id) == "mine_lamp":
			out.lamp = inst
	# Hide the default parts the fitted parts replace (only for parts that actually got fitted).
	for slot in out.attached:
		for h in hides_for(str(p.attach[slot].id), slot):
			var n := find_node(model, str(h))
			if n and n.visible and not n.has_meta(META_ATT):
				n.visible = false
				n.set_meta(META_HIDDEN, true)
				if not out.hidden.has(h):
					out.hidden.append(h)
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


## Visible default part names on a gun (tests / debug).
static func visible_parts(model: Node3D) -> Array:
	var out: Array = []
	for n in ["Body", "IronSights", "DefaultMag", "DefaultMuzzle", "DefaultStock", "DefaultGrip", "DefaultOptic"]:
		var node := find_node(model, n)
		if node and node.visible:
			out.append(n)
	return out
