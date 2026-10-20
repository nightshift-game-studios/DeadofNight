class_name NetEnetTransport
extends NetTransport
## ENet transport (Netz): UDP, host = server on `port`, range-coder compression, configurable peer timeouts.

var _peer: ENetMultiplayerPeer


func kind() -> String:
	return "enet"


func host(port: int, max_clients: int) -> Error:
	close()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, max_clients)
	if err != OK:
		_peer = null
		return err
	_tune()
	return OK


func join(target: Dictionary) -> Error:
	close()
	if str(target.get("kind", "direct")) != "direct":
		return ERR_INVALID_PARAMETER
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(str(target.get("address", "")), int(target.get("port", 0)))
	if err != OK:
		_peer = null
		return err
	_tune()
	return OK


func _tune() -> void:
	if _peer.host and str(NetConfig.get_value("compression", "range_coder")) == "range_coder":
		_peer.host.compress(ENetConnection.COMPRESS_RANGE_CODER)


## Apply timeouts once a peer object exists (call on connect).
func tune_peer(peer_id: int) -> void:
	if _peer == null:
		return
	var pp := _peer.get_peer(peer_id)
	if pp:
		pp.set_timeout(32, NetConfig.get_int("peer_timeout_min_ms"), NetConfig.get_int("peer_timeout_max_ms"))


func set_loading(peer_id: int, on: bool) -> void:
	if _peer == null or _peer.host == null:
		return
	var mx := NetConfig.get_int("loading_timeout_ms") if on else NetConfig.get_int("peer_timeout_max_ms")
	var mn := mx if on else NetConfig.get_int("peer_timeout_min_ms")
	var only: ENetPacketPeer = _peer.get_peer(peer_id) if peer_id != 0 else null
	if peer_id != 0 and only == null:
		return
	for pp in _peer.host.get_peers():
		if only == null or pp == only:
			pp.set_timeout(32, mn, mx)


func peer() -> MultiplayerPeer:
	return _peer


func ping_ms(peer_id: int) -> int:
	if _peer == null:
		return -1
	var pp := _peer.get_peer(peer_id)
	return int(pp.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)) if pp else -1


func kick(peer_id: int, now: bool = false) -> void:
	if _peer:
		_peer.disconnect_peer(peer_id, now)


func needs_port_forward() -> bool:
	return true


func close() -> void:
	if _peer:
		if _peer.host:
			_peer.host.flush() # send queued reliable packets (e.g. a rejection) before the disconnect
		_peer.close()
	_peer = null
