class_name ZombieVariants
extends RefCounted
## Zombie variant data (res://data/zombies.json) and the per-round wave mix.
##   ZombieVariants.pick(round)      -> variant id ("city" / "worker" / "soldier"), weighted by wave_mix
##   ZombieVariants.get_variant(id)  -> {model, model_height, health_mult, speed_mult, damage_mult, ...}
##   ZombieVariants.scene(id)        -> cached PackedScene of the model

const DATA_PATH := "res://data/zombies.json"
static var _data: Dictionary = {}
static var _scenes: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_data = d if d is Dictionary else {}
	return _data


static func ids() -> Array:
	return data().get("variants", {}).keys()


static func get_variant(id: String) -> Dictionary:
	return data().get("variants", {}).get(id, {})


static func scene(id: String) -> PackedScene:
	if not _scenes.has(id):
		var p: String = get_variant(id).get("model", "")
		_scenes[id] = load(p) as PackedScene if p != "" and ResourceLoader.exists(p) else null
	return _scenes[id]


## The weights that apply in round n (highest from_round <= n).
static func weights_for_round(n: int) -> Dictionary:
	var best: Dictionary = {}
	var best_from := -1
	for e in data().get("wave_mix", []):
		var fr := int(e.get("from_round", 1))
		if fr <= maxi(n, 1) and fr > best_from:
			best_from = fr
			best = e.get("weights", {})
	return best


static func pick(n: int, rng_value: float = -1.0) -> String:
	var w := weights_for_round(n)
	var total := 0.0
	for k in w:
		if not get_variant(k).is_empty():
			total += maxf(float(w[k]), 0.0)
	if total <= 0.0:
		return "city" if not get_variant("city").is_empty() else (str(ids()[0]) if ids().size() else "")
	var r := (rng_value if rng_value >= 0.0 else randf()) * total
	for k in w:
		if get_variant(k).is_empty():
			continue
		r -= maxf(float(w[k]), 0.0)
		if r <= 0.0:
			return k
	return w.keys().back()
