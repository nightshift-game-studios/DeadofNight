extends CanvasLayer
## One-time "parts moved back to your Armory" notice (ARMORY_HANDOFF art pass 2b).
## Progress.armory_unequipped_on_load = [{arch, slot, id, why: "fit" | rule id}] lists attachments that the last
## load unequipped (wrong class/slot, or a blocked pair). They stay owned. Shown by the home menu first, or by the
## Armory if the home menu never came up.
## Skillz has no ack/clear API for that list, so the dismissed state is kept here: a session-wide static keyed by the
## list's content. Dismissing it means the same list is not shown again for that load (the clean state is written on
## the next save, so the next load's list is empty anyway).

signal dismissed

const ArmoryScr := preload("res://scripts/armory/armory.gd")

static var _acked_sig: String = "" ## signature of the list the player dismissed
static var _live: WeakRef = null ## the notice currently on screen (only one at a time)

var entries: Array = [] ## [{arch, slot, id, why}] shown
var lines: Array = [] ## [{part, weapon, reason, id, arch}] built from entries (tests / layout)
var _card: PanelContainer
var _ok: Button


func _init() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "ArmoryUnequipNotice"


# ------------------------------------------------------------------ static API

static func _prog() -> Node:
	var ml := Engine.get_main_loop()
	return (ml as SceneTree).root.get_node_or_null("Progress") if ml is SceneTree else null


static func signature(list: Array) -> String:
	return JSON.stringify(list)


## The unequipped-on-load list if it hasn't been dismissed yet, else [].
static func pending_entries() -> Array:
	var p := _prog()
	if p == null or not ("armory_unequipped_on_load" in p):
		return []
	var list = p.armory_unequipped_on_load
	if typeof(list) != TYPE_ARRAY or (list as Array).is_empty():
		return []
	if signature(list) == _acked_sig:
		return []
	return list


static func is_pending() -> bool:
	return not pending_entries().is_empty()


static func acknowledge(list: Array) -> void:
	_acked_sig = signature(list)


## Tests only: forget the dismissal.
static func reset_ack() -> void:
	_acked_sig = ""
	_live = null


static func is_showing() -> bool:
	return _live != null and _live.get_ref() != null and is_instance_valid(_live.get_ref()) \
		and not (_live.get_ref() as Node).is_queued_for_deletion()


## Armory's reason for one removed part: the exclusion text for a blocked pair, the fit requirement otherwise.
static func reason_for(e: Dictionary) -> String:
	var arch := str(e.get("arch", ""))
	var id := str(e.get("id", ""))
	var why := str(e.get("why", "fit"))
	if why != "fit":
		var r := ArmoryScr.exclusion_reason(id, arch)
		if r != "":
			return r
		for rule in ArmoryScr.exclusions(arch):
			if str(rule.get("id", "")) == why and str(rule.get("reason", "")) != "":
				return str(rule.reason)
		return "Can't be fitted together with another part on the %s" % ArmoryScr.weapon_type(arch)
	for req in ArmoryScr.equip_requirements(id, arch):
		if str(req).begins_with("Does not fit"):
			return str(req)
	var reqs: Array = ArmoryScr.equip_requirements(id, arch)
	return str(reqs[0]) if not reqs.is_empty() else "Does not fit the %s" % ArmoryScr.weapon_type(arch)


static func line_for(e: Dictionary) -> Dictionary:
	var id := str(e.get("id", ""))
	var arch := str(e.get("arch", ""))
	var att: Dictionary = ArmoryScr.attachment(id)
	return {"id": id, "arch": arch, "slot": str(e.get("slot", att.get("slot", ""))),
		"part": str(att.get("name", id)) if not att.is_empty() else id,
		"weapon": ArmoryScr.weapon_type(arch) if arch != "" else "", "reason": reason_for(e)}


## Shows the notice on `parent` if there's an undismissed list and none is on screen. Returns it, or null.
static func show_if_pending(parent: Node) -> Node:
	if parent == null or is_showing():
		return null
	var list := pending_entries()
	if list.is_empty():
		return null
	var n = load("res://scripts/ui/armory_notice.gd").new()
	n.entries = list.duplicate(true)
	parent.add_child(n)
	_live = weakref(n)
	return n


# ------------------------------------------------------------------ view

func _ready() -> void:
	lines = entries.map(func(e): return line_for(e))
	var dlg := UIStyle.dialog_overlay("NoticeOverlay")
	add_child(dlg.overlay)
	_card = UIStyle.dialog_card(Vector2(540, 220), "UnequipNotice")
	(dlg.center as CenterContainer).add_child(_card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	_card.add_child(v)
	var t := UIStyle.label("PARTS MOVED TO YOUR ARMORY", 20, UIStyle.BONE, true)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var sub := UIStyle.label("Your loadout had attachments that can't be fitted anymore. They're unequipped and still owned.",
		12, UIStyle.BONE_DIM)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size.x = 500
	v.add_child(sub)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.6)
	line.custom_minimum_size = Vector2(0, 2)
	v.add_child(line)
	var list := VBoxContainer.new()
	list.name = "NoticeList"
	list.add_theme_constant_override("separation", 8)
	v.add_child(list)
	for l in lines:
		var row := HBoxContainer.new()
		row.name = "NoticeRow_%s" % str(l.id)
		row.set_meta("att_id", l.id)
		row.add_theme_constant_override("separation", 10)
		list.add_child(row)
		row.add_child(UIStyle.attachment_icon(str(l.id), 36, str(l.slot)))
		var tv := VBoxContainer.new()
		tv.add_theme_constant_override("separation", -1)
		row.add_child(tv)
		var nh := HBoxContainer.new()
		nh.add_theme_constant_override("separation", 8)
		tv.add_child(nh)
		var pn := UIStyle.label(str(l.part).to_upper(), 15, UIStyle.BONE, true)
		pn.name = "NoticePart"
		nh.add_child(pn)
		var wn := UIStyle.label(str(l.weapon).to_upper(), 12, UIStyle.OLIVE.lightened(0.35), true)
		wn.name = "NoticeWeapon"
		wn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		nh.add_child(wn)
		var rl := UIStyle.label(str(l.reason), 12, UIStyle.RUST.lightened(0.3))
		rl.name = "NoticeReason"
		rl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		rl.custom_minimum_size.x = 450
		tv.add_child(rl)
	var bh := HBoxContainer.new()
	bh.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(bh)
	_ok = Button.new()
	_ok.name = "NoticeOK"
	_ok.text = "OK"
	_ok.focus_mode = Control.FOCUS_ALL
	_ok.custom_minimum_size = Vector2(140, 44)
	_ok.add_theme_font_size_override("font_size", 16)
	UIStyle.style_primary_button(_ok)
	_ok.pressed.connect(dismiss)
	bh.add_child(_ok)
	var hint := UIStyle.label("ENTER / ESC  OK", 11, UIStyle.BONE_DIM)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)
	_snd("menu_open")
	_ok.call_deferred("grab_focus")


func dismiss() -> void:
	if is_queued_for_deletion():
		return
	acknowledge(entries)
	_snd("ui_equip")
	dismissed.emit()
	queue_free()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_mouse"):
		get_viewport().set_input_as_handled()
		dismiss()


func _snd(key: String) -> void:
	var a := get_node_or_null("/root/Sfx")
	if a:
		a.play(key)
