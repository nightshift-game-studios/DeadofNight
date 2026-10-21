extends Node
## Autoload "Characters" (DESIGN §23.5, API: /workspace/skillz/CHARACTER_API.md): character save slots.
##
## Files (all written with Progress.write_atomic: .tmp -> .bak rotate -> rename; read with Progress._pick_save_file):
##   user://characters/index.cfg      [index] version, active, order, next_id, chars {id: {name, class, level, ...}}
##   user://characters/char_<id>.cfg  one character: [character] name / class / Q-ability picks / respecs,
##                                    [stats] [player] [skills] [stash] in the same shape progress.cfg uses.
## Per character: name, class, Q-ability pick per class, XP / level / skill points, tree ranks, respec count, stats,
## gear stash (class items included). Account-wide (stay in progress.cfg): Gravemark (+ lifetime), Armory, Merchant,
## Settings, and Scrap once Batch A lands.
##
## Progress keeps being the live view of the ACTIVE character (every game system reads Progress as before); this
## autoload swaps character data in and out of it. progress.cfg keeps a full copy of the active character too
## (Progress.save_data is unchanged), so an older build still opens the last character played. On every
## Progress.saved for the bound path the active character's file is rewritten. At boot, if progress.cfg was saved after
## the character file (older build / crash between the two writes), progress.cfg wins and is copied into the file.
##
## Binding: only the default Progress.save_path binds at boot. Tests (and anything else pointing Progress elsewhere)
## call bind(path) explicitly; a save to a different path never touches the bound character files.
## Not allowed while a match scene is live (Progress.bound_inventory() != null): create / delete / select (they swap
## the gear stash). set_class / set_ability follow the respec window instead (Progress.respec_allowed: home, round 0,
## game over), so the game-over screen can still switch class.

signal characters_changed ## list changed (create / delete / rename / level / class)
signal active_changed(id: int) ## a different character is now live in Progress
signal class_changed(id: int, class_id: String)
signal ability_changed(id: int, class_id: String, ability_id: String)
signal delete_requested(id: int, token: String)

const DEFAULT_SAVE := "user://progress.cfg"
const INDEX_FILE := "index.cfg"
const INDEX_VERSION := 1
const CHAR_SAVE_VERSION := 1
const MAX_CHARACTERS := 6
const NAME_MAX := 20
const DELETE_TOKEN_TTL_MS := 60000

var bound_path: String = "" ## the Progress save path this instance mirrors ("" = unbound)
var dir_path: String = "" ## user://characters (default) or <dir>/<save basename>_characters
var index: Dictionary = {}
var last_migration: String = "" ## "", "created_from_progress", "index_rebuilt", "progress_newer" (tests / logs)
var abilities: Dictionary = {} ## active character: class_id -> ability_id
var respecs_used: int = 0 ## active character: full respecs taken (SkillSpec)
var _pending_delete: Dictionary = {} ## id -> {token, at}
var spec: Node ## SkillSpec child (home-menu tree API)


func _ready() -> void:
	spec = load("res://scripts/skills/skill_spec.gd").new()
	spec.name = "SkillSpec"
	add_child(spec)
	var prog := _prog()
	if prog and str(prog.save_path) == DEFAULT_SAVE:
		bind(DEFAULT_SAVE)
	if prog and not prog.saved.is_connected(_on_progress_saved):
		prog.saved.connect(_on_progress_saved)


func _prog() -> Node:
	return get_node_or_null("/root/Progress")


static func dir_for(save_path: String) -> String:
	if save_path == DEFAULT_SAVE:
		return "user://characters"
	return save_path.get_base_dir().path_join(save_path.get_file().get_basename() + "_characters")


func char_path(id: int) -> String:
	return dir_path.path_join("char_%d.cfg" % id)


func index_path() -> String:
	return dir_path.path_join(INDEX_FILE)


