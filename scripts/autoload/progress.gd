extends Node
## Autoload "Progress": game-to-game progression saved to user://progress.cfg.
## On Windows that is %APPDATA%\Godot\app_userdata\FPS Starter\progress.cfg.
## Add new persistent stats by adding a var, then reading/writing it in load_data/save_data.
##
## Skill tree v2 (data/skill_tree.json, see /workspace/skillz/GOOEY_HANDOFF.md):
##  - nodes have ranks (cost per rank), requires (all-of), requires_any (any-of), choice_group
##    (only one node per group; all keystones share "keystone"), and class gating.
##  - saved as skills/ranks {id: rank}. Old saves (skills/unlocked = [ids]) migrate to rank 1 for
##    ids that still exist; spent points are always recomputed from the tree, so removed v1 nodes
##    (tough_1 ... fleet_2) are refunded automatically.
##  - one currency: skill points = xp / xp_per_skill_point. get_level() is a display level derived from it.
##  - node effects are run by the player's SkillRunner (scripts/skills/skill_runner.gd).
##
## Save version 3 (2026-10-19): adds the persistent gear stash ([stash] data = Inventory.to_save_dict()) and
## [meta] save_version. v2 saves (no stash) start with the starter loadout; their items, if any, load seen=true.
## The stash is captured from the bound Inventory (player.gd calls bind_inventory) at match end (record_match),
## when the Inventory leaves the tree (restart / map change) and on window close; restore_stash() at match start.
## See /workspace/skillz/STASH_HANDOFF.md.
##
## Economy: data/economy.json -> points_per_hit / points_per_kill (main.gd reads them, see skillz/MAIN_HOOKS.md).

signal ranks_changed ## any rank bought, reset or loaded
signal rank_changed(id: String, new_rank: int) ## one node bought / ranked up (respec emits ranks_changed)
signal stash_saved ## the gear stash was captured from the live Inventory and written to disk

const SAVE_VERSION := 3 ## 1 = v1 skills, 2 = skill ranks, 3 = + persistent gear stash
const SKILL_TREE_PATH := "res://data/skill_tree.json"
const ECONOMY_PATH := "res://data/economy.json"

## Tests point this elsewhere. Changing it drops the in-memory stash so a test never restores the real save's gear.
var save_path: String = "user://progress.cfg":
	set(v):
		save_path = v
		stash = {}

var total_kills: int = 0
var best_round: int = 0
var xp: int = 0
var games_played: int = 0
var selected_class: String = "soldier" ## file name in res://resources/classes/
var skill_ranks: Dictionary = {} ## node id -> rank (>= 1)
var skill_points_spent: int = 0 ## derived from skill_ranks
var respec_allowed: bool = true ## main.gd: true at round 0 and on game over only
var loaded_save_version: int = 0 ## version of the file last loaded (0 = no file)

## Persistent gear: Inventory.to_save_dict() ({version, equipped{slot: item|null}, backpack{slot: [items]}}), or {}.
var stash: Dictionary = {}
var _inventory_ref: WeakRef = null

## Point economy (data/economy.json). Defaults = halved playtest values.
var economy: Dictionary = {}
var points_per_hit: int = 5
var points_per_kill: int = 50

var tree: Dictionary = {} ## raw v2 data/skill_tree.json
var _skill_nodes: Dictionary = {} ## id -> raw node dictionary
var _node_order: Array = [] ## ids in file order


func _ready() -> void:
	_load_skill_tree()
	_load_economy()
	load_data()


func _load_economy() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(ECONOMY_PATH)) if FileAccess.file_exists(ECONOMY_PATH) else null
	economy = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	points_per_hit = int(economy.get("points_per_hit", 5))
	points_per_kill = int(economy.get("points_per_kill", 50))


## Window close (quit): capture the live Inventory into the stash and save.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_stash()


func load_data() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(save_path) != OK:
		_recompute_spent()
		return # first run, keep defaults
	total_kills = cfg.get_value("stats", "total_kills", 0)
	best_round = cfg.get_value("stats", "best_round", 0)
	xp = cfg.get_value("stats", "xp", 0)
	games_played = cfg.get_value("stats", "games_played", 0)
	selected_class = cfg.get_value("player", "selected_class", "soldier")
	# v1 saves have no "ranks" key (a null default would log an error, so check first)
	var ranks_v = cfg.get_value("skills", "ranks") if cfg.has_section_key("skills", "ranks") else null
	skill_ranks = migrate_ranks(ranks_v, cfg.get_value("skills", "unlocked", []))
	loaded_save_version = int(cfg.get_value("meta", "save_version", cfg.get_value("skills", "version", 1)))
	stash = migrate_stash(cfg.get_value("stash", "data") if cfg.has_section_key("stash", "data") else null)
	_recompute_spent()


