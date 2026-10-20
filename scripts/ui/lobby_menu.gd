extends MenuBase
## Co-op front end (Gooey): Play → SOLO | CO-OP → (CO-OP) HOST | JOIN → join box or party LOBBY (DESIGN §2).
## Built against Netz's Net API (/workspace/netz/DESIGN.md §2.1) through scripts/ui/lobby_api.gd (factory + names;
## stub when scripts/net/net.gd is absent). Pages: "mode", "coop", "join", "lobby".
##
## Signals for the host screen (home_menu):
##   solo_chosen                         → existing map picker flow
##   match_start_requested(map, diff)    → Net.match_starting arrived: home selects map + difficulty, loads main.tscn
## Node names used by tests are listed in G4M3N_HOOKS.md (Mode_*, JoinInput, ConnectBtn, PartySlot_<i>, StartBtn, ...).

signal solo_chosen
signal match_start_requested(map_id: String, difficulty_id: String)

const LAPI := preload("res://scripts/ui/lobby_api.gd")
const MapPickerScript := preload("res://scripts/ui/map_picker.gd")
const NamePromptScript := preload("res://scripts/ui/name_prompt.gd")
const TOAST_SECS := 3.5
const KICK_ARM_S := 3.0
var _kick_armed: Dictionary = {} ## peer_id -> true while its KICK? confirm is showing
const UPNP_GIVE_UP_S := 12.0 ## Netz upnp.discover_ms is 2 s; past this the status flips to failed + help

var net: Node
var page: String = "mode"
var last_copied: String = ""
var last_notice: String = ""
var last_toast: String = ""
var join_code: String = ""
var share_address: String = ""
var upnp_state: String = "" ## "" | "trying" | "open" | "failed"
var upnp_message: String = ""
var connecting: bool = false
var name_prompt: Node = null

var _pages: Dictionary = {} ## id -> Control
var _title: Label
var _sub: Label
var _stub_tag: PanelContainer
var _mode_btns: Dictionary = {} ## solo / coop (page "mode") + host / join (page "coop")
var _coop_back: Button
# join
var _join_input: LineEdit
var _join_error: Label
var _connect_btn: Button
var _join_back: Button
var _connecting_box: Control
var _connecting_label: Label
var _spinner: Control
# lobby
var _slots: Array = [] ## PanelContainer x4
var _host_panel: PanelContainer
var _code_label: Label
var _copy_btn: Button
var _copy_feedback: Label
var _share_label: Label
var _upnp_label: Label
var _upnp_help: Label
var _upnp_spin: Control
var _map_btn: Button
var _map_ro: Label
var _diff_row: HBoxContainer
var _diff_btns: Dictionary = {}
var _diff_ro: Label
var _member_note: Label
var _ready_btn: Button
var _start_btn: Button
var _start_reason: Label
var _leave_btn: Button
var _map_picker: MenuBase
var _notice_overlay: Control
var _notice_title: Label
var _notice_text: Label
var _notice_ok: Button
var _toast: Label
var _toast_t: float = 0.0
var _spin_t: float = 0.0
var _pending_mode: String = ""
var _upnp_gen: int = 0


func _init() -> void:
	super._init()
	layer = 12
	toggle_action = ""


func _ready() -> void:
	super._ready()
	panel.custom_minimum_size = Vector2(1080, 600)
	if net == null:
		net = LAPI.create(self)
	_wire_net()
	_build()
	show_page("mode")


# ------------------------------------------------------------------ API wiring

func set_net(n: Node) -> void:
	_unwire_net()
	net = n
	_wire_net()


func _wire_net() -> void:
	if net == null:
		return
	LAPI.sig(net, "hosting_started", _on_hosting_started)
	LAPI.sig(net, "upnp_result", _on_upnp_result)
	LAPI.sig(net, "upnp_started", _on_upnp_started)
	LAPI.sig(net, "connected_to_party", _on_connected)
	LAPI.sig(net, "connection_failed", _on_connection_failed)
	LAPI.sig(net, "party_changed", _on_party_changed)
	LAPI.sig(net, "peer_joined", _on_peer_joined)
	LAPI.sig(net, "peer_left", _on_peer_left)
	LAPI.sig(net, "lobby_settings_changed", _on_lobby_settings)
	LAPI.sig(net, "match_starting", _on_match_starting)
	LAPI.sig(net, "host_left", _on_host_left)
	LAPI.sig(net, "disconnected", _on_disconnected)
	LAPI.sig(net, "peer_rejected", _on_peer_rejected)
	LAPI.sig(net, "returned_to_lobby", _on_returned_to_lobby)


func _unwire_net() -> void:
	if net == null:
		return
	for pair in [["hosting_started", _on_hosting_started], ["upnp_result", _on_upnp_result], ["upnp_started", _on_upnp_started],
			["connected_to_party", _on_connected], ["connection_failed", _on_connection_failed],
			["party_changed", _on_party_changed], ["peer_joined", _on_peer_joined], ["peer_left", _on_peer_left],
			["lobby_settings_changed", _on_lobby_settings], ["match_starting", _on_match_starting],
			["host_left", _on_host_left], ["disconnected", _on_disconnected],
			["peer_rejected", _on_peer_rejected], ["returned_to_lobby", _on_returned_to_lobby]]:
		LAPI.unsig(net, pair[0], pair[1])


func _api(key: String, args: Array = []):
	return LAPI.call_api(net, key, args)


func is_leader() -> bool:
	return bool(_api("is_leader", [int(_api("local_peer_id"))]))


func party() -> Array:
	var p = _api("get_party")
	return p if p is Array else []


func max_players() -> int:
	var v = _api("max_players")
	return int(v) if v != null else int(LAPI.prop(net, "MAX_PLAYERS", LAPI.MAX_PLAYERS_FALLBACK))


var port_override: int = 0 ## tests / LAN parties on another port; 0 = Net.port() (data/net.json default_port)


func port() -> int:
	if port_override > 0:
		return port_override
	var v = _api("port")
	return int(v) if v != null else int(LAPI.prop(net, "DEFAULT_PORT", LAPI.DEFAULT_PORT_FALLBACK))


# ------------------------------------------------------------------ build

