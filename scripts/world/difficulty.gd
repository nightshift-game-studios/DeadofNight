class_name Difficulty
extends RefCounted
## Difficulty profiles (res://data/difficulty.json), picked per map via data/maps.json -> maps[].difficulty.
##   Difficulty.for_map(map_id)            -> "easy" / "medium" / "hard" (missing field or unknown id -> data "default")
##   Difficulty.apply_to_main(main, id="") -> scales main.gd's wave exports from their scene values and makes `id` active
##   Difficulty.pick_variant(round)        -> zombie variant id using the active profile's mix (wraps ZombieVariants)
##   Difficulty.is_boss_round(n) / boss_count(n) / boss_cfg()  -> boss cadence for data/bosses.json
##   Difficulty.xp_mult() / loot_rarity_bias() / rare_currency_drop_mult() / points_mult()  -> reward scaling
## Until apply_to_main() runs (see /workspace/skillz/MAIN_HOOKS.md) the active profile is "" -> the default ("easy"),
## which is exactly the old tuning, so nothing changes. The active id is a static var: it survives scene reloads and
## is re-applied by main at every match start.

const DATA_PATH := "res://data/difficulty.json"
const MAIN_KEYS := ["first_round_zombies", "zombies_per_round", "base_health", "health_per_round", "base_speed",
	"speed_per_round", "max_speed", "base_damage", "damage_per_round", "spawn_interval", "max_alive"]
static var _data: Dictionary = {}
static var _active_id: String = ""


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_data = d if d is Dictionary else {}
	return _data


static func ids() -> Array:
	return data().get("profiles", {}).keys()


static func default_id() -> String:
	var d := str(data().get("default", "easy"))
	return d if data().get("profiles", {}).has(d) else (str(ids()[0]) if ids().size() else "")


static func is_valid(id: String) -> bool:
	return data().get("profiles", {}).has(id)


## Raw profile; unknown/empty id -> default profile.
static func profile(id: String = "") -> Dictionary:
	var p: Dictionary = data().get("profiles", {})
	if id == "":
		id = active_id()
	return p.get(id, p.get(default_id(), {}))


## data/maps.json -> maps[].difficulty ("" or unknown -> default).
static func for_map(map_id: String) -> String:
	var d := str(MapRegistry.get_info(map_id).get("difficulty", ""))
	return d if is_valid(d) else default_id()


static func active_id() -> String:
	return _active_id if _active_id != "" else default_id()


static func set_active(id: String) -> void:
	_active_id = id if is_valid(id) else ""


## difficulty.json -> wave_base (MAIN_KEYS only; "_" keys and _previous dropped). {} = main.gd's exports as they are.
static func wave_base() -> Dictionary:
	var out := {}
	var wb = data().get("wave_base", {})
	if typeof(wb) == TYPE_DICTIONARY:
		for k in wb:
			if str(k) in MAIN_KEYS:
				out[str(k)] = wb[k]
	return out


## Zombie stats of round n on profile `id` from main.gd's default exports (as main._zombie_stats computes them after
## apply_to_main): {health, speed, damage}. `exports` overrides the main.gd defaults (tests / before-after tables).
static func zombie_stats_for(n: int, id: String = "", exports: Dictionary = {}) -> Dictionary:
	var e := {"base_health": 90, "health_per_round": 35, "base_speed": 2.4, "speed_per_round": 0.3, "max_speed": 6.0,
		"base_damage": 10, "damage_per_round": 2}
	e.merge(exports, true)
	var fake := _StatsProbe.new()
	for k in e:
		fake.vals[k] = e[k]
	var prev_active := _active_id
	apply_to_main(fake, id if id != "" else default_id())
	_active_id = prev_active # a probe must not change the live profile
	var v: Dictionary = fake.vals.duplicate()
	fake.free()
	return {"health": int(v.base_health) + int(v.health_per_round) * (n - 1),
		"speed": minf(float(v.base_speed) + float(v.speed_per_round) * (n - 1), float(v.max_speed)),
		"damage": int(v.base_damage) + int(v.damage_per_round) * (n - 1)}


## Stand-in for main.gd in zombie_stats_for(): int-typed keys stay ints like main.gd's exports.
class _StatsProbe extends Object:
	var vals := {}
	const INTS := ["first_round_zombies", "zombies_per_round", "base_health", "health_per_round", "base_damage", "damage_per_round", "max_alive"]
	func _get(p: StringName):
		return vals.get(str(p))
	func _set(p: StringName, v) -> bool:
		if vals.has(str(p)):
			vals[str(p)] = int(v) if str(p) in INTS else float(v)
			return true
		return false
	func _get_property_list() -> Array:
		var out := []
		for k in vals:
			out.append({"name": k, "type": TYPE_INT if k in INTS else TYPE_FLOAT, "usage": PROPERTY_USAGE_DEFAULT})
		return out


static func _sec(section: String, key: String, fallback, id: String = ""):
	return profile(id).get(section, {}).get(key, fallback)


