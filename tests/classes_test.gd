extends SceneTree
## Headless Batch C test (DESIGN §23):  godot --headless --path . -s res://tests/classes_test.gd
## Classes + Q-ability loadouts, non-movement abilities, class items + keystone synergies, the bigger tree's
## exclusivity, SkillSpec (home-menu API, undo, paid respec), character slots (create / rename / delete / select,
## per-character vs account data, crash-safe files, migration from a single save). Own save files only.
## Exit code = number of failures.

const SAVE := "user://progress_classes_test.cfg"

var _fails := 0
var _passes := 0
var prog
var chars
var spec
var gdb
var main
var player
var runner
var _sig: Array = []


func check(cond: bool, what: String) -> void:
	print(("PASS  " if cond else "FAIL  ") + what)
	if cond:
		_passes += 1
	else:
		_fails += 1


func near(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps


func wait(frames: int) -> void:
	for i in frames:
		await physics_frame


func _initialize() -> void:
	_run.call_deferred()


func _wipe() -> void:
	var P = load("res://scripts/autoload/progress.gd")
	P.delete_save_files(SAVE)
	var d: String = chars.dir_for(SAVE)
	if DirAccess.dir_exists_absolute(d):
		for f in DirAccess.get_files_at(d):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(d.path_join(f)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(d))


func _run() -> void:
	prog = root.get_node("Progress")
	chars = root.get_node_or_null("Characters")
	if chars == null: # autoload line not in project.godot yet (G4M3N patch): run it the same way by hand
		chars = load("res://scripts/autoload/characters.gd").new()
		chars.name = "Characters"
		root.add_child(chars)
	gdb = root.get_node("GearDB")
	spec = chars.spec
	prog.save_path = SAVE
	chars.unbind()
	_wipe()
	_roster_checks()
	_tree_checks()
	_item_data_checks()
	_migration_checks()
	_slot_checks()
	_spec_checks()
	await _scene_checks()
	chars.unbind()
	_wipe()
	print("CLASSES TEST: %s (%d passed, %d failed)" % ["OK" if _fails == 0 else "FAILED", _passes, _fails])
	quit(_fails)


# ---------------------------------------------------------------- classes / abilities data

func _roster_checks() -> void:
	check(ClassRoster.ids() == ["soldier", "scout", "sexton", "chandler"], "4 classes: soldier, scout, sexton, chandler")
	var every_has_non_move := true
	var kinds := {}
	for c in ClassRoster.ids():
		var t := ClassRoster.template(c)
		check(t.id == c and t.role != "" and t.abilities.size() == 2, "%s: id, role, 2 Q abilities" % c)
		var nm := false
		for a in ClassRoster.abilities(c):
			check(a.id != "" and a.summary != "" and a.cooldown > 0.0, "%s/%s has id, summary, cooldown" % [c, a.id])
			kinds[a.kind] = true
			nm = nm or a.kind != "movement"
		every_has_non_move = every_has_non_move and nm
	check(every_has_non_move, "every class has a non-movement ability (deployable / aura / mark)")
	check(kinds.has("deployable") and kinds.has("aura") and kinds.has("mark"), "deployable, aura and mark kinds all exist")
	var b := ClassRoster.build("soldier", "rally_banner")
	check(b.ability.id == "rally_banner" and ClassRoster.template("soldier").ability.id == "dash", "build() swaps the Q ability on a private copy")
	check(ClassRoster.build("soldier", "nope").ability.id == "dash" and ClassRoster.build("ghost").id == "soldier", "unknown ability -> default; unknown class -> Soldier")
	check(ClassRoster.describe("sexton").max_health == 125 and ClassRoster.describe("chandler").abilities.size() == 2, "describe() card data")


# ---------------------------------------------------------------- tree

func _tree_checks() -> void:
	var counts := {}
	for id in prog.all_node_ids():
		var b: String = prog.get_skill(id).branch
		counts[b] = int(counts.get(b, 0)) + 1
	check(prog.all_node_ids().size() == 109, "109 nodes (%d)" % prog.all_node_ids().size())
	check(counts.get("marksman") == 13 and counts.get("ledger") == 9 and counts.get("sexton") == 12 and counts.get("chandler") == 12, "branch sizes %s" % str(counts))
	var groups := {}
	for id in prog.all_node_ids():
		var g: String = prog.get_skill(id).choice_group
		if g != "":
			groups[g] = int(groups.get(g, 0)) + 1
	check(groups.size() >= 17, "%d mutually exclusive groups" % groups.size())
	var ab_ok := true
	for id in prog.all_node_ids():
		var n: Dictionary = prog.get_skill(id)
		if n.has("ability"):
			ab_ok = ab_ok and n["class"] != "" and n.ability in ClassRoster.ability_ids(n["class"])
	check(ab_ok, "every ability-gated node names one of its class's abilities")
	# class keystones: one per class, independent of the general keystone
	prog.xp = 250 * 300
	prog.skill_ranks = {"mk_root": 1, "mk_aim": 1, "mk_spotter": 1, "mk_legend": 1, "mk_key": 1,
		"sx_core": 1, "sx_peal": 1, "sx_clapper": 1, "sx_oath_wake": 1, "sx_capstone": 1}
	prog._recompute_spent()
	check(prog.state("sx_oath_mourner") == "excluded" and prog.excluded_by("sx_oath_mourner") == "sx_oath_wake", "oath fork: picking Wake locks Mourner")
	check(prog.state("sx_key_pallbearer") == "available" and prog.buy_rank("sx_key_pallbearer"), "class keystone available alongside a general keystone")
	check(prog.state("sx_key_vesper") == "excluded", "second Sexton keystone excluded")
	check(prog.state("mk_cadence") == "available", "doctrine fork open after the legend")
	prog.buy_rank("mk_cadence")
	check(prog.state("mk_culling") == "excluded" and prog.state("mk_called") == "available", "doctrine fork: Cadence locks Culling; its follow-up opens")
	prog.skill_ranks = {}
	prog._recompute_spent()


# ---------------------------------------------------------------- class items

func _item_data_checks() -> void:
	check(ClassItems.all_ids().size() == 16, "16 class item effects")
	var pairs := {}
	var lines_ok := true
	for id in ClassItems.all_ids():
		var d := ClassItems.def(id)
		var ks: String = d.synergy.keystone
		lines_ok = lines_ok and prog.get_skill(ks).get("keystone", false)
		for r in range(1, 6):
			lines_ok = lines_ok and not "{" in ClassItems.fill(d, "line", r)
		lines_ok = lines_ok and not "{" in ClassItems.fill(d.synergy, "line", 1)
		pairs[d["class"]] = int(pairs.get(d["class"], 0)) + 1
	check(lines_ok, "every class item line fills at every rarity; every synergy names a keystone")
	check(pairs.values() == [4, 4, 4, 4], "4 effects per class")
	prog.selected_class = "scout"
	var it= gdb.roll_armor("class_item", 2)
	check(it.class_effect != "" and it.class_id == "scout" and ClassItems.def(it.class_effect)["class"] == "scout", "rolled class item gets a Scout effect (%s)" % it.class_effect)
	check(it.display_name == ClassItems.def(it.class_effect).name and it.class_line() != "" and it.class_synergy_line().begins_with("With "), "named after its effect, one-line text + synergy line")
	var back= gdb.item_from_dict(it.to_dict())
	check(back.class_effect == it.class_effect and back.class_id == "scout", "class effect survives to_dict / item_from_dict")
	var legacy: Dictionary = it.to_dict()
	legacy.erase("class_effect")
	legacy.erase("class_id")
	var l1= gdb.item_from_dict(legacy)
	var l2= gdb.item_from_dict(legacy)
	check(l1.class_effect != "" and l1.class_effect == l2.class_effect and l1.class_id == "scout", "legacy class item: deterministic effect for the current class")
	var helm= gdb.roll_armor("helmet", 1)
	check(helm.class_effect == "", "other armor slots get no class effect")
	check(ClassItems.active_defs(it, "soldier").is_empty() and ClassItems.active_defs(it, "scout").size() == 1, "item only works for its own class")
	prog.skill_ranks = {ClassItems.synergy_keystone(it): 1}
	check(ClassItems.active_defs(it, "scout").size() == 2, "synergy joins when the paired keystone is owned")
	# ClassItems.owned(class_id): the active character's stash, equipped first
	var c2 = gdb.roll_armor("class_item", 1)
	prog.selected_class = "chandler"
	var c3 = gdb.roll_armor("class_item", 3)
	prog.stash = {"version": 1, "equipped": {"class_item": it.to_dict()}, "backpack": {"class_item": [c2.to_dict(), c3.to_dict()]}}
	var mine: Array = ClassItems.owned_rows("scout")
	check(ClassItems.owned("scout").size() == 2 and mine[0].equipped and not mine[1].equipped and mine[0].line != "", "owned('scout'): 2 Scout items, equipped first, with lines")
	check(ClassItems.owned("chandler").size() == 1 and ClassItems.owned("sexton").is_empty(), "owned() filters by class")
	prog.stash = {}
	prog.skill_ranks = {}
	prog.selected_class = "soldier"


# ---------------------------------------------------------------- migration

func _migration_checks() -> void:
	# a pre-Batch C single save
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "xp", 2500)
	cfg.set_value("stats", "total_kills", 77)
	cfg.set_value("player", "selected_class", "scout")
	cfg.set_value("skills", "ranks", {"mk_root": 1})
	cfg.set_value("armory", "gravemarks", 9)
	cfg.set_value("meta", "save_serial", 4)
	cfg.save(SAVE)
	prog.load_data()
	chars.bind(SAVE)
	check(chars.last_migration == "created_from_progress" and chars.count() == 1 and chars.active_id() == 1, "single save migrates into character 1")
	var dir: String = chars.dir_for(SAVE)
	check(FileAccess.file_exists(dir.path_join("index.cfg")) and FileAccess.file_exists(dir.path_join("char_1.cfg")), "index.cfg + char_1.cfg written")
	var c1 := ConfigFile.new()
	c1.load(dir.path_join("char_1.cfg"))
	var xp_v6: int = prog.rebase_xp(2500) # Economy v2: a pre-v6 save's xp is re-based onto the XP curve (level 11 kept)
	check(int(c1.get_value("stats", "xp")) == xp_v6 and int(c1.get_value("stats", "xp_curve", 0)) == 1 and str(c1.get_value("player", "selected_class")) == "scout" and c1.get_value("skills", "ranks") == {"mk_root": 1},
		"character 1 holds xp, class, ranks")
	check(not c1.has_section("armory") and not c1.has_section("merchant"), "account data (Gravemark, Armory, Merchant) stays out of the character file")
	chars.bind(SAVE)
	check(chars.last_migration == "" and chars.count() == 1 and prog.xp == xp_v6, "re-bind is idempotent (xp not re-based twice)")
	# index lost -> rebuilt from char files
	load("res://scripts/autoload/progress.gd").delete_save_files(dir.path_join("index.cfg"))
	chars.bind(SAVE)
	check(chars.last_migration == "index_rebuilt" and chars.count() == 1 and chars.list()[0].class == "scout", "missing index rebuilt from character files")
	# corrupt character main file -> .bak / .tmp recovery
	prog.save_data()
	prog.xp = 2750
	prog.save_data()
	var f := FileAccess.open(dir.path_join("char_1.cfg"), FileAccess.WRITE)
	f.store_string("[[[ torn")
	f = null
	prog.xp = 0
	prog.load_data()
	chars.bind(SAVE)
	check(prog.xp == 2750, "torn character file: progress.cfg (newer) wins (%d)" % prog.xp)
	# progress.cfg saved by an older build (no mirror) -> copied into the active character
	var pc := ConfigFile.new()
	pc.load(SAVE)
	pc.set_value("stats", "xp", 3000)
	pc.set_value("meta", "save_serial", int(pc.get_value("meta", "save_serial")) + 5)
	pc.save(SAVE)
	prog.load_data()
	chars.bind(SAVE)
	var c1b := ConfigFile.new()
	c1b.load(dir.path_join("char_1.cfg"))
	check(chars.last_migration == "progress_newer" and prog.xp == 3000 and int(c1b.get_value("stats", "xp")) == 3000, "newer progress.cfg (older build) wins and is mirrored")
	# renamed node id (Leech Habit -> Bloodtithe): old saves keep the rank
	check(prog.migrate_ranks({"sv_leech": 1, "sv_root": 1}, []) == {"sv_bloodtithe": 1, "sv_root": 1} and prog.get_skill("sv_bloodtithe").name == "Bloodtithe",
		"old id sv_leech loads as sv_bloodtithe (Bloodtithe)")
	# SaveMigration knows the folder
	var SM = load("res://scripts/autoload/save_migration.gd")
	var base := OS.get_user_data_dir().path_join("classes_sm_test")
	var old := base.path_join("Old")
	var older := base.path_join("Older")
	var dst := base.path_join("New")
	for d in [old.path_join("characters"), older.path_join("characters"), dst]:
		DirAccess.make_dir_recursive_absolute(d)
	for d in [old, older]:
		FileAccess.open(d.path_join("progress.cfg"), FileAccess.WRITE).store_string("[stats]\nxp=1\n")
		FileAccess.open(d.path_join("characters/index.cfg"), FileAccess.WRITE).store_string("[index]\nversion=1\n# " + d.get_file() + "\n")
	SM.migrate_all([old, older], dst)
	check(FileAccess.file_exists(dst.path_join("characters/index.cfg")) and "Old" in FileAccess.get_file_as_string(dst.path_join("characters/index.cfg"))
		and not "Older" in FileAccess.get_file_as_string(dst.path_join("characters/index.cfg")), "SaveMigration copies characters/ only from the dir that supplied progress.cfg")
	_rm_tree(base)


