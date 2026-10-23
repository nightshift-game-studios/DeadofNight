class_name BossCatalog
extends RefCounted
## Boss data (res://data/bosses.json) + spawn roster / HP / payout helpers (Skillz).
## Cadence lives in Difficulty (is_boss_round / boss_count / boss_rounds / boss_cfg).
##   BossCatalog.ids() / get(id) / telegraph(id)
##   BossCatalog.normal_hp(round, base_health=90, health_per_round=35)
##   BossCatalog.boss_hp(id, round, _, _, difficulty_id="", players=1, boss_count=-1)   (TTK-driven, see data/bosses.json -> tuning)
##   BossCatalog.hit_damage(id, attack, round, difficulty_id, frenzy) / cooldown_mult / adds_count / adds_cap / enrage_time / stage_for / ttk_target / budgets
##   BossCatalog.kill_points(id, points_per_kill=50) / gravemark_reward(id)
##   BossCatalog.pick_roster(round, difficulty_id="") -> Array[String]
##   BossCatalog.script_path(id) / is_boss_id(id)
##   Art (2026-10-19): model_path(id) / icon_path(id) / anims(id) / fx(id) / echo_model_path() / echo_model_height()
##   BossCatalog.apply_echo_model(z) -> Echo Walker GLB + 1.526 m on a Choir Host add (call before add_child; MAIN_HOOKS §11)
## Until main.gd wires MAIN_HOOKS §7, nothing spawns bosses — this module is safe to load alone.

const DATA_PATH := "res://data/bosses.json"
const DEFAULT_BASE_HEALTH := 90
const DEFAULT_HEALTH_PER_ROUND := 35
const DEFAULT_POINTS_PER_KILL := 25

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_data = d if d is Dictionary else {}
	return _data


## Test helper: force-reload (or inject) JSON so suites don't share a stale cache.
static func reload(forced: Dictionary = {}) -> void:
	_data = forced if not forced.is_empty() else {}
	if forced.is_empty():
		data()


static func ids() -> Array:
	return data().get("bosses", {}).keys()


static func is_boss_id(id: String) -> bool:
	return data().get("bosses", {}).has(id)


static func get_boss(id: String) -> Dictionary:
	return data().get("bosses", {}).get(id, {})


static func telegraph(id: String) -> Dictionary:
	return get_boss(id).get("telegraph", {})


static func echo_cfg(id: String = "choir_host") -> Dictionary:
	return get_boss(id).get("echo", {})


static func script_path(id: String) -> String:
	return str(get_boss(id).get("script", ""))


## res:// path of the boss GLB (Desi), "" if none. Bosses fall back to the zombie scene's walker model when missing.
static func model_path(id: String) -> String:
	return str(get_boss(id).get("model", ""))


static func icon_path(id: String) -> String:
	return str(get_boss(id).get("icon", ""))


## Clip names + timing (data/bosses.json -> bosses[id].anims).
static func anims(id: String) -> Dictionary:
	return get_boss(id).get("anims", {})


## Socket / material / light presentation values (data/bosses.json -> bosses[id].fx).
static func fx(id: String) -> Dictionary:
	return get_boss(id).get("fx", {})


static func echo_model_path(host_id: String = "choir_host") -> String:
	return str(echo_cfg(host_id).get("model", ""))


## Real height of echo_walker.glb. Without it enemy.gd's 1.795 default would scale the add back up to walker size.
static func echo_model_height(host_id: String = "choir_host") -> float:
	return float(echo_cfg(host_id).get("model_height", 1.526))


## Gives a Choir Host echo add its own model. Call after setup() and before add_child. False if the GLB is missing
## (the add then keeps the default walker model at walker height).
static func apply_echo_model(enemy: Node, host_id: String = "choir_host") -> bool:
	var ok: bool = load("res://scripts/enemies/boss_art.gd").set_model(enemy, echo_model_path(host_id), echo_model_height(host_id))
	if ok:
		enemy.set("variant_id", "boss_echo")
		enemy.set_meta("boss_echo", true)
	return ok


static func display_name(id: String) -> String:
	return str(get_boss(id).get("name", id))


## Round-scaled normal zombie HP (matches main._zombie_stats before variant mults).
static func normal_hp(n: int, base_health: int = DEFAULT_BASE_HEALTH, health_per_round: int = DEFAULT_HEALTH_PER_ROUND) -> int:
	return maxi(base_health + health_per_round * (maxi(n, 1) - 1), 1)


## Boss rework (playtest #15): HP is TTK-driven. tuning() = data/bosses.json -> tuning.
static func tuning() -> Dictionary:
	return data().get("tuning", {})


## Sustained boss DPS of one competent player at round n (the reference the HP and the sim budgets are built on).
static func ref_dps(n: int) -> float:
	var t := tuning()
	return float(t.get("ref_dps_base", 70.0)) + float(t.get("ref_dps_per_round", 4.5)) * float(maxi(n, 1))


