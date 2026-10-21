extends MenuBase
## Loadout screen (Tab / I). Survivor in the centre, gear flanking the sides, chunky item cards:
##  - Weapons (Primary / Secondary / Heavy) on the left, armor on the right, survivor in the centre
##    with the total armor stats underneath.
##  - Click a slot to expand a grid of the other items you carry for it; click one to equip,
##    right-click to dismantle.
##  - Hover an item for its card: icon, Item Power (+/- vs equipped), name in rarity colour, manufacturer, damage x pellets,
##    big stat numbers with bars and +/- deltas versus what you have equipped, perk badges and
##    a flavor-text line.
## Shared colours/fonts/panels live in scripts/ui/ui_style.gd.

const ICON_DIR := "res://assets/icons/"
const STAT_HINTS := {
	"agility": "+%.0f%% move speed", "toughness": "-%.0f%% damage taken", "vitality": "regen after %.1fs",
	"ordnance": "grenade %.1fs", "focus": "ability %.1fs", "brawn": "melee %.0f dmg"}
const CARD_W := 360.0
const StatPreviewScr := preload("res://scripts/ui/stat_preview.gd")
var stat_preview: Dictionary = {} ## playtest #34: armor-stat totals being previewed (hovered armor / point allocation); {} = none
var _stat_rows: Array = [] ## StatPreview.rows() of the last stats render (tests)

var player: Node
var _expanded: String = ""
var _root: Control
var _class_label: Label
var _avg_ip_label: Label
var _avg_ip_sub: Label
var _left: VBoxContainer
var _right: VBoxContainer
var _stats_grid: GridContainer
var _consumables: HBoxContainer
var _tooltip: PanelContainer
var _mannequin: Dictionary = {} ## part -> MeshInstance3D
var _figure: Node3D
var _visor: MeshInstance3D
var _armor_holders: Dictionary = {} ## "slot:piece" -> Node3D holding that display GLB on the figure
var _armor_shown: Dictionary = {} ## slot -> piece id shown (tests); missing / unequipped slots are absent
var model_path_override: Dictionary = {} ## slot -> display path (tests / fallback checks); "" = no model
static var _display_cache: Dictionary = {} ## path -> PackedScene (or null when missing)
var _tooltip_fixed: bool = false
var _last_card_rows: Array = [] ## comparison rows of the last card shown (for tests)
var _last_card_power: Dictionary = {} ## Item Power comparison of the last card shown (for tests)
var _stash_label: Label ## carried_count()/stash_cap in the header
var _hint_label: Label ## footer controls + mark-all-seen hint
var _seen_bound: bool = false
var _gm_chip: PanelContainer ## Gravemark balance in the header
var _last_card_ip: Dictionary = {} ## Armory.item_power_breakdown() of the last weapon card shown (for tests)
var _tooltip_item: GearItem ## item on the open card, so IP can re-render on armory/inventory changes
var _tooltip_equipped: bool = false
var _ip_prog_bound: bool = false
var _ip_cache: Dictionary = {} ## item_id -> displayed (total) Item Power; cleared on refresh / armory / inventory changes
var _ip_inv: Inventory ## inventory whose changed signal drives card IP refresh


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.03, 0.025, 0.84)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)
	var vg := TextureRect.new()
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.45)
	gt.fill_to = Vector2(1.1, 1.1)
	var g := Gradient.new()
	g.set_color(0, Color(0.30, 0.24, 0.14, 0.22))
	g.set_color(1, Color(0, 0, 0, 0.7))
	gt.gradient = g
	vg.texture = gt
	vg.set_anchors_preset(Control.PRESET_FULL_RECT)
	vg.stretch_mode = TextureRect.STRETCH_SCALE
	vg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(vg)
	UIStyle.add_grit(_root, 0.06)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 34)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_bottom", 14)
	_root.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	# Header: stencil title + class chip
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	col.add_child(header)
	header.add_child(UIStyle.label("LOADOUT", 34, UIStyle.BONE, true, 0))
	var chip := PanelContainer.new()
	chip.add_theme_stylebox_override("panel", UIStyle.cut_box(UIStyle.OLIVE_DARK, UIStyle.OLIVE, 2, 8))
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_class_label = UIStyle.label("", 15, UIStyle.BONE)
	chip.add_child(_class_label)
	header.add_child(chip)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	header.add_child(_build_avg_ip())
	var sp_st := Control.new()
	sp_st.custom_minimum_size.x = 12
	header.add_child(sp_st)
	var stash_plate := PanelContainer.new()
	stash_plate.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 2, 7))
	stash_plate.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 6)
	stash_plate.add_child(sh)
	sh.add_child(UIStyle.label("STASH", 11, UIStyle.BONE_DIM, true))
	_stash_label = UIStyle.label("0/40", 16, UIStyle.BONE, true)
	_stash_label.name = "StashCount"
	sh.add_child(_stash_label)
	header.add_child(stash_plate)
	var sp_gm := Control.new()
	sp_gm.custom_minimum_size.x = 10
	header.add_child(sp_gm)
	_gm_chip = UIStyle.gravemark_chip(0, 20)
	_gm_chip.name = "GravemarkChip"
	header.add_child(_gm_chip)
	var sp2 := Control.new()
	sp2.custom_minimum_size.x = 12
	header.add_child(sp2)
	_hint_label = UIStyle.label("CLICK SLOT: STASH    CLICK: EQUIP    RIGHT-CLICK: SCRAP    M: MARK ALL SEEN    TAB: CLOSE", 12, UIStyle.BONE_DIM)
	_hint_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_hint_label)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	col.add_child(line)

	# Body: weapons | survivor + stats | armor
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	col.add_child(body)
	_left = VBoxContainer.new()
	_left.add_theme_constant_override("separation", 8)
	_left.custom_minimum_size.x = 400
	body.add_child(_left)
	var center := VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	body.add_child(center)
	_right = VBoxContainer.new()
	_right.add_theme_constant_override("separation", 6)
	_right.custom_minimum_size.x = 330
	body.add_child(_right)

	center.add_child(_build_character_view())
	_stats_grid = GridContainer.new()
	_stats_grid.columns = 3
	_stats_grid.add_theme_constant_override("h_separation", 6)
	_stats_grid.add_theme_constant_override("v_separation", 6)
	var sg_center := CenterContainer.new()
	sg_center.add_child(_stats_grid)
	center.add_child(sg_center)

	# Footer: consumables
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	col.add_child(footer)
	footer.add_child(UIStyle.label("SUPPLIES", 16, UIStyle.RUST, true))
	_consumables = HBoxContainer.new()
	_consumables.add_theme_constant_override("separation", 6)
	footer.add_child(_consumables)

	_tooltip = PanelContainer.new()
	_tooltip.visible = false
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_tooltip.z_index = 10
	_root.add_child(_tooltip)


## Header plate: rust "AVG IP" tab, big number, "N PIECES / RANGE a-b" underneath.
func _build_avg_ip() -> Control:
	var p := PanelContainer.new()
	var st := UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.RUST, 2, 10)
	st.set_content_margin_all(0)
	p.add_theme_stylebox_override("panel", st)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	p.add_child(h)
	var tab := PanelContainer.new()
	var ts := StyleBoxFlat.new()
	ts.bg_color = UIStyle.RUST.lightened(0.15)
	ts.content_margin_left = 8
	ts.content_margin_right = 8
	tab.add_theme_stylebox_override("panel", ts)
	var tl := UIStyle.label("AVG\nIP", 11, UIStyle.INK)
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tl.add_theme_constant_override("line_spacing", -4)
	tab.add_child(tl)
	h.add_child(tab)
	_avg_ip_label = UIStyle.label("100", 28, UIStyle.BONE, true)
	_avg_ip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(_avg_ip_label)
	_avg_ip_sub = UIStyle.label("", 11, UIStyle.BONE_DIM)
	_avg_ip_sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_avg_ip_sub.add_theme_constant_override("line_spacing", -3)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_right", 12)
	m.add_child(_avg_ip_sub)
	h.add_child(m)
	return p


