#!/bin/bash
# Round 2 addendum, target 51dbc3dd: real fm-teardown.sh, real Treehouse 2.3.0 pool, disposable lab home.
# The pending receipt shape (worktree= emptied, treehouse_retiring_worktree=<slot>) is restored by hand to emulate an interrupted retirement.
. "$1/env.sh"; cd "$W"
clean() { grep -v -e '^●' -e 'new version of treehouse' -e 'treehouse update' -e '^$' | sed -e "s#$LAB#<LAB>#g" -e "s#$X#<POOLROOT>#g" | cut -c1-700; }
poolraw() { (cd $LAB/proj2 && treehouse status --json 2>/dev/null | jq -c '.[]|{name,status,lease_id,lease_holder}'); }
pool() { echo '$ treehouse status --json'; poolraw | clean; }
td() { local id=$1; shift; local before after; before=$(poolraw)
  echo "\$ bin/fm-teardown.sh $id $*"; perl -e 'alarm shift; exec @ARGV' 110 bin/fm-teardown.sh $id "$@" 2>&1 | clean; echo "exit=${PIPESTATUS[0]}"
  after=$(poolraw); [ "$before" = "$after" ] && echo "pool status: unchanged by this call" || { echo "pool status: CHANGED by this call"; echo "$after" | clean; }
  [ -f $LAB/state/$id.meta ] && echo "receipt $id: still present" || echo "receipt $id: removed"; }
pending() { awk -F= '$1 == "worktree" { print "worktree="; next } { print }' $2 > $LAB/state/$1.meta; printf 'treehouse_retiring_worktree=%s\n' "$3" >> $LAB/state/$1.meta
  echo "pending receipt $1: $(grep -E '^(worktree|treehouse_)' $LAB/state/$1.meta | tr '\n' ' ' | clean)"; }
echo "== T4b retry while an ordinary treehouse get (no durable identity) occupies the released slot of sm-retry"
SLOT=$(sed -n 's/^home=//p' $LAB/sm-retry.meta.orig); rm -f "$SLOT/keep-proof.txt"
printf '#!/bin/sh\nexec sleep 120\n' > $LAB/hold-shell; chmod +x $LAB/hold-shell
for i in 1 2 3 4 5 6; do (cd $LAB/proj2 && SHELL=$LAB/hold-shell treehouse get --no-fetch >/dev/null 2>&1 &); sleep 2
  st=$(cd $LAB/proj2 && treehouse status --json 2>/dev/null | jq -r --arg p "$SLOT" '.[]|select(.path==$p)|.status'); [ "$st" = in-use ] && break; done
pool; echo "status of the retired slot path: $st"; echo occupant > "$SLOT/occupant-proof.txt"
pending sm-retry $LAB/sm-retry.meta.orig "$SLOT"; td sm-retry
echo "occupant file: $(cat "$SLOT/occupant-proof.txt" 2>&1); ordinary holder processes still running: $(pgrep -f 'sleep 120' | wc -l | tr -d ' ')"
pkill -f "sleep 120"
echo; echo "== T5 real complete retirement of second mate sm-qual (qualified holder receipt)"
cp $LAB/state/sm-qual.meta $LAB/sm-qual.meta.orig; QSLOT=$(sed -n 's/^home=//p' $LAB/sm-qual.meta.orig); pool; td sm-qual --force
echo "home directory: $([ -d "$QSLOT" ] && echo present || echo removed)"
echo; echo "== T6 (open round 1 finding F2) retry after the retiring home directory was removed, receipt still pending"
pending sm-qual $LAB/sm-qual.meta.orig "$QSLOT"; td sm-qual; td sm-qual --force