## Attach to a Progress save path: load (or create / repair) the index and make the active character live in Progress.
## Idempotent. Migration from a pre-character save: character 1 is built from what Progress loaded.
func bind(save_path: String) -> void:
	bound_path = save_path
	dir_path = dir_for(save_path)
	_pending_delete.clear()
	last_migration = ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_path))
	var prog := _prog()
	var picked: Dictionary = Progress._pick_save_file(index_path())
	if picked.cfg != null and int(picked.cfg.get_value("index", "version", 0)) >= 1:
		index = _read_index(picked.cfg)
	else:
		index = _rebuild_index()
		last_migration = "index_rebuilt" if not index.order.is_empty() else ""
	if index.order.is_empty():
		# first boot with characters: the existing single save becomes character 1
		var id := _new_id()
		var nm := _default_name(1)
		index.chars[str(id)] = {"name": nm, "class": str(prog.selected_class) if prog else "soldier",
			"level": prog.get_level() if prog else 1, "created": _now(), "last_played": _now()}
		index.order.append(id)
		index.active = id
		abilities = {}
		respecs_used = 0
		_write_char(id)
		last_migration = "created_from_progress"
	elif not index.order.has(int(index.active)):
		index.active = int(index.order[0])
	if last_migration != "created_from_progress":
		var cf: Dictionary = Progress._pick_save_file(char_path(active_id()))
		var prog_serial: int = int(prog.save_serial) if prog else 0
		if cf.cfg != null and int(cf.cfg.get_value("meta", "progress_serial", -1)) >= prog_serial:
			_apply_char(cf.cfg)
		else:
			# progress.cfg is newer than the character file (older build / crash between writes): keep Progress,
			# copy it into the active character.
			if cf.cfg != null:
				_read_char_meta(cf.cfg)
				last_migration = "progress_newer"
			_write_char(active_id())
	_write_index()
	characters_changed.emit()
	active_changed.emit(active_id())


func unbind() -> void:
	bound_path = ""
	dir_path = ""
	index = {}


func is_bound() -> bool:
	return bound_path != ""


func _on_progress_saved(path: String) -> void:
	if not is_bound() or path != bound_path:
		return
	_write_char(active_id())
	var e: Dictionary = index.chars.get(str(active_id()), {})
	if not e.is_empty():
		var prog := _prog()
		e["level"] = prog.get_level()
		e["class"] = str(prog.selected_class)
		e["last_played"] = _now()
	_write_index()


# ---------------------------------------------------------------- queries

## [{id, name, class, class_name, ability, level, created, last_played, active}] in slot order.
func list() -> Array:
	var out: Array = []
	if index.is_empty():
		return out
	for id in index.order:
		var e: Dictionary = index.chars.get(str(id), {})
		var cls := str(e.get("class", "soldier"))
		out.append({"id": int(id), "name": str(e.get("name", "")), "class": cls,
			"class_name": ClassRoster.template(cls).display_name, "level": int(e.get("level", 1)),
			"created": int(e.get("created", 0)), "last_played": int(e.get("last_played", 0)),
			"active": int(id) == active_id(), "ability": ability_for(cls) if int(id) == active_id() else str(e.get("abilities", {}).get(cls, ClassRoster.default_ability(cls)))})
	return out


func count() -> int:
	return index.get("order", []).size()


func active_id() -> int:
	return int(index.get("active", 0))


func get_character(id: int) -> Dictionary:
	for c in list():
		if c.id == id:
			return c
	return {}


## Why an edit is refused right now ("" = allowed).
func blocked_reason() -> String:
	if not is_bound():
		return "Characters are not loaded."
	var prog := _prog()
	if prog and prog.bound_inventory() != null:
		return "Finish or leave the match first."
	return ""


## Why set_class / set_ability are refused right now ("" = allowed): the respec window (home, round 0, game over).
func loadout_blocked_reason() -> String:
	if not is_bound():
		return "Characters are not loaded."
	var prog := _prog()
	if prog and not prog.respec_allowed:
		return "Change class at home, before round 1 or after game over."
	return ""


## The home menu calls this when it opens: home is always inside the respec / loadout window, and picks made from
## here on can be undone for free (SkillSpec session).
func enter_home() -> void:
	var prog := _prog()
	if prog:
		prog.respec_allowed = true
	if spec:
		spec.begin_session()


## The home menu calls this when it starts a match (or closes): picks become permanent.
func leave_home() -> void:
	if spec:
		spec.end_session()


func validate_name(n: String) -> String:
	var s := n.strip_edges()
	if s.length() < 1:
		return "Name can't be empty."
	if s.length() > NAME_MAX:
		return "Name is too long (max %d characters)." % NAME_MAX
	return ""


# ---------------------------------------------------------------- edits (each returns {ok, reason, ...})

