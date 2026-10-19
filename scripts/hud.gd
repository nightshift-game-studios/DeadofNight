extends CanvasLayer
## Rugged survival HUD (built in code). Everything sits small at the screen edges:
##  top-left   painted tally-mark round counter + points
##  top-right  zombies left
##  bottom-left  health bar + compact grenade / ability / melee cooldown badges
##  bottom-right active weapon, ammo, and small icons for the other weapons
##  centre     crosshair + hit markers, contextual prompt ("E  PICK UP ..."), round banner
## Controls are only hinted briefly at match start. Low health shows a red vignette.
## Colours / fonts / panels come from scripts/ui/ui_style.gd.

const ICON_DIR := "res://assets/icons/"

var _health_label: Label
var _health_fill: ColorRect
var _health_back: ColorRect
var _health_ghost: ColorRect
var _ammo_label: Label
var _reserve_label: Label
var _weapon_label: Label
var _maker_label: Label
var _buff_label: Label
var _enemies_label: Label
var _message: Label
var _vignette: TextureRect
var _round_tally: TallyCounter
var _points_label: Label
var _banner: Label
var _banner_sub: Label
var _prompt: PanelContainer
var _prompt_label: Label
var _prompt_key: Label
var _hint: Label
var _other_weapons: HBoxContainer
var _indicators: Dictionary = {} ## "grenade"/"ability"/"melee" -> CooldownIcon
var _loot_feed: VBoxContainer
var _hit_marker: HitMarker
var _last_hit: Dictionary = {} ## last hit_registered payload (tests / debugging)
var _last_health: int = -1
var _health_frac: float = 1.0
var _hurt: float = 0.0
var _t: float = 0.0
var _shield_frame: Panel ## overshield segment, right of the health bar (hidden at 0)
var _shield_fill: ColorRect
var _shield_label: Label
var _shield_w: float = 0.0
var _shield: float = 0.0
var _shield_cap: float = 0.0
var _health_max: int = 100
var _cards_strip: HBoxContainer ## owned Field Cards, top-left under the horde counter
var _unseen_chip: PanelContainer ## compact "TAB !" + count when stash has unseen loot
var _unseen_count_label: Label
var _seen_bound: bool = false
var _player_ref: Node ## bound via the "player" group (overshield / charges signals)
var _bind_t: float = 0.0