# ------------------------------------------------------------------ survivor preview

func _build_character_view() -> Control:
	var svc := SubViewportContainer.new()
	svc.custom_minimum_size = Vector2(280, 330)
	svc.stretch = true
	svc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.size = Vector2i(280, 330)
	vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	svc.add_child(vp)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.05, 3.4)
	cam.fov = 40
	vp.add_child(cam)
	cam.look_at_from_position(cam.position, Vector3(0, 0.95, 0))
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, 35, 0)
	light.light_energy = 1.3
	vp.add_child(light)
	var rim := OmniLight3D.new()
	rim.position = Vector3(-1.2, 2.0, -1.2)
	rim.light_color = Color(1.0, 0.55, 0.3)
	rim.light_energy = 2.0
	rim.omni_range = 5
	vp.add_child(rim)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.58, 0.5)
	env.ambient_light_energy = 0.6
	we.environment = env
	vp.add_child(we)
	_figure = Node3D.new()
	vp.add_child(_figure)
	# Placeholder survivor built from primitives; each part is tinted by the matching armor piece.
	_add_part("legs", CapsuleMesh.new(), Vector3(-0.13, 0.45, 0), Vector3(0.14, 0.9, 0))
	_add_part("legs2", CapsuleMesh.new(), Vector3(0.13, 0.45, 0), Vector3(0.14, 0.9, 0))
	_add_part("chest", CapsuleMesh.new(), Vector3(0, 1.2, 0), Vector3(0.27, 0.75, 0))
	_add_part("gauntlets", CapsuleMesh.new(), Vector3(-0.38, 1.12, 0), Vector3(0.09, 0.62, 0))
	_add_part("gauntlets2", CapsuleMesh.new(), Vector3(0.38, 1.12, 0), Vector3(0.09, 0.62, 0))
	_add_part("helmet", SphereMesh.new(), Vector3(0, 1.72, 0), Vector3(0.17, 0.36, 0))
	var cloak := BoxMesh.new()
	cloak.size = Vector3(0.5, 0.9, 0.04)
	_add_part("class_item", cloak, Vector3(0, 1.05, -0.24), Vector3.ZERO)
	# Dark under-suit (head, neck, arms) that the armor models sit on; always drawn, cheap primitives.
	_add_base(SphereMesh.new(), Vector3(0, 1.67, 0.0), Vector2(0.105, 0.24))
	_add_base(CapsuleMesh.new(), Vector3(0, 1.53, 0.0), Vector2(0.06, 0.2))
	_add_base_arm(-1.0) # A-pose left
	_add_base_arm(1.0)  # A-pose right
	var visor := BoxMesh.new()
	visor.size = Vector3(0.22, 0.06, 0.05)
	var vm := MeshInstance3D.new()
	vm.mesh = visor
	vm.position = Vector3(0, 1.74, 0.15)
	var vmat := StandardMaterial3D.new()
	vmat.emission_enabled = true
	vmat.emission = Color(1.0, 0.25, 0.1)
	vmat.emission_energy_multiplier = 3.0
	vmat.albedo_color = Color(0.6, 0.15, 0.08)
	vm.material_override = vmat
	_figure.add_child(vm)
	_visor = vm
	var ped := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.6
	pm.bottom_radius = 0.65
	pm.height = 0.06
	ped.mesh = pm
	ped.position.y = -0.03
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(0.18, 0.17, 0.13)
	pmat.emission_enabled = true
	pmat.emission = Color(0.55, 0.35, 0.15)
	pmat.emission_energy_multiplier = 0.4
	ped.material_override = pmat
	vp.add_child(ped)
	return svc


func _add_base(mesh: PrimitiveMesh, pos: Vector3, dims: Vector2) -> void:
	mesh.set("radius", dims.x)
	mesh.set("height", dims.y)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.12, 0.115, 0.1)
	m.roughness = 0.95
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_figure.add_child(mi)


## Thin under-suit arm in A-pose: hinged at the shoulder, swung ~32° out so it fills the gauntlet.
func _add_base_arm(side: float) -> void:
	var cap := CapsuleMesh.new()
	cap.radius = 0.07
	cap.height = 0.58
	var mi := MeshInstance3D.new()
	mi.mesh = cap
	var ang := deg_to_rad(32.0) * side
	mi.rotation.z = ang
	# Shoulder at (±0.26, 1.42); capsule centre halfway down the arm.
	var shoulder := Vector3(0.26 * side, 1.42, 0.0)
	var along := Vector3(sin(ang), -cos(ang), 0.0) # unit along the arm (down + out)
	mi.position = shoulder + along * 0.28
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.12, 0.115, 0.1)
	m.roughness = 0.95
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_figure.add_child(mi)


func _add_part(key: String, mesh: PrimitiveMesh, pos: Vector3, dims: Vector3) -> void:
	if mesh is CapsuleMesh:
		mesh.radius = dims.x
		mesh.height = dims.y
	elif mesh is SphereMesh:
		mesh.radius = dims.x
		mesh.height = dims.y
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.4, 0.4, 0.42)
	m.metallic = 0.5
	m.roughness = 0.45
	mi.material_override = m
	_figure.add_child(mi)
	_mannequin[key] = mi


func _process(delta: float) -> void:
	if visible and _figure:
		_figure.rotation.y += delta * 0.4
	if _tooltip and _tooltip.visible and not _tooltip_fixed:
		_place_tooltip()


# ------------------------------------------------------------------ refresh

func refresh() -> void:
	if player == null:
		return
	var inv: Inventory = player.inventory
	_ip_cache.clear()
	_bind_seen(inv)
	_class_label.text = player.player_class.display_name.to_upper() if player.player_class else "SURVIVOR"
	_refresh_avg_ip(inv)
	_refresh_stash_count(inv)
	_refresh_gravemark()
	_hide_tooltip()
	# Free immediately so rebuilt nodes keep stable names (Slot_secondary vs @Slot_secondary@2).
	for host in [_left, _right, _consumables, _stats_grid]:
		var kids: Array = host.get_children()
		for c in kids:
			host.remove_child(c)
			c.free()
	_left.add_child(UIStyle.label("WEAPONS", 18, UIStyle.RUST, true))
	for s in Inventory.WEAPON_SLOTS:
		_left.add_child(_slot_row(inv, s, false))
	var armor_title := UIStyle.label("ARMOR", 18, UIStyle.RUST, true)
	armor_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_right.add_child(armor_title)
	for s in Inventory.ARMOR_SLOTS:
		_right.add_child(_slot_row(inv, s, true))
	_build_field_cards()
	_refresh_stats(inv)
	_refresh_mannequin(inv)
	for i in inv.bag.size():
		var entry: Dictionary = inv.bag[i]
		var b := Button.new()
		b.text = "%s  x%d" % [entry.item.display_name.to_upper(), entry.count]
		b.add_theme_font_override("font", UIStyle.body_bold())
		b.add_theme_color_override("font_color", UIStyle.BONE)
		b.add_theme_stylebox_override("normal", UIStyle.cut_box(UIStyle.PANEL, entry.item.color, 2, 8))
		b.add_theme_stylebox_override("hover", UIStyle.cut_box(UIStyle.OLIVE_DARK, entry.item.color.lightened(0.3), 2, 8))
		b.pressed.connect(func(): inv.use_bag_item(i, player); _ui_snd("ui_equip"); refresh())
		_consumables.add_child(b)
	if inv.bag.is_empty():
		_consumables.add_child(UIStyle.label("nothing scavenged yet", 14, UIStyle.BONE_DIM))