func create(char_name: String, class_id: String = "soldier", make_active := true) -> Dictionary:
	var why := blocked_reason()
	if why == "" and count() >= MAX_CHARACTERS:
		why = "All %d character slots are in use." % MAX_CHARACTERS
	if why == "":
		why = validate_name(char_name)
	if why == "" and not ClassRoster.has(class_id):
		why = "Unknown class."
	if why != "":
		return {"ok": false, "reason": why}
	var id := _new_id()
	var cfg := ConfigFile.new()
	_fill_char_cfg(cfg, id, {"name": char_name.strip_edges(), "class": class_id, "created": _now()}, null)
	if Progress.write_atomic(cfg, char_path(id)) != OK:
		return {"ok": false, "reason": "Could not write the character file."}
	index.chars[str(id)] = {"name": char_name.strip_edges(), "class": class_id, "level": 1, "created": _now(), "last_played": 0}
	index.order.append(id)
	_write_index()
	characters_changed.emit()
	if make_active:
		select(id)
	return {"ok": true, "id": id, "reason": ""}


func rename(id: int, new_name: String) -> Dictionary:
	var why := "" if is_bound() else "Characters are not loaded."
	if why == "" and not index.chars.has(str(id)):
		why = "No such character."
	if why == "":
		why = validate_name(new_name)
	if why != "":
		return {"ok": false, "reason": why}
	index.chars[str(id)]["name"] = new_name.strip_edges()
	if id == active_id():
		_write_char(id)
	else:
		var p: Dictionary = Progress._pick_save_file(char_path(id))
		if p.cfg != null:
			p.cfg.set_value("character", "name", new_name.strip_edges())
			Progress.write_atomic(p.cfg, char_path(id))
	_write_index()
	characters_changed.emit()
	return {"ok": true, "reason": ""}


## Step 1 of delete: returns {ok, token, reason, name}. The UI shows "Delete <name>? This can't be undone." and passes
## the token to delete() on confirm. Tokens are single-use, per character, and expire after 60 s.
func request_delete(id: int) -> Dictionary:
	var why := blocked_reason()
	if why == "" and not index.chars.has(str(id)):
		why = "No such character."
	if why == "" and count() <= 1:
		why = "You can't delete your only character."
	if why != "":
		return {"ok": false, "token": "", "reason": why}
	var token := "%08x" % (randi() & 0x7fffffff)
	_pending_delete[id] = {"token": token, "at": Time.get_ticks_msec()}
	delete_requested.emit(id, token)
	return {"ok": true, "token": token, "reason": "", "name": str(index.chars[str(id)].get("name", ""))}


func delete(id: int, token: String) -> Dictionary:
	var why := blocked_reason()
	var pend: Dictionary = _pending_delete.get(id, {})
	if why == "" and (pend.is_empty() or str(pend.token) != token or Time.get_ticks_msec() - int(pend.at) > DELETE_TOKEN_TTL_MS):
		why = "Delete not confirmed (ask again)."
	if why == "" and count() <= 1:
		why = "You can't delete your only character."
	if why != "":
		return {"ok": false, "reason": why}
	_pending_delete.erase(id)
	if id == active_id():
		var next := -1
		for o in index.order:
			if int(o) != id:
				next = int(o)
				break
		var r := select(next)
		if not r.ok:
			return r
	index.order.erase(id)
	index.chars.erase(str(id))
	_write_index()
	Progress.delete_save_files(char_path(id))
	characters_changed.emit()
	return {"ok": true, "reason": ""}


## Make another character live: saves the current one, loads the other into Progress, saves (progress.cfg mirror).
func select(id: int) -> Dictionary:
	var why := blocked_reason()
	if why == "" and not index.chars.has(str(id)):
		why = "No such character."
	if why != "":
		return {"ok": false, "reason": why}
	if id == active_id():
		return {"ok": true, "reason": ""}
	var prog := _prog()
	prog.save_data() # current character -> its file (via saved)
	var p: Dictionary = Progress._pick_save_file(char_path(id))
	if p.cfg == null:
		return {"ok": false, "reason": "That character's save is missing."}
	index.active = id
	_apply_char(p.cfg)
	index.chars[str(id)]["last_played"] = _now()
	if spec:
		spec.end_session()
	prog.save_data()
	characters_changed.emit()
	active_changed.emit(id)
	return {"ok": true, "reason": ""}


