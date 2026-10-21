extends CanvasLayer
## Scope overlay (Gooey, for G4M3N): black vignette with a round lens cutout, a per-optic reticle (GOOEY_OPTICS §4:
## factory_scope bone mil reticle, Longwatch 6x fine mil-dots, Belfry 8x post + lantern dot), optional breathing sway
## (AdsProfile.overlay_sway) and a ~0.1 s fade. The reticle comes from Armory.optic_profile(arch) on every show.
##
## Shown on player.ads_changed(true) while the weapon in hand wants a scope:
##   AdsProfile.wants_scope_overlay(arch)  (sniper factory scope, Longwatch 6x, Belfry 8x; pending-model optics on the sniper)
## Hidden (viewmodel restored) on ads_changed(false), player.died, player.weapon_changed (swap), tree pause
## (pause menu, character screen, offers) and force_hide() (main.return_to_home).
## While up, the first-person viewmodel is hidden through player.set_viewmodel_hidden() (G4M3N hook) or, if the
## hook isn't there yet, by toggling player.gun.visible directly. The HUD stays (it sits on a higher layer); the
## crosshair ticks are dimmed through hud.set_scoped() and the hit marker stays at the screen centre.
##
##   var so = load("res://scripts/ui/scope_overlay.gd").new(); add_child(so); so.bind(player, hud)

signal scope_shown
signal scope_hidden

const AdsProfileScr := preload("res://scripts/combat/ads_profile.gd")

const FADE_TIME := 0.1
const LENS_RADIUS := 0.44 ## fraction of the viewport's short side
const LENS_SOFT := 0.012 ## edge softness, fraction of short side
const RETICLE_COLOR := Color(0.89, 0.85, 0.74, 0.92) ## UIStyle.BONE
const ArmoryScr := preload("res://scripts/armory/armory.gd")
## Per-optic 2D look (GOOEY_OPTICS §4/§5). Unknown reticle_id draws factory_scope.
const OPTIC_LOOKS := {
	"factory_scope": {"radius": 0.44, "soft": 0.012, "rim": Color(0, 0, 0, 0)},
	"longwatch_mil": {"radius": 0.42, "soft": 0.012, "rim": Color(0, 0, 0, 0)},
	"belfry_post": {"radius": 0.38, "soft": 0.016, "rim": Color(0.431, 0.353, 0.227, 0.4)}, # #6E5A3A at 40%
}
const BELFRY_DOT := Color(1.0, 0.824, 0.478) ## #FFD27A lantern-lit centre dot

@export var sway_enabled: bool = true ## breathing drift of the lens + reticle (visual; hits stay at screen centre)
@export var sway_amount: float = 0.006 ## max drift, fraction of the short side, while moving
@export var sway_still_mult: float = 0.35 ## drift multiplier while standing still
@export var auto_sway: bool = true ## sway_amount follows AdsProfile.overlay_sway(arch) on every show
@export var sway_crouch_mult: float = 0.25 ## drift multiplier while crouched (min with still)

var player: Node
var hud: Node
var active: bool = false ## logically up (fading in or fully shown)
var sway_offset: Vector2 = Vector2.ZERO ## current drift in pixels (tests)
var reticle_id: String = "factory_scope" ## 2D reticle in use (from Armory.optic_profile at show time)
var lens_radius: float = LENS_RADIUS
var optic_profile: Dictionary = {}

var _root: Control
var _lens: ColorRect
var _reticle: Control
var _halo: Control
var _mat: ShaderMaterial
var _tween: Tween
var _t: float = 0.0
var _rearm_t: float = -1.0 ## after a swap: re-show once the swap is done if ADS is still held