const BAR_W := 230.0


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# Low-health / damage vignette (replaces the old full-screen flash)
	_vignette = TextureRect.new()
	var gt := GradientTexture2D.new()
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(1.05, 1.05)
	var g := Gradient.new()
	g.set_color(0, Color(0.5, 0, 0, 0))
	g.add_point(0.72, Color(0.45, 0, 0, 0.0))
	g.set_color(1, Color(0.5, 0.0, 0.0, 0.8))
	gt.gradient = g
	_vignette.texture = gt
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette.modulate.a = 0.0
	root.add_child(_vignette)

	# Crosshair: four thin bone ticks with a dark outline
	var cross := Control.new()
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cross)
	for r in [Rect2(-11, -1, 7, 2), Rect2(4, -1, 7, 2), Rect2(-1, -11, 2, 7), Rect2(-1, 4, 2, 7)]:
		var o := ColorRect.new()
		o.color = Color(0, 0, 0, 0.5)
		o.position = r.position - Vector2(1, 1)
		o.size = r.size + Vector2(2, 2)
		cross.add_child(o)
		var bar := ColorRect.new()
		bar.color = Color(UIStyle.BONE, 0.9)
		bar.position = r.position
		bar.size = r.size
		cross.add_child(bar)
	var dot := ColorRect.new() # tiny blood-red centre dot
	dot.color = Color(UIStyle.BLOOD.lightened(0.2), 0.9)
	dot.position = Vector2(-1, -1)
	dot.size = Vector2(2, 2)
	cross.add_child(dot)
	_hit_marker = HitMarker.new()
	_hit_marker.size = Vector2(90, 90)
	_hit_marker.position = Vector2(-45, -45)
	cross.add_child(_hit_marker)

	# Top-left: tally round counter + points
	_round_tally = TallyCounter.new()
	_round_tally.position = Vector2(22, 14)
	_round_tally.size = Vector2(260, 58)
	_round_tally.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_round_tally)
	var pts_row := HBoxContainer.new()
	pts_row.position = Vector2(24, 74)
	pts_row.add_theme_constant_override("separation", 5)
	pts_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(pts_row)
	_points_label = UIStyle.label("0", 26, UIStyle.BONE, true, 5)
	pts_row.add_child(_points_label)
	var pts_l := UIStyle.label("PTS", 13, UIStyle.BONE_DIM, false, 4)
	pts_l.size_flags_vertical = Control.SIZE_SHRINK_END
	pts_row.add_child(pts_l)

	# Under the points: zombies left (kept with the round info, top-left)
	_enemies_label = UIStyle.label("", 14, UIStyle.BONE_DIM, false, 4)
	_enemies_label.position = Vector2(25, 108)
	_enemies_label.size = Vector2(300, 24)
	root.add_child(_enemies_label)
	_cards_strip = HBoxContainer.new()
	_cards_strip.position = Vector2(24, 132)
	_cards_strip.add_theme_constant_override("separation", 3)
	_cards_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_cards_strip)

	# Compact unseen-loot hint (TAB loadout key + '!' + count). Hidden when nothing is unseen.
	_unseen_chip = PanelContainer.new()
	_unseen_chip.name = "UnseenLootHint"
	_unseen_chip.visible = false
	_unseen_chip.position = Vector2(24, 108)
	_unseen_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unseen_chip.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(UIStyle.INK, 0.85), UIStyle.BLOOD.darkened(0.1), 2, 6))
	var uh := HBoxContainer.new()
	uh.add_theme_constant_override("separation", 5)
	uh.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unseen_chip.add_child(uh)
	uh.add_child(UIStyle.label("TAB", 11, UIStyle.BONE_DIM, true))
	uh.add_child(UIStyle.unseen_badge(12))
	_unseen_count_label = UIStyle.label("0", 12, UIStyle.BONE, true)
	_unseen_count_label.name = "UnseenCount"
	uh.add_child(_unseen_count_label)
	root.add_child(_unseen_chip)
	var rs := get_node_or_null("/root/RunState")
	if rs:
		rs.cards_changed.connect(refresh_cards)
	_bind_player.call_deferred()

	# Bottom-left: cooldown badges above a chunky health bar
	var bl := VBoxContainer.new()
	bl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bl.position = Vector2(24, -112)
	bl.add_theme_constant_override("separation", 8)
	root.add_child(bl)
	var icons := HBoxContainer.new()
	icons.add_theme_constant_override("separation", 6)
	bl.add_child(icons)
	for spec in [["grenade", "GR", "G", UIStyle.RUST], ["ability", "AB", "Q", UIStyle.OLIVE.lightened(0.15)], ["melee", "ML", "V", UIStyle.BONE_DIM]]:
		var ic := CooldownIcon.make(spec[1], spec[2], spec[3], 44)
		icons.add_child(ic)
		_indicators[spec[0]] = ic
	var hb := Control.new()
	hb.custom_minimum_size = Vector2(BAR_W + 70, 22)
	bl.add_child(hb)
	var frame := Panel.new()
	frame.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(0.04, 0.04, 0.035, 0.8), Color(UIStyle.BONE_DIM, 0.5), 2, 7))
	frame.position = Vector2(0, 0)
	frame.size = Vector2(BAR_W + 8, 22)
	hb.add_child(frame)
	_health_back = ColorRect.new()
	_health_back.color = Color(0.2, 0.05, 0.04, 0.6)
	_health_back.position = Vector2(4, 4)
	_health_back.size = Vector2(BAR_W, 14)
	hb.add_child(_health_back)
	_health_ghost = ColorRect.new() # recent damage, drains after a moment
	_health_ghost.color = Color(UIStyle.BLOOD, 0.9)
	_health_ghost.position = Vector2(4, 4)
	_health_ghost.size = Vector2(BAR_W, 14)
	hb.add_child(_health_ghost)
	_health_fill = ColorRect.new()
	_health_fill.color = UIStyle.BONE
	_health_fill.position = Vector2(4, 4)
	_health_fill.size = Vector2(BAR_W, 14)
	hb.add_child(_health_fill)
	var notches := Control.new() # segment notches for a stencilled, chunky look
	notches.position = Vector2(4, 4)
	hb.add_child(notches)
	for i in range(1, 10):
		var n := ColorRect.new()
		n.color = Color(0, 0, 0, 0.55)
		n.position = Vector2(BAR_W * i / 10.0, 0)
		n.size = Vector2(2, 14)
		notches.add_child(n)
	var grit_box := Control.new()
	grit_box.position = Vector2(4, 4)
	grit_box.size = Vector2(BAR_W, 14)
	grit_box.clip_contents = true
	hb.add_child(grit_box)
	UIStyle.add_grit(grit_box, 0.6)
	_shield_frame = Panel.new() # overshield: steel segment bolted onto the bar's right end
	_shield_frame.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(0.04, 0.05, 0.06, 0.85), Color(UIStyle.STEEL, 0.8), 2, 6))
	_shield_frame.position = Vector2(BAR_W + 10, 0)
	_shield_frame.size = Vector2(40, 22)
	_shield_frame.visible = false
	hb.add_child(_shield_frame)
	_shield_fill = ColorRect.new()
	_shield_fill.color = UIStyle.STEEL
	_shield_fill.position = Vector2(4, 4)
	_shield_fill.size = Vector2(32, 14)
	_shield_frame.add_child(_shield_fill)
	_health_label = UIStyle.label("100", 26, UIStyle.BONE, true, 5)
	_health_label.position = Vector2(BAR_W + 16, -10)
	hb.add_child(_health_label)
	_shield_label = UIStyle.label("", 15, UIStyle.STEEL, true, 4)
	_shield_label.visible = false
	hb.add_child(_shield_label)

	# Bottom-right: active weapon + ammo, other weapons as small icons
	var br := VBoxContainer.new()
	br.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	br.position = Vector2(-344, -142)
	br.custom_minimum_size = Vector2(320, 0)
	br.add_theme_constant_override("separation", -2)
	root.add_child(br)
	_buff_label = UIStyle.label("", 14, UIStyle.RUST.lightened(0.3), false, 4)
	_buff_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	br.add_child(_buff_label)
	_weapon_label = UIStyle.label("", 17, UIStyle.BONE, true, 5)
	_weapon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	br.add_child(_weapon_label)
	_maker_label = UIStyle.label("", 12, UIStyle.BONE_DIM, false, 4)
	_maker_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	br.add_child(_maker_label)
	var ammo_row := HBoxContainer.new()
	ammo_row.alignment = BoxContainer.ALIGNMENT_END
	ammo_row.add_theme_constant_override("separation", 6)
	br.add_child(ammo_row)
	_ammo_label = UIStyle.label("0", 40, UIStyle.BONE, true, 6)
	ammo_row.add_child(_ammo_label)
	_reserve_label = UIStyle.label("/ 0", 20, UIStyle.BONE_DIM, true, 5)
	_reserve_label.size_flags_vertical = Control.SIZE_SHRINK_END
	ammo_row.add_child(_reserve_label)
	_other_weapons = HBoxContainer.new()
	_other_weapons.alignment = BoxContainer.ALIGNMENT_END
	_other_weapons.add_theme_constant_override("separation", 6)
	br.add_child(_other_weapons)

	# Right-centre: compact loot feed
	_loot_feed = VBoxContainer.new()
	_loot_feed.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_loot_feed.position = Vector2(-300, -20)
	_loot_feed.custom_minimum_size = Vector2(276, 0)
	_loot_feed.add_theme_constant_override("separation", 3)
	_loot_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_loot_feed)

	# Centre: contextual prompt chip
	_prompt = PanelContainer.new()
	_prompt.add_theme_stylebox_override("panel", UIStyle.cut_box(Color(0.04, 0.04, 0.035, 0.75), Color(UIStyle.BONE, 0.5), 2, 8))
	_prompt.visible = false
	root.add_child(_prompt)
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 10)
	_prompt.add_child(ph)
	var keycap := PanelContainer.new()
	var ks := UIStyle.cut_box(UIStyle.BONE, Color(0, 0, 0, 0), 0, 5)
	ks.set_content_margin_all(1)
	ks.content_margin_left = 8
	ks.content_margin_right = 8
	keycap.add_theme_stylebox_override("panel", ks)
	_prompt_key = UIStyle.label("E", 16, UIStyle.INK, true)
	keycap.add_child(_prompt_key)
	ph.add_child(keycap)
	_prompt_label = UIStyle.label("", 17, UIStyle.BONE)
	ph.add_child(_prompt_label)

	# Brief control hints (match start only)
	_hint = UIStyle.label("", 15, UIStyle.BONE_DIM, false, 4)
	_hint.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.position = Vector2(-450, -64)
	_hint.size = Vector2(900, 50)
	root.add_child(_hint)

	# Round banner
	_banner = UIStyle.label("", 64, UIStyle.BLOOD, true, 8)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.position = Vector2(-400, 120)
	_banner.size = Vector2(800, 90)
	_banner.modulate.a = 0.0
	root.add_child(_banner)
	_banner_sub = UIStyle.label("", 18, UIStyle.BONE, false, 5)
	_banner_sub.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_sub.position = Vector2(-400, 200)
	_banner_sub.size = Vector2(800, 30)
	_banner_sub.modulate.a = 0.0
	root.add_child(_banner_sub)

	_message = UIStyle.label("", 26, UIStyle.BONE, false, 6)
	_message.set_anchors_preset(Control.PRESET_FULL_RECT)
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.visible = false
	root.add_child(_message)

	# The HUD is display-only. With the mouse captured, every motion event is reported at the screen centre,
	# so any Control there with the default MOUSE_FILTER_STOP (the crosshair ticks / centre dot) swallowed it
	# before player.gd's _unhandled_input and mouse-look died. Nothing in the HUD may take the mouse,
	# including rows added later (loot feed, weapon icons, card chips).
	mouse_passthrough(self)
	get_tree().node_added.connect(_on_node_added)


