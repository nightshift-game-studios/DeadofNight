extends Control
## Announcer callout banner (Gooey): big stamped text when Audi-0's Callouts autoload plays a line.
##   Callouts.callout_played(event_id, player_name, is_local)
##   local    → "MASSACRE"           teammate → "JASON — MASSACRE" (name in their tint when known)
## Text: data/callouts.json events[event_id].label / .display / .line (trailing "!" trimmed), else event_id.to_upper().
## Timing: stamp-in 0.16 s (scale punch 1.7 → 1.0), hold, slide-out 0.25 s; HOLD_TOTAL ≈ 2 s on screen.
## Rapid callouts: a higher-priority line replaces the one on screen; others queue (QUEUE_MAX, each waits ≤ MAX_WAIT s).
## Binds /root/Callouts itself (retries until it exists), so main.gd needs no hook. Solo and co-op both show it.
## Co-op: also listens to Net.callout_received(event_id, player_name, is_local) for TEAMMATES' callouts (shown even
## when this machine's Callouts drops the voice line on cooldown). Net emits callout_received and then calls
## Callouts.announce on every peer, so the same line can arrive twice: each arrival is remembered for DEDUP_S and a
## matching one from the other source (same id + name + local flag) is swallowed. Local callouts come from Callouts only.

const CONFIG_PATH := "res://data/callouts.json"
const STAMP_IN := 0.16
const SLIDE_OUT := 0.25
const SHOW_TIME := 2.0 ## total on screen, stamp-in + hold + slide-out
const QUEUE_MAX := 2
const MAX_WAIT := 3.0
const ROT_DEG := -4.0
const SEP := " — "
const DEDUP_S := 4.0 ## > Callouts' queue wait, so a queued voice line still matches the Net arrival
const LAPI := preload("res://scripts/ui/lobby_api.gd")

var tint_lookup: Callable = Callable() ## (player_name: String) -> Variant Color or null
var current: Dictionary = {} ## {id, name, local, text, prio}
var queue: Array = [] ## [{..., waited}]
var shown_log: Array = [] ## texts in the order they were stamped (tests)
var phase: String = "idle" ## idle | in | hold | out
var t: float = 0.0

var _labels: Dictionary = {} ## event_id -> label (from callouts.json)
var _prio: Dictionary = {}
var _stamp: PanelContainer
var _text: RichTextLabel
var _callouts: Node
var _bind_t: float = 0.0
var _base_y: float = 92.0 ## top of the stamp: below round/points row, above the teammate list
var _net: Node
var _recent: Array = [] ## [{key, src: "net"|"callouts", age}] arrivals for de-duplication
var deduped: int = 0 ## tests: arrivals swallowed as duplicates


func _ready() -> void:
	name = "CalloutBanner"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_labels()
	_stamp = PanelContainer.new()
	_stamp.name = "CalloutStamp"
	var st := UIStyle.cut_box(Color(UIStyle.BLOOD.darkened(0.45), 0.92), UIStyle.BONE, 4, 14)
	st.content_margin_left = 26
	st.content_margin_right = 26
	st.content_margin_top = 6
	st.content_margin_bottom = 8
	_stamp.add_theme_stylebox_override("panel", st)
	_stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stamp)
	_text = RichTextLabel.new()
	_text.name = "CalloutText"
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.autowrap_mode = TextServer.AUTOWRAP_OFF
	_text.scroll_active = false
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.add_theme_font_override("normal_font", UIStyle.FONT_STENCIL)
	_text.add_theme_font_size_override("normal_font_size", 46)
	_text.add_theme_color_override("default_color", UIStyle.BONE)
	_text.add_theme_constant_override("outline_size", 8)
	_text.add_theme_color_override("font_outline_color", Color(0.05, 0.0, 0.0, 0.9))
	_stamp.add_child(_text)
	_stamp.rotation_degrees = ROT_DEG
	_stamp.visible = false
	preload("res://scripts/ui/coop_hud.gd").ignore_mouse(self)
	_bind()


func _load_labels() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not (d is Dictionary):
		return
	var ev: Dictionary = d.get("events", {})
	for id in ev:
		var e: Dictionary = ev[id]
		var lab := str(e.get("label", e.get("display", e.get("line", ""))))
		lab = lab.strip_edges().rstrip("!.").strip_edges()
		if lab != "":
			_labels[str(id)] = lab.to_upper()
		_prio[str(id)] = int(e.get("priority", 0))


## Display label for an event id (callouts.json, else the id uppercased).
func label_for(event_id: String) -> String:
	return str(_labels.get(event_id, event_id.to_upper()))


func priority_for(event_id: String) -> int:
	if _callouts and _callouts.has_method("priority_of"):
		return int(_callouts.priority_of(event_id))
	return int(_prio.get(event_id, 0))


## Plain banner text (no colour tags).
func text_for(event_id: String, player_name: String, is_local: bool) -> String:
	if is_local or player_name == "":
		return label_for(event_id)
	return player_name.to_upper() + SEP + label_for(event_id)


func _bind() -> void:
	_bind_net()
	if _callouts and is_instance_valid(_callouts):
		return
	_callouts = get_node_or_null("/root/Callouts")
	if _callouts and _callouts.has_signal("callout_played") and not _callouts.callout_played.is_connected(on_callout):
		_callouts.callout_played.connect(on_callout)


func _bind_net() -> void:
	if _net and is_instance_valid(_net):
		return
	var n := LAPI.existing(self) if is_inside_tree() else null
	if n:
		bind_net(n)


func bind_net(n: Node) -> void:
	_net = n
	LAPI.sig(n, "callout_received", on_net_callout)