# ---------------------------------------------------------------- slots

func _slot_checks() -> void:
	_sig.clear()
	chars.characters_changed.connect(func(): _sig.append("list"))
	chars.active_changed.connect(func(id): _sig.append("active:%d" % id))
	prog.gravemarks = 11
	prog.save_data()
	var first: int = chars.active_id()
	var r: Dictionary = chars.create("", "sexton")
	check(not r.ok and r.reason != "", "create refuses an empty name")
	check(not chars.create("x".repeat(21), "sexton").ok, "create refuses a 21-char name")
	check(not chars.create("Bob", "warlock").ok, "create refuses an unknown class")
	r = chars.create("Ada", "sexton")
	check(r.ok and chars.active_id() == r.id and chars.count() == 2, "create + select Ada")
	check(prog.xp == 0 and prog.skill_ranks.is_empty() and prog.selected_class == "sexton" and prog.stash.is_empty(), "new character starts fresh (xp, ranks, class, gear)")
	check(prog.gravemarks == 11, "Gravemark is account-wide (still 11)")
	check(_sig.has("list") and _sig.has("active:%d" % r.id), "characters_changed + active_changed signals")
	prog.xp = 500
	chars.set_ability("sexton", "headstone")
	prog.save_data()
	check(chars.select(first).ok and prog.xp == 3000 and prog.selected_class == "scout", "select back: character 1's data restored")
	check(chars.select(r.id).ok and prog.xp == 500 and chars.ability_for("sexton") == "headstone", "select Ada: her xp and Q pick restored")
	prog.best_round = 7
	prog.games_played = 3
	prog.save_data()
	chars.select(first)
	var row_ada: Dictionary = chars.get_character(r.id)
	check(row_ada.best_round == 7 and row_ada.games_played == 3 and row_ada.ability == "headstone" and row_ada.ability_name == "Headstone",
		"list() rows: best_round, games_played, ability + ability_name (inactive character)")
	var row_me: Dictionary = chars.get_character(first)
	check(row_me.active and row_me.has("ability_name") and row_me.games_played == int(prog.games_played), "list() active row reads live Progress")
	chars.select(r.id)
	check(chars.rename(r.id, "  Ada Grey ").ok and chars.get_character(r.id).name == "Ada Grey", "rename (trimmed)")
	check(not chars.delete(r.id, "bogus").ok, "delete without a confirm token refused")
	var tok: Dictionary = chars.request_delete(r.id)
	check(tok.ok and tok.token != "" and tok.name == "Ada Grey", "request_delete returns a token + name to confirm")
	check(chars.delete(r.id, tok.token).ok and chars.count() == 1 and chars.active_id() == first, "delete active character -> falls back to the other")
	check(not FileAccess.file_exists(chars.char_path(r.id)) and not FileAccess.file_exists(chars.char_path(r.id) + ".bak"), "deleted character's files (and .bak) removed")
	check(not chars.request_delete(first).ok, "can't delete the last character")
	# match guard: an explicit flag (begin_match / leave_home), not "some Inventory is bound"
	chars.begin_match()
	check(chars.blocked_reason() != "" and not chars.create("Mid", "scout").ok, "begin_match: create / select refused")
	chars.end_match()
	check(chars.blocked_reason() == "", "end_match: allowed again")
	chars.leave_home()
	check(chars.is_match_live() and not chars.select(first).ok, "leave_home (starting a match) blocks switching")
	chars.enter_home()
	check(not chars.is_match_live(), "enter_home clears the match flag")
	var pl := Node3D.new() # a Player-owned Inventory still counts as a live match (scene loaded without begin_match)
	pl.add_to_group("player")
	var pinv := Node.new()
	pl.add_child(pinv)
	prog.bind_inventory(pinv)
	check(chars.blocked_reason() != "", "a Player's bound Inventory still blocks")
	prog.bind_inventory(null)
	pl.free()
	# Gooey #21: the home KIT binds its Inventory; that must not block, and must not leak gear across characters
	var other: Dictionary = chars.create("Kit Check", "scout", false)
	var ks := GDScript.new()
	ks.source_code = "extends Node\nfunc to_save_dict() -> Dictionary:\n\treturn {\"version\": 1, \"equipped\": {\"helmet\": {\"kind\": \"gear\", \"id\": \"kit_marker\"}}, \"backpack\": {}}\n"
	ks.reload()
	var kit_parent := Control.new()
	var kit = ks.new()
	kit_parent.add_child(kit)
	root.add_child(kit_parent)
	prog.bind_inventory(kit)
	var sw: Array = []
	chars.switching.connect(func(a, b): sw.append([a, b]))
	check(chars.blocked_reason() == "" and chars.request_delete(other.id).ok, "home kit Inventory bound: create / switch / delete allowed")
	check(chars.select(other.id).ok and sw == [[first, other.id]] and prog.bound_inventory() == null, "switch: `switching(from, to)` fired, kit unbound")
	check(prog.stash.is_empty(), "new character doesn't inherit the kit's gear")
	check(chars.select(first).ok and str(prog.stash.get("equipped", {}).get("helmet", {}).get("id", "")) == "kit_marker", "kit gear was saved into the character it belonged to")
	kit_parent.queue_free()
	var tk: Dictionary = chars.request_delete(other.id)
	chars.delete(other.id, tk.token)
	for i in chars.MAX_CHARACTERS:
		chars.create("Slot %d" % i, "scout", false)
	check(chars.count() == chars.MAX_CHARACTERS and not chars.create("Extra", "scout").ok, "max %d characters" % chars.MAX_CHARACTERS)
	# class switch persistence
	prog.respec_allowed = false
	check(not chars.set_class("chandler").ok, "set_class refused mid-round (respec window closed)")
	prog.respec_allowed = true
	check(chars.set_class("chandler").ok and prog.selected_class == "chandler", "set_class at home")
	check(not chars.set_ability("chandler", "dash").ok and chars.set_ability("chandler", "ember_brand").ok, "set_ability validates against the class kit")
	check(prog.load_selected_class().id == "chandler" and prog.load_selected_class().ability.id == "ember_brand", "Progress.load_selected_class uses class + Q pick")
	chars.bind(SAVE)
	check(prog.selected_class == "chandler" and chars.ability_for("chandler") == "ember_brand", "class + Q pick persist per character across reload")
	var lo: Dictionary = chars.loadout()
	check(lo.classes.size() == 4 and lo.class == "chandler" and lo.blocked == "", "loadout() panel data")