## FIELD CARDS (this match's run picks) under the armor column. Descriptions while the list is short,
## name + rank rows once it grows; refreshed on RunState.cards_changed while open.
func _build_field_cards() -> void:
	var rs := get_node_or_null("/root/RunState")
	if rs == null:
		return
	if not rs.cards_changed.is_connected(_on_cards_changed):
		rs.cards_changed.connect(_on_cards_changed)
	var owned: Array = rs.owned_cards()
	var head := HBoxContainer.new()
	head.name = "FieldCards"
	head.alignment = BoxContainer.ALIGNMENT_END
	head.add_theme_constant_override("separation", 8)
	var n_leg := owned.filter(func(c): return str(c.tier) == "legendary").size()
	if n_leg > 0:
		head.add_child(UIStyle.label("%d LEGENDARY" % n_leg, 11, UIStyle.TIER_LEGENDARY.lightened(0.35), true))
	head.add_child(UIStyle.label("FIELD CARDS // %d" % owned.size(), 16, UIStyle.RUST, true))
	_right.add_child(head)
	if owned.is_empty():
		var none := UIStyle.label("none yet // one is offered after every cleared round", 12, UIStyle.BONE_DIM)
		none.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_right.add_child(none)
		return
	var with_desc := owned.size() <= 2 # full descriptions while short, else one-line rows (full text on hover)
	var shown := mini(owned.size(), 6)
	for i in shown:
		var entry: Dictionary = owned[i].duplicate()
		if str(entry.get("summary", "")) == "" and rs.has_method("card_def"):
			entry["summary"] = str(rs.card_def(str(entry.id)).get("summary", ""))
		var row := UIStyle.field_card_row(entry, 330, 316.0 if with_desc else 0.0, not with_desc)
		row.set_meta("card_id", str(entry.id))
		row.tooltip_text = str(entry.get("description", entry.get("summary", "")))
		row.mouse_filter = Control.MOUSE_FILTER_PASS
		_right.add_child(row)
	if owned.size() > shown:
		var more := UIStyle.label("+%d MORE" % (owned.size() - shown), 11, UIStyle.BONE_DIM, true)
		more.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_right.add_child(more)


func _on_cards_changed() -> void:
	if visible:
		refresh()


func _refresh_avg_ip(inv: Inventory) -> void:
	var lo := 100000
	var hi := 0
	var n := 0
	for s in inv.equipped:
		var g: GearItem = inv.equipped[s]
		if g:
			n += 1
			var ip := display_ip(g)
			lo = mini(lo, ip)
			hi = maxi(hi, ip)
	_avg_ip_label.text = str(average_display_ip(inv))
	_avg_ip_sub.text = "%d PIECES\nRANGE %d-%d" % [n, lo, hi] if n > 0 else "NO GEAR"


## One slot: a chunky cut-corner panel with a thick rarity edge, the item tile and its
## name / maker. Clicking the tile toggles the stash grid for the slot.
func _slot_row(inv: Inventory, s: String, mirrored: bool) -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 2)
	wrap.set_meta("slot", s)
	wrap.name = "Slot_" + s
	var g: GearItem = inv.equipped.get(s)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	if mirrored:
		row.alignment = BoxContainer.ALIGNMENT_END
	var is_weapon := s in Inventory.WEAPON_SLOTS
	var tile := _tile(g, Vector2(116, 76) if is_weapon else Vector2(62, 62), true)
	tile.set_meta("slot", s)
	tile.pressed.connect(func():
		_expanded = "" if _expanded == s else s
		refresh())
	var info := VBoxContainer.new()
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	info.add_theme_constant_override("separation", -2)
	var cap_row := HBoxContainer.new()
	cap_row.add_theme_constant_override("separation", 4)
	if mirrored:
		cap_row.alignment = BoxContainer.ALIGNMENT_END
	var cap := UIStyle.label(Inventory.SLOT_LABELS[s].to_upper(), 12, UIStyle.BONE_DIM)
	cap_row.add_child(cap)
	var slot_bang := UIStyle.unseen_badge(13)
	slot_bang.name = "SlotUnseen"
	slot_bang.visible = inv.has_unseen(s)
	cap_row.add_child(slot_bang)
	info.add_child(cap_row)
	if g:
		info.add_child(UIStyle.label(g.display_name.to_upper(), 17 if is_weapon else 14, g.rarity_color().lightened(0.15), false, 3))
		var meta := HBoxContainer.new()
		meta.add_theme_constant_override("separation", 7)
		if mirrored:
			meta.alignment = BoxContainer.ALIGNMENT_END
		var maker_l := UIStyle.label(g.manufacturer.to_upper(), 11, g.manufacturer_color)
		maker_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var plate := UIStyle.ip_plate(display_ip(g), 12)
		plate.name = "SlotIP"
		if mirrored:
			meta.add_child(maker_l)
			meta.add_child(plate)
		else:
			meta.add_child(plate)
			meta.add_child(maker_l)
		info.add_child(meta)
	else:
		info.add_child(UIStyle.label("EMPTY", 15, UIStyle.BONE_DIM))
	if mirrored:
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		for c in info.get_children():
			if c is Label:
				(c as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			elif c is HBoxContainer:
				for cc in c.get_children():
					if cc is Label:
						(cc as Label).horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(info)
		row.add_child(tile)
	else:
		row.add_child(tile)
		row.add_child(info)
	wrap.add_child(row)
	if _expanded == s:
		wrap.add_child(_expansion(inv, s, mirrored))
	return wrap


func _expansion(inv: Inventory, s: String, mirrored: bool) -> Control:
	var holder := HBoxContainer.new()
	holder.alignment = BoxContainer.ALIGNMENT_END if mirrored else BoxContainer.ALIGNMENT_BEGIN
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(0.05, 0.05, 0.04, 0.95), UIStyle.RUST, 2, 10))
	holder.add_child(panel)
	var grid := GridContainer.new()
	grid.columns = 3 if s in Inventory.WEAPON_SLOTS else 4
	grid.add_theme_constant_override("h_separation", 5)
	grid.add_theme_constant_override("v_separation", 5)
	panel.add_child(grid)
	var items: Array = inv.backpack[s]
	if items.is_empty():
		grid.add_child(UIStyle.label("Stash empty - loot more %s" % Inventory.SLOT_LABELS[s].to_lower(), 13, UIStyle.BONE_DIM))
	for it in items:
		var t := _tile(it, Vector2(88, 58) if s in Inventory.WEAPON_SLOTS else Vector2(52, 52), false)
		t.pressed.connect(func(): inv.equip(it); _ui_snd("ui_equip"); refresh())
		t.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
				inv.dismantle(it)
				_ui_snd("ui_scrap_dismantle")
				refresh())
		grid.add_child(t)
	return holder


