extends SceneTree
## ENet loopback smoke test (Netz). Seed of the automated multi-instance harness.
## Run via tests/net/run_loopback.sh, or by hand:
##   godot --headless --path . -s res://tests/net/loopback_test.gd -- --role=server --port=7777
##   godot --headless --path . -s res://tests/net/loopback_test.gd -- --role=client --port=7777
## Prints "NET_LOOPBACK: PASS ..." / "NET_LOOPBACK: FAIL ..." and exits 0 / 1.

const ProbeScr := preload("res://tests/net/net_probe.gd")
var role := "server"
var port := 7777
var host := "127.0.0.1"
var timeout_s := 15.0
var _done := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="): role = a.get_slice("=", 1)
		elif a.begins_with("--port="): port = int(a.get_slice("=", 1))
		elif a.begins_with("--host="): host = a.get_slice("=", 1)
		elif a.begins_with("--timeout="): timeout_s = float(a.get_slice("=", 1))
	var probe: Node = ProbeScr.new()
	probe.name = "NetProbe"
	probe.role = role
	root.add_child(probe)
	probe.finished.connect(_finish)
	var peer := ENetMultiplayerPeer.new()
	var err: int
	if role == "server":
		err = peer.create_server(port, 4)
	else:
		err = peer.create_client(host, port)
	if err != OK:
		_finish(false, "%s create failed: %s" % [role, error_string(err)])
		return
	get_multiplayer().multiplayer_peer = peer
	print("[%s] up on %s:%d (unique id %d)" % [role, host, port, get_multiplayer().get_unique_id()])
	if role == "server":
		probe.nonce = randi() % 100000
		get_multiplayer().peer_connected.connect(func(id: int):
			print("[server] peer %d connected" % id)
			probe.ping.rpc_id(id, probe.nonce))
	else:
		get_multiplayer().connected_to_server.connect(func(): print("[client] connected"))
		get_multiplayer().connection_failed.connect(func(): _finish(false, "connection_failed"))
		get_multiplayer().server_disconnected.connect(func(): if not _done: _finish(false, "server_disconnected early"))
	create_timer(timeout_s).timeout.connect(func(): _finish(false, "timeout after %.0fs" % timeout_s))


func _finish(ok: bool, msg: String) -> void:
	if _done:
		return
	_done = true
	print("NET_LOOPBACK: %s [%s] %s" % ["PASS" if ok else "FAIL", role, msg])
	var p := get_multiplayer().multiplayer_peer
	if p is ENetMultiplayerPeer:
		(p as ENetMultiplayerPeer).close()
	quit(0 if ok else 1)