# ---------------------------------------------------------------- SkillSpec

func _spec_checks() -> void:
	prog.selected_class = "soldier"
	prog.skill_ranks = {}
	prog._recompute_spent()
	prog.xp = 250 * 12
	chars.respecs_used = 0
	chars.abilities.erase("soldier")
	var got: Array = []
	spec.node_changed.connect(func(id, r): got.append([id, r]))
	spec.begin_session()
	var cp: Dictionary = spec.can_pick("mk_aim")
	check(not cp.ok and cp.code == "locked" and "Steady Eye" in cp.reason, "can_pick says what's missing (%s)" % cp.reason)
	check(spec.pick("mk_root").ok and got == [["mk_root", 1]], "pick + node_changed")
	spec.pick("mk_aim")
	spec.pick("mk_spotter")
	cp = spec.can_pick("mk_longcount")
	check(not cp.ok and cp.code == "excluded" and "Spotter" in cp.reason, "exclusive pick explained (%s)" % cp.reason)
	check(spec.can_refund("mk_aim").code == "needed_by", "can't refund a node another owned node needs")
	check(spec.refund("mk_spotter").ok and spec.can_pick("mk_longcount").ok, "undo this visit's pick frees the other fork")
	var info: Dictionary = spec.node_info("so_colors")
	check(info.ability == "rally_banner" and info.inactive_reason.begins_with("Needs Rally Banner"), "ability-path node explains it needs Rally Banner")
	check(spec.node_info("sx_core").inactive_reason.begins_with("Sexton only"), "other class's node explains it")
	check(spec.list_nodes({"branch": "soldier"}).size() == 12 and spec.list_nodes({"class": ""}).size() == 61, "list_nodes filters")
	var pv: Dictionary = spec.preview("so_core")
	var hp_line: Dictionary = pv.lines.filter(func(l): return l.stat == "max_health")[0]
	check(near(hp_line.before, 100.0) and near(hp_line.after, 115.0) and pv.text_next != "", "preview: Max health 100 -> 115")
	pv = spec.preview("sv_skin")
	check(pv.rank_to == 1 and pv.lines.size() == 1, "preview of a ranked node")
	spec.end_session()
	check(spec.can_refund("mk_aim").code == "not_this_session", "after leaving home, refund needs a respec")
	var rc: Dictionary = spec.respec_cost()
	check(rc.allowed and rc.free and rc.amount == 0, "first full respec is free")
	var done: Array = []
	spec.respec_done.connect(func(c): done.append(c))
	check(spec.respec().ok and prog.skill_ranks.is_empty() and done == [0], "respec refunds everything, respec_done(0)")
	prog.skill_ranks = {"mk_root": 1, "mk_aim": 3}
	prog._recompute_spent()
	rc = spec.respec_cost()
	check(not rc.free and rc.amount == 10 and rc.currency == "scrap", "second respec costs Scrap: clamp(2 x 4, 10, 200) = %d" % rc.amount)
	check(rc.currency_available == spec.scrap_api_available(), "Scrap adapter reports whether Batch A's API exists")
	prog.respec_allowed = false
	prog.skill_ranks = {"mk_root": 1}
	prog._recompute_spent()
	check(not spec.respec_cost().allowed and not spec.respec().ok, "respec refused outside home / round 0 / game over")
	prog.respec_allowed = true
	prog.skill_ranks = {}
	prog._recompute_spent()