const LENS_SHADER := """
shader_type canvas_item;
uniform vec2 view_size = vec2(1920.0, 1080.0);
uniform vec2 center_offset = vec2(0.0);
uniform float radius_frac = 0.44;
uniform float soft_frac = 0.012;
uniform vec4 rim_color = vec4(0.0);
void fragment() {
	vec2 p = UV * view_size;
	vec2 c = view_size * 0.5 + center_offset;
	float s = min(view_size.x, view_size.y);
	float r = radius_frac * s;
	float d = length(p - c);
	float edge = smoothstep(r - soft_frac * s, r, d);            // 0 inside lens, 1 outside
	float inner = smoothstep(r * 0.72, r, d) * 0.55;               // darkening toward the rim inside the lens
	float ring = (1.0 - smoothstep(0.0, soft_frac * s * 0.6, abs(d - r))) * 0.9; // thin dark rim
	float a = clamp(max(max(edge, inner), ring), 0.0, 1.0);
	float rim = (1.0 - smoothstep(0.0, soft_frac * s * 1.4, abs(d - r + soft_frac * s * 1.2))) * rim_color.a; // brass tunnel rim
	COLOR = vec4(mix(vec3(0.0), rim_color.rgb, rim * (1.0 - edge)), max(a, rim));
}
"""


func _init() -> void:
	layer = 0 # under the HUD (layer 1) so ammo / health stay readable; menus sit on 10+
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "ScopeOverlay"


func _ready() -> void:
	_root = Control.new()
	_root.name = "ScopeRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_lens = ColorRect.new()
	_lens.name = "Lens"
	_lens.set_anchors_preset(Control.PRESET_FULL_RECT)
	_lens.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = LENS_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = sh
	_mat.set_shader_parameter("radius_frac", LENS_RADIUS)
	_mat.set_shader_parameter("soft_frac", LENS_SOFT)
	_lens.material = _mat
	_root.add_child(_lens)
	_reticle = Control.new()
	_reticle.name = "Reticle"
	_reticle.set_anchors_preset(Control.PRESET_FULL_RECT)
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.draw.connect(_draw_reticle)
	_root.add_child(_reticle)
	_halo = Control.new() # Belfry's lantern dot: additive halo on its own canvas item
	_halo.name = "Halo"
	_halo.set_anchors_preset(Control.PRESET_FULL_RECT)
	_halo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hm := CanvasItemMaterial.new()
	hm.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_halo.material = hm
	_halo.draw.connect(_draw_halo)
	_root.add_child(_halo)
	_root.modulate.a = 0.0
	visible = false
	get_viewport().size_changed.connect(_on_resized)
	_on_resized()


## Wire to the player (signals) and the HUD (crosshair dimming). Safe to call again with a new player.
func bind(p: Node, h: Node = null) -> void:
	if player and is_instance_valid(player):
		for pair in [["ads_changed", _on_ads_changed], ["died", _on_died], ["weapon_changed", _on_weapon_changed]]:
			if player.has_signal(pair[0]) and player.is_connected(pair[0], pair[1]):
				player.disconnect(pair[0], pair[1])
	player = p
	hud = h
	if p == null:
		return
	if p.has_signal("ads_changed"):
		p.ads_changed.connect(_on_ads_changed)
	if p.has_signal("died"):
		p.died.connect(_on_died)
	if p.has_signal("weapon_changed"):
		p.weapon_changed.connect(_on_weapon_changed)


# ------------------------------------------------------------------ triggers

## True when the weapon in hand should use the scope (sniper family, or an Armory scope_overlay optic).
static func weapon_wants_scope(w) -> bool:
	if w == null or not ("archetype" in w):
		return false
	var arch := str(w.archetype)
	if arch == "":
		return false
	return AdsProfileScr.wants_scope_overlay(arch) # sniper family, or Armory flag "scope_overlay" on the build


func _current_weapon():
	if player == null or not is_instance_valid(player):
		return null
	var inv = player.get("inventory")
	return inv.get_equipped_weapon() if inv and inv.has_method("get_equipped_weapon") else null


