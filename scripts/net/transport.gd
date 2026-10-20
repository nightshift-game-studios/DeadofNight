class_name NetTransport
extends RefCounted
## Transport seam (Netz). Net talks only to this interface; ENet (enet_transport.gd) is the only implementation
## today. A GodotSteam transport later implements the same calls with SteamMultiplayerPeer (host = create a Steam
## lobby, join target = {"kind": "steam", "lobby_id": ...}); nothing above Net changes. See DESIGN.md §4.4.

## Short id ("enet", later "steam").
func kind() -> String:
	return "none"


## Start hosting. Returns OK or an Error.
func host(_port: int, _max_clients: int) -> Error:
	return ERR_UNAVAILABLE


## Join a target from Net.join_*: {"kind": "direct", "address", "port"} (ENet) or a transport-specific dict.
func join(_target: Dictionary) -> Error:
	return ERR_UNAVAILABLE


## The MultiplayerPeer to assign to SceneTree.multiplayer (null before host/join).
func peer() -> MultiplayerPeer:
	return null


## Round-trip time to a peer in ms (-1 unknown). On a client only peer 1 is known.
func ping_ms(_peer_id: int) -> int:
	return -1


## Kick a peer (host). `now` = without waiting for the disconnect handshake.
func kick(_peer_id: int, _now: bool = false) -> void:
	pass


## While a match scene loads the main thread can block for many seconds (map + nav bake): keep `peer_id`'s
## connection (0 = every peer) alive with data/net.json loading_timeout_ms; on = false restores the normal timeouts.
func set_loading(_peer_id: int, _on: bool) -> void:
	pass


## Whether this transport wants UPnP / port forwarding (Steam relays don't).
func needs_port_forward() -> bool:
	return false


func close() -> void:
	pass