# ---------------------------------------------------------------- in a match: abilities + class items

func _scene_checks() -> void:
	prog.selected_class = "soldier"
	prog.skill_ranks = {}
	prog._recompute_spent()
	change_scene_to_file("res://scenes/main.tscn")
	await wait(5)
	for i in 240:
		if current_scene != null and current_scene.has_node("Player"):
			break
		await physics_frame
	main = current_scene
	main._break_timer = 99999.0
	player = main.get_node("Player")
	player.input_enabled = false
	runner = player.skill_runner
	await wait(30)
	# Rally Banner
	await _use("soldier", "rally_banner")
	var z := _zombie(Vector3(3, 0, 0))
	await wait(40)
	check(AbilityField.live(player, "rally_banner").size() == 1, "Rally Banner planted")
	check(player.overshield > 0.0 and z.has_status("slow"), "banner: overshield while near it, zombies slowed (%.0f)" % player.overshield)
	check(runner.cond("in_field", {}) and runner.cond("target_in_field", {"target": z}), "in_field / target_in_field conditions")
	player._ability_cd = 0.0
	player.use_ability()
	await wait(2)
	check(AbilityField.live(player, "rally_banner").size() == 1, "one banner at a time")
	# Chalk Mark
	await _use("scout", "chalk_mark", false)
	z = _zombie(_ahead(8.0))
	var far := _zombie(_ahead(-8.0))
	await wait(2)
	player.use_ability()
	await wait(2)
	check(z.has_status("mark") and not far.has_status("mark"), "Chalk Mark marks zombies ahead only")
	check(near(float(z.status("mark").amp), 0.25), "mark +25% damage taken")
	# Grave Bell
	await _use("sexton", "grave_bell", false)
	z = _zombie(Vector3(3, 0, 0), 1000)
	await wait(2)
	player.health = 50
	player.use_ability()
	await wait(220)
	var bell = player.ability
	check(bell.tolled == 4 and z.health <= 1000 - 4 * 25 and player.health > 50, "Grave Bell: 4 tolls hit, heal (%d tolls, hp %d)" % [bell.tolled, z.health])
	# Headstone
	await _use("sexton", "headstone", false)
	z = _zombie(_ahead(2.5), 1000)
	await wait(2)
	player.use_ability()
	await wait(40)
	check(AbilityField.live(player, "headstone").size() == 1 and z.has_status("slow") and z.has_status("mark"), "Headstone slows + marks nearby zombies")
	# Vigil Candle
	await _use("chandler", "vigil_candle", false)
	z = _zombie(Vector3(2, 0, 0), 1000)
	await wait(2)
	player.use_ability()
	await wait(70)
	check(z.has_status("burn") and z.health < 1000, "Vigil Candle burns zombies near it (%d)" % z.health)
	# Ember Brand
	await _use("chandler", "ember_brand", false)
	z = _zombie(_ahead(6.0), 10)
	var by := _zombie(_ahead(6.0) + Vector3(0.8, 0, 0.8), 1000)
	await wait(2)
	player.use_ability()
	await wait(2)
	check(z.has_status("brand") and z.has_status("burn"), "Ember Brand brands + burns")
	z.take_damage(100.0, z.global_position, false, player)
	player.register_hit(z, 100.0, false, true, {"target": z})
	await wait(3)
	check(by.health < 1000, "branded kill bursts on neighbours (%d)" % by.health)
	# ability-gated meta nodes + skill tuning
	await _use("soldier", "rally_banner", false, {"so_core": 1, "so_colors": 1, "so_ram": 1})
	check(not runner.effects_from("so_colors").is_empty() and runner.effects_from("so_ram").is_empty(), "banner path runs, Dash path idle with Rally Banner")
	check(near(player.mod_stat("ab_banner_radius", 6.0), 8.0), "Field Colors tunes banner radius 6 -> 8")
	# class item effect + synergy
	await _use("soldier", "dash", false)
	var ci= gdb.roll_armor("class_item", 4)
	ci.class_effect = "ci_tattered_standard"
	ci.class_id = "soldier"
	player.inventory.equipped["class_item"] = ci
	player.inventory.armor_changed.emit()
	z = _zombie(Vector3(3, 0, 0))
	await wait(2)
	player.overshield = 0.0
	var plain: float = player.mod_stat("damage_out", 100.0, {"target": z, "source": "gun"})
	player.overshield = 20.0
	var boosted: float = player.mod_stat("damage_out", 100.0, {"target": z, "source": "gun"})
	check(near(plain, 100.0) and near(boosted, 120.0), "Mythic Tattered Standard: +20%% with overshield (%.0f / %.0f)" % [plain, boosted])
	check(runner.effects_from("ci_syn:ci_tattered_standard").is_empty(), "no synergy without Stoneblood")
	prog.skill_ranks = {"sv_key": 1}
	player.apply_stats()
	check(runner.effects_from("ci_syn:ci_tattered_standard").size() == 1, "synergy active with Stoneblood")
	await _use("scout", "adrenaline", false)
	check(runner.effects_from("ci:ci_tattered_standard").is_empty(), "Soldier item does nothing on a Scout")
	player.inventory.equipped["class_item"] = null
	player.inventory.armor_changed.emit()
	prog.skill_ranks = {}
	prog.selected_class = "soldier"


