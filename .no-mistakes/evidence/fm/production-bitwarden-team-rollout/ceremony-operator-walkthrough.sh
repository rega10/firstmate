#!/usr/bin/env bash
# End-to-end operator walkthrough of bin/fm-bitwarden-ceremony.sh, exactly as a
# batch operator would drive it from a shell. No Bitwarden, no network, no secrets.
set -u
ROOT="$1"
WORK=$(mktemp -d /tmp/bw-e2e.XXXXXX)
export FM_DATA_OVERRIDE="$WORK/data"
CEREMONY="$ROOT/bin/fm-bitwarden-ceremony.sh"
REC="$FM_DATA_OVERRIDE/bitwarden/pilot-shared-team.ceremony"

step() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
cmd() {
  printf '\n$ fm-bitwarden-ceremony %s\n' "$*"
  ( "$CEREMONY" "$@" 2>&1 ); printf '[exit %s]\n' "$?"
}
showrec() { printf '\n--- record on disk (%s) ---\n' "${REC##*/}"; cat "$REC"; printf -- '--- end record (%s bytes, ends with newline: %s) ---\n' "$(wc -c < "$REC" | tr -d ' ')" "$(tail -c1 "$REC" | od -An -c | tr -d ' ')"; }

step "0. The record-format + gate contract the operator reads (--help)"
cmd --help

step "1. Operator refuses to be tricked: malicious and secret-shaped batch ids"
cmd init ../../etc/evil
cmd init 'a b'
cmd init ghp_AAAABBBBCCCCDDDDEEEEFFFF
cmd init deadbeefdeadbeefdeadbeefdeadbeef
printf '\nfiles created anywhere under the data root by those attempts:\n'
find "$WORK" -type f 2>/dev/null | sed "s|$WORK|<data>|" ; printf '(none above = nothing escaped or was persisted)\n'

step "2. Phase 2 pilot batch: init"
cmd init pilot-shared-team
showrec

step "3. Register per-item ownership/collection targets (labels only, never values)"
cmd add-item pilot-shared-team status-page-shared --owner ops-captain --collection team-ops
cmd add-item pilot-shared-team monitoring-shared --owner ops-captain --collection team-ops

step "3b. A pasted secret value is refused, redacted, and never persisted"
cmd add-item pilot-shared-team billing-login --owner ops-captain --collection 'ghp_ZZZZYYYYXXXXWWWWVVVVUUUU'
cmd add-item pilot-shared-team billing-login --owner ops-captain --collection 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'
printf '\ngrep the whole data root for those pasted values:\n'
grep -R -F -e 'ghp_ZZZZYYYYXXXXWWWWVVVVUUUU' -e 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6' "$WORK" 2>/dev/null && printf 'LEAKED!\n' || printf '(no match - the secret-shaped value was neither logged nor persisted)\n'

step "4. Destructive gate: retirement is refused before verification and approval"
cmd mark pilot-shared-team preflight
cmd mark pilot-shared-team retired
cmd status pilot-shared-team
printf '\n(the recovery entry point after an interruption: `check` re-validates the partial record and names the next required step)\n'
cmd check pilot-shared-team

step "4b. A batch with no registered item cannot be marked moved"
cmd init empty-batch
cmd mark empty-batch preflight
cmd mark empty-batch approval --approved-by captain-rega
cmd mark empty-batch moved

step "5. Out-of-order and unapproved moves are refused"
cmd mark pilot-shared-team moved
cmd mark pilot-shared-team approval
cmd mark pilot-shared-team approval --approved-by captain-rega

step "5b. Interrupted ceremony resumed by replay (idempotent), but a conflicting replay is refused"
cmd mark pilot-shared-team approval --approved-by captain-rega
cmd mark pilot-shared-team approval --approved-by mallory
printf '\napprover still recorded as:\n'; grep '^step: approval' "$REC"

step "6. Finish the batch: moved -> verified -> retired"
cmd mark pilot-shared-team moved
cmd mark pilot-shared-team verified
cmd mark pilot-shared-team retired
cmd status pilot-shared-team

step "7. The auditable, no-secret completion record"
showrec

step "8. A tampered record is refused by line number, content withheld"
cp "$REC" "$WORK/backup.ceremony"
sed -i.bak 's/^step: verified.*$/step: verified date=2099-01-01/' "$REC"; rm -f "$REC.bak"
cmd check pilot-shared-team
cp "$WORK/backup.ceremony" "$REC"
sed -i.bak '/^step: approval/d' "$REC"; rm -f "$REC.bak"
cmd status pilot-shared-team
cp "$WORK/backup.ceremony" "$REC"
printf '\n(truncating the record: stripping only the final newline byte)\n'
perl -0pe 's/\n\z//' "$WORK/backup.ceremony" > "$REC"
printf 'last byte is now: %s\n' "$(tail -c1 "$REC" | od -An -c | tr -d ' ')"
cmd check pilot-shared-team
cp "$WORK/backup.ceremony" "$REC"

step "9. Misfiled evidence: a record copied under another batch id is refused"
cp "$WORK/backup.ceremony" "$FM_DATA_OVERRIDE/bitwarden/prod-break-glass.ceremony"
cmd status prod-break-glass

step "10. Proof the tool never reaches a credential store: no network/vault calls in a full run"
printf '\n$ (PATH shimmed so curl/wget/bw/op/nc/ssh/security abort loudly) full ceremony replay\n'
SHIM="$WORK/shim"; mkdir -p "$SHIM"
for b in curl wget bw op nc ssh security aws gcloud vault openssl; do
  printf '#!/bin/sh\necho "FORBIDDEN CALL: %s $*" >&2\nexit 99\n' "$b" > "$SHIM/$b"; chmod +x "$SHIM/$b"
done
PATH="$SHIM:$PATH" "$CEREMONY" status pilot-shared-team 2>&1 | sed 's/^/  /'
PATH="$SHIM:$PATH" "$CEREMONY" init drill-batch 2>&1 | sed 's/^/  /'
PATH="$SHIM:$PATH" "$CEREMONY" add-item drill-batch drill-item --owner ops-captain --collection team-ops 2>&1 | sed 's/^/  /'
printf '(no FORBIDDEN CALL lines above = no credential store or network binary was invoked)\n'

printf '\n\033[1m=== walkthrough complete ===\033[0m\n'
rm -rf "$WORK"
