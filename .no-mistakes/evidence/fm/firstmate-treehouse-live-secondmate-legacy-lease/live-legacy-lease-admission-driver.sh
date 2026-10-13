#!/bin/bash
# Live driver: real fm-spawn.sh (base e6fe72ee and target 3ba84b4c), real Treehouse 2.3.0, real tmux, disposable lab home.
. "$1/env.sh"; cd "$W"
POOL=$LAB/pool/.treehouse/proj-a4da11; SLOT=$POOL/1/proj; SF=$POOL/treehouse-state.json; META=$LAB/state/catalog-sm-k2.meta
clean() { grep -v -e '^●' -e 'new version of treehouse' -e 'treehouse update' -e '^$' | sed "s#$LAB#<LAB>#g" | cut -c1-600; }
pool() { echo '$ treehouse status --json  (pool as Treehouse 2.3.0 reports it)'; (cd $LAB/proj && treehouse status --json 2>/dev/null | jq -c '.[]|{name,status,lease_id,lease_holder}') | clean; }
holder() { jq --arg p "$SLOT" --arg h "$1" '(.worktrees[]|select(.path==$p)|.lease_holder)=$h' "$SF" > "$SF.new" && mv "$SF.new" "$SF"; }
spawn() { # <script> <id>
  mkdir -p $LAB/data/$2; cp $LAB/data/probe-base/brief.md $LAB/data/$2/brief.md
  echo "\$ $1 $2 <LAB>/proj --scout 'sleep 600'"
  perl -e 'alarm shift; exec @ARGV' 110 "$1" "$2" "$LAB/proj" --scout 'sleep 600' 2>&1 | clean; echo "exit=${PIPESTATUS[0]}"
  if [ -f $LAB/state/$2.meta ]; then echo "record $2: $(grep -E '^(worktree|treehouse_lease_id|treehouse_lease_holder)=' $LAB/state/$2.meta | tr '\n' ' ' | clean)"; else echo "record $2: none written"; fi
}
BASE=.live-lease-validation/base-code/bin/fm-spawn.sh; NEW=bin/fm-spawn.sh
echo "treehouse $(treehouse --version 2>/dev/null | head -1); target $(git rev-parse --short HEAD); base script is a byte copy of e6fe72ee:bin/fm-spawn.sh"
echo "legacy record (no lease fields), md5 $(md5 -q $META):"; sed "s#$LAB#<LAB>#g" $META
echo; echo "== S1 base commit: live legacy second mate (bare holder, empty lease_id) blocks the pool"
holder catalog-sm-k2; pool; spawn $BASE s1-base
echo; echo "== S2 target commit: same state, a new spawn is admitted into another slot"
pool; spawn $NEW s2-bare
echo; echo "== S3 target commit: holder recorded as <physical-record-home>:<task-id> is admitted"
holder "$LAB:catalog-sm-k2"; pool; spawn $NEW s3-qualified
echo; echo "== S4 target commit (adversarial): slot leased to a different holder still blocks the pool"
holder some-other-task; pool; spawn $NEW s4-other-holder
echo; echo "== S5 target commit (adversarial): holder qualified with a different home still blocks the pool"
holder "/somewhere/else:catalog-sm-k2"; pool; spawn $NEW s5-foreign-home
echo; echo "== S6 target commit (adversarial): legacy record whose slot is no longer leased still blocks the pool"
holder catalog-sm-k2; echo '$ treehouse return --force <slot 1>'; (cd $LAB/proj && treehouse return --force "$SLOT" 2>&1 | clean); pool; spawn $NEW s6-unleased
echo; echo "== after all scenarios: legacy record md5 $(md5 -q $META) (unchanged when equal to the value at the top)"; pool
echo "state records: $(ls $LAB/state | grep meta | tr '\n' ' ')"