func _build() -> void:
	clear_content()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	content.add_child(head)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override("separation", -2)
	head.add_child(titles)
	_title = UIStyle.label("PLAY", 28, UIStyle.BONE, true)
	_title.name = "LobbyTitle"
	titles.add_child(_title)
	_sub = UIStyle.label("", 12, UIStyle.RUST.lightened(0.2), true)
	_sub.name = "LobbySub"
	titles.add_child(_sub)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_stub_tag = PanelContainer.new()
	_stub_tag.name = "StubTag"
	var sts := UIStyle.cut_box(Color(UIStyle.INK, 0.9), UIStyle.BONE_DIM, 1, 6)
	sts.set_content_margin_all(4)
	_stub_tag.add_theme_stylebox_override("panel", sts)
	_stub_tag.add_child(UIStyle.label("OFFLINE PREVIEW  //  NET NOT INSTALLED", 10, UIStyle.BONE_DIM, true))
	_stub_tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_stub_tag.visible = LAPI.is_stub(net)
	head.add_child(_stub_tag)
	var line := ColorRect.new()
	line.color = Color(UIStyle.RUST, 0.7)
	line.custom_minimum_size = Vector2(0, 3)
	content.add_child(line)
	var stack := Control.new()
	stack.name = "Pages"
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.custom_minimum_size = Vector2(1040, 470)
	content.add_child(stack)
	for id in ["mode", "coop", "join", "lobby"]:
		var pg := VBoxContainer.new()
		pg.name = "Page_" + id
		pg.set_anchors_preset(Control.PRESET_FULL_RECT)
		pg.add_theme_constant_override("separation", 12)
		pg.visible = false
		stack.add_child(pg)
		_pages[id] = pg
	_build_mode(_pages.mode)
	_build_coop(_pages.coop)
	_build_join(_pages.join)
	_build_lobby(_pages.lobby)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	content.add_child(foot)
	foot.add_child(UIStyle.key_cap("←↑→↓", 11))
	foot.add_child(UIStyle.label("NAV", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ENTER", 11))
	foot.add_child(UIStyle.label("SELECT", 11, UIStyle.BONE_DIM))
	foot.add_child(UIStyle.key_cap("ESC", 11))
	var back_l := UIStyle.label("BACK / LEAVE", 11, UIStyle.BONE_DIM)
	back_l.name = "FootBack"
	foot.add_child(back_l)
	var fsp := Control.new()
	fsp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fsp)
	_toast = UIStyle.label("", 12, UIStyle.BONE, true)
	_toast.name = "LobbyToast"
	_toast.visible = false
	foot.add_child(_toast)
	_build_notice()
	_map_picker = MapPickerScript.new()
	_map_picker.name = "LobbyMapPicker"
	_map_picker.home_mode = true
	_map_picker.dry_run = true
	_map_picker.pick_label = "PICK %s"
	_map_picker.gate_text = "PARTY MAP // LEADER PICKS"
	_map_picker.main = self
	add_child(_map_picker)
	_map_picker.layer = 14
	_map_picker.map_chosen.connect(_on_map_picked)


func _panel(border: Color = UIStyle.BONE_DIM, bw: int = 2, cut: int = 14) -> PanelContainer:
	var p := PanelContainer.new()
	var st := UIStyle.cut_box(Color(0.06, 0.06, 0.05, 0.95), border, bw, cut)
	st.set_content_margin_all(12)
	p.add_theme_stylebox_override("panel", st)
	return p


func _btn(text: String, cb: Callable, size_px := Vector2(0, 42), fs: int = 15) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = size_px
	b.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	b.add_theme_font_size_override("font_size", fs)
	b.add_theme_color_override("font_color", UIStyle.BONE)
	b.add_theme_color_override("font_focus_color", UIStyle.INK)
	b.add_theme_color_override("font_hover_color", UIStyle.BONE)
	b.add_theme_color_override("font_disabled_color", Color(0.55, 0.52, 0.45))
	b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.92), UIStyle.BONE_DIM, 2, 10))
	b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.16, 0.12, 0.08, 0.96), UIStyle.RUST, 3, 10))
	b.add_theme_stylebox_override("focus", UIStyle.cut_box(UIStyle.BONE, UIStyle.RUST, 3, 10))
	b.add_theme_stylebox_override("pressed", UIStyle.cut_box(UIStyle.OLIVE_DARK, UIStyle.RUST, 3, 10))
	b.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.08, 0.08, 0.07, 0.9), Color(0.36, 0.33, 0.28), 2, 10))
	b.pressed.connect(cb)
	b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
	b.focus_entered.connect(_ui_snd.bind("ui_hover"))
	return b


func _spinner_ctrl(sz: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(sz, sz)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func():
		var r := sz * 0.5 - 2.0
		var ctr := Vector2(sz, sz) * 0.5
		c.draw_arc(ctr, r, 0.0, TAU, 32, Color(UIStyle.BONE_DIM, 0.25), 3.0, true)
		var a := _spin_t * 5.0
		c.draw_arc(ctr, r, a, a + 1.9, 16, UIStyle.RUST.lightened(0.2), 3.0, true))
	return c


# --- mode
## Home PLAY flow (DESIGN §2): SOLO | CO-OP first, then CO-OP → HOST | JOIN (by IP or code).
func _build_mode(pg: VBoxContainer) -> void:
	_build_cards(pg, "HOW ARE YOU GOING IN?", [
		["solo", "SOLO", "Just you and the dead.\nPick a map and drop in.", UIStyle.BONE],
		["coop", "CO-OP", "Up to %d survivors.\nHost a party or join one." % max_players(), UIStyle.OLIVE.lightened(0.25)]])


func _build_coop(pg: VBoxContainer) -> void:
	_build_cards(pg, "CO-OP  //  HOST OR JOIN?", [
		["host", "HOST", "Open a party for up to %d friends.\nShare your join code." % (max_players() - 1), UIStyle.OLIVE.lightened(0.25)],
		["join", "JOIN", "Got a join code or the host's IP?\nGet in the lobby.", UIStyle.RUST.lightened(0.15)]])
	var back_row := HBoxContainer.new()
	back_row.alignment = BoxContainer.ALIGNMENT_CENTER
	pg.add_child(back_row)
	_coop_back = _btn("BACK", func(): show_page("mode"), Vector2(180, 40), 14)
	_coop_back.name = "CoopBack"
	back_row.add_child(_coop_back)
	for k in ["host", "join"]:
		var b: Button = _mode_btns[k]
		b.focus_neighbor_bottom = b.get_path_to(_coop_back)
	_coop_back.focus_neighbor_top = _coop_back.get_path_to(_mode_btns["host"])


func _build_cards(pg: VBoxContainer, lead_text: String, items: Array) -> void:
	var lead := UIStyle.label(lead_text, 16, UIStyle.BONE_DIM, true)
	pg.add_child(lead)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pg.add_child(row)
	for m in items:
		var b := Button.new()
		b.name = "Mode_" + m[0]
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(400 if items.size() == 2 else 320, 300)
		b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(0.06, 0.06, 0.05, 0.96), Color(m[3], 0.55), 3, 22))
		b.add_theme_stylebox_override("hover", UIStyle.cut_box(Color(0.12, 0.1, 0.07, 0.98), m[3], 4, 22))
		b.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0, 0, 0, 0), m[3], 5, 22))
		b.add_theme_stylebox_override("pressed", UIStyle.cut_box(UIStyle.OLIVE_DARK, m[3], 4, 22))
		b.pressed.connect(choose_mode.bind(m[0]))
		b.mouse_entered.connect(_ui_snd.bind("ui_hover"))
		b.focus_entered.connect(_ui_snd.bind("ui_hover"))
		var v := VBoxContainer.new()
		v.set_anchors_preset(Control.PRESET_FULL_RECT)
		v.offset_left = 22
		v.offset_right = -22
		v.offset_top = 26
		v.offset_bottom = -22
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_theme_constant_override("separation", 10)
		b.add_child(v)
		var glyph := _mode_glyph(m[0], m[3])
		v.add_child(glyph)
		var t := UIStyle.label(m[1], 40, m[3], true, 3)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(t)
		var d := UIStyle.label(m[2], 14, UIStyle.BONE_DIM)
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(d)
		row.add_child(b)
		_mode_btns[m[0]] = b
	var n := items.size()
	for i in n:
		var b: Button = _mode_btns[items[i][0]]
		b.focus_neighbor_left = b.get_path_to(_mode_btns[items[(i + n - 1) % n][0]])
		b.focus_neighbor_right = b.get_path_to(_mode_btns[items[(i + 1) % n][0]])