func _on_ads_changed(on: bool) -> void:
	_rearm_t = -1.0
	if on and weapon_wants_scope(_current_weapon()) and not get_tree().paused and not _player_dead():
		show_scope()
	else:
		hide_scope()


func _on_died() -> void:
	_rearm_t = -1.0
	hide_scope(true)


func _on_weapon_changed(w = null) -> void:
	hide_scope(true)
	# Hold-to-aim through a swap: no new ads_changed comes, so re-show once the swap time has passed.
	_rearm_t = -1.0
	if w != null and player and bool(player.get("ads_active")) and weapon_wants_scope(w):
		_rearm_t = float(w.swap_time()) if w.has_method("swap_time") else 0.3


func _player_dead() -> bool:
	return player != null and is_instance_valid(player) and bool(player.get("dead"))


# ------------------------------------------------------------------ show / hide

func show_scope() -> void:
	if active:
		return
	apply_optic(_current_weapon())
	active = true
	visible = true
	_set_viewmodel_hidden(true)
	_set_hud_scoped(true)
	_fade_to(1.0)
	scope_shown.emit()


## instant = skip the fade (death, swap, pause, leaving the match).
func hide_scope(instant: bool = false) -> void:
	if not active and not visible:
		return
	var was := active
	active = false
	_set_viewmodel_hidden(false)
	_set_hud_scoped(false)
	if instant or not is_inside_tree():
		_kill_tween()
		_root.modulate.a = 0.0
		visible = false
	else:
		_fade_to(0.0)
	if was:
		scope_hidden.emit()


## main.return_to_home() / anything leaving the match: hide now and restore the viewmodel.
func force_hide() -> void:
	_rearm_t = -1.0
	hide_scope(true)


## The 2D reticle for an optic profile: overlay optics draw their own (Longwatch 6x, Belfry 8x); a sniper optic whose
## model hasn't shipped (fallback) keeps the factory scope picture, like WeaponRig does.
static func reticle_for(p: Dictionary) -> String:
	if p.is_empty() or bool(p.get("fallback", false)) or str(p.get("optic_id", "")) == "":
		return "factory_scope"
	var r := str(p.get("reticle_id", ""))
	return r if OPTIC_LOOKS.has(r) else "factory_scope"


## Pick the reticle, lens and sway for the weapon in hand (called on every show).
func apply_optic(w) -> void:
	var arch := str(w.archetype) if w != null and "archetype" in w else ""
	optic_profile = ArmoryScr.optic_profile(arch) if arch != "" else {}
	set_reticle(reticle_for(optic_profile))
	if arch != "" and auto_sway:
		sway_amount = AdsProfileScr.overlay_sway(arch)


func set_reticle(id: String) -> void:
	reticle_id = id if OPTIC_LOOKS.has(id) else "factory_scope"
	var look: Dictionary = OPTIC_LOOKS[reticle_id]
	lens_radius = float(look.radius)
	if _mat:
		_mat.set_shader_parameter("radius_frac", lens_radius)
		_mat.set_shader_parameter("soft_frac", float(look.soft))
		_mat.set_shader_parameter("rim_color", look.rim)
	if _reticle:
		_reticle.queue_redraw()
	if _halo:
		_halo.queue_redraw()


func _fade_to(a: float) -> void:
	_kill_tween()
	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_tween.tween_property(_root, "modulate:a", a, FADE_TIME * absf(a - _root.modulate.a) if _root.modulate.a != a else 0.001)
	if a <= 0.0:
		_tween.tween_callback(func(): if not active: visible = false)


func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = null


func _set_viewmodel_hidden(h: bool) -> void:
	if player == null or not is_instance_valid(player):
		return
	if player.has_method("set_viewmodel_hidden"):
		player.set_viewmodel_hidden(h)
		return
	var g = player.get("gun")
	if g is Node3D:
		(g as Node3D).visible = (not h) and _current_weapon() != null


