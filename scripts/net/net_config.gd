class_name NetConfig
extends RefCounted
## data/net.json reader (Netz). get_value("downed.bleed_out_s") walks dotted keys; anything missing falls back to
## DEFAULTS, so the game works with no file at all. Tests: NetConfig.override({...}) / NetConfig.reload().

const PATH := "res://data/net.json"
const DEFAULTS := {
	"transport": "enet",
	"default_port": 7777,
	"max_players": 4,
	"proto_version": 1,
	"connect_timeout_s": 8.0,
	"peer_timeout_min_ms": 5000,
	"peer_timeout_max_ms": 15000,
	"loading_timeout_ms": 120000,
	"compression": "range_coder",
	"upnp": {"enabled": true, "discover_ms": 2000, "discover_ttl": 2, "description": "Gravecrew"},
	"join_code": {"prefix": "GC"},
	"avatar": {"body": "desi", "scene": "res://assets/models/player/player.glb",
		"tints": ["#D9601F", "#C9D12B", "#1E9FC8", "#C2307A"],
		"loco_speeds": {"walk": 2.0, "run": 5.0, "sprint": 8.5, "crouch_walk": 2.8},
		"clip_foot_speeds": {"walk": 1.16, "run": 6.2, "sprint": 9.5, "crouch_walk": 0.77},
		"reload_marks_s": {"mag_out_start": 0.28, "mag_out_end": 0.65, "mag_in": 1.71, "slap": 1.82, "clip_len": 2.167},
		"throw_release_s": 0.33, "throw_clip_len_s": 1.333, "ads_xfade_s": 0.12, "name_tag_offset_m": 0.0, "snap_teleport_m": 6.0},
	"profile": {"path": "user://net_profile.cfg", "max_name_length": 16, "default_name": "Survivor"},
	"lobby": {"leader_is_host": true, "leader_picks_map": true, "leader_picks_difficulty": true,
		"start_requires_all_ready": true, "allow_late_join": true, "scene_ready_timeout_s": 20.0, "party_refresh_s": 2.0},
	"downed": {"enabled": true, "bleed_out_s": 30.0, "revive_time_s": 3.0, "revive_range_m": 2.0, "revive_health_frac": 0.5,
		"respawn_next_round": true, "game_over_when_all_down": true},
	"points": {"host_authoritative": true, "per_hit": "economy", "kill_bonus": "economy", "revive": 100, "late_join_start": 500},
	"projectiles": {"max_throw_dist": 4.0, "max_throw_speed": 45.0, "max_throws_per_s": 4},
	"drops": {"shared_world_drops": true, "first_grab_wins": true, "powerups_team_wide": true},
	"scaling": {"per_extra_player": 0.5, "max_alive_cap": 24},
	"tick": {"player_state_hz": 30, "zombie_sync_hz": 20, "interp_delay_ms": 100, "teammate_hp_hz": 5.0},
	"offers": {"wait_for_all_s": 30.0},
	"spend": {"timeout_s": 3.0, "door_retry_s": 1.0},
	"spectate": {"enabled": true, "when_downed": true, "distance_m": 2.6, "height_m": 0.45, "next_action": "shoot", "prev_action": "ads"},
	"validation": {"range_slack": 1.1, "max_damage_mult": 2.0, "max_player_speed": 20.0, "max_hit_damage": 5000.0},
}
## Fallbacks for "economy" point values (match data/economy.json today).
const ECONOMY_FALLBACK := {"per_hit": 5, "kill_bonus": 50}

static var _data: Dictionary = {}
static var _loaded := false
static var _override: Dictionary = {}


static func data() -> Dictionary:
	if not _loaded:
		_loaded = true
		_data = {}
		if FileAccess.file_exists(PATH):
			var f := FileAccess.open(PATH, FileAccess.READ)
			var d = JSON.parse_string(f.get_as_text()) if f else null
			if d is Dictionary:
				_data = d
			else:
				push_warning("NetConfig: %s is not valid JSON; using defaults" % PATH)
	return _data


static func reload() -> void:
	_loaded = false
	_override = {}


## Tests: replace values (dotted keys allowed: {"downed.bleed_out_s": 5.0}).
static func override(values: Dictionary) -> void:
	for k in values:
		_override[str(k)] = values[k]


static func _walk(root: Dictionary, key: String):
	var cur = root
	for part in key.split("."):
		if cur is Dictionary and (cur as Dictionary).has(part):
			cur = cur[part]
		else:
			return null
	return cur


static func get_value(key: String, fallback = null):
	if _override.has(key):
		return _override[key]
	var v = _walk(data(), key)
	if v == null:
		v = _walk(DEFAULTS, key)
	return fallback if v == null else v


static func get_int(key: String) -> int:
	return int(get_value(key, 0))


static func get_float(key: String) -> float:
	return float(get_value(key, 0.0))


static func get_bool(key: String) -> bool:
	return bool(get_value(key, false))


## Point values for co-op ("per_hit" | "kill_bonus" | "revive"). "economy" -> the solo value (Progress / economy.json).
static func points(kind: String) -> int:
	var v = get_value("points." + kind)
	if v is String and v == "economy":
		var ml := Engine.get_main_loop()
		var prog = (ml as SceneTree).root.get_node_or_null("Progress") if ml is SceneTree else null
		var prop := "points_per_hit" if kind == "per_hit" else "points_per_kill"
		if prog and prop in prog:
			return int(prog.get(prop))
		return int(ECONOMY_FALLBACK.get(kind, 0))
	return int(v) if v != null else 0


## Zombie scaling for `players` in the match: {"count_mult", "max_alive"} from the solo base max_alive.
static func scaling(players: int, base_max_alive: int) -> Dictionary:
	var extra := maxi(players - 1, 0)
	var mult := 1.0 + get_float("scaling.per_extra_player") * extra
	var cap := get_int("scaling.max_alive_cap")
	var ma := base_max_alive if extra == 0 else mini(int(round(base_max_alive * mult)), maxi(cap, base_max_alive))
	return {"count_mult": mult, "max_alive": ma}