## v2 and older saves have no stash -> {} (starter loadout). Anything that isn't a {equipped, backpack} dict is dropped.
## Item dicts without "seen" load seen=true (GearItem.apply_dict), so old gear never shows the '!' badge.
func migrate_stash(v) -> Dictionary:
	if typeof(v) != TYPE_DICTIONARY or typeof(v.get("equipped")) != TYPE_DICTIONARY:
		return {}
	var out: Dictionary = v.duplicate(true)
	if typeof(out.get("backpack")) != TYPE_DICTIONARY:
		out["backpack"] = {}
	return out


## v1 -> v2: a ranks dict wins; otherwise each legacy unlocked id that still exists becomes rank 1.
## Unknown ids are dropped and ranks are clamped to the node's max.
func migrate_ranks(ranks_value, legacy_unlocked) -> Dictionary:
	var out := {}
	if typeof(ranks_value) == TYPE_DICTIONARY:
		for id in ranks_value:
			if _skill_nodes.has(str(id)) and int(ranks_value[id]) > 0:
				out[str(id)] = mini(int(ranks_value[id]), node_max_rank(str(id)))
	elif typeof(legacy_unlocked) == TYPE_ARRAY:
		for id in legacy_unlocked:
			if _skill_nodes.has(str(id)):
				out[str(id)] = 1
	return out


func save_data() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "total_kills", total_kills)
	cfg.set_value("stats", "best_round", best_round)
	cfg.set_value("stats", "xp", xp)
	cfg.set_value("stats", "games_played", games_played)
	cfg.set_value("player", "selected_class", selected_class)
	cfg.set_value("meta", "save_version", SAVE_VERSION)
	cfg.set_value("skills", "version", 2)
	cfg.set_value("skills", "ranks", skill_ranks)
	cfg.set_value("skills", "unlocked", skill_ranks.keys()) # read by pre-v2 builds only
	cfg.set_value("skills", "spent", skill_points_spent)
	if not stash.is_empty():
		cfg.set_value("stash", "version", int(stash.get("version", 1)))
		cfg.set_value("stash", "data", stash)
	var err := cfg.save(save_path)
	if err != OK:
		push_warning("Could not save progress (error %d)" % err)


## XP formula lives here so it's easy to tune: 10 per kill + 50 per round reached.
func xp_for_match(kills: int, round_reached: int) -> int:
	return kills * 10 + round_reached * 50


## Called at game over. Returns the XP earned this match. Also saves the gear stash.
func record_match(kills: int, round_reached: int) -> int:
	var earned := xp_for_match(kills, round_reached)
	total_kills += kills
	best_round = max(best_round, round_reached)
	xp += earned
	games_played += 1
	capture_stash()
	save_data()
	return earned


# ---------------------------------------------------------------- persistent gear stash

## player.gd: the match's Inventory (weakly held; the stash is captured from it).
func bind_inventory(inv: Node) -> void:
	_inventory_ref = weakref(inv) if inv else null


func bound_inventory() -> Node:
	return _inventory_ref.get_ref() if _inventory_ref else null


## Copies the bound Inventory into `stash` (memory only). Returns false if no inventory is bound.
func capture_stash() -> bool:
	var inv := bound_inventory()
	if inv == null or not inv.has_method("to_save_dict"):
		return false
	stash = inv.to_save_dict()
	return true


## capture_stash() + save_data(). Match end / quit / scene exit.
func save_stash() -> bool:
	if not capture_stash():
		return false
	save_data()
	stash_saved.emit()
	return true


## Inventory._exit_tree(): the match is ending (restart, map change, quit), so save its gear.
func on_inventory_exit(inv: Node) -> void:
	if inv != null and inv == bound_inventory():
		save_stash()
		_inventory_ref = null


func has_stash() -> bool:
	if stash.is_empty():
		return false
	for s in stash.get("equipped", {}):
		if stash.equipped[s] != null:
			return true
	return false


## Match start: loads the saved stash into `inv` and fills any empty equip slot with a Common starter piece.
## Returns false (inventory untouched) when there is no stash; the caller then gives the starter loadout.
func restore_stash(inv: Node) -> bool:
	if not has_stash() or inv == null:
		return false
	inv.load_save_dict(stash.duplicate(true))
	if inv.has_method("fill_empty_slots"):
		inv.fill_empty_slots()
	return true