## Scales main.gd's wave exports from the values it had when first seen (cached as meta, so calling twice doesn't
## compound) and activates the profile. id "" = for_map(main.map_id or MapRegistry.current_id()). Returns the id.
static func apply_to_main(main: Object, id: String = "") -> String:
	if id == "":
		var mid := str(main.get("map_id")) if "map_id" in main else MapRegistry.current_id()
		id = for_map(mid)
	if not is_valid(id):
		id = default_id()
	if not main.has_meta("difficulty_base"):
		var b := {}
		for k in MAIN_KEYS:
			if k in main:
				b[k] = main.get(k)
		main.set_meta("difficulty_base", b)
	var base: Dictionary = (main.get_meta("difficulty_base") as Dictionary).duplicate()
	for k in wave_base(): # Economy v2: data-driven per-round growth replaces main.gd's export (before profile mults)
		if base.has(k):
			base[k] = wave_base()[k]
	var w: Dictionary = profile(id).get("wave", {})
	var out := {
		"first_round_zombies": maxi(int(round(float(base.get("first_round_zombies", 6)) * float(w.get("count_mult", 1.0)))), 1),
		"zombies_per_round": maxi(int(round(float(base.get("zombies_per_round", 3)) * float(w.get("count_ramp_mult", 1.0)))), 0),
		"base_health": maxi(int(round(float(base.get("base_health", 90)) * float(w.get("health_mult", 1.0)))), 1),
		"health_per_round": int(round(float(base.get("health_per_round", 35)) * float(w.get("health_ramp_mult", 1.0)))),
		"base_speed": float(base.get("base_speed", 2.4)) * float(w.get("speed_mult", 1.0)),
		"speed_per_round": float(base.get("speed_per_round", 0.3)) * float(w.get("speed_ramp_mult", 1.0)),
		"max_speed": float(base.get("max_speed", 6.0)) + float(w.get("max_speed_add", 0.0)),
		"base_damage": maxi(int(round(float(base.get("base_damage", 10)) * float(w.get("damage_mult", 1.0)))), 1),
		"damage_per_round": int(round(float(base.get("damage_per_round", 2)) * float(w.get("damage_ramp_mult", 1.0)))),
		"spawn_interval": maxf(float(base.get("spawn_interval", 1.1)) * float(w.get("spawn_interval_mult", 1.0)), 0.1),
		"max_alive": maxi(int(base.get("max_alive", 16)) + int(w.get("max_alive_add", 0)), 1),
	}
	for k in out:
		if base.has(k):
			main.set(k, out[k])
	set_active(id)
	return id


# ------------------------------------------------------------------ variants

## ZombieVariants wave mix of round n + wave_mix_round_offset, each weight x weight_mult[variant].
static func variant_weights(n: int, id: String = "") -> Dictionary:
	var v: Dictionary = profile(id).get("variants", {})
	var w: Dictionary = ZombieVariants.weights_for_round(n + int(v.get("wave_mix_round_offset", 0))).duplicate()
	var m: Dictionary = v.get("weight_mult", {})
	for k in w:
		w[k] = float(w[k]) * float(m.get(k, 1.0))
	return w


static func pick_variant(n: int, rng_value: float = -1.0, id: String = "") -> String:
	var w := variant_weights(n, id)
	var total := 0.0
	for k in w:
		if not ZombieVariants.get_variant(k).is_empty():
			total += maxf(float(w[k]), 0.0)
	if total <= 0.0:
		return ZombieVariants.pick(n, rng_value)
	var r := (rng_value if rng_value >= 0.0 else randf()) * total
	for k in w:
		if ZombieVariants.get_variant(k).is_empty():
			continue
		r -= maxf(float(w[k]), 0.0)
		if r <= 0.0:
			return k
	return ZombieVariants.pick(n, rng_value)


## Share of variant `vid` in round n (0..1), for tuning/tests.
static func variant_share(vid: String, n: int, id: String = "") -> float:
	var w := variant_weights(n, id)
	var total := 0.0
	for k in w:
		total += maxf(float(w[k]), 0.0)
	return float(w.get(vid, 0.0)) / total if total > 0.0 else 0.0


## A per-profile variant knob from difficulty.json profiles[].variants (e.g. "bloater_burst_player_cap"), or `fallback`.
static func variant_knob(key: String, fallback, id: String = ""):
	return profile(id).get("variants", {}).get(key, fallback)


## Share (0..1) of all spawns that special variant `vid` takes in round n (difficulty.json variants.specials):
## 0 before from_round, then weight + per_round x (n - from_round), capped at max.
static func special_share(vid: String, n: int, id: String = "") -> float:
	var sp: Dictionary = profile(id).get("variants", {}).get("specials", {})
	if not sp.has(vid) or ZombieVariants.get_variant(vid).is_empty():
		return 0.0
	var e: Dictionary = sp[vid]
	var from := int(e.get("from_round", 1))
	if n < from:
		return 0.0
	var w := float(e.get("weight", 0.0)) + float(e.get("per_round", 0.0)) * float(n - from)
	return clampf(minf(w, float(e.get("max", w))), 0.0, 1.0)


