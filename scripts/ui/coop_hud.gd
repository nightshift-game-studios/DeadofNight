extends Control
## Co-op HUD layer (Gooey), created by hud.gd. Hidden in solo (Net offline / no teammates).
##  - TeammateList (left): name, tint swatch, health bar, DOWNED / SPECTATING / DISCONNECTED tag, teammate bleed-out.
##  - ReviveBar (under the crosshair): "REVIVING JASON" for the reviver, "JASON IS REVIVING YOU" for the downed player.
##  - BleedOut (centre): "DOWNED" + "BLEEDING OUT 0:24" countdown + draining bar while the local player is downed.
##  - RevivePrompt: "HOLD [E] TO REVIVE JASON" near a downed teammate (Net.match_players does the hold itself).
##  - SpendToast: "NOT ENOUGH POINTS (750)" on a refused Net.request_spend / door buy.
## Fed by Netz through scripts/ui/lobby_api.gd names (DESIGN §2.1 / §10.7):
##   Net.party_changed / get_party (names, slots → tints), Net.points_changed(peer, total) / get_points,
##   Net.match_players.life_changed(peer, alive|downed|dead), revive_changed(target, reviver, active) (bar fills over
##   data/net.json downed.revive_time_s; bleed-out = downed.bleed_out_s, paused while a revive is active),
##   all_down, life_of; Net.world.spend_result(ok, amount, reason) + door_refused; Net.round_state_changed;
##   Net.host_left (in a match: notice, then main.return_to_home()).
## Fallback only: Net.game_event("player_downed" | "player_revived" | "revive_progress"). The setters
## (set_party / set_revive / set_local_downed) still work for a push-style hook.

const LAPI := preload("res://scripts/ui/lobby_api.gd")
const ROW_W := 230.0

var net: Node
var local_peer: int = 1
var entries: Array = [] ## teammates only (local filtered out)
var local_downed: bool = false
var bleed_total: float = 0.0
var bleed_left: float = 0.0
var revive_role: String = "" ## "" | "reviver" | "downed"
var revive_progress: float = 0.0
var revive_name: String = ""
var _mate_bleed: Dictionary = {} ## peer -> seconds left (teammates downed)
var _points: Dictionary = {} ## peer -> total (Net.points_changed)
var _hp: Dictionary = {} ## peer -> 0..1 (Net.teammate_health_changed hp / max_hp)
var _life: Dictionary = {} ## peer -> alive | downed | dead (NetPlayers.life_changed)
var revive_active: Dictionary = {} ## active revive: {target, reviver, t}; empty when none
var local_dead: bool = false ## bled out: "BLED OUT  //  BACK NEXT ROUND" until life_changed alive
var round_phase: String = "pre"
var all_down_seen: bool = false
var last_toast: String = ""
var host_left_t: float = -1.0 ## seconds until main.return_to_home() after the host left mid-match
const HOST_LEFT_RETURN_S := 4.0
var _prompt: Label
var _toast: Label
var _toast_t: float = 0.0
var _down_title: Label
var _down_hint: Label
var _bleed_bar: Control

var _list: VBoxContainer
var _revive: VBoxContainer
var _revive_label: Label
var _revive_fill: ColorRect
var _revive_bg: ColorRect
var _bleed: VBoxContainer
var _bleed_label: Label
var _bleed_fill: ColorRect
var _bind_t: float = 0.0
const BAR_W := 260.0
const MATE_BAR := 150.0