## Home loadout: the active character's class (persisted per character).
func set_class(class_id: String) -> Dictionary:
	var why := loadout_blocked_reason()
	if why == "" and not ClassRoster.has(class_id):
		why = "Unknown class."
	if why != "":
		return {"ok": false, "reason": why}
	var prog := _prog()
	prog.selected_class = class_id
	if spec:
		spec.end_session()
	prog.save_data()
	class_changed.emit(active_id(), class_id)
	characters_changed.emit()
	return {"ok": true, "reason": ""}


## Home loadout: which Q ability the active character takes for `class_id` (persisted per character and class).
func set_ability(class_id: String, ability_id: String) -> Dictionary:
	var why := loadout_blocked_reason()
	if why == "" and not ClassRoster.has(class_id):
		why = "Unknown class."
	if why == "" and not (ability_id in ClassRoster.ability_ids(class_id)):
		why = "That ability isn't part of this class."
	if why != "":
		return {"ok": false, "reason": why}
	abilities[class_id] = ability_id
	_prog().save_data()
	ability_changed.emit(active_id(), class_id, ability_id)
	return {"ok": true, "reason": ""}


## The Q ability the active character uses for `class_id` (class default when never picked).
func ability_for(class_id: String) -> String:
	var a := str(abilities.get(class_id, ""))
	return a if a in ClassRoster.ability_ids(class_id) else ClassRoster.default_ability(class_id)


## Loadout panel data for the active character: {class, ability, classes: [ClassRoster.describe + "selected"]}.
func loadout() -> Dictionary:
	var prog := _prog()
	var cls := str(prog.selected_class) if prog else "soldier"
	var rows: Array = []
	for c in ClassRoster.ids():
		var d := ClassRoster.describe(c)
		d["selected"] = c == cls
		d["ability"] = ability_for(c)
		rows.append(d)
	return {"class": cls, "ability": ability_for(cls), "classes": rows, "blocked": loadout_blocked_reason()}


# ---------------------------------------------------------------- files

func _new_id() -> int:
	var id := maxi(int(index.get("next_id", 1)), 1)
	while index.get("chars", {}).has(str(id)):
		id += 1
	index["next_id"] = id + 1
	return id


func _default_name(n: int) -> String:
	var st := get_node_or_null("/root/Settings")
	var pn := str(st.player_name).strip_edges() if st and "player_name" in st else ""
	if pn != "" and pn.length() <= NAME_MAX:
		return pn
	return "Survivor %d" % n


func _now() -> int:
	return int(Time.get_unix_time_from_system())


func _read_index(cfg: ConfigFile) -> Dictionary:
	var d := {"version": INDEX_VERSION, "active": int(cfg.get_value("index", "active", 0)), "order": [],
		"next_id": int(cfg.get_value("index", "next_id", 1)), "chars": {}}
	var chars = cfg.get_value("index", "chars", {})
	if typeof(chars) != TYPE_DICTIONARY:
		chars = {}
	for o in cfg.get_value("index", "order", []):
		var k := str(int(o))
		if chars.has(k) and typeof(chars[k]) == TYPE_DICTIONARY and not d.order.has(int(o)):
			d.order.append(int(o))
			d.chars[k] = chars[k]
	return d


## Index lost or unreadable: rebuild from the char_<id>.cfg files present (sorted by id). Active = most recent.
func _rebuild_index() -> Dictionary:
	var d := {"version": INDEX_VERSION, "active": 0, "order": [], "next_id": 1, "chars": {}}
	var ids: Array = []
	var da := DirAccess.open(dir_path)
	if da:
		for f in da.get_files():
			var m := f.trim_suffix(".bak").trim_suffix(".tmp")
			if m.begins_with("char_") and m.ends_with(".cfg"):
				var n := int(m.trim_prefix("char_").trim_suffix(".cfg"))
				if n > 0 and not ids.has(n):
					ids.append(n)
	ids.sort()
	var best_played := -1
	for n in ids:
		var p: Dictionary = Progress._pick_save_file(dir_path.path_join("char_%d.cfg" % n))
		if p.cfg == null:
			continue
		var c: ConfigFile = p.cfg
		var lp := int(c.get_value("character", "last_played", 0))
		d.chars[str(n)] = {"name": str(c.get_value("character", "name", "Survivor %d" % n)),
			"class": str(c.get_value("player", "selected_class", "soldier")), "level": int(c.get_value("character", "level", 1)),
			"created": int(c.get_value("character", "created", 0)), "last_played": lp}
		d.order.append(n)
		d.next_id = maxi(int(d.next_id), n + 1)
		if lp > best_played:
			best_played = lp
			d.active = n
	return d


