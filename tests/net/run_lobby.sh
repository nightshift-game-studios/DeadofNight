#!/bin/bash
# Multi-instance lobby tests: 1 headless host + 2-4 headless clients on 127.0.0.1. Exit 0 = PASS.
# usage: tests/net/run_lobby.sh [project dir]       (logs in $NET_LOGDIR, default /tmp/netz_lobby)
P=${1:-$(pwd)}
G=${GODOT:-/workspace/tools/Godot_v4.7.2-stable_linux.x86_64}
L=${NET_LOGDIR:-/tmp/netz_lobby}; mkdir -p "$L"; rm -f "$L"/*.log
cd "$P" || exit 2
S="res://tests/net/lobby_peer.gd"
run() { local name=$1; shift; timeout 70 "$G" --headless --path . -s $S -- --name=$name "$@" > "$L/$name.log" 2>&1 & pids+=($!); }
FAIL=0
# ---- scenario 1: lobby (host Alice + Bob, Cara, Dan; Dan leaves after the callout; then the host leaves)
PORT=$((20000 + RANDOM % 20000))
pids=()
run Alice --role=host --scenario=lobby --port=$PORT --clients=3
sleep 1.5
run Bob --role=client --scenario=lobby --port=$PORT --clients=3
run Cara --role=client --scenario=lobby --port=$PORT --clients=3
run Dan --role=client --scenario=lobby --port=$PORT --clients=3 --leave-after=callout
for p in "${pids[@]}"; do wait $p || FAIL=1; done
# ---- scenario 2: rejections (max 2 players): bad protocol, party full, match in progress
PORT=$((20000 + RANDOM % 20000))
pids=()
run Host2 --role=host --scenario=reject --port=$PORT --max=2
sleep 1.5
run Old --role=client --scenario=reject --port=$PORT --proto=99 --expect-fail=version_mismatch
sleep 1.5
run Ann --role=client --scenario=reject --port=$PORT --leave-after=match_started
sleep 2.0
run Late --role=client --scenario=reject --port=$PORT --expect-fail=party_full
sleep 4.0
run Late2 --role=client --scenario=reject --port=$PORT --expect-fail=in_progress
for p in "${pids[@]}"; do wait $p || FAIL=1; done
# ---- scenario 3: a client crashes (kill -9); the host must drop it via ENet timeouts
PORT=$((20000 + RANDOM % 20000))
pids=()
run Host3 --role=host --scenario=crash --port=$PORT --peer-timeout-ms=3000
sleep 1.5
timeout 70 "$G" --headless --path . -s $S -- --name=Eve --role=client --scenario=crash --port=$PORT > "$L/Eve.log" 2>&1 & EVE=$!
for i in $(seq 1 100); do grep -q CRASH_READY "$L/Host3.log" && break; sleep 0.2; done
kill -9 $(pgrep -P $EVE) $EVE 2>/dev/null; wait $EVE 2>/dev/null
echo "NETTEST: PASS [Eve] killed with SIGKILL on purpose" >> "$L/Eve.log"
for p in "${pids[@]}"; do wait $p || FAIL=1; done
# ---- scenario 4: Gooey UI API: start_block_reason, kick(reason) + peer_left reasons, teammate hp (throttled)
PORT=$((20000 + RANDOM % 20000))
pids=()
run Alice4 --role=host --scenario=ui --port=$PORT
sleep 1.5
run Bob --role=client --scenario=ui --port=$PORT
sleep 0.5
run Cara --role=client --scenario=ui --port=$PORT
for p in "${pids[@]}"; do wait $p || FAIL=1; done
cat "$L"/*.log | grep -h "NETTEST\|SCRIPT ERROR\|Parse Error"
n_pass=$(cat "$L"/*.log | grep -c "^NETTEST: PASS"); n_fail=$(cat "$L"/*.log | grep -c "^NETTEST: FAIL")
echo "run_lobby: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL) ($n_pass peers passed, $n_fail failed; logs in $L)"
exit $FAIL
