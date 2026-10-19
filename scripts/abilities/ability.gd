class_name Ability
extends Resource
## Base class for an active ability (bound to Q). Make a new ability by extending
## this script and overriding activate(). Abilities are Resources, so you can
## create/tune them in the Inspector and save them as .tres files.

@export var display_name: String = "Ability"
@export var cooldown: float = 5.0 ## seconds
@export var duration: float = 0.0 ## seconds the effect lasts (0 = instant)


## Called when the player presses Q and the ability is off cooldown.
## Return true if it actually fired (which starts the cooldown).
func activate(_player: Node) -> bool:
	return false


## Called every physics frame while the effect is active (optional override).
func process_active(_player: Node, _delta: float) -> void:
	pass


## Called once when the effect's duration runs out (optional override).
func end(_player: Node) -> void:
	pass


## With extra charges (Twin Stride, Reverb Core): may it fire again while still active?
func allow_recast_while_active() -> bool:
	return true
