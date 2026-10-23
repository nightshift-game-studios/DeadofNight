#!/bin/bash
# NOTE: the sim is load sensitive (4x time scale); keep P <= cores/2. P env sets parallel jobs (default 3).
# usage: tools/boss_sim_matrix.sh <worktree> <outdir> [runs] [bosses...]  -- runs tests/boss_sim.gd over the budget matrix in parallel
WT=$1; OUT=$2; RUNS=${3:-2}; shift 3; BOSSES=${@:-bellwether choir_host lantern_stalker}
mkdir -p $OUT; rm -f $OUT/*.log
jobs=()
for b in $BOSSES; do for cfg in easy:10 medium:8 hard:6 hard:11 hard:21; do for p in 1 4; do
  jobs+=("$b ${cfg%%:*} ${cfg##*:} $p"); done; done; done
printf '%s\n' "${jobs[@]}" | xargs -P ${P:-3} -L1 bash -c 'XDG_DATA_HOME=/tmp/xdg_$$ timeout 900 /workspace/tools/Godot_v4.7.2-stable_linux.x86_64 --headless --path '$WT' -s res://tests/boss_sim.gd -- --boss=$0 --diff=$1 --round=$2 --players=$3 --bot=competent,sloppy,idle --runs='$RUNS' 2>&1 | grep -E "^SIM|SCRIPT ERROR|ERROR:" > '$OUT'/$0_$1_$2_p$3.log'
cat $OUT/*.log | grep -v "ERROR: .* resources still" | sort