## Sets MOUSE_FILTER_IGNORE on every Control under `n`.
static func mouse_passthrough(n: Node) -> void:
	for c in n.get_children():
		if c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		mouse_passthrough(c)


func _on_node_added(n: Node) -> void:
	if n is Control and is_ancestor_of(n):
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t += delta
	if _player_ref == null or not is_instance_valid(_player_ref):
		_bind_t -= delta
		if _bind_t <= 0.0:
			_bind_t = 0.5
			_bind_player()
	_hurt = maxf(_hurt - delta * 2.2, 0.0)
	var low := clampf((0.45 - _health_frac) / 0.45, 0.0, 1.0)
	var pulse := 0.85 + 0.15 * sin(_t * (3.0 + low * 4.0))
	_vignette.modulate.a = clampf(low * 0.6 * pulse + _hurt * 0.35, 0.0, 0.7)
	# ghost bar drains toward the real value
	var target := _health_fill.size.x
	if _health_ghost.size.x > target:
		_health_ghost.size.x = maxf(_health_ghost.size.x - BAR_W * delta * 0.6, target)


func set_health(current: int, maximum: int) -> void:
	_health_frac = float(current) / max(maximum, 1)
	_health_max = maxi(maximum, 1)
	_health_label.text = str(current)
	_health_fill.size.x = BAR_W * clampf(_health_frac, 0.0, 1.0)
	if _health_ghost.size.x < _health_fill.size.x:
		_health_ghost.size.x = _health_fill.size.x
	var low := _health_frac < 0.35
	_health_fill.color = UIStyle.BLOOD.lightened(0.15) if low else UIStyle.BONE
	_health_label.add_theme_color_override("font_color", UIStyle.BLOOD.lightened(0.3) if low else UIStyle.BONE)
	if _last_health >= 0 and current < _last_health:
		_hurt = minf(_hurt + 0.6, 1.0)
	_last_health = current
	_layout_shield()