func _use(cls: String, ability_id: String, fire := true, ranks := {}) -> void:
	for z in main.zombies_root.get_children():
		z.queue_free()
	for f in get_nodes_in_group("ability_fields"):
		f.queue_free()
	await wait(2)
	prog.selected_class = cls
	chars.abilities[cls] = ability_id
	prog.skill_ranks = ranks.duplicate()
	prog._recompute_spent()
	player.ability = null
	player.player_class = prog.load_selected_class()
	player.apply_stats()
	player._ability_cd = 0.0
	player._ability_active = 0.0
	player.overshield = 0.0
	player.health = player.max_health
	player.invulnerable_t = 9999.0
	if fire:
		player.use_ability()


func _ahead(d: float) -> Vector3:
	var fwd: Vector3 = -player.camera.global_transform.basis.z
	fwd.y = 0.0
	return fwd.normalized() * d


func _zombie(offset: Vector3, hp: int = 100000) -> Node:
	var z = main.ZOMBIE_SCENE.instantiate()
	z.setup(hp, 0.0, 0)
	main.zombies_root.add_child(z)
	z.global_position = player.global_position + offset
	return z


func _rm_tree(d: String) -> void:
	for f in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(d.path_join(f))
	for sub in DirAccess.get_directories_at(d):
		_rm_tree(d.path_join(sub))
	DirAccess.remove_absolute(d)