func _set_hud_scoped(on: bool) -> void:
	if hud and is_instance_valid(hud) and hud.has_method("set_scoped"):
		hud.set_scoped(on)


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	_t += delta
	if active and get_tree().paused:
		hide_scope(true) # pause menu / character screen / offer chooser
		_rearm_t = 0.0 # back on unpause if ADS is still held (no new ads_changed comes)
		return
	if _rearm_t >= 0.0 and not get_tree().paused:
		_rearm_t -= delta
		if _rearm_t <= 0.0:
			_rearm_t = -1.0
			if player and bool(player.get("ads_active")) and weapon_wants_scope(_current_weapon()) and not _player_dead():
				show_scope()
	if not visible:
		return
	_update_sway(delta)


func _update_sway(_delta: float) -> void:
	var target := Vector2.ZERO
	if sway_enabled:
		var mult := 1.0
		if player and is_instance_valid(player):
			var v = player.get("velocity")
			var spd: float = Vector2(v.x, v.z).length() if v is Vector3 else 0.0
			mult = lerpf(sway_still_mult, 1.0, clampf(spd / 4.0, 0.0, 1.0))
			if player.has_method("is_crouched") and player.is_crouched():
				mult = minf(mult, sway_crouch_mult)
		var s := _short_side() * sway_amount * mult
		target = Vector2(sin(_t * 0.9) * s, sin(_t * 1.7 + 0.6) * s * 0.55) # slow figure-eight breathing drift
	sway_offset = sway_offset.lerp(target, 0.15)
	_mat.set_shader_parameter("center_offset", sway_offset)
	_reticle.queue_redraw()
	_halo.queue_redraw()


func _short_side() -> float:
	var vs := _view_size()
	return minf(vs.x, vs.y)


func _view_size() -> Vector2:
	return get_viewport().get_visible_rect().size if is_inside_tree() else Vector2(1920, 1080)


func _on_resized() -> void:
	if _mat:
		_mat.set_shader_parameter("view_size", _view_size())
	if _reticle:
		_reticle.queue_redraw()


## Lens radius in pixels at the current viewport size (tests / layout).
func lens_radius_px() -> float:
	return lens_radius * _short_side()


func _draw_reticle() -> void:
	match reticle_id:
		"longwatch_mil":
			_draw_longwatch()
		"belfry_post":
			_draw_belfry()
		_:
			_draw_factory()


## Longwatch 6x: the mil-dot family, finer: 1 px lines, 5 ticks each side, hollow centre dot, no posts, no glow.
func _draw_longwatch() -> void:
	var vs := _view_size()
	var s := minf(vs.x, vs.y)
	var r := lens_radius * s
	var c := vs * 0.5 + sway_offset
	var w := maxf(1.0, s / 1400.0)
	var col := RETICLE_COLOR
	var shadow := Color(0, 0, 0, 0.45)
	for dir in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		_reticle.draw_line(c + dir * w * 6.0, c + dir * r, shadow, w + 1.0)
		_reticle.draw_line(c + dir * w * 6.0, c + dir * r, col, w)
	var step := r * 0.11
	for i in range(1, 6):
		var tl := w * (5.0 if i == 5 else 3.0)
		for dir in [Vector2.LEFT, Vector2.RIGHT, Vector2.DOWN, Vector2.UP]:
			var p: Vector2 = c + dir * step * i
			var perp := Vector2(dir.y, dir.x)
			_reticle.draw_circle(p, w * 1.4, col) # mil dot
			if i == 5:
				_reticle.draw_line(p - perp * tl, p + perp * tl, col, w)
	_reticle.draw_arc(c, w * 3.2, 0.0, TAU, 24, shadow, w + 1.0)
	_reticle.draw_arc(c, w * 3.2, 0.0, TAU, 24, col, w) # hollow centre