## Little silhouettes: 1 / 4 / door-arrow.
func _mode_glyph(id: String, col: Color) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 90)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func():
		var n := 1 if id == "solo" else (4 if id in ["host", "coop"] else 2)
		var w := 34.0
		for i in n:
			var x := 10.0 + i * (w + 6.0)
			var dim := 1.0 if (id != "join" or i == 1) else 0.45
			var cc := Color(col, dim)
			c.draw_circle(Vector2(x + w * 0.5, 22), 12, cc)
			c.draw_colored_polygon(PackedVector2Array([Vector2(x, 84), Vector2(x + 4, 44), Vector2(x + w - 4, 44), Vector2(x + w, 84)]), cc)
		if id == "join":
			c.draw_line(Vector2(10, 64), Vector2(44, 64), col, 4.0)
			c.draw_colored_polygon(PackedVector2Array([Vector2(44, 54), Vector2(56, 64), Vector2(44, 74)]), col))
	return c


# --- join
func _build_join(pg: VBoxContainer) -> void:
	var box := _panel(UIStyle.RUST, 3, 18)
	box.name = "JoinPanel"
	box.custom_minimum_size = Vector2(640, 0)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pg.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	box.add_child(v)
	v.add_child(UIStyle.label("JOIN A PARTY", 24, UIStyle.BONE, true))
	var hint := UIStyle.label("Paste the host's join code, or their IP (port %d unless they told you another)." % port(), 13, UIStyle.BONE_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = 600
	v.add_child(hint)
	_join_input = LineEdit.new()
	_join_input.name = "JoinInput"
	_join_input.placeholder_text = "%s-XXXXX-XXXXX   or   203.0.113.5:7777" % LAPI.code_prefix()
	_join_input.custom_minimum_size = Vector2(600, 54)
	_join_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_join_input.add_theme_font_override("font", UIStyle.FONT_STENCIL)
	_join_input.add_theme_font_size_override("font_size", 24)
	_join_input.add_theme_color_override("font_color", UIStyle.BONE)
	_join_input.add_theme_color_override("font_placeholder_color", Color(UIStyle.BONE_DIM, 0.45))
	_join_input.add_theme_color_override("caret_color", UIStyle.RUST.lightened(0.3))
	_join_input.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.95), UIStyle.BONE_DIM, 2, 12))
	_join_input.add_theme_stylebox_override("focus", UIStyle.cut_box(Color(0, 0, 0, 0), UIStyle.RUST, 3, 12))
	_join_input.text_changed.connect(_on_join_text)
	_join_input.text_submitted.connect(func(_t): connect_pressed())
	v.add_child(_join_input)
	_join_error = UIStyle.label("", 13, UIStyle.BONE_DIM)
	_join_error.name = "JoinError"
	_join_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_join_error.custom_minimum_size = Vector2(600, 36)
	v.add_child(_join_error)
	_connecting_box = HBoxContainer.new()
	_connecting_box.name = "ConnectingBox"
	(_connecting_box as HBoxContainer).add_theme_constant_override("separation", 12)
	_connecting_box.visible = false
	v.add_child(_connecting_box)
	_spinner = _spinner_ctrl(34)
	_spinner.name = "ConnectSpinner"
	_connecting_box.add_child(_spinner)
	_connecting_label = UIStyle.label("CONNECTING…", 16, UIStyle.BONE, true)
	_connecting_label.name = "ConnectingLabel"
	_connecting_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_connecting_box.add_child(_connecting_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	v.add_child(row)
	_connect_btn = _btn("CONNECT", connect_pressed, Vector2(200, 46), 17)
	_connect_btn.name = "ConnectBtn"
	UIStyle.style_primary_button(_connect_btn)
	_connect_btn.add_theme_stylebox_override("focus", UIStyle.cut_box(UIStyle.BONE, UIStyle.RUST, 3, 10))
	_connect_btn.add_theme_color_override("font_focus_color", UIStyle.INK)
	_connect_btn.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.08, 0.08, 0.07, 0.9), Color(0.36, 0.33, 0.28), 2, 10))
	row.add_child(_connect_btn)
	_join_back = _btn("BACK", _on_join_back, Vector2(140, 46))
	_join_back.name = "JoinBack"
	row.add_child(_join_back)
	_join_input.focus_neighbor_bottom = _join_input.get_path_to(_connect_btn)
	_connect_btn.focus_neighbor_top = _connect_btn.get_path_to(_join_input)
	_join_back.focus_neighbor_top = _join_back.get_path_to(_join_input)
	_on_join_text("")


