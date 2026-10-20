extends Node
## Loopback probe node (Netz). Lives at /root/NetProbe on both server and client so RPC paths match.
## Server: on peer connect -> ping(nonce) [authority, reliable]. Client -> pong(nonce*2+1) [any_peer, reliable].
## Server checks sender id + value, sends a burst of unreliable "tick" packets, then done(). Both exit 0 on pass.

signal finished(ok: bool, msg: String)

var role := "server"
var nonce := 0
var ticks_rx := 0
const TICKS := 30


@rpc("authority", "call_remote", "reliable")
func ping(n: int) -> void:
	print("[client] ping %d from %d" % [n, multiplayer.get_remote_sender_id()])
	if multiplayer.get_remote_sender_id() != 1:
		finished.emit(false, "ping not from server")
		return
	pong.rpc_id(1, n * 2 + 1)


@rpc("any_peer", "call_remote", "reliable")
func pong(v: int) -> void:
	var from := multiplayer.get_remote_sender_id()
	print("[server] pong %d from peer %d" % [v, from])
	if v != nonce * 2 + 1:
		finished.emit(false, "bad pong value %d" % v)
		return
	for i in TICKS:
		tick.rpc_id(from, i)
	done.rpc_id(from, TICKS)
	# give ENet a moment to flush before the server quits
	await get_tree().create_timer(0.5).timeout
	finished.emit(true, "rpc round-trip ok with peer %d" % from)


@rpc("authority", "call_remote", "unreliable")
func tick(_i: int) -> void:
	ticks_rx += 1


@rpc("authority", "call_remote", "reliable")
func done(sent: int) -> void:
	# reliable done() is ordered after the unreliable ticks only loosely; on loopback nearly all arrive
	await get_tree().create_timer(0.2).timeout
	finished.emit(ticks_rx > 0, "done: %d/%d unreliable ticks received" % [ticks_rx, sent])