## Item tile: dark body, thick rarity border with cut corners, weapon icon (or slot glyph).
func _tile(item: GearItem, sz: Vector2, equipped: bool) -> Button:
	var b := Button.new()
	b.custom_minimum_size = sz
	b.focus_mode = Control.FOCUS_NONE
	var c := item.rarity_color() if item else Color(0.3, 0.3, 0.28)
	var body := c.darkened(0.72)
	body.a = 0.95
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(body, c, 3 if item else 1, 10))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(c.darkened(0.5), c.lightened(0.35), 4, 10))
	b.add_theme_stylebox_override("pressed", UIStyle.cut_box(c.darkened(0.35), Color.WHITE, 4, 10))
	if item == null:
		var e := UIStyle.label("+", 26, Color(1, 1, 1, 0.2), true)
		e.set_anchors_preset(Control.PRESET_FULL_RECT)
		e.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		e.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_child(e)
		return b
	# rarity glow from the bottom
	var glow := TextureRect.new()
	var gt := GradientTexture2D.new()
	gt.fill_from = Vector2(0.5, 1.0)
	gt.fill_to = Vector2(0.5, 0.0)
	var gr := Gradient.new()
	gr.set_color(0, Color(c, 0.45))
	gr.set_color(1, Color(c, 0.0))
	gt.gradient = gr
	glow.texture = gt
	glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	glow.offset_left = 4
	glow.offset_right = -4
	glow.offset_top = 4
	glow.offset_bottom = -4
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(glow)
	if item is ArmorItem and str(item.get("class_effect")) != "" and str(ClassItems.state(item, Progress.selected_class)) == "wrong_class":
		b.modulate = Color(0.6, 0.6, 0.6, 0.85) # #9: another class's item does nothing for you
		b.set_meta("wrong_class", true)
	var icon_path: String = ICON_DIR + item.archetype + ".png"
	if not item is WeaponItem:
		icon_path = armor_icon_path(item)
	if ResourceLoader.exists(icon_path):
		var tr := TextureRect.new()
		tr.texture = load(icon_path)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.offset_left = 6
		tr.offset_right = -6
		tr.offset_top = 5
		tr.offset_bottom = -5
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(tr)
	else:
		var glyph := UIStyle.label(_initials(item), 15 if sz.x > 56 else 12, UIStyle.BONE, true, 3)
		glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.add_child(glyph)
	var wi := item as WeaponItem
	if wi and wi.element != "ballistic":
		var dot := ColorRect.new()
		dot.color = GearDB.element_color(wi.element)
		dot.size = Vector2(8, 8)
		dot.position = Vector2(sz.x - 14, 6)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(dot)
	# Item Power plate, bottom-right corner; stash tiles tint the number vs what's equipped
	var pc: Dictionary = {} if equipped or player == null else compare_display_ip(player.inventory, item)
	var plate := UIStyle.ip_plate(display_ip(item), 12 if sz.x > 60 else 10, UIStyle.ip_tint(int(pc.get("delta", 0))))
	plate.name = "TileIP"
	plate.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	plate.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	plate.grow_vertical = Control.GROW_DIRECTION_BEGIN
	plate.offset_right = -5
	plate.offset_bottom = -4
	b.add_child(plate)
	if not equipped and player:
		var cmp: Array = player.inventory.compare(item)
		var score := 0
		if not pc.is_empty():
			score += 2 if pc.better else (-2 if pc.worse else 0)
		for r in cmp:
			score += 1 if r.better else (-1 if r.worse else 0)
		if score != 0: # quick "is it better?" arrow on stash tiles
			var arrow := DeltaArrow.make(score > 0, 12.0)
			arrow.position = Vector2(5, sz.y - 17)
			b.add_child(arrow)
	if not item.seen and not equipped:
		var bang := UIStyle.unseen_badge(14 if sz.x > 60 else 12)
		bang.set_anchors_preset(Control.PRESET_TOP_LEFT)
		bang.position = Vector2(3, 2)
		b.add_child(bang)
		b.set_meta("unseen", true)
	b.set_meta("gear", item)
	b.mouse_entered.connect(_on_tile_hover.bind(item, equipped))
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	b.mouse_exited.connect(_hide_tooltip)
	return b


## Pre-rendered armor icon (tests/render_armor_icons.gd) for the item's slot look ("" if none).
func armor_icon_path(item: GearItem) -> String:
	var piece := ArmorModels.piece_for_slot(str(item.get("slot")), _class_id())
	return ICON_DIR + "armor_" + piece + ".png" if piece != "" else ""


func _initials(item: GearItem) -> String:
	var map := {"helmet": "HELM", "gauntlets": "ARMS", "chest": "CHEST", "legs": "LEGS", "class_item": "MARK"}
	return map.get(item.slot, item.type_name().substr(0, 4).to_upper())


## Playtest #34: each stat tile shows what the points do in real numbers (StatPreview mirrors player.gd's formulas):
## the derived values now, and either the gain from the next point ("+1 PT") or, while previewing (hovering an armor
## piece in the stash, or a stat-point allocator calling set_stat_preview), current -> previewed with green / red deltas.
func _refresh_stats(inv: Inventory) -> void:
	var t: Dictionary = inv.total_armor_stats()
	_stat_rows = StatPreviewScr.rows(player, t, stat_preview)
	for row in _stat_rows:
		var s: String = row.stat
		var pv: bool = row.previewing and int(row.next_value) != int(row.value)
		var box := PanelContainer.new()
		box.name = "Stat_" + s
		var edge := Color(UIStyle.OLIVE, 0.8)
		if pv:
			edge = UIStyle.GOOD if int(row.next_value) > int(row.value) else UIStyle.BAD
		box.add_theme_stylebox_override("panel", UIStyle.cut_box(UIStyle.PANEL, edge, 2, 8))
		box.custom_minimum_size = Vector2(150, 0)
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 1)
		box.add_child(v)
		var head := HBoxContainer.new()
		head.add_child(UIStyle.label(ArmorItem.STAT_LABELS[s].to_upper(), 13, UIStyle.BONE_DIM))
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(sp)
		var val := UIStyle.label(str(row.value), 24, UIStyle.BONE, true)
		val.name = "Value"
		head.add_child(val)
		if pv:
			var nv := UIStyle.label(" → %d" % int(row.next_value), 18,
				UIStyle.GOOD if int(row.next_value) > int(row.value) else UIStyle.BAD, true)
			nv.name = "PreviewValue"
			nv.size_flags_vertical = Control.SIZE_SHRINK_END
			head.add_child(nv)
		v.add_child(head)
		var ghost := float(row.next_value) / 100.0 if pv else -1.0
		v.add_child(UIStyle.bar(float(row.value) / 100.0, UIStyle.RUST, 132, 5, ghost))
		for ln in row.lines:
			var lh := HBoxContainer.new()
			lh.add_theme_constant_override("separation", 3)
			lh.name = "Line_" + str(ln.key)
			var ll := UIStyle.label(str(ln.label), 10, UIStyle.BONE_DIM)
			lh.add_child(ll)
			var lsp := Control.new()
			lsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lh.add_child(lsp)
			var cur := UIStyle.label(str(ln.now), 11, UIStyle.OLIVE.lightened(0.35))
			cur.name = "Now"
			lh.add_child(cur)
			if int(ln.better) != 0:
				var col := UIStyle.GOOD if int(ln.better) > 0 else UIStyle.BAD
				var dl := UIStyle.label(("→ " + str(ln.next).split(" ")[0]) if pv else ("%s/pt" % str(ln.get("delta_text", ""))), 10,
					col if pv else Color(col, 0.75))
				dl.name = "Delta"
				lh.add_child(dl)
			v.add_child(lh)
		_stats_grid.add_child(box)


## Previews armor-stat totals on the stat tiles (absolute totals for the stats that change; {} clears).
## Used by armor hover in the stash grid; a future stat-point allocator (Skillz) can call it per click / hover.
func set_stat_preview(totals: Dictionary) -> void:
	stat_preview = totals.duplicate()
	_rebuild_stats()