# ---------------------------------------------------------------- player self-binding (main.gd untouched)

## Finds the player through its "player" group and listens to the overshield / charge signals that
## main.gd does not route to the HUD. Re-tried from _process until a player exists.
func _bind_player() -> void:
	if _player_ref != null and is_instance_valid(_player_ref):
		return
	var p := get_tree().get_first_node_in_group("player")
	if p == null:
		return
	_player_ref = p
	if p.has_signal("overshield_changed"):
		p.overshield_changed.connect(set_overshield)
		set_overshield(float(p.get("overshield")), float(p.get("overshield_cap")))
	if p.has_signal("grenade_charges_changed"):
		p.grenade_charges_changed.connect(set_grenade_charges)
		set_grenade_charges(int(p.get("grenade_charges")), int(p.get("grenade_charges_max")))
	if p.has_signal("ability_charges_changed"):
		p.ability_charges_changed.connect(set_ability_charges)
		set_ability_charges(int(p.get("ability_charges")), int(p.get("ability_charges_max")))
	_bind_seen(p)
	refresh_cards()
	refresh_unseen_hint()


## Overshield segment: steel block right of the health bar, sized by cap vs max health, hidden at 0.
func set_overshield(current: float, cap: float) -> void:
	_shield = maxf(current, 0.0)
	_shield_cap = maxf(cap, 0.0)
	_layout_shield()