func _ready() -> void:
	name = "CoopHud"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list = VBoxContainer.new()
	_list.name = "TeammateList"
	_list.position = Vector2(22, 196)
	_list.add_theme_constant_override("separation", 6)
	_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_list)
	# revive bar: just under the crosshair
	var rc := CenterContainer.new()
	rc.name = "ReviveAnchor"
	_place_centered(rc, Vector2(BAR_W + 120, 40), Vector2(0, 74))
	rc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rc)
	_revive = VBoxContainer.new()
	_revive.name = "ReviveBar"
	_revive.add_theme_constant_override("separation", 3)
	_revive.visible = false
	rc.add_child(_revive)
	_revive_label = UIStyle.label("", 14, UIStyle.BONE, true, 4)
	_revive_label.name = "ReviveLabel"
	_revive_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_revive.add_child(_revive_label)
	var rbar := Control.new()
	rbar.custom_minimum_size = Vector2(BAR_W, 12)
	_revive.add_child(rbar)
	_revive_bg = ColorRect.new()
	_revive_bg.color = Color(0, 0, 0, 0.65)
	_revive_bg.size = Vector2(BAR_W, 12)
	rbar.add_child(_revive_bg)
	_revive_fill = ColorRect.new()
	_revive_fill.name = "ReviveFill"
	_revive_fill.color = UIStyle.OLIVE.lightened(0.35)
	_revive_fill.position = Vector2(2, 2)
	_revive_fill.size = Vector2(0, 8)
	rbar.add_child(_revive_fill)
	# bleed-out: centre, above the crosshair
	var bc := CenterContainer.new()
	bc.name = "BleedAnchor"
	_place_centered(bc, Vector2(420, 120), Vector2(0, -150))
	bc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bc)
	_bleed = VBoxContainer.new()
	_bleed.name = "BleedOut"
	_bleed.add_theme_constant_override("separation", 2)
	_bleed.visible = false
	bc.add_child(_bleed)
	var dl := UIStyle.label("DOWNED", 46, UIStyle.BLOOD.lightened(0.25), true, 6)
	dl.name = "DownedTitle"
	_down_title = dl
	dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bleed.add_child(dl)
	_bleed_label = UIStyle.label("BLEEDING OUT  0:30", 18, UIStyle.BONE, true, 4)
	_bleed_label.name = "BleedLabel"
	_bleed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bleed.add_child(_bleed_label)
	var bbar := Control.new()
	bbar.custom_minimum_size = Vector2(BAR_W, 10)
	bbar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_bleed.add_child(bbar)
	_bleed_bar = bbar
	var bbg := ColorRect.new()
	bbg.color = Color(0, 0, 0, 0.65)
	bbg.size = Vector2(BAR_W, 10)
	bbar.add_child(bbg)
	_bleed_fill = ColorRect.new()
	_bleed_fill.name = "BleedFill"
	_bleed_fill.color = UIStyle.BLOOD.lightened(0.15)
	_bleed_fill.position = Vector2(2, 2)
	_bleed_fill.size = Vector2(BAR_W - 4, 6)
	bbar.add_child(_bleed_fill)
	var hint := UIStyle.label("Hang on. A teammate can revive you.", 12, UIStyle.BONE_DIM, false, 3)
	hint.name = "DownedHint"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bleed.add_child(hint)
	_down_hint = hint
	# revive prompt: under the revive bar
	var pc := CenterContainer.new()
	pc.name = "PromptAnchor"
	_place_centered(pc, Vector2(520, 30), Vector2(0, 112))
	add_child(pc)
	_prompt = UIStyle.label("", 15, UIStyle.BONE, true, 4)
	_prompt.name = "RevivePrompt"
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.visible = false
	pc.add_child(_prompt)
	# spend / door refusal toast: above the bottom-centre ammo row
	var tc := CenterContainer.new()
	tc.name = "ToastAnchor"
	tc.anchor_left = 0.5
	tc.anchor_right = 0.5
	tc.anchor_top = 1.0
	tc.anchor_bottom = 1.0
	tc.offset_left = -260
	tc.offset_right = 260
	tc.offset_top = -170
	tc.offset_bottom = -140
	add_child(tc)
	_toast = UIStyle.label("", 14, UIStyle.BAD, true, 4)
	_toast.name = "SpendToast"
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	tc.add_child(_toast)
	ignore_mouse(self)
	_update_visibility()
	_try_bind()