# --- lobby
func _build_lobby(pg: VBoxContainer) -> void:
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pg.add_child(body)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.custom_minimum_size.x = 560
	body.add_child(left)
	var ph := HBoxContainer.new()
	left.add_child(ph)
	ph.add_child(UIStyle.label("PARTY", 14, UIStyle.RUST, true))
	var psp := Control.new()
	psp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ph.add_child(psp)
	var pc := UIStyle.label("", 13, UIStyle.BONE_DIM, true)
	pc.name = "PartyCount"
	ph.add_child(pc)
	for i in LAPI.MAX_PLAYERS_FALLBACK:
		var s := _panel(UIStyle.BONE_DIM, 2, 12)
		s.name = "PartySlot_%d" % i
		s.custom_minimum_size = Vector2(560, 74)
		left.add_child(s)
		_slots.append(s)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(right)
	# host share panel
	_host_panel = _panel(UIStyle.OLIVE.lightened(0.15), 3, 16)
	_host_panel.name = "HostPanel"
	right.add_child(_host_panel)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 4)
	_host_panel.add_child(hv)
	hv.add_child(UIStyle.label("JOIN CODE", 12, UIStyle.BONE_DIM, true))
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 10)
	hv.add_child(crow)
	_code_label = UIStyle.label("…", 42, UIStyle.BONE, true, 2)
	_code_label.name = "JoinCode"
	_code_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	crow.add_child(_code_label)
	_copy_btn = _btn("COPY", copy_code, Vector2(92, 40), 14)
	_copy_btn.name = "CopyCode"
	_copy_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	crow.add_child(_copy_btn)
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 10)
	hv.add_child(arow)
	_share_label = UIStyle.label("", 13, UIStyle.BONE_DIM)
	_share_label.name = "ShareAddress"
	_share_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	arow.add_child(_share_label)
	_copy_feedback = UIStyle.label("", 12, UIStyle.OLIVE.lightened(0.5), true)
	_copy_feedback.name = "CopyFeedback"
	arow.add_child(_copy_feedback)
	var urow := HBoxContainer.new()
	urow.add_theme_constant_override("separation", 8)
	hv.add_child(urow)
	_upnp_spin = _spinner_ctrl(18)
	_upnp_spin.name = "UpnpSpinner"
	urow.add_child(_upnp_spin)
	_upnp_label = UIStyle.label("", 13, UIStyle.BONE, true)
	_upnp_label.name = "UpnpStatus"
	_upnp_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_upnp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	urow.add_child(_upnp_label)
	_upnp_help = UIStyle.label("", 12, UIStyle.BONE)
	_upnp_help.name = "UpnpHelp"
	_upnp_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_upnp_help.custom_minimum_size.x = 420
	_upnp_help.visible = false
	hv.add_child(_upnp_help)
	# match settings
	var mp := _panel(UIStyle.BONE_DIM, 2, 14)
	mp.name = "MatchPanel"
	right.add_child(mp)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 6)
	mp.add_child(mv)
	mv.add_child(UIStyle.label("MATCH", 12, UIStyle.BONE_DIM, true))
	_map_btn = _btn("MAP", open_map_picker, Vector2(0, 40), 15)
	_map_btn.name = "MapPick"
	_map_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	mv.add_child(_map_btn)
	_map_ro = UIStyle.label("", 18, UIStyle.BONE, true)
	_map_ro.name = "MapReadOnly"
	mv.add_child(_map_ro)
	_diff_row = HBoxContainer.new()
	_diff_row.name = "DiffRow"
	_diff_row.add_theme_constant_override("separation", 6)
	mv.add_child(_diff_row)
	for id in Difficulty.ids():
		var prof: Dictionary = Difficulty.profile(id)
		var b := _btn(str(prof.get("name", id)).to_upper(), choose_difficulty.bind(id), Vector2(100, 34), 13)
		b.name = "Diff_" + str(id)
		b.toggle_mode = true
		_diff_row.add_child(b)
		_diff_btns[id] = b
	_diff_ro = UIStyle.label("", 14, UIStyle.BONE_DIM, true)
	_diff_ro.name = "DiffReadOnly"
	mv.add_child(_diff_ro)
	_member_note = UIStyle.label("The party leader picks the map and difficulty.", 12, UIStyle.BONE_DIM)
	_member_note.name = "MemberNote"
	mv.add_child(_member_note)
	var rsp := Control.new()
	rsp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(rsp)
	# actions
	var act := HBoxContainer.new()
	act.add_theme_constant_override("separation", 10)
	pg.add_child(act)
	_ready_btn = _btn("READY UP", toggle_ready, Vector2(200, 50), 18)
	_ready_btn.name = "ReadyToggle"
	act.add_child(_ready_btn)
	_start_btn = _btn("START MATCH", start_pressed, Vector2(220, 50), 18)
	_start_btn.name = "StartBtn"
	UIStyle.style_primary_button(_start_btn)
	_start_btn.add_theme_stylebox_override("focus", UIStyle.cut_box(UIStyle.BONE, UIStyle.RUST, 3, 10))
	_start_btn.add_theme_color_override("font_focus_color", UIStyle.INK)
	_start_btn.add_theme_stylebox_override("disabled", UIStyle.cut_box(Color(0.08, 0.08, 0.07, 0.9), Color(0.36, 0.33, 0.28), 2, 10))
	act.add_child(_start_btn)
	_start_reason = UIStyle.label("", 13, UIStyle.BONE_DIM)
	_start_reason.name = "StartReason"
	_start_reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_start_reason.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_reason.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	act.add_child(_start_reason)
	_leave_btn = _btn("LEAVE", leave_pressed, Vector2(130, 50), 16)
	_leave_btn.name = "LeaveBtn"
	act.add_child(_leave_btn)


func _build_notice() -> void:
	var dlg := UIStyle.dialog_overlay("LobbyNoticeOverlay")
	_notice_overlay = dlg.overlay
	_notice_overlay.visible = false
	add_child(_notice_overlay)
	var card := UIStyle.dialog_card(Vector2(460, 190), "LobbyNotice")
	(dlg.center as CenterContainer).add_child(card)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(v)
	_notice_title = UIStyle.label("", 20, UIStyle.BLOOD.lightened(0.35), true)
	_notice_title.name = "NoticeTitle"
	_notice_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_notice_title)
	_notice_text = UIStyle.label("", 14, UIStyle.BONE)
	_notice_text.name = "NoticeText"
	_notice_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice_text.custom_minimum_size.x = 420
	v.add_child(_notice_text)
	_notice_ok = _btn("OK", dismiss_notice, Vector2(140, 42))
	_notice_ok.name = "NoticeOK"
	UIStyle.style_primary_button(_notice_ok)
	_notice_ok.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(_notice_ok)


# ------------------------------------------------------------------ pages

func open_mode() -> void:
	open()
	show_page("mode")


func open() -> void:
	_wire_net()
	super.open()
	var st := int(LAPI.prop(net, "state", LAPI.OFFLINE))
	if st in [LAPI.HOSTING_LOBBY, LAPI.IN_LOBBY]:
		show_page("lobby")


func show_page(id: String) -> void:
	page = id
	for k in _pages:
		(_pages[k] as Control).visible = k == id
	_stub_tag.visible = LAPI.is_stub(net)
	match id:
		"mode":
			_title.text = "PLAY"
			_sub.text = "SOLO  //  CO-OP"
			if visible:
				(_mode_btns["solo"] as Button).call_deferred("grab_focus")
		"coop":
			_title.text = "CO-OP"
			_sub.text = "HOST A PARTY  //  JOIN BY CODE OR IP"
			if visible:
				(_mode_btns["host"] as Button).call_deferred("grab_focus")
		"join":
			_title.text = "JOIN"
			_sub.text = "UP TO %d SURVIVORS" % max_players()
			_set_connecting(false)
			if visible:
				_join_input.call_deferred("grab_focus")
		"lobby":
			refresh_lobby()
			if visible:
				_ready_btn.call_deferred("grab_focus")


## SOLO → map picker (home); CO-OP → HOST / JOIN page; HOST → host_party + lobby; JOIN → join box.
## CO-OP / HOST / JOIN ask for a name first when none is set (Net.needs_name_prompt).
func choose_mode(m: String) -> void:
	_ui_snd("ui_equip")
	if m == "solo":
		close()
		solo_chosen.emit()
		return
	if not _has_name():
		_pending_mode = m
		prompt_name()
		return
	_push_profile()
	if m == "coop":
		show_page("coop")
	elif m == "host":
		start_hosting()
	else:
		show_page("join")


