extends OmniLight3D
## Cheap unshadowed flicker for work lights / fires / spark flashes.
@export var base_energy: float = 1.4
@export var jitter: float = 0.45
@export var speed: float = 9.0
@export var pulse_only: bool = false ## if true, mostly off with rare flashes (sparks)
@export var pulse_interval: float = 2.8
@export var pulse_duration: float = 0.12
var _t: float = 0.0
var _next_pulse: float = 0.0

func _ready() -> void:
	shadow_enabled = false
	distance_fade_enabled = true
	if distance_fade_begin <= 0.0:
		distance_fade_begin = 28.0
		distance_fade_length = 10.0
	_next_pulse = randf() * pulse_interval
	_t = randf() * 10.0

func _process(delta: float) -> void:
	_t += delta
	if pulse_only:
		_next_pulse -= delta
		if _next_pulse <= 0.0:
			light_energy = base_energy * randf_range(0.8, 1.3)
			await get_tree().create_timer(pulse_duration).timeout
			light_energy = 0.0
			_next_pulse = pulse_interval * randf_range(0.6, 1.5)
		return
	var n := sin(_t * speed) * 0.5 + sin(_t * speed * 1.7 + 1.3) * 0.5
	light_energy = base_energy * (1.0 + n * jitter)