## HUD rule (input_test): no HUD Control may eat mouse input.
static func ignore_mouse(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children(true): # include internal (RichTextLabel scrollbars)
		ignore_mouse(c)


## Anchors c at the screen centre, offset by `off` (centre of c), so it follows any window size.
static func _place_centered(c: Control, sz: Vector2, off: Vector2) -> void:
	c.anchor_left = 0.5
	c.anchor_right = 0.5
	c.anchor_top = 0.5
	c.anchor_bottom = 0.5
	c.offset_left = off.x - sz.x * 0.5
	c.offset_right = off.x + sz.x * 0.5
	c.offset_top = off.y - sz.y * 0.5
	c.offset_bottom = off.y + sz.y * 0.5


# ------------------------------------------------------------------ binding

func _try_bind() -> void:
	if net and is_instance_valid(net):
		return
	var n := LAPI.existing(self)
	if n:
		bind(n)


func bind(n: Node) -> void:
	net = n
	LAPI.sig(n, "party_changed", _on_party)
	LAPI.sig(n, "state_changed", _on_state)
	LAPI.sig(n, "points_changed", _on_points)
	LAPI.sig(n, "teammate_health_changed", _on_teammate_hp)
	LAPI.sig(n, "round_state_changed", _on_round_state)
	LAPI.sig(n, "host_left", _on_host_left)
	LAPI.sig(n, "returned_to_lobby", _on_match_reset)
	LAPI.sig(n, "game_event", _on_game_event) # fallback route
	LAPI.psig(n, "life_changed", _on_life)
	LAPI.psig(n, "revive_changed", _on_revive_changed)
	LAPI.psig(n, "all_down", _on_all_down)
	LAPI.wsig(n, "spend_result", _on_spend_result)
	LAPI.wsig(n, "door_refused", _on_door_refused)
	_on_party(LAPI.call_api(n, "get_party") if LAPI.call_api(n, "get_party") is Array else [])
	var pl := LAPI.players_of(n)
	var lf = pl.get("life") if pl else null
	if lf is Dictionary: # bound mid-match (HUD rebuilt): catch up on downed / dead teammates
		for peer in lf:
			if str(lf[peer]) != LAPI.LIFE_ALIVE:
				_on_life(int(peer), str(lf[peer]))


func networked() -> bool:
	return net != null and is_instance_valid(net) and bool(LAPI.call_api(net, "is_networked"))


func _on_state(_s: int = 0) -> void:
	if not networked() and _toast_t > 0.0:
		_toast_t = 0.0
		_toast.visible = false
	_on_party(LAPI.call_api(net, "get_party") if net else [])


func _on_party(p: Array = []) -> void:
	if net:
		local_peer = int(LAPI.call_api(net, "local_peer_id"))
	set_party(p, local_peer)


func _name_of(peer: int) -> String:
	for e in entries:
		if int(e.get(LAPI.K_PEER, -1)) == peer:
			return str(e.get(LAPI.K_NAME, ""))
	return str(LAPI.call_api(net, "get_player_name", [peer])) if net else ""


## DESIGN §2.3 route: Net.game_event("player_downed" | "player_revived" | "revive_progress", peer, data).
## data: bleed_out_s (downed), reviver_peer + progress (revive_progress). Same handlers as the EXT signals.
func _on_game_event(event_id: StringName, peer_id: int, data: Dictionary) -> void:
	match str(event_id):
		LAPI.EV_DOWNED:
			_on_downed(peer_id, float(data.get(LAPI.K_BLEED, LAPI.BLEED_FALLBACK_S)))
		LAPI.EV_REVIVED:
			_on_revived(peer_id)
		LAPI.EV_REVIVE_PROGRESS:
			_on_revive_progress(int(data.get("reviver_peer", -1)), peer_id, float(data.get("progress", -1.0)))


func _on_downed(peer: int, bleed_s: float) -> void:
	_life[peer] = LAPI.LIFE_DOWNED
	if peer == local_peer:
		set_local_downed(true, bleed_s)
	else:
		_mate_bleed[peer] = bleed_s
		_set_mate_state(peer, LAPI.P_DOWNED)
		_rebuild()


func _on_revived(peer: int) -> void:
	_life[peer] = LAPI.LIFE_ALIVE
	if peer == local_peer:
		set_local_downed(false)
		_set_local_dead(false)
	_mate_bleed.erase(peer)
	_set_mate_state(peer, LAPI.P_ALIVE)
	if revive_role != "" or not revive_active.is_empty():
		revive_active = {}
		set_revive(-1.0)
	_rebuild()


## NetPlayers.life_changed(peer, "alive" | "downed" | "dead"), host-authoritative, every peer.
func _on_life(peer: int, st: String) -> void:
	match st:
		LAPI.LIFE_DOWNED:
			_on_downed(peer, LAPI.bleed_out_s(net))
		LAPI.LIFE_ALIVE:
			_on_revived(peer)
		LAPI.LIFE_DEAD:
			_life[peer] = LAPI.LIFE_DEAD
			_mate_bleed.erase(peer)
			if not revive_active.is_empty() and int(revive_active.target) == peer:
				revive_active = {}
				set_revive(-1.0)
			if peer == local_peer:
				set_local_downed(false)
				_set_local_dead(true)
			else:
				_set_mate_state(peer, LAPI.P_DEAD)
				_rebuild()


## NetPlayers.revive_changed(target, reviver, active): the host only says start / stop, so the bar fills locally
## over downed.revive_time_s (host: revive at progress >= revive_time_s; walking out of range resets it).
func _on_revive_changed(target: int, reviver: int, active: bool) -> void:
	if active:
		revive_active = {"target": target, "reviver": reviver, "t": 0.0}
		_apply_revive_bar()
	else:
		if not revive_active.is_empty() and int(revive_active.target) == target:
			revive_active = {}
		if reviver == local_peer or target == local_peer:
			set_revive(-1.0)
	_rebuild()


func _apply_revive_bar() -> void:
	if revive_active.is_empty():
		return
	var p := clampf(float(revive_active.t) / LAPI.revive_time_s(net), 0.0, 0.999)
	var tg := int(revive_active.target)
	var rv := int(revive_active.reviver)
	if rv == local_peer:
		set_revive(p, "reviver", _name_of(tg))
	elif tg == local_peer:
		set_revive(p, "downed", _name_of(rv))


## Everyone is down: Net calls main._on_player_died() (the real game over screen). Clear the co-op overlays.
func _on_all_down() -> void:
	all_down_seen = true
	revive_active = {}
	set_revive(-1.0)
	set_local_downed(false)
	_set_local_dead(false)
	_prompt.visible = false
	_update_visibility()


func _set_local_dead(on: bool) -> void:
	local_dead = on
	if on:
		_down_title.text = "BLED OUT"
		_bleed_label.text = "BACK NEXT ROUND" if bool(LAPI.net_value(net, "downed.respawn_next_round", true)) else "SPECTATING"
		_bleed_label.add_theme_color_override("font_color", UIStyle.BONE)
		_bleed_bar.visible = false
		_down_hint.text = "Your crew can still win the round."
		_bleed.visible = true
	else:
		_down_title.text = "DOWNED"
		_bleed_bar.visible = true
		_down_hint.text = "Hang on. A teammate can revive you."
		_bleed.visible = local_downed
	_update_visibility()


## Netz: ~5 Hz on change, every peer, local too; party_changed isn't re-emitted for HP.
func _on_teammate_hp(peer: int, hp: int, max_hp: int, hp_frac: float = -1.0) -> void:
	var f := clampf(hp_frac, 0.0, 1.0) if hp_frac >= 0.0 else (clampf(float(hp) / float(max_hp), 0.0, 1.0) if max_hp > 0 else 0.0)
	if is_equal_approx(float(_hp.get(peer, -1.0)), f):
		return
	_hp[peer] = f
	if peer != local_peer:
		_set_row_hp(peer, f)


func _set_row_hp(peer: int, f: float) -> void:
	var row := mate_row(peer)
	var fill := row.find_child("HpFill", true, false) as ColorRect if row else null
	if fill == null or (float(row.get_meta("hp", 1.0)) < 0.3) != (f < 0.3): # low-HP colour flips: rebuild
		_rebuild()
		return
	if str(row.get_meta("state", LAPI.P_ALIVE)) in [LAPI.P_SPECTATING, LAPI.P_DISCONNECTED, LAPI.P_DEAD]:
		f = 0.0
	fill.size.x = (MATE_BAR - 2.0) * f
	row.set_meta("hp", f)


func hp_of(peer: int) -> float:
	return float(_hp.get(peer, -1.0))


func _on_points(peer: int, total: int) -> void:
	_points[peer] = total
	if peer != local_peer:
		_rebuild()


func points_of(peer: int):
	if _points.has(peer):
		return int(_points[peer])
	return null


func _on_round_state(_n: int, phase: String, _enemies: int) -> void:
	round_phase = phase


func _on_spend_result(ok: bool, amount: int, reason: String) -> void:
	if not ok:
		show_toast("NOT ENOUGH POINTS  (%d)" % amount if amount > 0 else "CAN'T BUY THAT  (%s)" % reason)


func _on_door_refused(_door_id: String, reason: String) -> void:
	match reason:
		"points":
			show_toast("NOT ENOUGH POINTS")
		"already_open":
			pass
		_:
			show_toast("CAN'T OPEN THAT DOOR")


func show_toast(text: String, secs: float = 2.5) -> void:
	last_toast = text
	_toast.text = text
	_toast.visible = true
	_toast_t = secs
	visible = true


## Host left mid-match (no host migration): notice, then back home after HOST_LEFT_RETURN_S.
func _on_host_left() -> void:
	var sc := get_tree().current_scene if is_inside_tree() else null
	if sc == null or not sc.has_method("return_to_home"):
		return # lobby / home: lobby_menu shows its own notice
	_down_title.text = "HOST LEFT"
	_bleed_label.text = "RETURNING HOME…"
	_bleed_label.add_theme_color_override("font_color", UIStyle.BONE)
	_bleed_bar.visible = false
	_down_hint.text = "The match ended when the host left. Your XP and stash are kept."
	_bleed.visible = true
	visible = true
	host_left_t = HOST_LEFT_RETURN_S


func _on_match_reset() -> void:
	_life.clear()
	_points.clear()
	_hp.clear()
	_mate_bleed.clear()
	revive_active = {}
	all_down_seen = false
	set_revive(-1.0)
	set_local_downed(false)
	_set_local_dead(false)
	_rebuild()


## "HOLD [E] TO REVIVE JASON" while near a downed teammate (Net.match_players.avatars + the local player).
func revive_prompt_text() -> String:
	var pl := LAPI.players_of(net)
	if pl == null or local_downed or local_dead or all_down_seen:
		return ""
	var me := get_tree().get_first_node_in_group("player") as Node3D if is_inside_tree() else null
	var av = pl.get("avatars")
	if me == null or not (av is Dictionary):
		return ""
	var best := -1
	var bd := INF
	for id in av:
		var a = av[id]
		if not (a is Node3D) or not is_instance_valid(a) or str(_life.get(int(id), "")) != LAPI.LIFE_DOWNED:
			continue
		var d: float = (a as Node3D).global_position.distance_to(me.global_position)
		if d <= LAPI.revive_range_m(net) and d < bd:
			bd = d
			best = int(id)
	if best < 0:
		return ""
	if not revive_active.is_empty() and int(revive_active.target) == best and int(revive_active.reviver) == local_peer:
		return ""
	return "HOLD [%s] TO REVIVE %s" % [_interact_key(), _name_of(best).to_upper()]


static func _interact_key() -> String:
	if InputMap.has_action("interact"):
		for ev in InputMap.action_get_events("interact"):
			if ev is InputEventKey:
				var k := (ev as InputEventKey)
				var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
				return OS.get_keycode_string(code)
	return "E"


## Local copy only (the event may arrive before the next party_changed).
func _set_mate_state(peer: int, st: String) -> void:
	for e in entries:
		if int(e.get(LAPI.K_PEER, -1)) == peer:
			e[LAPI.K_STATE] = st


func _on_revive_progress(reviver: int, downed: int, p: float) -> void:
	if reviver == local_peer:
		set_revive(p, "reviver", _name_of(downed))
	elif downed == local_peer:
		set_revive(p, "downed", _name_of(reviver))


# ------------------------------------------------------------------ setters (public)

## entries: Net.get_party() shape; the local peer is skipped. Empty → list hidden.
func set_party(p: Array, local_id: int = -1) -> void:
	if local_id >= 0:
		local_peer = local_id
	entries = []
	var slot := 0
	for e in p:
		var d: Dictionary = e.duplicate()
		d["_slot"] = slot
		slot += 1
		if int(d.get(LAPI.K_PEER, -1)) == local_peer:
			continue
		if d.has(LAPI.K_BLEED) and str(d.get(LAPI.K_STATE, "")) == LAPI.P_DOWNED and not _mate_bleed.has(int(d[LAPI.K_PEER])):
			_mate_bleed[int(d[LAPI.K_PEER])] = float(d[LAPI.K_BLEED])
		if str(d.get(LAPI.K_STATE, "")) != LAPI.P_DOWNED:
			_mate_bleed.erase(int(d.get(LAPI.K_PEER, -1)))
		entries.append(d)
	_rebuild()


func tint_for_name(n: String):
	for e in entries:
		if str(e.get(LAPI.K_NAME, "")).to_lower() == n.to_lower():
			return LAPI.tint_of(e, int(e.get("_slot", 0)))
	return null


## progress 0..1 shows the bar; <0 or >=1 hides it. role "reviver" | "downed".
func set_revive(progress: float, role: String = "", other_name: String = "") -> void:
	if progress < 0.0 or progress >= 1.0:
		revive_role = ""
		revive_progress = 0.0
		_revive.visible = false
		return
	revive_role = role
	revive_progress = progress
	revive_name = other_name
	_revive_label.text = ("REVIVING %s" % other_name.to_upper()) if role == "reviver" else ("%s IS REVIVING YOU" % other_name.to_upper())
	_revive_fill.size.x = (BAR_W - 4.0) * clampf(progress, 0.0, 1.0)
	_revive.visible = true
	_update_visibility()


func set_local_downed(on: bool, bleed_s: float = 30.0) -> void:
	local_downed = on
	bleed_total = maxf(bleed_s, 0.01)
	bleed_left = bleed_s if on else 0.0
	_bleed.visible = on
	_refresh_bleed()
	_update_visibility()


static func format_bleed(s: float) -> String:
	var n := maxi(int(ceil(s)), 0)
	return "BLEEDING OUT  %d:%02d" % [n / 60, n % 60]


func _refresh_bleed() -> void:
	_bleed_label.text = format_bleed(bleed_left)
	_bleed_fill.size.x = (BAR_W - 4.0) * clampf(bleed_left / bleed_total, 0.0, 1.0) if bleed_total > 0.0 else 0.0
	var low := bleed_left < 10.0
	_bleed_label.add_theme_color_override("font_color", UIStyle.BAD if low else UIStyle.BONE)


func _update_visibility() -> void:
	var on := (networked() and (not entries.is_empty() or local_downed or local_dead or revive_role != "")) or host_left_t >= 0.0 or (_toast_t > 0.0 and networked())
	visible = on
	_list.visible = on and not entries.is_empty()


func _rebuild() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for e in entries:
		var r := _mate_row(e)
		ignore_mouse(r)
		_list.add_child(r)
	_update_visibility()


func _mate_row(e: Dictionary) -> PanelContainer:
	var peer := int(e.get(LAPI.K_PEER, -1))
	var st := str(e.get(LAPI.K_STATE, LAPI.P_ALIVE))
	if LAPI.is_alive_state(st):
		st = LAPI.P_ALIVE # Netz: lobby | loading | in_match
	var lf := str(_life.get(peer, ""))
	if lf == LAPI.LIFE_DOWNED:
		st = LAPI.P_DOWNED
	elif lf == LAPI.LIFE_DEAD:
		st = LAPI.P_DEAD
	elif lf == LAPI.LIFE_ALIVE and st in [LAPI.P_DOWNED, LAPI.P_DEAD]:
		st = LAPI.P_ALIVE
	var tint := LAPI.tint_of(e, int(e.get("_slot", 0)))
	var row := PanelContainer.new()
	row.name = "Mate_%d" % peer
	row.set_meta("state", st)
	row.set_meta("tint", tint)
	var border := UIStyle.BLOOD.lightened(0.2) if st == LAPI.P_DOWNED else Color(UIStyle.BONE_DIM, 0.6)
	var bs := UIStyle.cut_box(Color(UIStyle.INK, 0.78), border, 2, 8)
	bs.set_content_margin_all(5)
	bs.content_margin_left = 6
	row.add_theme_stylebox_override("panel", bs)
	row.custom_minimum_size.x = ROW_W
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 7)
	row.add_child(h)
	var sw := ColorRect.new()
	sw.name = "Swatch"
	sw.color = tint
	sw.custom_minimum_size = Vector2(6, 30)
	h.add_child(sw)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	h.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	v.add_child(top)
	var nl := UIStyle.label(str(e.get(LAPI.K_NAME, "?")).to_upper(), 13, tint.lightened(0.1) if st == LAPI.P_ALIVE else UIStyle.BONE_DIM, true, 3)
	nl.name = "MateName"
	top.add_child(nl)
	if st != LAPI.P_ALIVE:
		var being := not revive_active.is_empty() and int(revive_active.target) == peer
		var tag_txt := "BLED OUT" if st == LAPI.P_DEAD else ("REVIVING" if being else st.to_upper())
		var tag := UIStyle.label(tag_txt, 11, UIStyle.BAD if st == LAPI.P_DOWNED and not being else (UIStyle.OLIVE.lightened(0.4) if being else UIStyle.BONE_DIM), true, 3)
		tag.name = "MateState"
		top.add_child(tag)
	if st == LAPI.P_DOWNED and _mate_bleed.has(peer):
		var bt := UIStyle.label("%d" % ceili(float(_mate_bleed[peer])), 11, UIStyle.BAD, true, 3)
		bt.name = "MateBleed"
		top.add_child(bt)
	var pts = points_of(peer)
	if pts == null:
		pts = e.get(LAPI.K_POINTS, LAPI.call_api(net, "get_points", [peer]) if net and networked() else null)
	if pts != null:
		var pl := UIStyle.label("%d" % int(pts), 11, UIStyle.BONE_DIM, true, 3)
		pl.name = "MatePoints"
		top.add_child(pl)
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(MATE_BAR, 7)
	v.add_child(bar)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.size = Vector2(MATE_BAR, 7)
	bar.add_child(bg)
	var hp: float = float(_hp[peer]) if _hp.has(peer) else LAPI.hp_fraction(e)
	if st in [LAPI.P_SPECTATING, LAPI.P_DISCONNECTED, LAPI.P_DEAD]:
		hp = 0.0
	var fill := ColorRect.new()
	fill.name = "HpFill"
	row.set_meta("hp", hp)
	fill.position = Vector2(1, 1)
	fill.size = Vector2((MATE_BAR - 2.0) * hp, 5)
	fill.color = UIStyle.BLOOD.lightened(0.2) if st == LAPI.P_DOWNED or hp < 0.3 else tint.lerp(UIStyle.BONE, 0.2)
	bar.add_child(fill)
	return row


