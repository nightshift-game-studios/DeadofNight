#!/bin/bash
# Netz net-only runner (team rules 2026-10-20: no full-suite runs): compile_check + the net unit suites present in this
# tree + the multi-instance net tests (loopback, lobby, match, late join). Godot user data goes to a temp XDG_DATA_HOME.
# usage: tests/net/run_net_suites.sh [project dir] [logdir]
P=${1:-$(pwd)}; L=${2:-/tmp/netz_suites}; mkdir -p $L
G=/workspace/tools/Godot_v4.7.2-stable_linux.x86_64
export XDG_DATA_HOME=${XDG_DATA_HOME_NETZ:-$(mktemp -d /tmp/netz_xdg.XXXX)}
cd "$P"
for s in compile_check net_test net_seam_test net_avatar_test item_dict_test net_ui_api_test net_m13_test m13_review_test; do
  [ -f tests/$s.gd ] || continue
  timeout 600 $G --headless --path . -s res://tests/$s.gd > $L/$s.log 2>&1; rc=$?
  sum=$(grep -E "passed|OK|FAILED|failed" $L/$s.log | tail -1)
  nf=$(grep -c "^FAIL" $L/$s.log); ne=$(grep -c "SCRIPT ERROR\|Parse Error" $L/$s.log)
  echo "$s rc=$rc fail=$nf script_errors=$ne | $sum"
done
for t in loopback lobby match latejoin; do
  NET_LOGDIR=$L/$t bash tests/net/run_$t.sh "$P" 2>&1 | tail -1
done