func clear_stat_preview() -> void:
	if stat_preview.is_empty():
		return
	stat_preview = {}
	_rebuild_stats()


## Tests / screenshots: preview `n` extra points in `stat`.
func debug_preview_stat(stat: String, n: int = 5) -> void:
	if player == null:
		return
	var t: Dictionary = player.inventory.total_armor_stats()
	set_stat_preview({stat: int(t.get(stat, 0)) + n})


func _rebuild_stats() -> void:
	if _stats_grid == null or player == null:
		return
	for c in _stats_grid.get_children():
		_stats_grid.remove_child(c)
		c.free()
	_refresh_stats(player.inventory)


## Totals if `item` replaced what is equipped in its slot (armor only; {} for anything else).
func armor_swap_totals(item: GearItem) -> Dictionary:
	if player == null or not (item is ArmorItem):
		return {}
	var inv = player.inventory
	var t: Dictionary = inv.total_armor_stats()
	var cur = inv.equipped.get(item.slot)
	var out := t.duplicate()
	for s in ArmorItem.STAT_ORDER:
		var d := int((item as ArmorItem).stats.get(s, 0))
		if cur is ArmorItem:
			d -= int((cur as ArmorItem).stats.get(s, 0))
		out[s] = int(t.get(s, 0)) + d
	return out


func _stat_effect(s: String) -> String:
	match s:
		"agility": return STAT_HINTS[s] % ((player.walk_speed / max(player._base_walk, 0.01) - 1.0) * 100.0)
		"toughness": return STAT_HINTS[s] % (player.damage_reduction * 100.0)
		"vitality": return STAT_HINTS[s] % player.regen_delay
		"ordnance": return STAT_HINTS[s] % player.grenade_cooldown
		"focus": return STAT_HINTS[s] % (player.ability.cooldown if player.ability else 0.0)
		"brawn": return STAT_HINTS[s] % player.melee_damage
	return ""


## Where each display GLB's centre sits on the figure (display models are centred at the origin).
## Gauntlets are split into their two nodes. The class item depends on the class (sash / cloak).
const ARMOR_FIT := {
	"helmet": Vector3(0, 1.73, 0.0),
	"chest": Vector3(0, 1.22, 0.0),
	"legs": Vector3(0, 0.50, 0.0),
	"gauntlets": Vector3(0.40, 1.00, 0.0), # A-pose forearm centre (mirrored); see _armor_holder
	"sash": Vector3(0, 1.18, 0.04),
	"cloak": Vector3(0, 1.04, -0.02),
}
const GAUNTLET_ANGLE := 32.0 ## degrees out from vertical, matches the A-pose under-suit arms
## Primitive parts a slot's model replaces (hidden), and parts kept as a dark under-suit beneath it.
const ARMOR_HIDES := {"helmet": ["helmet"], "class_item": ["class_item"]}


func _class_id() -> String:
	if player and player.player_class and player.player_class.resource_path != "":
		return player.player_class.resource_path.get_file().get_basename()
	return str(Progress.selected_class)


## Display GLB path for an armor slot ("" = none; tests can override per slot).
func armor_display_path(slot: String) -> String:
	if model_path_override.has(slot):
		return str(model_path_override[slot])
	return ArmorModels.display_path(slot, _class_id())


static func _display_scene(path: String) -> PackedScene:
	if path == "":
		return null
	if not _display_cache.has(path):
		_display_cache[path] = load(path) as PackedScene if ResourceLoader.exists(path) else null
	return _display_cache[path]


func _armor_holder(slot: String, piece: String, path: String) -> Node3D:
	var key := "%s:%s:%s" % [slot, piece, path]
	if _armor_holders.has(key):
		return _armor_holders[key]
	var sc := _display_scene(path)
	if sc == null:
		_armor_holders[key] = null
		return null
	var holder := Node3D.new()
	holder.name = "Armor_" + slot
	_figure.add_child(holder)
	var inst: Node3D = sc.instantiate()
	holder.add_child(inst)
	var fit: Vector3 = ARMOR_FIT.get(piece, ARMOR_FIT.get(slot, Vector3(0, 1.0, 0)))
	var meshes := inst.find_children("*", "MeshInstance3D", true, false)
	if slot == "gauntlets" and meshes.size() >= 2: # one per hand, slid down the A-pose arm to the forearm
		for i in meshes.size():
			var mi: MeshInstance3D = meshes[i]
			mi.position = Vector3.ZERO
			mi.rotation = Vector3.ZERO
			var c := mi.get_aabb().get_center()
			var side := 1.0 if i == 0 else -1.0
			var ang := deg_to_rad(GAUNTLET_ANGLE) * side
			mi.rotation.z = ang
			# Same shoulder / angle as _add_base_arm; 0.50 along puts the mesh on the lower forearm.
			var shoulder := Vector3(0.26 * side, 1.42, 0.0)
			var along := Vector3(sin(ang), -cos(ang), 0.0)
			mi.position = shoulder + along * 0.50 - mi.basis * c
	else:
		var box := AABB()
		for i in meshes.size():
			var mi: MeshInstance3D = meshes[i]
			var a: AABB = mi.transform * mi.get_aabb()
			box = a if i == 0 else box.merge(a)
		inst.position = fit - box.get_center()
	for mi in meshes:
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.set_meta("meshes", meshes)
	_armor_holders[key] = holder
	return holder


## Rarity tint on the model's own (textured) materials: albedo multiplied toward the rarity colour,
## a faint emission for Mythic. Materials are duplicated once per holder and re-tinted in place.
func _tint_holder(holder: Node3D, c: Color, mythic: bool) -> void:
	for mi in holder.get_meta("meshes", []):
		var m3: MeshInstance3D = mi
		for si in m3.mesh.get_surface_count():
			var mat := m3.get_surface_override_material(si) as StandardMaterial3D
			if mat == null:
				var base := m3.mesh.surface_get_material(si) as StandardMaterial3D
				mat = base.duplicate() as StandardMaterial3D if base else StandardMaterial3D.new()
				m3.set_surface_override_material(si, mat)
			# Light tint only: Desi's gunmetal is driven by the albedo texture + metallic; a heavy
			# colour wash washes the steel out. Mythic keeps a quiet emission rim.
			mat.albedo_color = Color.WHITE.lerp(c.lightened(0.1), 0.14)
			mat.emission_enabled = mythic
			mat.emission = c
			mat.emission_energy_multiplier = 0.18


func _refresh_mannequin(inv: Inventory) -> void:
	_armor_shown.clear()
	var cid := _class_id()
	var modelled := {}
	for slot in Inventory.ARMOR_SLOTS:
		var a: GearItem = inv.equipped.get(slot)
		var piece := ArmorModels.piece_for_slot(slot, cid)
		var path := armor_display_path(slot)
		for k in _armor_holders: # hide every look of this slot, then show the current one
			if k.begins_with(slot + ":") and _armor_holders[k] != null:
				(_armor_holders[k] as Node3D).visible = false
		if a == null or path == "":
			continue
		var h := _armor_holder(slot, piece, path)
		if h == null:
			continue
		h.visible = true
		_tint_holder(h, a.rarity_color(), a.rarity == Rarity.MYTHIC)
		_armor_shown[slot] = piece
		modelled[slot] = true
	for key in _mannequin:
		var slot: String = key.trim_suffix("2")
		var a: GearItem = inv.equipped.get(slot)
		var mi: MeshInstance3D = _mannequin[key]
		var m: StandardMaterial3D = mi.material_override
		mi.visible = not modelled.has(slot) # the model replaces the primitive stand-in
		if modelled.has(slot):
			continue
		m.albedo_color = a.rarity_color().lerp(UIStyle.OLIVE, 0.45) if a else Color(0.25, 0.25, 0.22)
		m.metallic = 0.25
		m.roughness = 0.8
		m.emission_enabled = a != null and a.rarity == Rarity.MYTHIC
		m.emission = a.rarity_color() if a else Color.BLACK
		m.emission_energy_multiplier = 0.4
	if _visor:
		_visor.visible = not modelled.has("helmet")