func mate_row(peer: int) -> Node:
	return _list.get_node_or_null("Mate_%d" % peer)


func _process(delta: float) -> void:
	if net == null or not is_instance_valid(net):
		_bind_t -= delta
		if _bind_t <= 0.0:
			_bind_t = 0.5
			_try_bind()
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast.visible = false
			_update_visibility()
	if host_left_t >= 0.0:
		host_left_t -= delta
		if host_left_t < 0.0:
			var sc := get_tree().current_scene if is_inside_tree() else null
			if sc and sc.has_method("return_to_home"):
				sc.return_to_home()
	var reviving_target := int(revive_active.target) if not revive_active.is_empty() else 0
	if not revive_active.is_empty():
		revive_active.t = float(revive_active.t) + delta
		_apply_revive_bar()
	if local_downed and bleed_left > 0.0 and reviving_target != local_peer: # bleed-out pauses while being revived
		bleed_left = maxf(bleed_left - delta, 0.0)
		_refresh_bleed()
	if is_inside_tree() and networked():
		var pt := revive_prompt_text()
		_prompt.text = pt
		_prompt.visible = pt != ""
	var changed := false
	for k in _mate_bleed.keys():
		if int(k) == reviving_target:
			continue
		var before := ceili(float(_mate_bleed[k]))
		_mate_bleed[k] = maxf(float(_mate_bleed[k]) - delta, 0.0)
		if ceili(float(_mate_bleed[k])) != before:
			changed = true
	if changed:
		_rebuild()