func start_hosting() -> bool:
	upnp_state = "trying"
	upnp_message = ""
	join_code = ""
	share_address = ""
	var err = _api("host_party", [port(), true])
	if err != OK:
		_show_toast("Couldn't open a party: %s" % error_string(int(err)) if err != null else "Net isn't available.", true)
		return false
	show_page("lobby")
	return true


## Net's profile is the name store when Net is installed (Net.needs_name_prompt); Settings mirrors it.
func _has_name() -> bool:
	var s := get_node_or_null("/root/Settings")
	if s == null or not s.has_method("has_player_name"):
		return false
	return not LAPI.needs_name(s, net)


## Netz keeps its own profile (user://net_profile.cfg). If Settings has no name yet but Net does, take it over
## (when it passes Settings' rules) so the player isn't asked twice.
static func adopt_net_name(s: Node, n: Object) -> bool:
	if s == null or n == null or LAPI.is_stub(n) or not n.has_method("needs_name_prompt") or n.needs_name_prompt():
		return false
	var r: Dictionary = s.validate_player_name(str(LAPI.call_api(n, "local_name")))
	if not bool(r.ok):
		return false
	s.set_player_name(str(r.name))
	return true


func _push_profile() -> void:
	var s := get_node_or_null("/root/Settings")
	var prog := get_node_or_null("/root/Progress")
	var cls := ""
	if prog and prog.get("selected_class") != null:
		cls = str(prog.selected_class)
	if s and s.has_method("has_player_name") and s.has_player_name():
		_api("set_local_profile", [str(s.player_name), cls])


func prompt_name(allow_cancel: bool = true) -> Node:
	if name_prompt and is_instance_valid(name_prompt):
		return name_prompt
	name_prompt = NamePromptScript.new()
	name_prompt.allow_cancel = allow_cancel
	name_prompt.submitted.connect(_on_name_submitted)
	name_prompt.cancelled.connect(func(): _pending_mode = "")
	add_child(name_prompt)
	return name_prompt


func _on_name_submitted(_n: String) -> void:
	name_prompt = null
	var m := _pending_mode
	_pending_mode = ""
	if m != "":
		choose_mode(m)


# ------------------------------------------------------------------ join

func _on_join_text(t: String) -> void:
	if connecting:
		return
	if t.strip_edges() == "":
		_join_error.text = "Codes look like %s-7K2QM-9XH4P. IPs like 203.0.113.5 or 203.0.113.5:7777." % LAPI.code_prefix()
		_join_error.add_theme_color_override("font_color", UIStyle.BONE_DIM)
		_connect_btn.disabled = true
		return
	var v := LAPI.validate_join_input(t, net)
	_connect_btn.disabled = not v.ok
	if v.ok:
		_join_error.text = ("Join code → %s:%d" % [v.address, v.port]) if v.kind == "code" else ("Host %s, port %d" % [v.address, v.port])
		_join_error.add_theme_color_override("font_color", UIStyle.OLIVE.lightened(0.45))
	else:
		_join_error.text = str(v.reason)
		_join_error.add_theme_color_override("font_color", UIStyle.BAD)


func set_join_text(t: String) -> void:
	_join_input.text = t
	_on_join_text(t)


func connect_pressed() -> bool:
	if connecting:
		return false
	var v := LAPI.validate_join_input(_join_input.text, net)
	if not v.ok:
		_join_error.text = str(v.reason)
		_join_error.add_theme_color_override("font_color", UIStyle.BAD)
		_ui_error()
		return false
	var err
	if v.kind == "code":
		err = _api("join_by_code", [str(v.code)])
	else:
		err = _api("join_by_address", [str(v.address), int(v.port)])
	if err == null or int(err) != OK:
		var le := str(LAPI.prop(net, "last_error", ""))
		if le != "" and LAPI.REASON_TEXT.has(le):
			show_join_error(LAPI.reason_text(le))
		else:
			show_join_error("Couldn't start connecting (%s)." % (error_string(int(err)) if err != null else "Net isn't available"))
		return false
	_ui_snd("ui_equip")
	_set_connecting(true, "%s:%d" % [v.address, v.port])
	return true


func _set_connecting(on: bool, target: String = "") -> void:
	connecting = on
	_connecting_box.visible = on
	_join_input.editable = not on
	_connect_btn.disabled = on or not LAPI.validate_join_input(_join_input.text, net).ok
	_join_back.text = "CANCEL" if on else "BACK"
	if on:
		_connecting_label.text = "CONNECTING TO %s…" % target
		_join_error.text = ""


func show_join_error(text: String) -> void:
	_set_connecting(false)
	_join_error.text = text
	_join_error.add_theme_color_override("font_color", UIStyle.BAD)
	_ui_error()


func _on_join_back() -> void:
	if connecting:
		_api("leave_party")
		_set_connecting(false)
		_join_error.text = "Cancelled."
		_join_error.add_theme_color_override("font_color", UIStyle.BONE_DIM)
		return
	show_page("coop")


func _on_connected() -> void:
	_set_connecting(false)
	_ui_snd("ui_equip")
	show_page("lobby")


func _on_connection_failed(reason: String) -> void:
	if page == "lobby" and int(LAPI.prop(net, "state", 0)) != LAPI.JOINING:
		return
	if page != "join":
		show_page("join")
	show_join_error(LAPI.reason_text(reason))


# ------------------------------------------------------------------ host panel

func _on_hosting_started(addr: String, code: String) -> void:
	share_address = addr
	join_code = code
	if upnp_state == "":
		upnp_state = "trying"
	if upnp_state == "trying" and (LAPI.is_stub(net) or not net.has_signal("upnp_started")):
		_arm_upnp_timeout()
	refresh_lobby()


func _on_upnp_started() -> void:
	upnp_state = "trying" # once per host_party, before its upnp_result
	refresh_lobby()


## Stub only (and a pre-cb5e52a Net without upnp_started): the real Net always answers upnp_result.
func _arm_upnp_timeout() -> void:
	_upnp_gen += 1
	var g := _upnp_gen
	get_tree().create_timer(UPNP_GIVE_UP_S, true).timeout.connect(func():
		if g == _upnp_gen and upnp_state == "trying" and is_instance_valid(self):
			_on_upnp_result(false, "", "No answer from the router."))


## Netz upnp_result(ok, external_ip, message): a private / CGNAT "external" address comes back as ok=false with
## Net.upnp_info.double_nat = true and a message that says so; that's the "cgnat" state (help shows the message).
func _on_upnp_result(ok: bool, external_ip: String, message: String) -> void:
	_upnp_gen += 1
	upnp_state = "open" if ok else "failed"
	upnp_message = message
	var inf = LAPI.prop(net, "upnp_info", {})
	if not ok and (message == "skipped" or (inf is Dictionary and str((inf as Dictionary).get("status", "")) == "skipped")):
		upnp_state = "skipped" # Netz: not tried (upnp_info.why = not_requested / disabled / not_needed)
		upnp_message = str((inf as Dictionary).get("why", "")) if inf is Dictionary else ""
		refresh_lobby()
		return
	var info = LAPI.prop(net, "upnp_info", {})
	var dn: bool = info is Dictionary and bool((info as Dictionary).get("double_nat", false))
	if external_ip != "" and _is_private(external_ip):
		dn = true
	if dn or message.to_lower().contains("double nat") or message.to_lower().contains("carrier-grade"):
		upnp_state = "cgnat"
	refresh_lobby()


