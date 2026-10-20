#!/bin/bash
# Multi-instance MATCH test: the real main.tscn on 1 headless host + 2 headless clients (127.0.0.1). Exit 0 = PASS.
# usage: tests/net/run_match.sh [project dir] [map] [body]   (logs in $NET_LOGDIR, default /tmp/netz_match)
P=${1:-$(pwd)}; MAP=${2:-arena}; BODY=${3:-desi}
G=${GODOT:-/workspace/tools/Godot_v4.7.2-stable_linux.x86_64}
L=${NET_LOGDIR:-/tmp/netz_match}; mkdir -p "$L"; rm -f "$L"/*.log
cd "$P" || exit 2
S="res://tests/net/match_peer.gd"
PORT=$((20000 + RANDOM % 20000))
pids=(); FAIL=0
run() { local name=$1; shift; timeout 200 "$G" --headless --path . -s $S -- --name=$name --port=$PORT --map=$MAP --body=$BODY "$@" > "$L/$name.log" 2>&1 & pids+=($!); }
run Alice --role=host --clients=2
sleep 1.5
run Bob --role=client --clients=2
run Cara --role=client --clients=2
for p in "${pids[@]}"; do wait $p || FAIL=1; done
grep -h "NETTEST\|SCRIPT ERROR\|Parse Error" "$L"/*.log
n_pass=$(cat "$L"/*.log | grep -c "^NETTEST: PASS"); n_fail=$(cat "$L"/*.log | grep -c "^NETTEST: FAIL")
n_checks=$(cat "$L"/*.log | grep -cE "^\[[A-Za-z]+\] ok  ")
[ $n_pass -eq 3 ] || FAIL=1
echo "run_match: $([ $FAIL -eq 0 ] && echo PASS || echo FAIL) ($n_pass/3 peers passed, $n_fail failed, $n_checks checks ok; logs in $L)"
exit $FAIL