func shield_visible() -> bool:
	return _shield_frame != null and _shield_frame.visible


func _layout_shield() -> void:
	if _shield_frame == null:
		return
	var on := _shield > 0.0 and _shield_cap > 0.0
	_shield_frame.visible = on
	_shield_label.visible = on
	var x := BAR_W + 16.0
	if on:
		_shield_w = clampf(BAR_W * _shield_cap / float(_health_max), 28.0, 96.0)
		_shield_frame.size = Vector2(_shield_w + 8, 22)
		_shield_fill.size = Vector2(_shield_w * clampf(_shield / _shield_cap, 0.0, 1.0), 14)
		x = BAR_W + 10.0 + _shield_w + 8 + 8
	_health_label.position = Vector2(x, -10)
	if on:
		_shield_label.text = "+%d" % roundi(_shield)
		_shield_label.position = Vector2(x + _health_label.get_minimum_size().x + 4, -1)


func set_grenade_charges(c: int, m: int) -> void:
	(_indicators.grenade as CooldownIcon).set_charges(c, m)


func set_ability_charges(c: int, m: int) -> void:
	(_indicators.ability as CooldownIcon).set_charges(c, m)


## Owned Field Cards as tiny chips (initials + rank) under the horde counter. Max 8 shown, then "+n".

func _bind_seen(p: Node) -> void:
	if _seen_bound:
		return
	var inv = p.get("inventory") if p else null
	if inv == null or not inv.has_signal("seen_changed"):
		return
	if not inv.seen_changed.is_connected(_on_seen_changed):
		inv.seen_changed.connect(_on_seen_changed)
	_seen_bound = true


func _on_seen_changed(_item = null) -> void:
	refresh_unseen_hint()


## Compact "TAB !" + count when the stash has unseen loot. Declutter: hide when zero.
func refresh_unseen_hint() -> void:
	if _unseen_chip == null:
		return
	var n := 0
	if _player_ref and is_instance_valid(_player_ref):
		var inv = _player_ref.get("inventory")
		if inv and inv.has_method("unseen_count"):
			n = int(inv.unseen_count())
	_unseen_chip.visible = n > 0
	if _unseen_count_label:
		_unseen_count_label.text = str(n)