## Boss HP factor for `players` (co-op): 1 + hp_per_extra x (players - 1).
static func party_hp_mult(players: int) -> float:
	return 1.0 + float(tuning().get("hp_per_extra", 0.85)) * float(maxi(players, 1) - 1)


## Per-boss HP factor when a round spawns `count` bosses (Hard 11 / 21).
static func multi_hp_mult(count: int) -> float:
	var m: Dictionary = tuning().get("multi_boss_hp", {})
	return float(m.get(str(clampi(count, 1, 3)), 1.0))


## How many bosses `n` spawns on `difficulty_id` (>= 1 so a test can configure a boss on any round).
static func count_for(n: int, difficulty_id: String = "") -> int:
	var D = load("res://scripts/world/difficulty.gd")
	return maxi(int(D.boss_count(n, difficulty_id)), 1)


## Boss max HP at spawn round = ref_dps(n) x ttk x dps_eff x Difficulty hp_mult x multi-boss x party. base_health /
## health_per_round are kept for call compatibility and ignored (bosses no longer track zombie HP).
static func boss_hp(id: String, n: int, _base_health: int = DEFAULT_BASE_HEALTH, _health_per_round: int = DEFAULT_HEALTH_PER_ROUND, difficulty_id: String = "", players: int = 1, boss_count: int = -1) -> int:
	var b := get_boss(id)
	if b.is_empty():
		return 0
	var D = load("res://scripts/world/difficulty.gd")
	var diff_m := float(D.boss_cfg(difficulty_id).get("hp_mult", 1.0))
	if boss_count < 0:
		boss_count = count_for(n, difficulty_id)
	var raw := ref_dps(n) * float(b.get("ttk", 60.0)) * dps_eff(id) * diff_m * multi_hp_mult(boss_count) * party_hp_mult(players)
	return maxi(int(round(raw)), 1)


## Seconds a reference player needs for this boss (solo, boss_count 1): HP / (ref_dps x dps_eff). The sim checks it.
static func ttk_target(id: String, n: int, difficulty_id: String = "", players: int = 1, boss_count: int = 1) -> float:
	var hp := float(boss_hp(id, n, 0, 0, difficulty_id, players, boss_count))
	return hp / (ref_dps(n) * dps_eff(id) * float(maxi(players, 1)))


## Fraction of the reference DPS that lands on the boss (dodging, reloads, add-killing, shield phases). Per-boss override.
static func dps_eff(id: String) -> float:
	return float(get_boss(id).get("dps_eff", tuning().get("dps_eff", 0.8)))


static func budgets(difficulty_id: String) -> Dictionary:
	return tuning().get("budgets", {}).get(difficulty_id, {})


## HP-fraction thresholds crossed -> stage (0-based). hp_frac 1.0 = stage 0.
static func stage_for(id: String, hp_frac: float) -> int:
	var st := 0
	for t in get_boss(id).get("stages", []):
		if hp_frac <= float(t):
			st += 1
	return st


## Per-hit damage for attack `key` (bosses[id].damage, a fraction of tuning.player_ref_hp) at round n.
static func hit_damage(id: String, key: String, n: int, difficulty_id: String = "", frenzy: bool = false) -> int:
	var b := get_boss(id)
	if b.is_empty():
		return 1
	var D = load("res://scripts/world/difficulty.gd")
	var t := tuning()
	var frac := float(b.get("damage", {}).get(key, 0.2))
	var slope := maxf(float(t.get("damage_round_floor", 0.7)), 1.0 + float(t.get("damage_round_slope", 0.015)) * float(n - 10))
	var raw := frac * float(t.get("player_ref_hp", 100)) * slope * float(D.boss_cfg(difficulty_id).get("damage_mult", 1.0))
	if frenzy:
		raw *= float(b.get("frenzy", {}).get("damage_mult", 1.3))
	raw = minf(raw, float(t.get("hit_cap_frac", 0.85)) * float(t.get("player_ref_hp", 100))) # no single hit one-shots a full-health player
	return maxi(int(round(raw)), 1)


## Attack cooldown multiplier: Difficulty boss cooldown_mult x co-op cut (floored).
static func cooldown_mult(difficulty_id: String = "", players: int = 1, frenzy: bool = false, id: String = "") -> float:
	var D = load("res://scripts/world/difficulty.gd")
	var t := tuning()
	var party := maxf(float(t.get("cooldown_floor", 0.75)), 1.0 - float(t.get("cooldown_cut_per_extra", 0.05)) * float(maxi(players, 1) - 1))
	var m := float(D.boss_cfg(difficulty_id).get("cooldown_mult", 1.0)) * party
	if frenzy:
		m *= float(get_boss(id).get("frenzy", {}).get("cooldown_mult", 0.7))
	return m


