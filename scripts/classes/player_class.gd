class_name PlayerClass
extends Resource
## A playable class: base stats plus one active ability. Create new classes as
## .tres files in res://resources/classes/ (right-click > New Resource > PlayerClass).

@export var display_name: String = "Soldier"
@export_multiline var description: String = ""
@export var max_health: int = 100
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var jump_velocity: float = 5.0
@export var ability: Ability
@export var grenade_id: String = "frag" ## key in data/grenades.json
