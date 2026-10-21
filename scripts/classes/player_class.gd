class_name PlayerClass
extends Resource
## A playable class: base stats plus one active ability. Create new classes as
## .tres files in res://resources/classes/ (right-click > New Resource > PlayerClass).

@export var display_name: String = "Soldier"
## Stable id = file name in res://resources/classes/ (DESIGN §23).
@export var id: String = ""
## Short role line for the loadout picker ("Front line", ...).
@export var role: String = ""
@export_multiline var description: String = ""
@export var max_health: int = 100
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 8.5
@export var jump_velocity: float = 5.0
@export var ability: Ability ## the default Q ability (also the one used when the character picked nothing)
## Every Q ability the class can take (the loadout picks one; ClassRoster.build() sets `ability` to the pick).
## Rule (playtest #32): at least one entry that isn't kind "movement".
@export var abilities: Array[Resource] = [] ## Array of Ability (typed Resource so .tres files stay plain)
@export var grenade_id: String = "frag" ## key in data/grenades.json