func refresh_cards() -> void:
	if _cards_strip == null:
		return
	for c in _cards_strip.get_children():
		c.queue_free()
	var rs := get_node_or_null("/root/RunState")
	if rs == null:
		return
	var owned: Array = rs.owned_cards()
	for i in mini(owned.size(), 8):
		var c: Dictionary = owned[i].duplicate()
		if str(c.get("summary", "")) == "" and rs.has_method("card_def"):
			c["summary"] = str(rs.card_def(str(c.id)).get("summary", ""))
		var chip := PanelContainer.new()
		var st := StyleBoxFlat.new()
		st.bg_color = Color(UIStyle.INK, 0.7)
		st.border_color = UIStyle.TIER_LEGENDARY.lightened(0.15) if str(c.tier) == "legendary" else Color(UIStyle.branch_accent(str(c.branch)), 0.9)
		st.border_width_bottom = 2
		st.content_margin_left = 4
		st.content_margin_right = 4
		chip.add_theme_stylebox_override("panel", st)
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t := UIStyle.initials(str(c.name))
		if int(c.ranks) > 1:
			t += " " + UIStyle.roman(int(c.rank))
		chip.add_child(UIStyle.label(t, 10, UIStyle.BONE_DIM, true))
		var blurb := UIStyle.card_blurb(c)
		if blurb != "":
			chip.tooltip_text = "%s — %s" % [str(c.get("name", "")), blurb]
		_cards_strip.add_child(chip)
	if owned.size() > 8:
		_cards_strip.add_child(UIStyle.label("+%d" % (owned.size() - 8), 10, UIStyle.BONE_DIM, true))


func set_ammo(in_mag: int, reserve: int, reloading: bool) -> void:
	_ammo_label.text = "--" if reloading else str(in_mag)
	_reserve_label.text = ("RELOAD  " if reloading else "") + "/ %d" % reserve
	_ammo_label.add_theme_color_override("font_color", UIStyle.BLOOD.lightened(0.2) if (in_mag == 0 and not reloading) else UIStyle.BONE)


func set_weapon(w: WeaponItem) -> void:
	if w == null:
		_weapon_label.text = ""
		_maker_label.text = ""
		return
	_weapon_label.text = w.display_name.to_upper()
	_weapon_label.add_theme_color_override("font_color", w.rarity_color().lightened(0.25))
	_maker_label.text = "%s  //  %s" % [w.manufacturer.to_upper(), w.type_name().to_upper()]


## Other weapons shown as small dim icons (with their slot number) under the ammo.
func update_weapons(inv: Inventory) -> void:
	for c in _other_weapons.get_children():
		c.queue_free()
	for i in 3:
		var s: String = Inventory.WEAPON_SLOTS[i]
		var w: WeaponItem = inv.equipped.get(s)
		if w == null or s == inv.active_weapon_slot:
			continue
		var box := PanelContainer.new()
		var st := UIStyle.cut_box(Color(0.04, 0.04, 0.035, 0.6), Color(w.rarity_color(), 0.7), 2, 6)
		st.set_content_margin_all(2)
		box.add_theme_stylebox_override("panel", st)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 2)
		box.add_child(h)
		h.add_child(UIStyle.label(str(i + 1), 12, UIStyle.BONE_DIM, true))
		var path: String = ICON_DIR + w.archetype + ".png"
		if ResourceLoader.exists(path):
			var tr := TextureRect.new()
			tr.texture = load(path)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.custom_minimum_size = Vector2(52, 26)
			tr.modulate = Color(1, 1, 1, 0.75)
			h.add_child(tr)
		else:
			h.add_child(UIStyle.label(w.type_name().substr(0, 3).to_upper(), 12, UIStyle.BONE_DIM))
		_other_weapons.add_child(box)
	var aw := inv.get_equipped_weapon()
	_buff_label.text = PerkSystem.status_text(aw).to_upper() if aw else ""


func set_grenade(_grenade_name: String, left: float, total: float) -> void:
	(_indicators.grenade as CooldownIcon).set_state(left, total)