static func _is_private(ip: String) -> bool:
	var p := ip.split(".")
	if p.size() != 4:
		return false
	var a := int(p[0])
	var b := int(p[1])
	return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 100 and b >= 64 and b <= 127)


func copy_code() -> String:
	var code := join_code if join_code != "" else str(_api("make_join_code"))
	if code == "":
		return ""
	DisplayServer.clipboard_set(code)
	last_copied = code
	_copy_feedback.text = "COPIED"
	_ui_snd("ui_equip")
	get_tree().create_timer(2.0, true).timeout.connect(func():
		if is_instance_valid(_copy_feedback):
			_copy_feedback.text = "")
	return code


func upnp_help_text() -> String:
	var lan := share_address.get_slice(":", 0) if share_address != "" else "this PC's LAN IP"
	if upnp_state == "cgnat":
		return ((upnp_message + "\n") if upnp_message != "" else "Your router is behind another router or your ISP's NAT (double NAT).\n") + (
			"•  Port forwarding on your own router won't be enough: the outer router / ISP blocks it.\n"
			+ "•  Easiest fix: everyone joins the same VPN (e.g. Tailscale) and friends join your VPN IP.\n"
			+ "•  Or ask your ISP for a public IP / put the outer router in bridge mode.")
	return ("Friends can't reach you yet. Either:\n"
		+ "•  Forward port %d (UDP; TCP too if your router asks) to this PC (%s) in your router settings, or\n" % [port(), lan]
		+ "•  Share your IP with friends directly (or join the same VPN, e.g. Tailscale).\n"
		+ "Windows may ask to allow Gravecrew through the firewall: tick Private.")


func _refresh_host_panel() -> void:
	var host := bool(_api("is_host")) and is_leader()
	_host_panel.visible = host
	if not host:
		return
	_code_label.text = join_code if join_code != "" else "…"
	_copy_btn.disabled = join_code == ""
	_share_label.text = ("or IP  %s" % share_address) if share_address != "" else ""
	_upnp_spin.visible = upnp_state == "trying"
	_upnp_help.visible = upnp_state == "failed"
	match upnp_state:
		"trying":
			_upnp_label.text = "TRYING UPnP: OPENING PORT %d…" % port()
			_upnp_label.add_theme_color_override("font_color", UIStyle.BONE)
		"open":
			_upnp_label.text = "PORT %d OPEN (UPnP)  //  friends can join" % port()
			_upnp_label.add_theme_color_override("font_color", UIStyle.OLIVE.lightened(0.5))
		"cgnat":
			_upnp_label.text = "DOUBLE NAT DETECTED  //  friends can't reach you directly (see below)"
			_upnp_label.add_theme_color_override("font_color", UIStyle.RUST.lightened(0.3))
			_upnp_help.visible = true
		"skipped":
			_upnp_label.text = ("PORT %d  //  UPnP OFF" % port()) if upnp_message != "not_needed" else "PORT %d  //  NO UPnP NEEDED" % port()
			_upnp_label.add_theme_color_override("font_color", UIStyle.BONE_DIM)
			_upnp_help.visible = upnp_message != "not_needed"
		"failed":
			_upnp_label.text = "UPnP FAILED%s" % (("  //  " + upnp_message) if upnp_message != "" else "")
			_upnp_label.add_theme_color_override("font_color", UIStyle.BAD)
		_:
			_upnp_label.text = ""
	_upnp_help.text = upnp_help_text()


# ------------------------------------------------------------------ lobby

func _on_party_changed(_p: Array = []) -> void:
	if page == "lobby":
		refresh_lobby()


func _on_peer_joined(_id: int, n: String) -> void:
	_ui_snd("ui_equip")
	_show_toast("%s joined the party" % n, false)


func _on_peer_left(_id: int, n: String, reason: String) -> void:
	_kick_armed.erase(_id)
	var why := LAPI.reason_text(reason)
	if reason not in ["left", "lost"]: # Netz: "kicked" or the host's kick reason
		why = "was removed by the host" + ("" if reason in ["kicked", ""] else " (%s)" % reason)
	_show_toast("%s %s" % [n, why], true)


func _on_lobby_settings(_m: String = "", _d: String = "") -> void:
	if page == "lobby":
		refresh_lobby()


func _on_match_starting(map_id: String, difficulty_id: String) -> void:
	_ui_snd("ui_equip")
	close()
	match_start_requested.emit(map_id, difficulty_id)


func _on_host_left() -> void:
	if notice_visible() and _notice_title.text == "HOST LEFT":
		return
	show_notice("HOST LEFT", LAPI.reason_text("host_left"))


func _on_disconnected(reason: String) -> void:
	if reason == "left":
		return # our own LEAVE / CANCEL (Netz emits it too)
	if reason == "host_left":
		_on_host_left() # Netz emits host_left then disconnected("host_left"): one notice
	elif reason == "kicked":
		show_notice("REMOVED FROM PARTY", LAPI.reason_text("kicked"))
	elif not LAPI.REASON_TEXT.has(reason) and reason != "": # Netz kick(peer, reason): the host's own reason
		show_notice("REMOVED FROM PARTY", "%s\nReason: %s" % [LAPI.reason_text("kicked"), reason])
	else:
		show_notice("DISCONNECTED", LAPI.reason_text(reason))


func _on_peer_rejected(_id: int, n: String, reason: String) -> void:
	_show_toast("%s couldn't join: %s" % [n if n != "" else "A player", LAPI.reason_text(reason)], true)


## Netz return_to_lobby: home reloads; if this menu is still up, just show the lobby again.
func _on_returned_to_lobby() -> void:
	if visible:
		show_page("lobby")


func show_notice(title: String, text: String) -> void:
	last_notice = "%s: %s" % [title, text]
	_notice_title.text = title
	_notice_text.text = text
	_notice_overlay.visible = true
	_ui_error()
	if visible:
		_notice_ok.call_deferred("grab_focus")


func notice_visible() -> bool:
	return _notice_overlay.visible


func dismiss_notice() -> void:
	_notice_overlay.visible = false
	_ui_snd("ui_hover")
	show_page("coop")


func my_entry() -> Dictionary:
	var me := int(_api("local_peer_id"))
	for e in party():
		if int(e.get(LAPI.K_PEER, -1)) == me:
			return e
	return {}


