#!/bin/bash
# Live driver: real fm-spawn.sh and fm-teardown.sh at target 51dbc3dd (round 2), real Treehouse 2.3.0 pool, real tmux, disposable lab home.
# An interrupted retirement is emulated by writing the pending receipt shape that teardown writes before its conditional return
# (worktree= emptied, treehouse_retiring_worktree=<slot>); every pool state below is produced by real treehouse commands
# except the empty lease_id of T3, which Treehouse 2.3.0 cannot produce and is edited into the disposable pool state.
. "$1/env.sh"; cd "$W"
clean() { grep -v -e '^●' -e 'new version of treehouse' -e 'treehouse update' -e '^$' | sed -e "s#$LAB#<LAB>#g" -e "s#$X#<POOLROOT>#g" | cut -c1-700; }
poolraw() { (cd $LAB/proj2 && treehouse status --json 2>/dev/null | jq -c '.[]|{name,status,lease_id,lease_holder}'); }
pool() { echo '$ treehouse status --json'; poolraw | clean; }
ID=sm-retry
R=$(cd $LAB/proj2 && treehouse get --lease --json --lease-holder $ID --no-fetch 2>/dev/null); SLOT=$(echo "$R" | jq -r .path); LID=$(echo "$R" | jq -r .lease_id)
POOL=$(dirname "$(dirname "$SLOT")"); SF=$POOL/treehouse-state.json
mkdir -p $SLOT/bin $SLOT/data $SLOT/state $SLOT/config $SLOT/projects; echo '# Firstmate' > $SLOT/AGENTS.md; echo $ID > $SLOT/.fm-secondmate-home; echo charter > $SLOT/data/charter.md
printf -- '- %s - disposable second mate (home: %s; scope: lease validation; projects: ; added 2026-10-13)\n' $ID "$SLOT" >> $LAB/data/secondmates.md
echo "== setup: launch second mate $ID on its seeded leased home"
FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 perl -e 'alarm shift; exec @ARGV' 110 bin/fm-spawn.sh $ID "$SLOT" 'sleep 600' --secondmate 2>&1 | clean
cp $LAB/state/$ID.meta $LAB/$ID.meta.orig; echo "receipt $ID: $(grep -E '^(worktree|treehouse_)' $LAB/state/$ID.meta | tr '\n' ' ' | clean)"
pending() { awk -F= '$1 == "worktree" { print "worktree="; next } { print }' $LAB/$ID.meta.orig > $LAB/state/$ID.meta; printf 'treehouse_retiring_worktree=%s\n' "$SLOT" >> $LAB/state/$ID.meta
  echo "pending receipt $ID: $(grep -E '^(worktree|treehouse_)' $LAB/state/$ID.meta | tr '\n' ' ' | clean)"; }
td() { local before after; before=$(poolraw)
  echo "\$ bin/fm-teardown.sh $ID $*"; perl -e 'alarm shift; exec @ARGV' 110 bin/fm-teardown.sh $ID "$@" 2>&1 | clean; echo "exit=${PIPESTATUS[0]}"
  after=$(poolraw); [ "$before" = "$after" ] && echo "pool status: unchanged by this call" || { echo "pool status: CHANGED by this call"; echo "$after" | clean; }
  [ -f $LAB/state/$ID.meta ] && echo "receipt $ID: still present" || echo "receipt $ID: removed"
  echo "slot directory: $([ -d "$SLOT" ] && echo present || echo MISSING); marker file: $(cat "$SLOT/keep-proof.txt" 2>&1 | clean)"; }
echo keep > "$SLOT/keep-proof.txt"
echo; echo "== T2 (adversarial, run first while the lease is live) pending receipt names a different identity than the still-leased slot: must refuse"
pending; sed -i '' "s/^treehouse_lease_id=.*/treehouse_lease_id=0123456789abcdef0123456789abcdef/" $LAB/state/$ID.meta; pool; td; td --force
echo; echo "== T3 (adversarial) slot still leased with an empty identity (legacy lease), receipt carries an identity: must refuse"
pending; jq --arg p "$SLOT" '(.worktrees[]|select(.path==$p)|.lease_id)=""' "$SF" > "$SF.new" && mv "$SF.new" "$SF"; pool; td
jq --arg p "$SLOT" --arg l "$LID" '(.worktrees[]|select(.path==$p)|.lease_id)=$l' "$SF" > "$SF.new" && mv "$SF.new" "$SF"
echo; echo "== T1 interruption right after the conditional return: slot released, receipt still pending; retry must finish cleanup only"
pending; echo "\$ treehouse return --force --if-lease-id $LID <slot>"; (cd $LAB/proj2 && treehouse return --force --if-lease-id "$LID" "$SLOT" 2>&1 | clean); echo keep > "$SLOT/keep-proof.txt"; pool; td
echo; echo "== T4 retry while an ordinary treehouse get (no durable identity) occupies the released slot: finish cleanup, do not touch the allocation"
printf '#!/bin/sh\nexec sleep 120\n' > $LAB/hold-shell; chmod +x $LAB/hold-shell
for i in 1 2 3 4; do (cd $LAB/proj2 && SHELL=$LAB/hold-shell treehouse get --no-fetch >/dev/null 2>&1 &); sleep 2
  cd $LAB/proj2; treehouse status --json 2>/dev/null | jq -e --arg p "$SLOT" '.[]|select(.path==$p and .status=="in-use")' >/dev/null && { cd $W; break; }; cd $W; done
pool; echo "ordinary allocation occupies the retired slot path: $(cd $LAB/proj2 && treehouse status --json 2>/dev/null | jq -r --arg p "$SLOT" '.[]|select(.path==$p)|.status')"
[ -d "$SLOT" ] && echo keep > "$SLOT/keep-proof.txt"; pending; td; echo "ordinary holder processes still running: $(pgrep -f 'sleep 120' | wc -l | tr -d ' ')"
pkill -f "sleep 120"
