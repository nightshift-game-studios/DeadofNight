#!/bin/bash
# Netz suite runner: the standard suites in /workspace/tools/run_suites.sh + the net unit suites + the multi-instance net tests (loopback, lobby, match).
# usage: tests/net/run_net_suites.sh [project dir] [logdir]
# (To fold the unit suites into /workspace/tools/run_suites.sh, add "net_test net_seam_test net_avatar_test item_dict_test net_m13_test net_ui_api_test" to its list; see NET_HOOKS.md.)
P=${1:-/workspace/netz}; L=${2:-/tmp/netz_suites}; mkdir -p $L
G=/workspace/tools/Godot_v4.7.2-stable_linux.x86_64
bash /workspace/tools/run_suites.sh "$P" "$L"
cd "$P"
for s in net_test net_seam_test net_avatar_test item_dict_test net_m13_test net_ui_api_test; do
  timeout 600 $G --headless --path . -s res://tests/$s.gd > $L/$s.log 2>&1; rc=$?
  sum=$(grep -E "passed|OK|FAILED" $L/$s.log | tail -1)
  np=$(grep -c "^PASS" $L/$s.log); nf=$(grep -c "^FAIL" $L/$s.log); ne=$(grep -c "SCRIPT ERROR\|Parse Error" $L/$s.log)
  echo "$s rc=$rc pass=$np fail=$nf script_errors=$ne | $sum"
done
NET_LOGDIR=$L/loopback bash tests/net/run_loopback.sh "$P" | tail -1
NET_LOGDIR=$L/lobby bash tests/net/run_lobby.sh "$P" | tail -1
NET_LOGDIR=$L/match bash tests/net/run_match.sh "$P" | tail -1