func _write_index() -> void:
	if not is_bound() or index.is_empty():
		return
	var cfg := ConfigFile.new()
	cfg.set_value("index", "version", INDEX_VERSION)
	cfg.set_value("index", "active", active_id())
	cfg.set_value("index", "order", index.order.duplicate())
	cfg.set_value("index", "next_id", int(index.next_id))
	cfg.set_value("index", "chars", index.chars.duplicate(true))
	cfg.set_value("meta", "save_serial", Time.get_ticks_usec())
	cfg.set_value("end", "complete", true)
	Progress.write_atomic(cfg, index_path())


## Active character (live in Progress) -> char_<id>.cfg.
func _write_char(id: int) -> void:
	if not is_bound() or id <= 0:
		return
	var e: Dictionary = index.chars.get(str(id), {})
	var cfg := ConfigFile.new()
	_fill_char_cfg(cfg, id, e, _prog())
	Progress.write_atomic(cfg, char_path(id))


## prog == null: a brand-new character (fresh stats, no stash).
func _fill_char_cfg(cfg: ConfigFile, id: int, e: Dictionary, prog: Node) -> void:
	var fresh := prog == null
	cfg.set_value("character", "version", CHAR_SAVE_VERSION)
	cfg.set_value("character", "id", id)
	cfg.set_value("character", "name", str(e.get("name", "Survivor %d" % id)))
	cfg.set_value("character", "created", int(e.get("created", _now())))
	cfg.set_value("character", "last_played", int(e.get("last_played", 0)))
	cfg.set_value("character", "abilities", {} if fresh else abilities.duplicate())
	cfg.set_value("character", "respecs_used", 0 if fresh else respecs_used)
	cfg.set_value("character", "level", 1 if fresh else prog.get_level())
	cfg.set_value("stats", "total_kills", 0 if fresh else prog.total_kills)
	cfg.set_value("stats", "best_round", 0 if fresh else prog.best_round)
	cfg.set_value("stats", "xp", 0 if fresh else prog.xp)
	cfg.set_value("stats", "games_played", 0 if fresh else prog.games_played)
	cfg.set_value("player", "selected_class", str(e.get("class", "soldier")) if fresh else str(prog.selected_class))
	cfg.set_value("skills", "version", 2)
	cfg.set_value("skills", "ranks", {} if fresh else prog.skill_ranks.duplicate())
	cfg.set_value("skills", "spent", 0 if fresh else prog.skill_points_spent)
	if not fresh and not prog.stash.is_empty():
		cfg.set_value("stash", "version", int(prog.stash.get("version", 1)))
		cfg.set_value("stash", "data", prog.stash)
	cfg.set_value("meta", "save_serial", Time.get_ticks_usec())
	cfg.set_value("meta", "progress_serial", -1 if fresh else int(prog.save_serial) + 0)
	cfg.set_value("end", "complete", true)


func _read_char_meta(cfg: ConfigFile) -> void:
	var ab = cfg.get_value("character", "abilities", {})
	abilities = ab.duplicate() if typeof(ab) == TYPE_DICTIONARY else {}
	respecs_used = maxi(int(cfg.get_value("character", "respecs_used", 0)), 0)


## char_<id>.cfg -> Progress (per-character fields only; account fields untouched).
func _apply_char(cfg: ConfigFile) -> void:
	var prog := _prog()
	_read_char_meta(cfg)
	prog.total_kills = int(cfg.get_value("stats", "total_kills", 0))
	prog.best_round = int(cfg.get_value("stats", "best_round", 0))
	prog.xp = int(cfg.get_value("stats", "xp", 0))
	prog.games_played = int(cfg.get_value("stats", "games_played", 0))
	var cls := str(cfg.get_value("player", "selected_class", "soldier"))
	prog.selected_class = cls if ClassRoster.has(cls) else "soldier"
	var ranks_v = cfg.get_value("skills", "ranks") if cfg.has_section_key("skills", "ranks") else null
	prog.skill_ranks = prog.migrate_ranks(ranks_v, [])
	prog.stash = prog.migrate_stash(cfg.get_value("stash", "data") if cfg.has_section_key("stash", "data") else null)
	prog._recompute_spent()
