class_name ClassRoster
extends RefCounted
## The playable classes (DESIGN §23.1) and their Q-ability loadouts. One .tres per class in res://resources/classes/
## (PlayerClass: stats, grenade, `abilities` = every Q ability it can take, `ability` = the default).
## Progress.load_selected_class() goes through load_for_progress(): the class the character plays, with the Q ability
## the character picked for it (Characters.ability_for(class)), so player.gd needs no change.

const IDS: Array[String] = ["soldier", "scout", "sexton", "chandler"] ## picker order
const DIR := "res://resources/classes/%s.tres"
const MOVEMENT := "movement"

static var _cache: Dictionary = {}


static func ids() -> Array[String]:
	return IDS.duplicate()


static func has(class_id: String) -> bool:
	return class_id in IDS and ResourceLoader.exists(DIR % class_id)


## The shared template (do not mutate; build() returns a private copy).
static func template(class_id: String) -> PlayerClass:
	if not has(class_id):
		class_id = "soldier"
	if not _cache.has(class_id):
		_cache[class_id] = load(DIR % class_id) as PlayerClass
	return _cache[class_id]


static func abilities(class_id: String) -> Array:
	var c := template(class_id)
	var out: Array = []
	for a in c.abilities:
		if a is Ability:
			out.append(a)
	if out.is_empty() and c.ability:
		out.append(c.ability)
	return out


static func ability_ids(class_id: String) -> Array[String]:
	var out: Array[String] = []
	for a in abilities(class_id):
		out.append(str(a.id))
	return out


static func default_ability(class_id: String) -> String:
	var c := template(class_id)
	return str(c.ability.id) if c.ability else (ability_ids(class_id)[0] if not ability_ids(class_id).is_empty() else "")


static func find_ability(class_id: String, ability_id: String) -> Ability:
	for a in abilities(class_id):
		if str(a.id) == ability_id:
			return a
	return null


## Loadout rows: [{id, name, kind, summary, cooldown, duration, default, movement}].
static func ability_info(class_id: String) -> Array:
	var out: Array = []
	var d := default_ability(class_id)
	for a in abilities(class_id):
		out.append({"id": str(a.id), "name": a.display_name, "kind": str(a.kind), "summary": str(a.summary),
			"cooldown": a.cooldown, "duration": a.duration, "default": str(a.id) == d, "movement": str(a.kind) == MOVEMENT})
	return out


## A private PlayerClass for `class_id` whose `ability` is `ability_id` (unknown / "" = the class default).
static func build(class_id: String, ability_id: String = "") -> PlayerClass:
	var t := template(class_id)
	var c: PlayerClass = t.duplicate()
	var a := find_ability(class_id if has(class_id) else "soldier", ability_id)
	if a:
		c.ability = a
	return c


## Progress.load_selected_class(): the selected class + this character's Q pick.
static func load_for_progress(prog: Node) -> PlayerClass:
	var cid := str(prog.selected_class) if prog else "soldier"
	var pick := ""
	var ml := Engine.get_main_loop()
	var chars: Node = (ml as SceneTree).root.get_node_or_null("Characters") if ml is SceneTree else null
	if chars and chars.has_method("ability_for"):
		pick = str(chars.ability_for(cid))
	return build(cid, pick)


## Picker card: {id, name, role, description, max_health, walk_speed, sprint_speed, jump_velocity, grenade_id, abilities}.
static func describe(class_id: String) -> Dictionary:
	var c := template(class_id)
	return {"id": class_id, "name": c.display_name, "role": c.role, "description": c.description,
		"max_health": c.max_health, "walk_speed": c.walk_speed, "sprint_speed": c.sprint_speed,
		"jump_velocity": c.jump_velocity, "grenade_id": c.grenade_id, "abilities": ability_info(class_id)}