func refresh_lobby() -> void:
	if _slots.is_empty():
		return
	var p := party()
	var me := int(_api("local_peer_id"))
	var leader := is_leader()
	var host := bool(_api("is_host"))
	_title.text = "LOBBY"
	_sub.text = ("HOSTING  //  %d/%d" if host and leader else "PARTY  //  %d/%d") % [p.size(), max_players()]
	var pc := find_child("PartyCount", true, false) as Label
	if pc:
		pc.text = "%d / %d" % [p.size(), max_players()]
	for i in _slots.size():
		_fill_slot(_slots[i], p[i] if i < p.size() else {}, i, me, leader)
	_refresh_host_panel()
	# match settings
	var map_id := str(LAPI.prop(net, "lobby_map_id", ""))
	var diff_id := LAPI.effective_difficulty(net) # Netz: lobby "" = the map's own difficulty
	var map_name := str(MapRegistry.get_info(map_id).get("display_name", map_id)).to_upper() if map_id != "" else "NO MAP YET"
	var dprof: Dictionary = Difficulty.profile(diff_id) if diff_id != "" and Difficulty.is_valid(diff_id) else {}
	var diff_name := str(dprof.get("name", diff_id if diff_id != "" else "-")).to_upper()
	_map_btn.visible = leader
	_map_btn.text = "MAP   %s   ▸" % map_name
	_diff_row.visible = leader
	for id in _diff_btns:
		var b: Button = _diff_btns[id]
		b.button_pressed = id == diff_id
		var col := _diff_color(id)
		b.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.INK, 0.92), col if id == diff_id else UIStyle.BONE_DIM, 3 if id == diff_id else 2, 8))
		b.add_theme_stylebox_override("pressed", UIStyle.cut_box(Color(col.darkened(0.6), 0.95), col, 3, 8))
	_map_ro.visible = not leader
	_map_ro.text = "MAP  //  %s" % map_name
	_diff_ro.visible = not leader
	_diff_ro.text = "DIFFICULTY  //  %s" % diff_name
	if dprof.has("color"):
		_diff_ro.add_theme_color_override("font_color", _diff_color(diff_id))
	_member_note.visible = not leader
	# ready / start
	var mine := my_entry()
	var r := bool(mine.get(LAPI.K_READY, false))
	_ready_btn.text = "READY  ✓" if r else "READY UP"
	_ready_btn.add_theme_stylebox_override("normal", UIStyle.cut_box(Color(UIStyle.OLIVE_DARK, 0.95) if r else Color(UIStyle.INK, 0.92),
		UIStyle.OLIVE.lightened(0.3) if r else UIStyle.BONE_DIM, 3 if r else 2, 10))
	_start_btn.visible = leader
	var why := start_block_reason()
	_start_btn.disabled = why != ""
	_start_btn.tooltip_text = why
	_start_reason.text = why if leader else ("Waiting for the leader to start." if r else "Ready up so the leader can start.")
	_start_reason.add_theme_color_override("font_color", UIStyle.BONE_DIM if why == "" else UIStyle.RUST.lightened(0.3))
	_wire_lobby_nav()


func _diff_color(id: String) -> Color:
	var c = Difficulty.profile(id).get("color", null)
	if c is Array and c.size() >= 3:
		return Color(float(c[0]), float(c[1]), float(c[2]))
	return UIStyle.BONE_DIM


func _fill_slot(slot: PanelContainer, e: Dictionary, i: int, me: int, _leader_view: bool) -> void:
	for c in slot.get_children():
		slot.remove_child(c)
		c.queue_free()
	var empty := e.is_empty()
	var tint := LAPI.tint_of(e, i)
	var st := UIStyle.cut_box(Color(0.06, 0.06, 0.05, 0.95 if not empty else 0.6),
		(UIStyle.RUST if int(e.get(LAPI.K_PEER, -1)) == me else UIStyle.BONE_DIM) if not empty else Color(UIStyle.BONE_DIM, 0.3), 2, 12)
	st.set_content_margin_all(10)
	slot.add_theme_stylebox_override("panel", st)
	slot.set_meta("peer_id", int(e.get(LAPI.K_PEER, -1)))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	slot.add_child(h)
	var sw := ColorRect.new()
	sw.name = "Swatch"
	sw.custom_minimum_size = Vector2(14, 50)
	sw.color = tint if not empty else Color(UIStyle.BONE_DIM, 0.15)
	h.add_child(sw)
	if empty:
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", -2)
		h.add_child(v)
		var l := UIStyle.label("OPEN SLOT", 18, Color(UIStyle.BONE_DIM, 0.6), true)
		l.name = "SlotName"
		v.add_child(l)
		v.add_child(UIStyle.label("share the join code" if is_leader() and bool(_api("is_host")) else "waiting for players…", 12, Color(UIStyle.BONE_DIM, 0.5)))
		slot.set_meta("empty", true)
		return
	slot.set_meta("empty", false)
	var crown := Control.new()
	crown.name = "LeaderCrown"
	crown.custom_minimum_size = Vector2(26, 26)
	crown.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	crown.visible = bool(e.get(LAPI.K_LEADER, false))
	crown.draw.connect(func():
		var gold := Color(0.95, 0.72, 0.25)
		crown.draw_colored_polygon(PackedVector2Array([Vector2(2, 22), Vector2(2, 8), Vector2(8, 14), Vector2(13, 4),
			Vector2(18, 14), Vector2(24, 8), Vector2(24, 22)]), gold)
		crown.draw_rect(Rect2(2, 20, 22, 4), gold.darkened(0.3)))
	h.add_child(crown)
	if not crown.visible:
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(26, 26)
		h.add_child(pad)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	var nr := HBoxContainer.new()
	nr.add_theme_constant_override("separation", 8)
	v.add_child(nr)
	var nl := UIStyle.label(str(e.get(LAPI.K_NAME, "?")).to_upper(), 20, tint.lightened(0.1), true, 2)
	nl.name = "SlotName"
	nr.add_child(nl)
	if int(e.get(LAPI.K_PEER, -1)) == me:
		var you := PanelContainer.new()
		you.name = "YouTag"
		var ys := UIStyle.cut_box(UIStyle.RUST.darkened(0.1), Color(0, 0, 0, 0), 0, 5)
		ys.set_content_margin_all(2)
		ys.content_margin_left = 6
		ys.content_margin_right = 6
		you.add_theme_stylebox_override("panel", ys)
		you.add_child(UIStyle.label("YOU", 10, UIStyle.BONE, true))
		you.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		nr.add_child(you)
	var sub := []
	if bool(e.get(LAPI.K_LEADER, false)):
		sub.append("LEADER")
	var cls := str(e.get(LAPI.K_CLASS, ""))
	if cls != "":
		sub.append(cls.to_upper())
	var sl := UIStyle.label("  //  ".join(sub) if not sub.is_empty() else "SURVIVOR", 11, UIStyle.BONE_DIM, true)
	v.add_child(sl)
	var ping = e.get(LAPI.K_PING, null)
	var pl := UIStyle.label("", 13, UIStyle.BONE_DIM, true)
	pl.name = "Ping"
	pl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if ping != null and int(ping) > 0:
		var pm := int(ping)
		pl.text = "%d ms" % pm
		pl.add_theme_color_override("font_color", UIStyle.GOOD if pm < 80 else (UIStyle.BONE if pm < 150 else UIStyle.BAD))
	elif ping != null and int(e.get(LAPI.K_PEER, -1)) == 1:
		pl.text = "HOST"
	h.add_child(pl)
	var r := bool(e.get(LAPI.K_READY, false))
	var badge := PanelContainer.new()
	badge.name = "ReadyBadge"
	badge.set_meta("ready", r)
	var bs := UIStyle.cut_box(Color(UIStyle.OLIVE_DARK, 0.95) if r else Color(UIStyle.INK, 0.9), UIStyle.OLIVE.lightened(0.3) if r else UIStyle.BONE_DIM, 2, 7)
	bs.set_content_margin_all(5)
	bs.content_margin_left = 12
	bs.content_margin_right = 12
	badge.add_theme_stylebox_override("panel", bs)
	badge.custom_minimum_size.x = 120
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bl := UIStyle.label("READY" if r else "NOT READY", 13, UIStyle.OLIVE.lightened(0.55) if r else UIStyle.BONE_DIM, true)
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(bl)
	h.add_child(badge)
	var pid := int(e.get(LAPI.K_PEER, -1))
	if is_leader() and bool(_api("is_host")) and pid != me and net and net.has_method("kick"):
		var kb := _btn("KICK?" if _kick_armed.has(pid) else "✕", kick_pressed.bind(pid), Vector2(64, 34), 13)
		kb.name = "KickBtn"
		kb.tooltip_text = "Remove %s from the party (press twice)" % str(e.get(LAPI.K_NAME, "?"))
		kb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(kb)