## Every variant's spawn weight in round n, specials included: the specials' shares, and the regular
## variant_weights() mix scaled to fill the rest. Sums to 1 (when there is a regular mix).
static func spawn_weights(n: int, id: String = "") -> Dictionary:
	var reg := variant_weights(n, id)
	var sp: Dictionary = profile(id).get("variants", {}).get("specials", {})
	var out := {}
	var special_total := 0.0
	for k in sp:
		var s := special_share(str(k), n, id)
		if s > 0.0:
			out[str(k)] = s
			special_total += s
	special_total = minf(special_total, 0.95)
	var reg_total := 0.0
	for k in reg:
		reg_total += maxf(float(reg[k]), 0.0)
	for k in reg:
		out[k] = (maxf(float(reg[k]), 0.0) / reg_total * (1.0 - special_total)) if reg_total > 0.0 else 0.0
	_apply_floors(out, profile(id).get("variants", {}).get("share_floor", {}))
	return out


## share_floor {vid: {share, from: [vids]}}: lifts vid to `share` (only if it's below), taking the gap from the `from`
## variants in proportion to their shares. Totals stay 1.
static func _apply_floors(w: Dictionary, floors: Dictionary) -> void:
	for vid in floors:
		var f: Dictionary = floors[vid]
		if not w.has(vid):
			continue
		var gap := float(f.get("share", 0.0)) - float(w[vid])
		if gap <= 0.0:
			continue
		var pool := 0.0
		for k in f.get("from", []):
			pool += float(w.get(k, 0.0))
		if pool <= 0.0:
			continue
		gap = minf(gap, pool)
		for k in f.get("from", []):
			if w.has(k):
				w[k] = float(w[k]) * (1.0 - gap / pool)
		w[vid] = float(w[vid]) + gap


## Like spawn_weights()[vid], 0 if absent.
static func spawn_share(vid: String, n: int, id: String = "") -> float:
	return float(spawn_weights(n, id).get(vid, 0.0))


## Spawner pick including the special variants (MAIN_HOOKS §15a). pick_variant() stays regular-only, so the
## live main.gd (no §15a) never spawns a Bloater / Crawler / Riot without its behaviour script.
static func pick_spawn_variant(n: int, rng_value: float = -1.0, id: String = "") -> String:
	var w := spawn_weights(n, id)
	var total := 0.0
	for k in w:
		total += maxf(float(w[k]), 0.0)
	if total <= 0.0:
		return pick_variant(n, rng_value, id)
	var r := (rng_value if rng_value >= 0.0 else randf()) * total
	var keys := w.keys()
	keys.sort() # deterministic order for a given rng_value
	for k in keys:
		r -= maxf(float(w[k]), 0.0)
		if r <= 0.0:
			return k
	return pick_variant(n, rng_value, id)


# ------------------------------------------------------------------ bosses (cadence for data/bosses.json)

static func boss_cfg(id: String = "") -> Dictionary:
	return profile(id).get("boss", {})


static func is_boss_round(n: int, id: String = "") -> bool:
	var b := boss_cfg(id)
	var first := int(b.get("first_round", 10))
	var every := maxi(int(b.get("every", 10)), 1)
	return n >= first and (n - first) % every == 0


## Bosses in round n (0 if not a boss round): base_count + per_cycle x (boss rounds so far - 1), capped at max_count.
static func boss_count(n: int, id: String = "") -> int:
	if not is_boss_round(n, id):
		return 0
	var b := boss_cfg(id)
	var cycle := (n - int(b.get("first_round", 10))) / maxi(int(b.get("every", 10)), 1)
	return mini(int(b.get("base_count", 1)) + int(b.get("per_cycle", 0)) * cycle, int(b.get("max_count", 1)))


static func boss_rounds(up_to: int, id: String = "") -> Array:
	var out := []
	for n in range(1, up_to + 1):
		if is_boss_round(n, id):
			out.append(n)
	return out


# ------------------------------------------------------------------ rewards

static func xp_mult(id: String = "") -> float:
	return float(_sec("rewards", "xp_mult", 1.0, id))


static func loot_rarity_bias(id: String = "") -> float:
	return float(_sec("rewards", "loot_rarity_bias", 0.0, id))


static func rare_currency_drop_mult(id: String = "") -> float:
	return float(_sec("rewards", "rare_currency_drop_mult", 1.0, id))


static func points_mult(id: String = "") -> float:
	return float(_sec("rewards", "points_mult", 1.0, id))


## Rarity weights (index = Rarity tier) x (1 + bias)^tier. bias 0 returns them unchanged.
static func bias_rarity_weights(ws: Array, bias: float) -> Array:
	if is_zero_approx(bias):
		return ws
	var out := []
	for i in ws.size():
		out.append(float(ws[i]) * pow(1.0 + bias, i))
	return out
