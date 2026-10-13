#!/bin/bash
# Round 2 live driver: real fm-spawn.sh --secondmate at target 51dbc3dd, real Treehouse 2.3.0 pool, real tmux, disposable lab home.
# FM_SKIP_SECONDMATE_SYNC / FM_SKIP_SECONDMATE_INHERIT are set because the disposable home is not a Firstmate checkout.
. "$1/env.sh"; cd "$W"
clean() { grep -v -e '^●' -e 'new version of treehouse' -e 'treehouse update' -e '^$' | sed -e "s#$LAB#<LAB>#g" -e "s#$X#<POOLROOT>#g" | cut -c1-700; }
pool() { echo '$ treehouse status --json'; (cd $LAB/proj2 && treehouse status --json 2>/dev/null | jq -c '.[]|{name,status,lease_id,lease_holder}') | clean; }
seed() { # <id> <holder> -> home path
  local h; h=$(cd $LAB/proj2 && treehouse get --lease --json --lease-holder "$2" --no-fetch 2>/dev/null | jq -r .path)
  mkdir -p $h/bin $h/data $h/state $h/config $h/projects; echo '# Firstmate' > $h/AGENTS.md; echo "$1" > $h/.fm-secondmate-home; echo charter > $h/data/charter.md
  printf -- '- %s - disposable second mate (home: %s; scope: lease validation; projects: ; added 2026-10-13)\n' "$1" "$h" >> $LAB/data/secondmates.md
  echo "$h"
}
sm() { # <id> <home>
  echo "\$ bin/fm-spawn.sh $1 <home> 'sleep 600' --secondmate"
  FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 perl -e 'alarm shift; exec @ARGV' 110 bin/fm-spawn.sh "$1" "$2" 'sleep 600' --secondmate > $LAB/out.txt 2> $LAB/err.txt; rc=$?
  cat $LAB/out.txt | clean; echo "stderr:"; cat $LAB/err.txt | clean | sed 's/^/  /'; echo "exit=$rc"
  if [ -f $LAB/state/$1.meta ]; then echo "record $1: $(grep -E '^(worktree|home|treehouse_lease_id|treehouse_lease_holder)=' $LAB/state/$1.meta | tr '\n' ' ' | clean)"; else echo "record $1: none written"; fi
}
echo "target $(git rev-parse --short HEAD); treehouse $(treehouse --version 2>/dev/null | head -1)"
echo "== S7 fresh second mate, bare holder, nonempty pool identity: record must carry the pool identity and holder, stderr has no shell error"
h=$(seed sm-live sm-live); echo "$h" > $LAB/sm-home; pool; sm sm-live "$h"
echo; echo "== S8 fresh second mate, pool holder is <physical-lab-home>:<id> with a nonempty identity (failed in round 1)"
h=$(seed sm-qual "$LAB:sm-qual"); pool; sm sm-qual "$h"
echo; echo "== S9 fresh second mate on a live legacy lease (empty pool lease_id): must refuse with the repair, keep the home leased"
h=$(seed sm-legacy sm-legacy); SF=$(dirname "$(dirname "$h")")/treehouse-state.json; jq --arg p "$h" '(.worktrees[]|select(.path==$p)|.lease_id)=""' "$SF" > "$SF.new" && mv "$SF.new" "$SF"; pool; sm sm-legacy "$h"; pool
echo; echo "== S10 (adversarial) fresh second mate whose home is leased to another holder: must refuse"
h=$(seed sm-stolen someone-else); pool; sm sm-stolen "$h"
echo; echo "== S10b (adversarial) fresh second mate whose holder is qualified with a foreign home: must refuse"
h=$(seed sm-foreign "/somewhere/else:sm-foreign"); sm sm-foreign "$h"
echo; echo "== S11 automatic recovery: endpoint of sm-live is gone, spawn --secondmate again; the receipt must be preserved"
grep -E '^treehouse_lease' $LAB/state/sm-live.meta
tmux kill-window -t primary:fm-sm-live 2>&1 | clean; sm sm-live "$(cat $LAB/sm-home)"
echo "treehouse_lease lines after recovery: $(grep -c '^treehouse_lease_id=' $LAB/state/sm-live.meta) id, $(grep -c '^treehouse_lease_holder=' $LAB/state/sm-live.meta) holder"; pool
echo "tmux windows: $(tmux list-windows -t primary -F '#{window_name}' | tr '\n' ' ')"