## Leader KICK: first press arms (KICK?), a second press within KICK_ARM_S calls Net.kick(peer).
func kick_pressed(peer_id: int) -> bool:
	if not _kick_armed.has(peer_id):
		_kick_armed[peer_id] = true
		get_tree().create_timer(KICK_ARM_S, true).timeout.connect(func():
			if is_instance_valid(self) and _kick_armed.has(peer_id):
				_kick_armed.erase(peer_id)
				refresh_lobby())
		refresh_lobby()
		return false
	_kick_armed.erase(peer_id)
	var ok := bool(_api("kick", [peer_id, "kicked"]))
	_ui_snd("ui_equip" if ok else "ui_hover")
	refresh_lobby()
	return ok


## Why START is disabled ("" = can start). Leader-only; members never see START.
## Netz cb5e52a: Net.start_block_reason() code + not_ready_names(); the local checks below are the fallback.
func start_block_reason() -> String:
	if net and net.has_method("start_block_reason"):
		var code := str(_api("start_block_reason"))
		var names = _api("not_ready_names") if code == "not_ready" else []
		return LAPI.start_block_text(code, names if names is Array else [])
	if not is_leader():
		return "Only the party leader can start."
	var p := party()
	if p.is_empty():
		return "No party."
	var map_id := str(LAPI.prop(net, "lobby_map_id", ""))
	if not MapRegistry.is_valid(map_id):
		return "Pick a map first."
	var waiting: Array = []
	var me := int(_api("local_peer_id"))
	for e in p:
		# the leader's START is its ready (Netz can_start() skips the host), so only the others gate START
		if int(e.get(LAPI.K_PEER, -1)) != me and not bool(e.get(LAPI.K_READY, false)):
			waiting.append(str(e.get(LAPI.K_NAME, "?")))
	if not waiting.is_empty():
		return "Waiting on %s to ready up." % ", ".join(waiting)
	if not bool(_api("can_start")):
		return "Can't start yet."
	return ""


func toggle_ready() -> void:
	var r := not bool(my_entry().get(LAPI.K_READY, false))
	_api("set_ready", [r])
	_ui_snd("ui_equip" if r else "ui_hover")


func start_pressed() -> bool:
	var why := start_block_reason()
	if why != "":
		_show_toast(why, true)
		_ui_error()
		return false
	return bool(_api("start_match"))


func choose_difficulty(id: String) -> void:
	if not is_leader():
		return
	if not bool(_api("select_difficulty", [id])):
		_show_toast("Couldn't set difficulty.", true)
	_ui_snd("ui_equip")
	refresh_lobby()


func open_map_picker() -> void:
	if not is_leader():
		return
	_map_picker.open()


func _on_map_picked(id: String) -> void:
	if is_leader():
		_api("select_map", [id])
	_map_picker.close()
	get_tree().paused = true # the lobby is still up (MenuBase pause), map_picker.close() cleared it
	refresh_lobby()
	_map_btn.call_deferred("grab_focus")


func leave_pressed() -> void:
	_api("leave_party")
	_ui_snd("ui_scrap_dismantle")
	upnp_state = ""
	join_code = ""
	show_page("coop")


func _wire_lobby_nav() -> void:
	var row := [_ready_btn]
	if _start_btn.visible:
		row.append(_start_btn)
	row.append(_leave_btn)
	for i in row.size():
		var b: Button = row[i]
		b.focus_neighbor_left = b.get_path_to(row[(i - 1 + row.size()) % row.size()])
		b.focus_neighbor_right = b.get_path_to(row[(i + 1) % row.size()])
		var up: Control = _map_btn if _map_btn.visible else (_copy_btn if _host_panel.visible else b)
		b.focus_neighbor_top = b.get_path_to(up)
	if _map_btn.visible:
		_map_btn.focus_neighbor_bottom = _map_btn.get_path_to(_diff_btns.values()[0] if not _diff_btns.is_empty() else _ready_btn)
		_map_btn.focus_neighbor_top = _map_btn.get_path_to(_copy_btn if _host_panel.visible else _map_btn)
		for b in _diff_btns.values():
			b.focus_neighbor_bottom = b.get_path_to(_ready_btn)
			b.focus_neighbor_top = b.get_path_to(_map_btn)
	if _host_panel.visible:
		_copy_btn.focus_neighbor_bottom = _copy_btn.get_path_to(_map_btn if _map_btn.visible else _ready_btn)


# ------------------------------------------------------------------ misc

func _show_toast(text: String, bad: bool) -> void:
	last_toast = text
	_toast.text = text
	_toast.add_theme_color_override("font_color", UIStyle.BLOOD.lightened(0.35) if bad else UIStyle.OLIVE.lightened(0.5))
	_toast.visible = true
	_toast_t = TOAST_SECS


func _ui_error() -> void:
	var a := get_node_or_null("/root/Sfx")
	if a:
		a.play("ui_error" if a.has_method("has") and a.has("ui_error") else "ui_hover")


func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast.visible = false
	if not visible:
		return
	_spin_t += delta
	if _spinner and _spinner.is_visible_in_tree():
		_spinner.queue_redraw()
	if _upnp_spin and _upnp_spin.is_visible_in_tree():
		_upnp_spin.queue_redraw()


func back() -> void:
	if notice_visible():
		dismiss_notice()
		return
	match page:
		"mode":
			close()
		"coop":
			show_page("mode")
		"join":
			_on_join_back()
		"lobby":
			leave_pressed()


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _map_picker.visible or (name_prompt and is_instance_valid(name_prompt)):
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_mouse"):
		get_viewport().set_input_as_handled()
		back()
