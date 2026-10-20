#!/bin/bash
# Multi-instance LATE JOIN test (phase 3a): host Alice + Bob start rustwell_foundry; Dan joins mid-round, Eve in the
# break. Exit 0 = PASS.   usage: tests/net/run_latejoin.sh [project dir] [map]   (logs in $NET_LOGDIR, default /tmp/netz_late)
P=${1:-/workspace/netz}; MAP=${2:-rustwell_foundry}
G=${GODOT:-/workspace/tools/Godot_v4.7.2-stable_linux.x86_64}
L=${NET_LOGDIR:-/tmp/netz_late}; mkdir -p "$L"; rm -f "$L"/*.log
cd "$P" || exit 2
S="res://tests/net/latejoin_peer.gd"
PORT=$((20000 + RANDOM % 20000))
pids=(); FAIL=0
run() { local name=$1; shift; timeout 360 "$G" --headless --path . -s $S -- --name=$name --port=$PORT --map=$MAP "$@" > "$L/$name.log" 2>&1 & pids+=($!); }
waitfor() { for i in $(seq 1 1200); do grep -q "$1" "$L/Alice.log" 2>/dev/null && return 0; grep -q "^NETTEST" "$L/Alice.log" 2>/dev/null && return 1; sleep 0.25; done; return 1; }
run Alice --role=host
sleep 1.5
run Bob --role=client
waitfor LATE_DAN && run Dan --role=client
waitfor LATE_EVE && run Eve --role=client
for p in "${pids[@]}"; do wait $p || FAIL=1; done
grep -h "NETTEST\|SCRIPT ERROR\|Parse Error" "$L"/*.log
n_pass=$(cat "$L"/*.log | grep -c "^NETTEST: PASS"); n_fail=$(cat "$L"/*.log | grep -c "^NETTEST: FAIL")
n_checks=$(cat "$L"/*.log | grep -cE "^\[[A-Za-z]+\] ok  ")
[ $n_pass -eq 4 ] || FAIL=1
echo "run_latejoin: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL) ($n_pass/4 peers passed, $n_fail failed, $n_checks checks ok; logs in $L)"
exit $FAIL
