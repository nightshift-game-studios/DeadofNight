class_name NetGate
extends RefCounted
## Static entry points for hooks in scripts that can be compiled before the autoloads exist (enemy.gd and
## zombie_nav.gd are preloaded by `-s` test scripts such as Skillz's ai_nav_test, where the `Net` global isn't
## registered yet). Each call looks up /root/Net at runtime and falls back to exactly the old solo behaviour.

static func net() -> Node:
	var ml := Engine.get_main_loop()
	return (ml as SceneTree).root.get_node_or_null("Net") if ml is SceneTree else null


static func is_networked() -> bool:
	var n := net()
	return n != null and n.is_networked()


## E1: nearest alive player (solo / no Net: the "player" group's first node, as before).
static func pick_target(e: Node3D) -> Node3D:
	var n := net()
	if n:
		return n.pick_target(e)
	return e.get_tree().get_first_node_in_group("player") as Node3D if e.is_inside_tree() else null


## E2: client puppet tick.
static func zombie_puppet_tick(e: Node, delta: float) -> void:
	var n := net()
	if n:
		n.zombie_puppet_tick(e, delta)


## E3: client hit -> host claim; returns the predicted kill.
static func forward_zombie_damage(e: Node, amount: float, hit_pos: Vector3, crit: bool, source: Node) -> bool:
	var n := net()
	return n.forward_zombie_damage(e, amount, hit_pos, crit, source) if n else false


static func forward_zombie_status(e: Node, id: String, p: Dictionary) -> void:
	var n := net()
	if n:
		n.forward_zombie_status(e, id, p)


## E4: seeded RNG for a co-op spawn (null = use the global RNG, as before).
static func rng_for(e: Node) -> RandomNumberGenerator:
	var n := net()
	return n.rng_for(e) if n else null


## E6: every player body (local player + remote avatars) when networked; null = keep the caller's own lookup.
static func players_or_null() -> Variant:
	var n := net()
	return n.players() if n and n.is_networked() else null


## M13 (map_door.gd interact): true = co-op handled it (host charges + opens everywhere); false = solo, door as before.
static func door_interact(door: Node, player: Node) -> bool:
	var n := net()
	return n != null and n.is_networked() and n.world.door_interact(door, player)


## M13 (run_state.gd paid reroll): charge through the host; cb.call(ok, reason) -> bool (false = not taken -> refund).
static func spend_with_callback(amount: int, reason: String, cb: Callable) -> void:
	var n := net()
	if n:
		n.world.spend_with_callback(amount, reason, cb)
	else:
		cb.call(false, "no_net")


## P1 (ThrownProjectile.spawn, MAIN_HOOKS §22): the host's authoritative projectile exists -> every client spawns a
## visual-only copy of `spec`. Solo / client / a visual copy: no-op.
static func projectile_spawned(spec: Dictionary, p: Node = null) -> void:
	var n := net()
	if n and n.is_networked() and n.is_host():
		n.projectiles.host_spawned(spec, p)


## G2 (host, the authoritative projectile only): a gameplay moment every client copy should show
## (detonate {pos}, stick {target}, bounce {pos}, orbs {...}). Node values in `data` are mapped per machine.
## Copies get p.net_event(kind, data). Solo / client / not broadcast: false, nothing sent.
static func projectile_event(p: Node, kind: String, data: Dictionary = {}) -> bool:
	var n := net()
	return n != null and n.is_networked() and n.is_host() and n.projectiles.host_event(p, kind, data)


## G3: a heal the host decided (Leechbell orb reached the thrower). Co-op host: the owner's machine heals its own
## player and true is returned. Solo: false -> the caller heals as before (target.heal(amount)). A co-op client
## (visual copies) must not call it: false, nothing happens.
static func grant_heal(target: Node, amount: int, reason: String = "") -> bool:
	var n := net()
	if n == null or not n.is_networked():
		return false
	if n.is_host():
		n.match_players.host_heal(target, amount, reason)
	return true


## E7 (enemy.gd take_damage / apply_status, host side): note who caused this damage so kill / hit credit goes to
## the player behind `source` (a remote avatar's grenade, fire patch, chain shock ...). Solo: nothing.
static func note_damage_source(e: Node, source: Node) -> void:
	var n := net()
	if n and n.is_networked() and n.is_host():
		n.note_damage_source(e, source)


## A player's own throw (grenades, later): co-op client -> visual copy + request to the host; solo / host -> null,
## so the caller spawns as before (ThrownProjectile.spawn(spec)).
static func request_throw(spec: Dictionary) -> Node:
	var n := net()
	if n and n.is_networked() and not n.is_host():
		return n.projectiles.request_throw(spec)
	return null