## Wipes saved gear (next match starts with the starter loadout). Doesn't touch skills or stats.
func clear_stash() -> void:
	stash = {}
	save_data()


## Display level, derived from skill points earned (one currency: no separate level curve).
func get_level() -> int:
	return 1 + skill_points_earned()


func load_selected_class() -> PlayerClass:
	var path := "res://resources/classes/%s.tres" % selected_class
	if ResourceLoader.exists(path):
		return load(path) as PlayerClass
	return load("res://resources/classes/soldier.tres") as PlayerClass


# ---------------------------------------------------------------- skill tree data

func _load_skill_tree() -> void:
	var text := FileAccess.get_file_as_string(SKILL_TREE_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Could not parse %s" % SKILL_TREE_PATH)
		return
	tree = normalize_tree(parsed)
	_skill_nodes.clear()
	_node_order.clear()
	for node in tree.get("nodes", []):
		_skill_nodes[node.id] = node
		_node_order.append(node.id)


## Accepts v2 ({nodes: [...]}) or v1 ({branches: [{nodes: [{stat, amount, cost}]}]}) and returns v2.
## A v1 node with stat/amount becomes {script: "stat_mod", params: {stat, add: amount}}.
static func normalize_tree(data: Dictionary) -> Dictionary:
	if int(data.get("version", 1)) >= 2 and data.has("nodes"):
		var t: Dictionary = data.duplicate(true)
		for n in t.nodes:
			_fill_node_defaults(n)
		return t
	var out := {"version": 2, "xp_per_skill_point": data.get("xp_per_skill_point", 250), "branches": [], "nodes": []}
	var bx := 0
	for b in data.get("branches", []):
		var bid: String = str(b.get("id", str(b.get("name", "branch")).to_snake_case()))
		out.branches.append({"id": bid, "name": b.get("name", bid), "accent": "", "color": [0.85, 0.5, 0.25], "x": bx, "class": ""})
		var y := 0
		for n in b.get("nodes", []):
			var nn := {"id": n.id, "name": n.get("name", n.id), "branch": bid, "x": bx, "y": y,
				"cost": [int(n.get("cost", 1))], "requires": n.get("requires", []), "description": n.get("description", ""),
				"effects": [{"script": "stat_mod", "params": {"stat": n.get("stat", ""), "add": float(n.get("amount", 0.0))}}]}
			_fill_node_defaults(nn)
			out.nodes.append(nn)
			y += 1
		bx += 1
	return out


static func _fill_node_defaults(n: Dictionary) -> void:
	var c = n.get("cost", 1)
	if typeof(c) != TYPE_ARRAY:
		c = [int(c)]
	n["cost"] = c
	n["ranks"] = int(n.get("ranks", c.size()))
	for k in ["requires", "requires_any", "effects", "unlocks_cards", "tags"]:
		if not n.has(k):
			n[k] = []
	for k in ["choice_group", "class", "description", "drawback"]:
		if not n.has(k):
			n[k] = ""
	if not n.has("values"):
		n["values"] = {}
	if not n.has("requires_rank"):
		n["requires_rank"] = {}
	if not n.has("type"):
		n["type"] = "keystone" if n.get("keystone", false) else "passive"
	n["keystone"] = n.get("keystone", n.type == "keystone") or n.type == "keystone"
	if not n.has("icon"):
		n["icon"] = n.id


func get_skill(id: String) -> Dictionary:
	return _skill_nodes.get(id, {})


func all_node_ids() -> Array:
	return _node_order.duplicate()


func branches() -> Array:
	return tree.get("branches", [])


func node_max_rank(id: String) -> int:
	return int(get_skill(id).get("ranks", 1))


## Cost of the next rank (0 when maxed).
func next_cost(id: String) -> int:
	var n := get_skill(id)
	var r := rank(id)
	var costs: Array = n.get("cost", [1])
	if r >= int(n.get("ranks", 1)):
		return 0
	return int(costs[mini(r, costs.size() - 1)])


func skill_points_earned() -> int:
	var per := int(tree.get("xp_per_skill_point", 250))
	return xp / max(per, 1)


func skill_points_available() -> int:
	return skill_points_earned() - skill_points_spent


# ---------------------------------------------------------------- v2 API (agreed with Gooey)

## Owned rank (0 = not owned).
func rank(id: String) -> int:
	return int(skill_ranks.get(id, 0))


## True if the node's class gate matches the selected class (class nodes are buyable regardless).
func class_active(id: String) -> bool:
	var c: String = str(get_skill(id).get("class", ""))
	return c == "" or c == selected_class


## requires (all-of) and requires_any (any-of) mean "rank >= 1", unless requires_rank {id: n} says more.
func _req_ok(id: String, n: Dictionary) -> bool:
	return rank(id) >= int(n.get("requires_rank", {}).get(id, 1))


func requirements_met(id: String) -> bool:
	var n := get_skill(id)
	for req in n.get("requires", []):
		if not _req_ok(req, n):
			return false
	var any_of: Array = n.get("requires_any", [])
	if not any_of.is_empty() and not any_of.any(func(r): return _req_ok(r, n)):
		return false
	return true


## Owned node sharing this node's choice_group ("" if none). All keystones share "keystone".
func excluded_by(id: String) -> String:
	var g: String = str(get_skill(id).get("choice_group", ""))
	if g == "":
		return ""
	for other in skill_ranks:
		if other != id and str(get_skill(other).get("choice_group", "")) == g:
			return other
	return ""


## Structural state, independent of points: "maxed", "owned" (0 < rank < max), "excluded" (another
## node of its choice group is owned), "locked" (prerequisites missing) or "available" (rank 0, buyable).
## Use can_afford(id) for points.
func state(id: String) -> String:
	var n := get_skill(id)
	if n.is_empty():
		return "locked"
	var r := rank(id)
	if r >= int(n.get("ranks", 1)):
		return "maxed"
	if r > 0:
		return "owned"
	if excluded_by(id) != "":
		return "excluded"
	if not requirements_met(id):
		return "locked"
	return "available"


## Enough points for the next rank (false when maxed).
func can_afford(id: String) -> bool:
	var c := next_cost(id)
	return c > 0 and c <= skill_points_available()


## Buys the next rank: state must be available/owned and can_afford. Emits rank_changed(id, rank).
func buy_rank(id: String) -> bool:
	if not (state(id) in ["available", "owned"]) or not can_afford(id):
		return false
	skill_ranks[id] = rank(id) + 1
	_recompute_spent()
	save_data()
	rank_changed.emit(id, rank(id))
	return true


func can_respec() -> bool:
	return respec_allowed


## Cost of everything you can own at once: all nodes at max rank, with only the most expensive
## member of each choice group (one keystone in the whole tree).
func tree_total_cost() -> int:
	var groups := {}
	var total := 0
	for id in _node_order:
		var n: Dictionary = _skill_nodes[id]
		var c := 0
		for v in n.cost:
			c += int(v)
		var g: String = str(n.get("choice_group", ""))
		if g == "":
			total += c
		else:
			groups[g] = maxi(int(groups.get(g, 0)), c)
	for g in groups:
		total += int(groups[g])
	return total


func _recompute_spent() -> void:
	var spent := 0
	for id in skill_ranks.keys():
		if not _skill_nodes.has(id):
			skill_ranks.erase(id)
			continue
		var costs: Array = get_skill(id).get("cost", [1])
		for i in int(skill_ranks[id]):
			spent += int(costs[mini(i, costs.size() - 1)])
	skill_points_spent = spent
	ranks_changed.emit()


## Wipes skills and refunds every point (always allowed; use respec() for player-facing respecs).
func reset_skills() -> void:
	skill_ranks.clear()
	_recompute_spent()
	save_data()


## Player-facing respec: free, but only at round 0 or on game over (main.gd sets respec_allowed).
func respec() -> bool:
	if not respec_allowed:
		return false
	reset_skills()
	return true


# ---------------------------------------------------------------- formatting / helpers

## Rank-indexed value: arrays are per rank (index rank-1, clamped), scalars apply to every rank.
static func rank_value(v, r: int):
	if typeof(v) == TYPE_ARRAY:
		if v.is_empty():
			return 0
		return v[clampi(r - 1, 0, v.size() - 1)]
	return v


static func fmt_value(v) -> String:
	if typeof(v) == TYPE_FLOAT:
		if is_equal_approx(v, roundf(v)):
			return str(int(roundf(v)))
		return ("%.2f" % v).rstrip("0").rstrip(".")
	return str(v)


## Fills {placeholders} in a node or card template field ("description" or "drawback") from its
## "values" for rank `r` (min 1).
static func format_template(def: Dictionary, field: String, r: int) -> String:
	var text: String = str(def.get(field, ""))
	var vals: Dictionary = def.get("values", {})
	for k in vals:
		text = text.replace("{%s}" % k, fmt_value(rank_value(vals[k], maxi(r, 1))))
	return text


static func format_description(def: Dictionary, r: int) -> String:
	return format_template(def, "description", r)


static func format_drawback(def: Dictionary, r: int) -> String:
	return format_template(def, "drawback", r)