func set_ability(ability_name: String, left: float, total: float) -> void:
	var ic: CooldownIcon = _indicators.ability
	ic.visible = ability_name != ""
	if ability_name != "":
		ic.glyph = ability_name.substr(0, 2).to_upper()
		ic.set_state(left, total)


func set_melee(left: float, total: float) -> void:
	(_indicators.melee as CooldownIcon).set_state(left, total)


func add_loot(item: Item) -> void:
	var gear := item as GearItem
	var c: Color = gear.rarity_color() if gear else item.color
	var row := PanelContainer.new()
	var st := UIStyle.cut_box(Color(0.04, 0.04, 0.035, 0.72), Color(0, 0, 0, 0), 0, 6)
	st.border_width_left = 4
	st.border_color = c
	st.set_content_margin_all(3)
	st.content_margin_left = 10
	row.add_theme_stylebox_override("panel", st)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	row.add_child(v)
	v.add_child(UIStyle.label("+ " + item.display_name.to_upper(), 15, c.lightened(0.25)))
	if gear:
		v.add_child(UIStyle.label("%s %s  //  %s" % [gear.rarity_name(), gear.type_name(), gear.manufacturer], 11, UIStyle.BONE_DIM))
	_loot_feed.add_child(row)
	while _loot_feed.get_child_count() > 5:
		_loot_feed.get_child(0).free()
	var t := row.create_tween()
	t.tween_interval(4.0)
	t.tween_property(row, "modulate:a", 0.0, 1.0)
	t.tween_callback(row.queue_free)


func set_enemies(count: int) -> void:
	_enemies_label.text = "%d  LEFT IN HORDE" % count if count > 0 else ""


func set_round(round_number: int) -> void:
	_round_tally.value = round_number
	_banner.text = "ROUND %d" % round_number if round_number > 0 else "GET READY"
	_banner_sub.text = "THEY'RE COMING" if round_number > 0 else "SCAVENGE.  ARM UP.  SURVIVE."
	for l in [_banner, _banner_sub]:
		l.modulate.a = 1.0
		var t := create_tween()
		t.tween_interval(1.8)
		t.tween_property(l, "modulate:a", 0.0, 0.9)


func set_points(points: int) -> void:
	_points_label.text = "%d" % points


## player.hit_registered -> crosshair hit marker (body X / red headshot X / kill flourish).
func on_hit_registered(target: Node, damage: float, is_headshot: bool, is_kill: bool) -> void:
	_last_hit = {"target": target, "damage": damage, "head": is_headshot, "kill": is_kill}
	_hit_marker.show_hit(is_headshot, is_kill)


## Contextual hint chip under the crosshair, e.g. show_hint("Pick up ...", "interact").
## `key` is an input action name (its first key is looked up) or a literal key label.
## Pass an empty text to hide it.
func show_hint(text: String, key: String = "") -> void:
	_prompt.visible = text != ""
	_prompt_label.text = text.to_upper()
	var label := key
	if InputMap.has_action(key):
		label = ""
		for ev in InputMap.action_get_events(key):
			if ev is InputEventKey:
				var code: int = ev.physical_keycode if ev.physical_keycode != 0 else ev.keycode
				label = OS.get_keycode_string(code)
				break
	_prompt_key.text = label
	_prompt_key.get_parent().visible = label != ""
	_prompt.reset_size()
	var vp := get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1280, 720)
	_prompt.position = Vector2((vp.x - _prompt.size.x) * 0.5, vp.y * 0.5 + 56)


## Back-compat wrapper (text already includes any key).
func set_prompt(text: String) -> void:
	show_hint(text, "")


## Short-lived control hint (shown at match start, fades out).
func set_hint(text: String, duration: float = 9.0) -> void:
	_hint.text = text
	_hint.modulate.a = 1.0
	if text != "":
		var t := create_tween()
		t.tween_interval(duration)
		t.tween_property(_hint, "modulate:a", 0.0, 1.5)


func hide_message() -> void:
	_message.visible = false


func show_message(text: String, color: Color) -> void:
	_message.text = text
	_message.modulate = color
	_message.visible = true
