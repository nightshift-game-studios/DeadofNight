class_name HitMarker
extends Control
## Crosshair hit markers, drawn around the screen centre:
##  body hit  - small bone X, quick fade
##  headshot  - larger blood-red X with a slight scale pop
##  kill      - the X plus four outer brackets that kick outward, and a short-lived red dot
## Driven by hud.on_hit_registered(); several hits in a row just restart the animation
## (a headshot is never downgraded to a body marker while it is still showing).

enum Kind { BODY, HEAD }

const BODY_TIME := 0.16
const HEAD_TIME := 0.28
const KILL_TIME := 0.42

var _kind: int = Kind.BODY
var _t: float = 0.0 ## time left for the X
var _dur: float = BODY_TIME
var _kill_t: float = 0.0 ## time left for the kill flourish
var _frozen: bool = false ## screenshots: hold the current frame


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func show_hit(is_headshot: bool, is_kill: bool) -> void:
	if is_headshot or not (_t > 0.0 and _kind == Kind.HEAD):
		_kind = Kind.HEAD if is_headshot else Kind.BODY
		_dur = HEAD_TIME if is_headshot else BODY_TIME
		_t = _dur
	if is_kill:
		_kill_t = KILL_TIME
	set_process(true)
	queue_redraw()


## Test / screenshot helper: show a marker frozen at `progress` (0 = just hit, 1 = gone).
func debug_freeze(is_headshot: bool, is_kill: bool, progress: float = 0.25) -> void:
	show_hit(is_headshot, is_kill)
	_t = _dur * (1.0 - progress)
	_kill_t = KILL_TIME * (1.0 - progress) if is_kill else 0.0
	_frozen = true
	set_process(false)
	queue_redraw()


func is_showing() -> bool:
	return _t > 0.0 or _kill_t > 0.0


func kind_name() -> String:
	return "" if not is_showing() else ("head" if _kind == Kind.HEAD else "body")


func _process(delta: float) -> void:
	if _frozen:
		return
	_t = maxf(_t - delta, 0.0)
	_kill_t = maxf(_kill_t - delta, 0.0)
	queue_redraw()
	if not is_showing():
		set_process(false)


func _draw() -> void:
	var c := size * 0.5
	if _t > 0.0:
		var p := 1.0 - _t / _dur # 0 -> 1 over the marker's life
		var head := _kind == Kind.HEAD
		var a := clampf(_t / (_dur * 0.6), 0.0, 1.0)
		var pop := 1.0
		if head: # quick overshoot pop: 1.35 -> 1.0 in the first 30%
			pop = lerpf(1.35, 1.0, clampf(p / 0.3, 0.0, 1.0))
		var inner := (7.0 if head else 6.0) * pop
		var outer := (17.0 if head else 12.0) * pop
		var w := 3.0 if head else 2.0
		var col: Color = UIStyle.BLOOD.lightened(0.15) if head else UIStyle.BONE
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var n: Vector2 = d.normalized()
			draw_line(c + n * inner, c + n * outer, Color(0, 0, 0, 0.6 * a), w + 2.0, true)
			draw_line(c + n * inner, c + n * outer, Color(col, a), w, true)
	if _kill_t > 0.0:
		var kp := 1.0 - _kill_t / KILL_TIME
		var ka := clampf(_kill_t / (KILL_TIME * 0.5), 0.0, 1.0)
		var r := lerpf(20.0, 30.0, sqrt(kp)) # brackets kick outward
		var arm := 7.0
		var kc := Color(UIStyle.BLOOD.lightened(0.25), ka)
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var corner: Vector2 = c + d * r
			var pts := PackedVector2Array([corner - Vector2(d.x * arm, 0), corner, corner - Vector2(0, d.y * arm)])
			draw_polyline(pts, Color(0, 0, 0, 0.6 * ka), 5.0, true)
			draw_polyline(pts, kc, 3.0, true)
		draw_circle(c, lerpf(3.5, 2.0, kp), kc)