## Slot -> piece id currently drawn as a model (tests).
func armor_models_shown() -> Dictionary:
	return _armor_shown.duplicate()


# ------------------------------------------------------------------ item card

## Borderlands-style item card anchored beside the cursor.
func _bind_seen(inv: Inventory) -> void:
	_bind_ip_sources(inv)
	if _seen_bound:
		return
	if not inv.seen_changed.is_connected(_on_seen_changed):
		inv.seen_changed.connect(_on_seen_changed)
	_seen_bound = true


## Item Power on the weapon card = rolled + Rework bonus; re-render on Progress.armory_changed (upgrade) and
## Inventory.changed (new / swapped item). Armory itself doesn't emit for breakdowns.
func _bind_ip_sources(inv: Inventory) -> void:
	if not _ip_prog_bound:
		var prog := get_node_or_null("/root/Progress")
		if prog and prog.has_signal("armory_changed") and not prog.armory_changed.is_connected(_on_ip_source_changed):
			prog.armory_changed.connect(_on_ip_source_changed)
			_ip_prog_bound = true
	if inv == _ip_inv:
		return
	if _ip_inv and is_instance_valid(_ip_inv) and _ip_inv.changed.is_connected(_on_ip_source_changed):
		_ip_inv.changed.disconnect(_on_ip_source_changed)
	_ip_inv = inv
	if inv and not inv.changed.is_connected(_on_ip_source_changed):
		inv.changed.connect(_on_ip_source_changed)


func _on_ip_source_changed(_a = null, _b = null) -> void:
	_ip_cache.clear()
	if not visible:
		return
	if player and _ip_inv == player.inventory and _avg_ip_label:
		_refresh_avg_ip(player.inventory)
		_refresh_ip_plates(player.inventory)
	if _tooltip == null or not _tooltip.visible or _tooltip_item == null:
		return
	var fixed := _tooltip_fixed
	var at := _tooltip.position
	_show_tooltip(_tooltip_item, _tooltip_equipped)
	if fixed:
		_tooltip_fixed = true
		_tooltip.position = at


## Item Power shown everywhere on this screen: weapons = breakdown total (rolled + Rework), armor = rolled.
func display_ip(item: GearItem) -> int:
	if item == null:
		return 0
	var w := item as WeaponItem
	if w == null:
		return item.item_power
	var key := w.item_id if w.item_id != "" else str(w.get_instance_id())
	if _ip_cache.has(key):
		return int(_ip_cache[key])
	var t := int(weapon_ip_breakdown(w).get("total", w.item_power))
	_ip_cache[key] = t
	return t


## Average of display_ip() over equipped gear (empty slots ignored), same rounding as Inventory.average_item_power().
func average_display_ip(inv: Inventory) -> int:
	var t := 0
	var n := 0
	for s in inv.equipped:
		if inv.equipped[s]:
			t += display_ip(inv.equipped[s])
			n += 1
	return int(round(float(t) / max(n, 1)))


## Inventory.compare_power() shape, on display_ip() totals.
func compare_display_ip(inv: Inventory, item: GearItem) -> Dictionary:
	var cur: GearItem = inv.equipped.get(item.slot)
	if cur == null or cur == item:
		return {}
	var d := display_ip(item) - display_ip(cur)
	return {"label": "Item Power", "delta": float(d), "better": d > 0, "worse": d < 0, "text": "%+d" % d if d != 0 else ""}


## Update slot / tile IP plates in place (no rebuild) after an armory or inventory change.
func _refresh_ip_plates(inv: Inventory) -> void:
	for side in [_left, _right]:
		if side == null:
			continue
		for wrap in side.get_children():
			if not wrap.has_meta("slot"):
				continue
			var g: GearItem = inv.equipped.get(str(wrap.get_meta("slot")))
			var sp: Node = wrap.find_child("SlotIP", true, false)
			if sp and g:
				_set_plate_number(sp, display_ip(g))
			_refresh_tile_plates(wrap, inv)


func _refresh_tile_plates(n: Node, inv: Inventory) -> void:
	if n is Button and n.has_meta("gear"):
		var g: GearItem = n.get_meta("gear")
		var tp: Node = n.find_child("TileIP", false, false)
		if tp and g:
			_set_plate_number(tp, display_ip(g))
			if inv.equipped.get(g.slot) != g:
				var num: Node = tp.find_child("IPNumber", true, false)
				if num is Label:
					(num as Label).add_theme_color_override("font_color",
						UIStyle.ip_tint(int(compare_display_ip(inv, g).get("delta", 0))))
	for c in n.get_children():
		_refresh_tile_plates(c, inv)


func _set_plate_number(plate: Node, n: int) -> void:
	var num: Node = plate.find_child("IPNumber", true, false)
	if num is Label:
		(num as Label).text = str(n)


## Armory.item_power_breakdown(item_id); falls back to rolled + power_bonus(type) for items Armory can't find
## (e.g. a card shown for an item that isn't in the inventory or stash).
func weapon_ip_breakdown(w: WeaponItem) -> Dictionary:
	var ArmoryScr = load("res://scripts/armory/armory.gd")
	var bd: Dictionary = {}
	if ArmoryScr and w.item_id != "":
		bd = ArmoryScr.item_power_breakdown(w.item_id)
	if bd.is_empty() or str(bd.get("source", "")) != "item":
		var bonus: int = int(ArmoryScr.power_bonus(str(w.archetype))) if ArmoryScr else 0
		bd = {"base_rolled": w.item_power, "rework_bonus": bonus, "total": w.item_power + bonus,
			"archetype": str(w.archetype), "item_id": w.item_id, "tier": int(ArmoryScr.upgrade_tier(str(w.archetype))) if ArmoryScr else 0,
			"source": "card"}
	return bd


func _on_seen_changed(_item = null) -> void:
	if not visible or player == null:
		return
	_refresh_unseen_badges(player.inventory)
	_refresh_stash_count(player.inventory)


func _refresh_gravemark() -> void:
	if _gm_chip == null:
		return
	var prog := get_node_or_null("/root/Progress")
	var n := int(prog.gravemark_balance()) if prog and prog.has_method("gravemark_balance") else 0
	UIStyle.set_gravemark_chip_amount(_gm_chip, n)


func _refresh_stash_count(inv: Inventory) -> void:
	if _stash_label == null:
		return
	var n: int = inv.carried_count()
	var cap: int = inv.stash_cap
	_stash_label.text = "%d/%d" % [n, cap]
	var col := UIStyle.BONE
	if cap > 0 and n >= cap:
		col = UIStyle.BAD
	elif cap > 0 and n >= int(cap * 0.85):
		col = UIStyle.RUST.lightened(0.25)
	_stash_label.add_theme_color_override("font_color", col)


## Walk the built slot rows / stash tiles and show or hide '!' badges without a full rebuild.
func _refresh_unseen_badges(inv: Inventory) -> void:
	for side in [_left, _right]:
		if side == null:
			continue
		for wrap in side.get_children():
			if not wrap.has_meta("slot"):
				continue
			var slot: String = wrap.get_meta("slot")
			var bang: Node = wrap.find_child("SlotUnseen", true, false)
			if bang:
				(bang as CanvasItem).visible = inv.has_unseen(slot)
			_refresh_tile_bangs(wrap, inv)


