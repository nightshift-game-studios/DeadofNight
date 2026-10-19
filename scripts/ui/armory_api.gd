extends RefCounted
## Thin factory for Skillz Armory (scripts/armory/armory.gd). Kept so home_menu / tests can
## `preload("res://scripts/ui/armory_api.gd").new()` — returns a live Armory instance.
## Prefer `Armory.new()` / preload armory.gd directly in new code.

const ArmoryScr := preload("res://scripts/armory/armory.gd")


static func create() -> RefCounted:
	return ArmoryScr.new()


func _init() -> void:
	# If someone does ArmoryAPIScript.new(), they get this empty RefCounted — prefer create().
	# armory_menu uses ArmoryScr directly.
	pass