## Summoned-add count: base x Difficulty adds_mult x (1 + adds_per_extra x (players - 1)), min 1 when base > 0.
static func adds_count(base: float, difficulty_id: String = "", players: int = 1) -> int:
	if base <= 0.0:
		return 0
	var D = load("res://scripts/world/difficulty.gd")
	var raw := base * float(D.boss_cfg(difficulty_id).get("adds_mult", 1.0)) * (1.0 + float(tuning().get("adds_per_extra", 0.5)) * float(maxi(players, 1) - 1))
	return maxi(int(round(raw)), 1)


static func adds_cap(players: int = 1) -> int:
	var t := tuning()
	return mini(int(t.get("adds_cap_base", 6)) + int(t.get("adds_cap_per_extra", 2)) * (maxi(players, 1) - 1), int(t.get("adds_cap_max", 12)))


## Seconds of fight before Frenzy (soft enrage).
static func enrage_time(id: String, difficulty_id: String = "") -> float:
	var D = load("res://scripts/world/difficulty.gd")
	return float(get_boss(id).get("enrage_timer", 150.0)) * float(D.boss_cfg(difficulty_id).get("enrage_mult", 1.0))


## Echo add HP = normal_hp * echo.hp_mult (no boss/Difficulty boss hp_mult).
static func echo_hp(n: int, base_health: int = DEFAULT_BASE_HEALTH, health_per_round: int = DEFAULT_HEALTH_PER_ROUND, host_id: String = "choir_host") -> int:
	var e := echo_cfg(host_id)
	return maxi(int(round(float(normal_hp(n, base_health, health_per_round)) * float(e.get("hp_mult", 0.4)))), 1)


static func kill_points(id: String, points_per_kill: int = -1) -> int:
	if points_per_kill < 0:
		points_per_kill = int(data().get("default_points_per_kill", DEFAULT_POINTS_PER_KILL))
	var b := get_boss(id)
	if b.is_empty():
		return points_per_kill
	return maxi(int(round(float(points_per_kill) * float(b.get("kill_points_mult", 1.0)))), 0)


static func gravemark_reward(id: String) -> int:
	return maxi(int(get_boss(id).get("gravemark_reward", 0)), 0)


## Gravemark after Difficulty.rare_currency_drop_mult (rounded; min 1 if base > 0).
static func gravemark_scaled(id: String, difficulty_id: String = "") -> int:
	var base := gravemark_reward(id)
	if base <= 0:
		return 0
	var D = load("res://scripts/world/difficulty.gd")
	return maxi(int(round(float(base) * float(D.rare_currency_drop_mult(difficulty_id)))), 1)


## 0-based index of this boss round among Difficulty.boss_rounds(n), or -1 if not a boss round.
static func boss_cycle_index(n: int, difficulty_id: String = "") -> int:
	var D = load("res://scripts/world/difficulty.gd")
	if not D.is_boss_round(n, difficulty_id):
		return -1
	var rounds: Array = D.boss_rounds(n, difficulty_id)
	return rounds.find(n)


## Fill Difficulty.boss_count slots using roster_rules.
static func pick_roster(n: int, difficulty_id: String = "") -> Array:
	var D = load("res://scripts/world/difficulty.gd")
	var count := int(D.boss_count(n, difficulty_id))
	if count <= 0:
		return []
	var rules: Dictionary = data().get("roster_rules", {})
	var cycle := boss_cycle_index(n, difficulty_id)
	var out: Array = []
	var first := str(rules.get("first_slot_default", "bellwether"))
	var alt: Array = rules.get("solo_alternate", ["choir_host", "lantern_stalker"])
	var alt_from := int(rules.get("solo_alternate_from_cycle", 1))
	# Solo Easy/Medium from the second cadence round: alternate Choir / Lantern (no Bellwether).
	var diff := difficulty_id if difficulty_id != "" else str(D.active_id())
	var multi := count > 1 or diff == "hard"
	if count >= 1:
		if multi or cycle < alt_from or alt.is_empty():
			out.append(first)
		else:
			var i := (cycle - alt_from) % alt.size()
			out.append(str(alt[i]))
	if count >= 2:
		out.append(str(rules.get("second_slot", "choir_host")))
	if count >= 3:
		out.append(str(rules.get("third_slot", "lantern_stalker")))
	# Cap / pad to exact count (Hard max 3).
	while out.size() > count:
		out.pop_back()
	while out.size() < count:
		out.append(str(rules.get("third_slot", "lantern_stalker")))
	return out


## Contact / slam / spit damage: round-scaled base zombie damage x boss damage_mult x Difficulty damage_mult x optional attack mult.
static func attack_damage(id: String, n: int, base_damage: int = 10, damage_per_round: int = 2, attack_mult: float = 1.0, difficulty_id: String = "") -> int:
	var b := get_boss(id)
	if b.is_empty():
		return base_damage
	var D = load("res://scripts/world/difficulty.gd")
	var round_dmg := float(base_damage + damage_per_round * (maxi(n, 1) - 1))
	var raw := round_dmg * float(b.get("damage_mult", 1.0)) * float(D.boss_cfg(difficulty_id).get("damage_mult", 1.0)) * attack_mult
	return maxi(int(round(raw)), 1)
