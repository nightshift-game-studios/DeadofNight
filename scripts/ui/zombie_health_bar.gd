class_name ZombieHealthBar
extends MeshInstance3D
## Small rugged health bar floating above a zombie (one quad, one shader, see
## res://shaders/zombie_health_bar.gdshader). Hidden until the zombie is first damaged,
## fades out after `linger` seconds without hits, hidden immediately on death.
## Only processes while visible, so idle zombies cost nothing.

const SHADER := preload("res://shaders/zombie_health_bar.gdshader")
const BAR_SIZE := Vector2(0.62, 0.09)

@export var linger: float = 3.0 ## seconds after the last hit before it fades
@export var fade_time: float = 0.6

var _frac: float = 1.0
var _ghost: float = 1.0
var _since_hit: float = 0.0
var _mat: ShaderMaterial


static func make(height: float) -> ZombieHealthBar:
	var b := ZombieHealthBar.new()
	var q := QuadMesh.new()
	q.size = BAR_SIZE
	b.mesh = q
	b.position = Vector3(0, height, 0)
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b._mat = ShaderMaterial.new()
	b._mat.shader = SHADER
	b._mat.set_shader_parameter("aspect", BAR_SIZE.x / BAR_SIZE.y)
	b._mat.render_priority = 2
	b.material_override = b._mat
	b.visible = false
	b.set_process(false)
	return b


## Call after every hit with the new health fraction (0..1).
func show_damage(frac: float) -> void:
	frac = clampf(frac, 0.0, 1.0)
	if not visible:
		_ghost = _frac # ghost starts where the bar was
	_frac = frac
	_since_hit = 0.0
	visible = true
	set_process(true)
	_apply(1.0)


func hide_now() -> void:
	visible = false
	set_process(false)


func is_showing() -> bool:
	return visible


func _process(delta: float) -> void:
	_since_hit += delta
	if _ghost > _frac:
		_ghost = maxf(_ghost - delta * 0.8, _frac)
	var a := 1.0
	if _since_hit > linger:
		a = 1.0 - (_since_hit - linger) / fade_time
		if a <= 0.0:
			hide_now()
			return
	_apply(a)


func _apply(a: float) -> void:
	_mat.set_shader_parameter("fill", _frac)
	_mat.set_shader_parameter("ghost", maxf(_ghost, _frac))
	_mat.set_shader_parameter("alpha", a)