func _refresh_tile_bangs(n: Node, inv: Inventory) -> void:
	if n is Button and n.has_meta("gear"):
		var g: GearItem = n.get_meta("gear")
		var bang: Node = n.find_child("UnseenBadge", true, false)
		var show: bool = g != null and not g.seen and not (player.inventory.equipped.get(g.slot) == g)
		if bang:
			(bang as CanvasItem).visible = show
		elif show:
			var b2: PanelContainer = UIStyle.unseen_badge(12)
			b2.position = Vector2(3, 2)
			n.add_child(b2)
	for c in n.get_children():
		_refresh_tile_bangs(c, inv)


func _on_tile_hover(item: GearItem, equipped: bool) -> void:
	_show_tooltip(item, equipped)
	if item is ArmorItem and not equipped:
		set_stat_preview(armor_swap_totals(item))
	else:
		clear_stat_preview()
	if item and not item.seen and player:
		player.inventory.mark_seen(item) # seen_changed → _refresh_unseen_badges


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_M:
		if player:
			player.inventory.mark_all_seen()
			_ui_snd("ui_equip")
		get_viewport().set_input_as_handled()
		return
	super._unhandled_input(event)


## Playtest #9 class items (Skillz CHARACTER_API "Class items on item cards"): effect line, keystone synergy
## (lit when you own it), and a WRONG CLASS warning when the item belongs to another class.
func _class_item_block(b: VBoxContainer, item) -> void:
	if not (item is ArmorItem) or str(item.get("class_effect")) == "" or not item.has_method("class_line"):
		return
	var st := str(ClassItems.state(item, Progress.selected_class))
	b.add_child(_divider())
	var head := UIStyle.label(("%s CLASS ITEM" % str(item.class_id).to_upper()) + ("  //  WRONG CLASS: NO EFFECT" if st == "wrong_class" else ""),
		12, UIStyle.BAD.lightened(0.15) if st == "wrong_class" else UIStyle.TIER_LEGENDARY.lightened(0.4), true)
	head.name = "ClassItemHead"
	b.add_child(head)
	var l := UIStyle.label(item.class_line(), 12, UIStyle.BONE if st == "active" else UIStyle.BONE_DIM)
	l.name = "ClassItemLine"
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = CARD_W - 30
	b.add_child(l)
	var syn := str(item.class_synergy_line())
	if syn != "":
		var kid := str(ClassItems.synergy_keystone(item))
		var lit := kid != "" and int(Progress.rank(kid)) > 0 and st == "active"
		var sl := UIStyle.label(syn + ("  (OWNED)" if lit else ""), 11, UIStyle.GOOD if lit else UIStyle.BONE_DIM)
		sl.name = "ClassItemSynergy"
		sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sl.custom_minimum_size.x = CARD_W - 30
		b.add_child(sl)


func _show_tooltip(item: GearItem, equipped: bool) -> void:
	_tooltip_fixed = false
	_tooltip_item = item
	_tooltip_equipped = equipped
	for c in _tooltip.get_children():
		_tooltip.remove_child(c)
		c.queue_free()
	var rc := item.rarity_color()
	var w := item as WeaponItem
	var card := PanelContainer.new()
	var cs := UIStyle.cut_box(Color(0.06, 0.06, 0.05, 0.97), rc, 4, 18)
	cs.set_content_margin_all(0)
	card.add_theme_stylebox_override("panel", cs)
	card.custom_minimum_size = Vector2(CARD_W, 0)
	_tooltip.add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	card.add_child(v)

	# Icon banner: rarity gradient + icon + rarity tag
	var banner := Control.new()
	var a_icon := "" if w else armor_icon_path(item)
	var has_a_icon := a_icon != "" and ResourceLoader.exists(a_icon)
	banner.custom_minimum_size = Vector2(CARD_W, 112 if (w or has_a_icon) else 64)
	v.add_child(banner)
	var bgt := TextureRect.new()
	var gt := GradientTexture2D.new()
	gt.fill_from = Vector2(0, 1)
	gt.fill_to = Vector2(1, 0)
	var gr := Gradient.new()
	gr.set_color(0, Color(rc.darkened(0.55), 0.95))
	gr.set_color(1, Color(0.05, 0.05, 0.04, 0.6))
	gt.gradient = gr
	bgt.texture = gt
	bgt.stretch_mode = TextureRect.STRETCH_SCALE
	bgt.set_anchors_preset(Control.PRESET_FULL_RECT)
	bgt.offset_left = 4
	bgt.offset_right = -4
	bgt.offset_top = 4
	banner.add_child(bgt)
	UIStyle.add_grit(banner, 0.35)
	var icon_path: String = ICON_DIR + item.archetype + ".png"
	if has_a_icon:
		icon_path = a_icon
	if (w or has_a_icon) and ResourceLoader.exists(icon_path):
		var tr := TextureRect.new()
		tr.texture = load(icon_path)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.offset_left = 40
		tr.offset_right = -40
		tr.offset_top = 10
		tr.offset_bottom = -4
		banner.add_child(tr)
	var tag := PanelContainer.new()
	var ts := UIStyle.cut_box(rc, Color(0, 0, 0, 0), 0, 8)
	ts.set_content_margin_all(3)
	ts.content_margin_left = 10
	ts.content_margin_right = 10
	tag.add_theme_stylebox_override("panel", ts)
	tag.position = Vector2(10, 10)
	tag.add_child(UIStyle.label(item.rarity_name().to_upper(), 13, UIStyle.INK, true))
	banner.add_child(tag)
	# Item Power block, top-right of the banner, with delta vs equipped
	var pc: Dictionary = {} if equipped or player == null else compare_display_ip(player.inventory, item)
	_last_card_power = pc
	banner.add_child(_card_ip_box(item, pc))

	var body := MarginContainer.new()
	for side in ["left", "right"]:
		body.add_theme_constant_override("margin_" + side, 14)
	body.add_theme_constant_override("margin_top", 6)
	body.add_theme_constant_override("margin_bottom", 12)
	v.add_child(body)
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", 3)
	body.add_child(b)
	var name_l := UIStyle.label(item.display_name.to_upper(), 24, rc.lightened(0.1), true, 4)
	name_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_l.custom_minimum_size.x = CARD_W - 28
	b.add_child(name_l)
	var maker := HBoxContainer.new()
	maker.add_theme_constant_override("separation", 8)
	maker.add_child(UIStyle.label(item.manufacturer.to_upper(), 14, item.manufacturer_color))
	var sub := item.type_name().to_upper()
	if w:
		sub += "  /  " + w.element.to_upper()
	maker.add_child(UIStyle.label(sub, 13, GearDB.element_color(w.element) if w else UIStyle.BONE_DIM))
	b.add_child(maker)

	var cmp: Array = [] if equipped or player == null else player.inventory.compare(item)
	_last_card_rows = cmp
	var cur: GearItem = null if player == null else player.inventory.equipped.get(item.slot)
	var cur_rows: Array = cur.call("card_stats") if cur and not equipped else []
	if w:
		# Big damage readout
		var dmg := HBoxContainer.new()
		dmg.add_theme_constant_override("separation", 8)
		var rows: Array = w.card_stats()
		dmg.add_child(UIStyle.label(rows[0][1], 40, UIStyle.BONE, true, 0))
		var dl := UIStyle.label("DAMAGE", 13, UIStyle.BONE_DIM)
		dl.size_flags_vertical = Control.SIZE_SHRINK_END
		dmg.add_child(dl)
		if cmp.size() > 0:
			dmg.add_child(_delta_widget(cmp[0]))
		b.add_child(dmg)
	b.add_child(_divider())
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	b.add_child(grid)
	var stats: Array = item.call("card_stats")
	for i in stats.size():
		if w and i == 0:
			continue # damage is shown big above
		var r: Array = stats[i]
		var lab := UIStyle.label(str(r[0]).to_upper(), 13, UIStyle.BONE_DIM)
		lab.custom_minimum_size.x = 92
		grid.add_child(lab)
		var num := UIStyle.label(str(r[1]), 19, UIStyle.BONE, true)
		num.custom_minimum_size.x = 64
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(num)
		var ghost: float = float(cur_rows[i][2]) if i < cur_rows.size() else -1.0
		var bar := UIStyle.bar(float(r[2]), rc.lerp(UIStyle.BONE, 0.25), 110, 7, ghost)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grid.add_child(bar)
		grid.add_child(_delta_widget(cmp[i]) if i < cmp.size() else Control.new())
	if item.roll_quality >= 0.0:
		b.add_child(UIStyle.roll_bar(item.roll_quality, item.item_power, 120))
	if cmp.size() > 0:
		b.add_child(UIStyle.label("VS EQUIPPED: %s  //  IP %d" % [cur.display_name.to_upper(), display_ip(cur)], 11, UIStyle.BONE_DIM))
	# Perks
	if item.perks.size() > 0:
		b.add_child(_divider())
		for pid in item.perks:
			var p: Dictionary = GearDB.perk(pid)
			var pr := HBoxContainer.new()
			pr.add_theme_constant_override("separation", 10)
			pr.add_child(PerkBadge.make(p, 34))
			var pt := VBoxContainer.new()
			pt.add_theme_constant_override("separation", -3)
			pt.add_child(UIStyle.label(str(p.get("name", pid)).to_upper(), 16, UIStyle.BONE))
			var d := UIStyle.label(p.get("description", ""), 12, UIStyle.BONE_DIM)
			d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			d.custom_minimum_size.x = CARD_W - 80
			pt.add_child(d)
			pr.add_child(pt)
			b.add_child(pr)
	_class_item_block(b, item)
	# Armory: Rework tier + equipped attachments (per weapon TYPE)
	if w:
		var ArmoryScr = load("res://scripts/armory/armory.gd")
		var arch := str(w.archetype)
		var tier_n: int = int(ArmoryScr.upgrade_tier(arch))
		var loadout: Dictionary = ArmoryScr.loadout(arch)
		b.add_child(_divider())
		var type_n := str(w.type_name())
		var rework := "BASE" if tier_n <= 0 else "REWORK %s" % UIStyle.roman(tier_n)
		b.add_child(UIStyle.label("%s  //  applies to all %ss" % [rework, type_n], 12, UIStyle.OLIVE.lightened(0.35), true))
		if not loadout.is_empty():
			var parts: PackedStringArray = []
			for slot in loadout:
				var aid := str(loadout[slot])
				var att: Dictionary = ArmoryScr.attachment(aid)
				var aname := str(att.get("name", aid)) if not att.is_empty() else aid
				parts.append("%s: %s" % [str(slot).to_upper(), aname])
			var pl := UIStyle.label("  ".join(parts), 11, UIStyle.BONE_DIM)
			pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			pl.custom_minimum_size.x = CARD_W - 28
			b.add_child(pl)
	# Flavor text in an accent colour
	if item.flavor != "":
		b.add_child(_divider())
		var fl := UIStyle.label('"%s"' % item.flavor, 14, UIStyle.RUST.lightened(0.25))
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.custom_minimum_size.x = CARD_W - 28
		b.add_child(fl)
	var foot := UIStyle.label("EQUIPPED" if equipped else "[LMB] EQUIP    [RMB] SCRAP", 12,
		UIStyle.OLIVE.lightened(0.4) if equipped else UIStyle.BONE_DIM, true)
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	b.add_child(foot)
	_tooltip.visible = true
	_tooltip.reset_size()
	_place_tooltip()


