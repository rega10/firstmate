#!/bin/bash
# Live driver: real fm-teardown.sh at target 3ba84b4c, real Treehouse 2.3.0 pool, disposable lab home.
# An interrupted retirement is emulated by restoring the pending receipt that teardown writes before its conditional return
# (worktree= emptied, treehouse_retiring_worktree=<slot>); every pool state below is produced by real treehouse commands.
. "$1/env.sh"; . "$1/env2.sh"; cd "$W"
ORIG=$LAB/sm-bare.meta.orig; SLOT=$(sed -n 's/^home=//p' $ORIG); POOL=$(dirname "$(dirname "$SLOT")"); SF=$POOL/treehouse-state.json
clean() { grep -v -e '^●' -e 'new version of treehouse' -e 'treehouse update' -e '^$' | sed -e "s#$LAB#<LAB>#g" -e "s#$X#<POOLROOT>#g" | cut -c1-700; }
poolraw() { (cd $LAB/proj2 && treehouse status --json 2>/dev/null | jq -c '.[]|{name,status,lease_id,lease_holder}'); }
pool() { echo '$ treehouse status --json'; poolraw | clean; }
pending() { awk -F= '$1 == "worktree" { print "worktree="; next } { print }' $ORIG > $LAB/state/sm-bare.meta; printf 'treehouse_retiring_worktree=%s\n' "$SLOT" >> $LAB/state/sm-bare.meta
  echo "pending receipt sm-bare: $(grep -E '^(worktree|treehouse_)' $LAB/state/sm-bare.meta | tr '\n' ' ' | clean)"; }
td() { local before after; before=$(poolraw)
  echo "\$ bin/fm-teardown.sh sm-bare $*"; perl -e 'alarm shift; exec @ARGV' 110 bin/fm-teardown.sh sm-bare "$@" 2>&1 | clean; echo "exit=${PIPESTATUS[0]}"
  after=$(poolraw); [ "$before" = "$after" ] && echo "pool status: unchanged by this call" || echo "pool status: CHANGED by this call"
  [ -f $LAB/state/sm-bare.meta ] && echo "receipt sm-bare: still present" || echo "receipt sm-bare: removed"; }
echo "== T1 retry after the slot was released (the real teardown already returned and removed slot 2)"
pool; pending; td
echo; echo "== T2 (adversarial) retry while the same slot path is leased again under a different durable identity: must refuse"
p=; for i in 1 2 3; do p=$(cd $LAB/proj2 && treehouse get --lease --json --lease-holder successor-task --no-fetch 2>/dev/null | jq -r .path); [ "$p" = "$SLOT" ] && break; done
echo "successor lease path equals the retired slot path: $([ "$p" = "$SLOT" ] && echo yes || echo no)"; echo keep > "$SLOT/successor-proof.txt"
pool; pending; td; td --force; echo "successor file: $(cat "$SLOT/successor-proof.txt" 2>&1)"
echo; echo "== T3 (adversarial) retry while the slot is still leased with an empty identity (legacy lease): must refuse"
jq --arg p "$SLOT" '(.worktrees[]|select(.path==$p)|.lease_id)=""' "$SF" > "$SF.new" && mv "$SF.new" "$SF"; pool; td; echo "successor file: $(cat "$SLOT/successor-proof.txt" 2>&1)"
echo; echo "== T4 retry while an ordinary treehouse get (no durable identity) now occupies the slot: finish cleanup, do not touch the allocation"
(cd $LAB/proj2 && treehouse return --force "$SLOT" 2>&1 | clean)
printf '#!/bin/sh\nexec sleep 120\n' > $LAB/hold-shell; chmod +x $LAB/hold-shell
(cd $LAB/proj2 && SHELL=$LAB/hold-shell treehouse get --no-fetch >/dev/null 2>&1 &) ; sleep 3
pool; inuse=$(cd $LAB/proj2 && treehouse status --json 2>/dev/null | jq -r '.[]|select(.status=="in-use")|.path'); echo "ordinary allocation path equals the retired slot path: $([ "$inuse" = "$SLOT" ] && echo yes || echo no)"
echo keep > "$SLOT/successor-proof.txt"; pending; td; echo "successor file: $(cat "$SLOT/successor-proof.txt" 2>&1)"; pgrep -f "sleep 120" >/dev/null && echo "ordinary holder process: still running"
pkill -f "sleep 120"
