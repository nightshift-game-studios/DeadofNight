extends Node3D
## Timer-driven GPUParticles3D burst + brief unshadowed Omni flash.
@export var interval: float = 3.2
@export var flash_energy: float = 2.2
@export var flash_range: float = 4.5
var _parts: GPUParticles3D
var _light: OmniLight3D
var _timer: float = 0.0

func _ready() -> void:
	_parts = get_node_or_null("Sparks") as GPUParticles3D
	_light = get_node_or_null("Flash") as OmniLight3D
	if _light:
		_light.shadow_enabled = false
		_light.light_energy = 0.0
		_light.omni_range = flash_range
		_light.light_color = Color(0.7, 0.85, 1.0)
	_timer = randf() * interval

func _process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = interval * randf_range(0.7, 1.4)
	if _parts:
		_parts.restart()
		_parts.emitting = true
	if _light:
		_light.light_energy = flash_energy
		await get_tree().create_timer(0.08).timeout
		_light.light_energy = 0.0