## Card's ITEM POWER box: bone frame, "ITEM POWER" tab, big number, delta vs equipped.
func _card_ip_box(item: GearItem, pc: Dictionary) -> Control:
	var box := PanelContainer.new()
	var st := UIStyle.cut_box(Color(UIStyle.INK, 0.92), UIStyle.BONE, 2, 9, true)
	st.set_content_margin_all(0)
	st.content_margin_bottom = 3
	box.add_theme_stylebox_override("panel", st)
	var wi := item as WeaponItem
	var bd: Dictionary = weapon_ip_breakdown(wi) if wi else {}
	_last_card_ip = bd
	var wide: bool = not bd.is_empty()
	box.position = Vector2(CARD_W - (148 if wide else 104), 8)
	box.custom_minimum_size.x = 138 if wide else 94
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	box.add_child(v)
	var tab := PanelContainer.new()
	var ts := StyleBoxFlat.new()
	ts.bg_color = UIStyle.BONE
	ts.content_margin_left = 4
	ts.content_margin_right = 4
	tab.add_theme_stylebox_override("panel", ts)
	var tl := UIStyle.label("ITEM POWER", 10, UIStyle.INK)
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tab.add_child(tl)
	v.add_child(tab)
	if wide:
		# "312 IP" big (rolled + Rework) over "290 rolled + 22 Rework"
		var blk := UIStyle.ip_breakdown_block(bd, 32, 11)
		blk.name = "CardIPBreakdown"
		v.add_child(blk)
	else:
		var n := UIStyle.label(str(item.item_power), 32, UIStyle.BONE, true, 0)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(n)
	var dh := HBoxContainer.new()
	dh.alignment = BoxContainer.ALIGNMENT_CENTER
	if pc.is_empty():
		dh.add_child(UIStyle.label("EQUIPPED" if player and player.inventory.equipped.get(item.slot) == item else "-", 10, UIStyle.BONE_DIM))
	else:
		dh.add_child(_delta_widget(pc))
	v.add_child(dh)
	return box


func _divider() -> Control:
	var d := ColorRect.new()
	d.color = Color(UIStyle.BONE, 0.14)
	d.custom_minimum_size = Vector2(0, 2)
	return d


## "+12 ▲" / "-0.3 ▼" comparison chip.
func _delta_widget(row: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 3)
	h.custom_minimum_size.x = 54
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if not (row.better or row.worse):
		h.add_child(UIStyle.label("=", 13, UIStyle.BONE_DIM))
		return h
	h.add_child(DeltaArrow.make(row.better, 11.0))
	h.add_child(UIStyle.label(row.text, 14, UIStyle.GOOD if row.better else UIStyle.BAD))
	return h


func _place_tooltip() -> void:
	var vp := get_viewport().get_visible_rect().size
	var m := get_viewport().get_mouse_position() + Vector2(22, -40)
	var sz := _tooltip.get_combined_minimum_size()
	m.x = clamp(m.x if m.x + sz.x < vp.x else m.x - sz.x - 44, 0, max(vp.x - sz.x, 0))
	m.y = clamp(m.y, 0, max(vp.y - sz.y, 0))
	_tooltip.position = m


func _hide_tooltip() -> void:
	if _tooltip:
		_tooltip.visible = false
	clear_stat_preview()


## For tests / screenshots: show the card for an item at a fixed position.
func debug_show_tooltip(item: GearItem, at: Vector2) -> void:
	if item and player and not item.seen:
		player.inventory.mark_seen(item)
	_show_tooltip(item, player != null and player.inventory.equipped.get(item.slot) == item)
	_tooltip_fixed = true
	_tooltip.position = at
