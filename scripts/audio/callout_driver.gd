extends Node
## Host-side glue between gameplay and the announcer. Holds one KillTracker per peer (keyed by peer_id)
## and routes every detected event:
##   - Net autoload present (co-op, phase 2): only the host detects; it calls
##     Net.broadcast_callout(event_id, peer_id), which RPCs to every peer, and each peer calls
##     Callouts.announce(event_id, Net.get_player_name(peer_id), peer_id == Net.local_peer_id()).
##   - No Net autoload (solo today): Callouts.announce(event_id, "", true) directly.
## Typical use (main.gd):  var cd := CalloutDriver.new(); add_child(cd); cd.bind_local_player(player)
## For remote players the host calls on_kill(peer_id, ...) / on_damage(peer_id) from its own hit/damage code.

const KillTrackerScr := preload("res://scripts/audio/kill_tracker.gd")

signal event_detected(event_id: String, peer_id: int)

var config: Dictionary = {}
var trackers: Dictionary = {} ## peer_id -> KillTracker
var manual_time := -1.0 ## tests: fixed clock when >= 0
var _player: Node = null
var _seen_kills: Dictionary = {} ## target instance id -> time (dedupe multi-pellet / multi-source kill reports)


func _ready() -> void:
	if config.is_empty():
		config = KillTrackerScr.load_config()


func now() -> float:
	return manual_time if manual_time >= 0.0 else Time.get_ticks_msec() / 1000.0


func tracker(peer_id: int):
	if not trackers.has(peer_id):
		if config.is_empty():
			config = KillTrackerScr.load_config()
		trackers[peer_id] = KillTrackerScr.new(config)
	return trackers[peer_id]


func local_peer_id() -> int:
	var net := _net()
	return int(net.local_peer_id()) if net else 1


## True where detection should run: always in solo / without Net; only on the host when networked.
func is_authority() -> bool:
	var net := _net()
	return net == null or bool(net.is_host())


## Register a kill by peer_id; returns the routed event ids.
func on_kill(peer_id: int, is_headshot: bool = false, is_boss: bool = false, time_s: float = -1.0) -> Array:
	if not is_authority():
		return []
	var evs: Array = tracker(peer_id).register_kill(now() if time_s < 0.0 else time_s, is_headshot, is_boss)
	for ev in evs:
		_route(str(ev), peer_id)
	return evs


func on_damage(peer_id: int) -> void:
	if is_authority():
		tracker(peer_id).register_damage_taken()


func remove_peer(peer_id: int) -> void:
	trackers.erase(peer_id)


## Solo / host-local hookup: listens on the GameEvents bus for this player's kills and damage.
func bind_local_player(player: Node) -> void:
	_player = player
	var bus := get_node_or_null("/root/GameEvents")
	if bus and not bus.event.is_connected(_on_game_event):
		bus.event.connect(_on_game_event)


func _on_game_event(name: StringName, ctx: Dictionary) -> void:
	if _player == null or ctx.get("player") != _player:
		return
	match name:
		&"enemy_killed":
			var target = ctx.get("target")
			if target is Object and is_instance_valid(target):
				var id: int = target.get_instance_id()
				if _seen_kills.has(id):
					return
				_seen_kills[id] = now()
				_prune_seen()
			var boss: bool = target is Node and is_instance_valid(target) and target.has_meta("is_boss") and bool(target.get_meta("is_boss"))
			on_kill(local_peer_id(), bool(ctx.get("is_headshot", false)), boss)
		&"damage_taken":
			if int(ctx.get("dealt", 0)) + int(ctx.get("absorbed", 0)) > 0:
				on_damage(local_peer_id())


func _route(event_id: String, peer_id: int) -> void:
	event_detected.emit(event_id, peer_id)
	var net := _net()
	if net and net.has_method("broadcast_callout"):
		net.broadcast_callout(event_id, peer_id)
		return
	var callouts := get_node_or_null("/root/Callouts")
	if callouts:
		callouts.announce(event_id, "", true)


func _net() -> Node:
	return get_node_or_null("/root/Net")


func _prune_seen() -> void:
	if _seen_kills.size() < 256:
		return
	var t := now()
	for k in _seen_kills.keys():
		if t - float(_seen_kills[k]) > 5.0:
			_seen_kills.erase(k)
