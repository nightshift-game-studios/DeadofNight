#!/bin/bash
# ENet loopback smoke test: 1 headless server + 1 headless client on 127.0.0.1. Exit 0 = PASS.
# usage: tests/net/run_loopback.sh [project dir] [port]
P=${1:-$(pwd)}; PORT=${2:-$((20000 + RANDOM % 20000))}
G=${GODOT:-/workspace/tools/Godot_v4.7.2-stable_linux.x86_64}
L=${NET_LOGDIR:-/tmp/netz_loopback}; mkdir -p "$L"
cd "$P" || exit 2
timeout 40 "$G" --headless --path . -s res://tests/net/loopback_test.gd -- --role=server --port=$PORT > "$L/server.log" 2>&1 & SP=$!
sleep 1.5
timeout 40 "$G" --headless --path . -s res://tests/net/loopback_test.gd -- --role=client --port=$PORT > "$L/client.log" 2>&1 & CP=$!
wait $SP; SRC=$?; wait $CP; CRC=$?
grep -h "NET_LOOPBACK\|SCRIPT ERROR\|Parse Error" "$L/server.log" "$L/client.log"
if [ $SRC -eq 0 ] && [ $CRC -eq 0 ]; then echo "run_loopback: PASS (port $PORT, server rc=$SRC client rc=$CRC)"; exit 0; fi
echo "run_loopback: FAIL (port $PORT, server rc=$SRC client rc=$CRC; logs in $L)"; exit 1