## Belfry 8x: heavy post from below (6 px tapering to 2 px) with a 4-step range ladder, thin full-width horizontal +
## upper vertical hairline, lantern-lit centre dot (#FFD27A, additive halo ~3x the dot).
func _draw_belfry() -> void:
	var vs := _view_size()
	var s := minf(vs.x, vs.y)
	var r := lens_radius * s
	var c := vs * 0.5 + sway_offset
	var k := s / 1080.0
	var col := RETICLE_COLOR
	var shadow := Color(0, 0, 0, 0.5)
	var hw := maxf(1.0, k)
	_reticle.draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), shadow, hw + 1.0)
	_reticle.draw_line(c + Vector2(-r, 0), c + Vector2(r, 0), col, hw)
	_reticle.draw_line(c + Vector2(0, -r), c + Vector2(0, -hw * 5.0), col, hw)
	var top := c + Vector2(0, r * 0.06)
	var bot := c + Vector2(0, r)
	var w_top := 2.0 * k
	var w_bot := 6.0 * k
	var poly := PackedVector2Array([top + Vector2(-w_top * 0.5, 0), top + Vector2(w_top * 0.5, 0), bot + Vector2(w_bot * 0.5, 0), bot + Vector2(-w_bot * 0.5, 0)])
	_reticle.draw_colored_polygon(poly, col)
	for i in range(1, 5): # range ladder on the post
		var y := r * (0.06 + 0.13 * i)
		var half := (lerpf(w_top, w_bot, y / r) * 0.5) + 5.0 * k + i * 1.5 * k
		_reticle.draw_line(c + Vector2(-half, y), c + Vector2(half, y), col, hw)
	_reticle.draw_circle(c, belfry_dot_px() + 1.0, shadow)
	_reticle.draw_circle(c, belfry_dot_px(), BELFRY_DOT)


func belfry_dot_px() -> float:
	return 2.2 * _short_side() / 1080.0 + 1.0


## Additive halo (radius ~3x the dot); the dot is the only lit element.
func _draw_halo() -> void:
	if reticle_id != "belfry_post":
		return
	var c := _view_size() * 0.5 + sway_offset
	var dot := belfry_dot_px()
	for i in 6:
		var f := float(i + 1) / 6.0
		_halo.draw_circle(c, dot * 3.0 * f, Color(BELFRY_DOT, 0.07))


func _draw_factory() -> void:
	var vs := _view_size()
	var s := minf(vs.x, vs.y)
	var r := lens_radius * s
	var c := vs * 0.5 + sway_offset
	var w := maxf(1.0, s / 900.0) # ~1.2 px at 1080p, scales with resolution
	var post := w * 3.0
	var col := RETICLE_COLOR
	var shadow := Color(0, 0, 0, 0.55)
	# thick outer posts (outer 35% of the radius), thin crosshair through the middle
	var gap := r * 0.65
	for dir in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		if dir != Vector2.UP: # classic: no top post
			_reticle.draw_line(c + dir * gap, c + dir * r, shadow, post + 2.0)
			_reticle.draw_line(c + dir * gap, c + dir * r, col, post)
		_reticle.draw_line(c + dir * w * 4.0, c + dir * gap, shadow, w + 1.5)
		_reticle.draw_line(c + dir * w * 4.0, c + dir * gap, col, w)
	# mil ticks every 6% of the radius, longer every 5th
	var step := r * 0.06
	var n := int(gap / step)
	for i in range(1, n + 1):
		var long := i % 5 == 0
		var tl := (w * 6.0) if long else (w * 3.5)
		for dir in [Vector2.LEFT, Vector2.RIGHT, Vector2.DOWN, Vector2.UP]:
			var p: Vector2 = c + dir * step * i
			var perp := Vector2(dir.y, dir.x)
			_reticle.draw_line(p - perp * tl, p + perp * tl, col, w)
	# centre dot
	_reticle.draw_circle(c, w * 1.6 + 1.0, shadow)
	_reticle.draw_circle(c, w * 1.6, col)