func bind_callouts(c: Node) -> void:
	_callouts = c
	if c and c.has_signal("callout_played") and not c.callout_played.is_connected(on_callout):
		c.callout_played.connect(on_callout)


## Net.callout_received handler: teammates only (local lines come through Callouts.callout_played).
func on_net_callout(event_id: String, player_name: String = "", is_local: bool = false) -> void:
	if is_local:
		return
	if _seen_other(event_id, player_name, is_local, "net"):
		return
	_show_or_queue(event_id, player_name, is_local)


## Callouts.callout_played handler.
func on_callout(event_id: String, player_name: String = "", is_local: bool = true) -> void:
	if not is_local and _seen_other(event_id, player_name, is_local, "callouts"):
		return
	_show_or_queue(event_id, player_name, is_local)


## Remembers this arrival; true when the same line already arrived from the other source (then it's consumed).
func _seen_other(event_id: String, player_name: String, is_local: bool, src: String) -> bool:
	var key := "%s|%s|%s" % [event_id, player_name.to_lower(), is_local]
	for i in _recent.size():
		var r: Dictionary = _recent[i]
		if str(r.key) == key and str(r.src) != src:
			_recent.remove_at(i)
			deduped += 1
			return true
	_recent.append({"key": key, "src": src, "age": 0.0})
	return false


func _show_or_queue(event_id: String, player_name: String, is_local: bool) -> void:
	var e := {"id": event_id, "name": player_name, "local": is_local, "text": text_for(event_id, player_name, is_local),
		"prio": priority_for(event_id), "waited": 0.0}
	if phase == "idle":
		_show(e)
		return
	if int(e.prio) > int(current.get("prio", 0)):
		_show(e) # replace: higher tier wins the screen now
		return
	if str(current.get("text", "")) == str(e.text) and phase != "out":
		t = minf(t, STAMP_IN) # same line again: re-punch, no duplicate
		return
	queue.append(e)
	queue.sort_custom(func(a, b): return int(a.prio) > int(b.prio))
	while queue.size() > QUEUE_MAX:
		queue.pop_back()


func _show(e: Dictionary) -> void:
	current = e
	phase = "in"
	t = 0.0
	shown_log.append(str(e.text))
	var tint = null
	if not bool(e.local) and str(e.name) != "" and tint_lookup.is_valid():
		tint = tint_lookup.call(str(e.name))
	var lab := label_for(str(e.id))
	if bool(e.local) or str(e.name) == "":
		_text.text = "[center]%s[/center]" % lab
	else:
		var nc: Color = tint if tint is Color else UIStyle.BONE
		_text.text = "[center][color=#%s]%s[/color][color=#%s]%s[/color]%s[/center]" % [nc.to_html(false), str(e.name).to_upper(),
			UIStyle.BLOOD.lightened(0.35).to_html(false), SEP, lab]
	if tint is Color:
		_stamp.set_meta("tint", tint)
	elif _stamp.has_meta("tint"):
		_stamp.remove_meta("tint")
	_stamp.visible = true
	_stamp.reset_size()
	_layout() # silent: the announcer voice (Callouts) is the sound


func _layout() -> void:
	var vs := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	var sz := _stamp.get_combined_minimum_size()
	_stamp.size = sz
	_stamp.pivot_offset = sz * 0.5
	_stamp.position = Vector2((vs.x - sz.x) * 0.5, _base_y)


func is_showing() -> bool:
	return phase != "idle"


func banner_text() -> String:
	return str(current.get("text", "")) if is_showing() else ""


## Advances the animation (also driven by _process); tests call it with fixed steps.
func advance(delta: float) -> void:
	for r in _recent:
		r.age = float(r.age) + delta
	_recent = _recent.filter(func(r): return float(r.age) <= DEDUP_S)
	for q in queue:
		q.waited = float(q.waited) + delta
	queue = queue.filter(func(q): return float(q.waited) <= MAX_WAIT)
	if phase == "idle":
		return
	t += delta
	var hold_end := SHOW_TIME - SLIDE_OUT
	if t < STAMP_IN:
		phase = "in"
		var k := t / STAMP_IN
		var s := lerpf(1.7, 1.0, 1.0 - pow(1.0 - k, 3.0))
		_stamp.scale = Vector2(s, s)
		_stamp.modulate.a = clampf(k * 1.6, 0.0, 1.0)
		_stamp.rotation_degrees = ROT_DEG - 3.0 * (1.0 - k)
		_stamp.position.y = _base_y
	elif t < hold_end:
		phase = "hold"
		var k2 := clampf((t - STAMP_IN) / 0.12, 0.0, 1.0) # tiny settle bounce
		var s2 := 1.0 + 0.04 * sin(k2 * PI)
		_stamp.scale = Vector2(s2, s2)
		_stamp.modulate.a = 1.0
		_stamp.rotation_degrees = ROT_DEG
	elif t < SHOW_TIME:
		phase = "out"
		var k3 := (t - hold_end) / SLIDE_OUT
		_stamp.modulate.a = 1.0 - k3
		_stamp.position.y = _base_y - 60.0 * k3 * k3
		_stamp.scale = Vector2.ONE * (1.0 - 0.08 * k3)
	else:
		phase = "idle"
		_stamp.visible = false
		current = {}
		if not queue.is_empty():
			_show(queue.pop_front())


func _process(delta: float) -> void:
	if _callouts == null or not is_instance_valid(_callouts) or _net == null or not is_instance_valid(_net):
		_bind_t -= delta
		if _bind_t <= 0.0:
			_bind_t = 1.0
			_bind()
	advance(delta)
