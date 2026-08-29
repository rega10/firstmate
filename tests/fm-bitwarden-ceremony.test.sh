#!/usr/bin/env bash
# Behavior tests for fm-bitwarden-ceremony.sh, the no-secret structure/status
# validator for Bitwarden migration ceremony records.
#
# The safety contract under test: the tool refuses secret-shaped input without
# echoing or persisting it, refuses malicious batch ids that could escape the
# record directory, enforces the strict step order that keeps old-custody
# retirement behind post-move verification and captain approval, stays
# idempotent so an interrupted ceremony can be replayed, and reports a corrupt
# record by line number only, never by content.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bitwarden-ceremony-tests)
CEREMONY="$ROOT/bin/fm-bitwarden-ceremony.sh"
export FM_DATA_OVERRIDE="$TMP_ROOT/data"
RECORDS="$FM_DATA_OVERRIDE/bitwarden"

run() {  # <expected-exit> <label> <args...>
  local expected=$1 label=$2 rc=0
  shift 2
  OUT=$("$CEREMONY" "$@" 2>&1) || rc=$?
  [ "$rc" -eq "$expected" ] || fail "$label: expected exit $expected, got $rc"$'\n'"--- output ---"$'\n'"$OUT"
}

# --- init and malicious batch ids -------------------------------------------

run 0 'init creates a record' init batch-a
[ -f "$RECORDS/batch-a.ceremony" ] || fail 'init did not create the record file'

run 0 'init is an idempotent no-op' init batch-a
assert_contains "$OUT" 'already initialized' 'repeat init reports no-op'

# shellcheck disable=SC2016  # the literal '$(touch x)' string is the attack input
for bad in '../evil' 'a/b' 'a b' 'UPPER' '-lead' '' '$(touch x)'; do
  rc=0
  OUT=$("$CEREMONY" init "$bad" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "malicious batch id was accepted: '$bad'"
done
# A secret-shaped batch id faces the same refusals as a label: it is persisted
# as a filename and echoed in progress messages.
SECRET_BATCH_IDS=(
  'glpat-xxxxxxxxxxxxxxxxxxxx'
  'sk-proj-abcdef'
  'xoxb-1234-abcd'
  'deadbeefdeadbeefdeadbeefdeadbeef'
)
for secret in "${SECRET_BATCH_IDS[@]}"; do
  for cmd in init status check; do
    rc=0
    OUT=$("$CEREMONY" "$cmd" "$secret" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "secret-shaped batch id was accepted by $cmd: shape $(printf '%.4s' "$secret")..."
    case $OUT in
      *"$secret"*) fail "$cmd refusal output echoed the secret-shaped batch id" ;;
    esac
    assert_contains "$OUT" 'refused' "$cmd refuses a secret-shaped batch id with a redacted message"
  done
  rc=0
  OUT=$("$CEREMONY" add-item "$secret" item-x --owner ops --collection team 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'secret-shaped batch id was accepted by add-item'
  case $OUT in
    *"$secret"*) fail 'add-item refusal output echoed the secret-shaped batch id' ;;
  esac
  assert_absent "$RECORDS/$secret.ceremony" 'a refused secret-shaped batch id created a record file'
done

# The dispatcher must not log an argument it has not validated.
rc=0
OUT=$("$CEREMONY" 'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'unknown command was accepted'
case $OUT in
  *ghp_*) fail 'unknown-command diagnostic echoed the raw argument' ;;
esac

[ ! -e "$TMP_ROOT/data/evil.ceremony" ] || fail 'traversal id escaped the record dir'
[ ! -e "$RECORDS/x" ] || fail 'metacharacter id executed or created a file'
found=$(find "$TMP_ROOT" -name '*.ceremony' | wc -l | tr -d ' ')
[ "$found" = 1 ] || fail "malicious ids created records (found $found)"

# --- secret-shaped input is refused, redacted, and never persisted ----------

SECRETS=(
  'ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  'github_pat_11ABCDEFG'
  'sk-proj-abcdef'
  'xoxb-1234-abcd'
  'AKIAIOSFODNN7EXAMPLE'
  'glpat-xxxxxxxxxxxxxxxxxxxx'
  'eyJhbGciOiJIUzI1NiJ9.payload.sig'
  'deadbeefdeadbeefdeadbeefdeadbeef'
  'p4ssw0rd with spaces'
  'has"quote'
)
for secret in "${SECRETS[@]}"; do
  rc=0
  OUT=$("$CEREMONY" add-item batch-a item-x --owner "$secret" --collection team 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "secret-shaped owner was accepted: shape $(printf '%.4s' "$secret")..."
  case $OUT in
    *"$secret"*) fail 'refusal output echoed the secret-shaped value' ;;
  esac
  assert_contains "$OUT" 'refused' 'secret-shaped value is refused with a redacted message'
done
overlong=$(printf 'a%.0s' $(seq 1 80))
run 1 'over-long label is refused' add-item batch-a "$overlong" --owner ops --collection team
case $OUT in *"$overlong"*) fail 'refusal output echoed the over-long value' ;; esac
for secret in "${SECRETS[@]}"; do
  ! grep -Fq "$secret" "$RECORDS/batch-a.ceremony" || fail 'a refused secret-shaped value was persisted to the record'
done

# --- ordering, retirement gates, and idempotent replay ----------------------

run 0 'item registers with owner and collection' add-item batch-a prod-db --owner ops-team --collection prod-infra
run 0 'identical add-item is an idempotent no-op' add-item batch-a prod-db --owner ops-team --collection prod-infra
[ "$(grep -c '^item: prod-db ' "$RECORDS/batch-a.ceremony")" = 1 ] || fail 'idempotent add-item duplicated the item line'
run 1 'conflicting re-add of the same label is refused' add-item batch-a prod-db --owner other --collection prod-infra

# A leading-dash label must reach the conflict guard as a pattern, not as
# options to the command that implements it.
run 0 'dash-leading batch initializes' init batch-dash
run 0 'dash-leading item registers' add-item batch-dash -dash-item --owner ops --collection team
assert_not_contains "$OUT" 'grep:' 'dash-leading label was parsed as command options'
run 0 'identical dash-leading re-add is an idempotent no-op' add-item batch-dash -dash-item --owner ops --collection team
run 1 'conflicting dash-leading re-add is refused' add-item batch-dash -dash-item --owner other --collection team
assert_contains "$OUT" 'different owner/collection' 'dash-leading conflict names the reason'
[ "$(grep -Fc -- 'item: -dash-item ' "$RECORDS/batch-dash.ceremony")" = 1 ] || fail 'conflicting dash-leading item was appended anyway'
run 0 'dash-leading batch status counts one item' status batch-dash
assert_contains "$OUT" 'items: 1' 'dash-leading batch reports one registered item'

run 1 'retirement is refused before any earlier step' mark batch-a retired
assert_contains "$OUT" 'before post-move verification' 'retirement refusal names the verification gate, not generic ordering'
! grep -q '^step: retired' "$RECORDS/batch-a.ceremony" || fail 'refused retirement was recorded anyway'
run 1 'verification cannot be recorded before the move' mark batch-a verified
assert_contains "$OUT" "next required step is 'preflight'" 'out-of-turn step names the required step'
run 1 'approval requires --approved-by' mark batch-a approval
assert_contains "$OUT" 'approval requires --approved-by' 'approval refusal names the missing approver, not generic ordering'

run 0 'preflight records' mark batch-a preflight
run 0 'preflight re-mark is an idempotent no-op' mark batch-a preflight
[ "$(grep -c '^step: preflight' "$RECORDS/batch-a.ceremony")" = 1 ] || fail 'idempotent re-mark duplicated the step line'
run 1 'skipping ahead to moved is refused' mark batch-a moved
assert_contains "$OUT" "next required step is 'approval'" 'skip-ahead refusal names the required step'
# With preflight recorded, approval is the next step, so this reaches the
# --approved-by gate rather than the ordering check ahead of it.
run 1 'approval at its own turn still requires --approved-by' mark batch-a approval
assert_contains "$OUT" 'approval requires --approved-by' 'in-turn approval refusal names the missing approver'
! grep -q '^step: approval' "$RECORDS/batch-a.ceremony" || fail 'refused approval was recorded anyway'
run 1 '--approved-by is rejected for a non-approval step' mark batch-a moved --approved-by captain
assert_contains "$OUT" 'only valid for the approval step' 'misplaced --approved-by names the reason'
run 0 'approval records with approver' mark batch-a approval --approved-by captain
grep -q '^step: approval date=.* approved-by=captain$' "$RECORDS/batch-a.ceremony" || fail 'approval line missing approver'
run 1 'retirement is still refused before verification' mark batch-a retired
assert_contains "$OUT" 'before post-move verification' 'retirement refusal after approval still names the verification gate'
run 0 'moved records' mark batch-a moved
run 1 'items cannot be added after the move' add-item batch-a late-item --owner ops --collection team
run 1 'retirement is refused before post-move verification' mark batch-a retired
assert_contains "$OUT" 'before post-move verification' 'post-move retirement refusal names the verification gate'
! grep -q '^step: retired' "$RECORDS/batch-a.ceremony" || fail 'refused retirement was recorded after the move'
run 0 'verified records' mark batch-a verified
run 0 'retirement is allowed only after verification and approval' mark batch-a retired
run 0 'status renders the complete batch' status batch-a
assert_contains "$OUT" 'next: complete' 'complete batch reports next: complete'

# A batch with no registered items can never be marked moved.
run 0 'empty batch initializes' init batch-empty
run 0 'empty batch preflight' mark batch-empty preflight
run 0 'empty batch approval' mark batch-empty approval --approved-by captain
run 1 'moved is refused with no registered items' mark batch-empty moved
assert_contains "$OUT" 'no registered items' 'itemless move refusal names the reason'

# --- partial ceremony recovery ----------------------------------------------

run 0 'partial batch initializes' init batch-part
run 0 'partial batch item' add-item batch-part svc-token --owner ci-owner --collection ci
run 0 'partial batch preflight' mark batch-part preflight
run 0 'check reports the next required step on a partial record' check batch-part
assert_contains "$OUT" 'next: approval' 'check names the resume point'
run 0 'replaying the completed step still succeeds' mark batch-part preflight
run 0 'ceremony resumes from the reported step' mark batch-part approval --approved-by captain
run 0 'check advances with the record' check batch-part
assert_contains "$OUT" 'next: moved' 'check reflects recorded progress'

# --- tampered step histories are refused by every reader --------------------

# The record file is this tool's own append-only text contract (see its --help),
# so a hand-edited history is written here and then read back through the
# commands, exactly as a tampered record would reach an auditor.
write_record() {  # <batch> <step-lines...>
  local batch=$1
  shift
  {
    printf 'fm-bitwarden-ceremony v1\n'
    printf 'batch: %s\n' "$batch"
    printf 'created: 2026-01-01\n'
    printf 'item: prod-db owner=ops-team collection=prod-infra\n'
    printf '%s\n' "$@"
  } > "$RECORDS/$batch.ceremony"
}

# retired written before approval and verified: the exact history the ceremony
# exists to make impossible.
write_record tamper-order \
  'step: preflight date=2026-01-01' \
  'step: moved date=2026-01-01' \
  'step: retired date=2026-01-01'
for cmd in check status; do
  run 1 "$cmd refuses a record whose steps are out of order" "$cmd" tamper-order
  assert_contains "$OUT" 'corrupt at line 6' 'out-of-order record is reported by line number'
  assert_contains "$OUT" "expected 'approval' at this point" 'out-of-order refusal names the expected transition'
  assert_not_contains "$OUT" 'step: moved' 'out-of-order refusal echoed record content'
  assert_contains "$OUT" 'last valid prefix' 'refusal explains the recovery path'
  assert_not_contains "$OUT" 'next:' "$cmd reported progress from a tampered record"
done
run 1 'mark refuses to append to an out-of-order record' mark tamper-order approval --approved-by captain
[ "$(grep -c '^step: ' "$RECORDS/tamper-order.ceremony")" = 3 ] || fail 'a refused record was appended to'

# A skipped prerequisite is refused at the line that skips it.
write_record tamper-skip \
  'step: preflight date=2026-01-01' \
  'step: approval date=2026-01-01 approved-by=captain' \
  'step: verified date=2026-01-01'
run 1 'check refuses a record with a skipped step' check tamper-skip
assert_contains "$OUT" "expected 'moved' at this point" 'skipped-step refusal names the expected transition'

# A repeated step is refused even though every name is individually valid.
write_record tamper-dup \
  'step: preflight date=2026-01-01' \
  'step: preflight date=2026-01-01'
run 1 'check refuses a duplicated step' check tamper-dup
assert_contains "$OUT" 'corrupt at line 6' 'duplicate step is reported by line number'

# Nothing may follow a complete ceremony.
write_record tamper-trailing \
  'step: preflight date=2026-01-01' \
  'step: approval date=2026-01-01 approved-by=captain' \
  'step: moved date=2026-01-01' \
  'step: verified date=2026-01-01' \
  'step: retired date=2026-01-01' \
  'step: retired date=2026-01-01'
run 1 'check refuses a step recorded after completion' check tamper-trailing
assert_contains "$OUT" 'already complete' 'trailing step refusal names the reason'

# An approval line with no approver is not a recorded approval.
write_record tamper-approver \
  'step: preflight date=2026-01-01' \
  'step: approval date=2026-01-01 approved-by=' \
  'step: moved date=2026-01-01' \
  'step: verified date=2026-01-01'
run 1 'check refuses an approval with an empty approver' check tamper-approver
assert_contains "$OUT" 'empty approved-by' 'empty-approver refusal names the reason'
run 1 'mark refuses to append to a record whose approval has no approver' mark tamper-approver retired
assert_contains "$OUT" 'empty approved-by' 'the empty-approver record is refused when read, before any gate on the step itself'
! grep -q '^step: retired' "$RECORDS/tamper-approver.ceremony" || fail 'retirement was recorded against an empty approver'

# A hand-edited duplicate item line would double-count the auditable evidence.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: tamper-item\n'
  printf 'created: 2026-01-01\n'
  printf 'item: prod-db owner=ops-team collection=prod-infra\n'
  printf 'item: prod-db owner=other collection=prod-infra\n'
} > "$RECORDS/tamper-item.ceremony"
run 1 'status refuses a record with a duplicated item label' status tamper-item
assert_contains "$OUT" 'corrupt at line 5' 'duplicate item is reported by line number'
assert_not_contains "$OUT" 'items:' 'status counted items from a tampered record'

# A record that is a valid prefix - the shape a corrected record is restored to
# - stays fully usable, so the validation never blocks legitimate recovery.
write_record tamper-fixed \
  'step: preflight date=2026-01-01' \
  'step: approval date=2026-01-01 approved-by=captain'
run 0 'a corrected record resumes from its last valid prefix' check tamper-fixed
assert_contains "$OUT" 'next: moved' 'corrected record reports the true resume point'
run 0 'the corrected record accepts the next real step' mark tamper-fixed moved

# Refusals never echo secret-shaped content from the record itself.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: tamper-secret\n'
  printf 'created: 2026-01-01\n'
  printf 'step: preflight date=2026-01-01\n'
  printf 'step: retired date=2026-01-01 note=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'
} > "$RECORDS/tamper-secret.ceremony"
run 1 'a tampered record holding secret material is refused' check tamper-secret
assert_not_contains "$OUT" 'ghp_' 'refusal echoed secret-shaped record content'

# --- a record is evidence for exactly one batch ------------------------------

# Completing a batch and copying its record to another batch id is an ordinary
# operator slip; the copy must not be certified as the second batch's evidence.
run 0 'source batch for the copy initializes' init copy-src
run 0 'source batch item' add-item copy-src prod-db --owner ops-team --collection prod-infra
run 0 'source batch preflight' mark copy-src preflight
run 0 'source batch approval' mark copy-src approval --approved-by captain
run 0 'source batch moved' mark copy-src moved
run 0 'source batch verified' mark copy-src verified
run 0 'source batch retired' mark copy-src retired
cp "$RECORDS/copy-src.ceremony" "$RECORDS/copy-dst.ceremony"
for cmd in init check status; do
  run 1 "$cmd refuses a record copied from another batch" "$cmd" copy-dst
  assert_contains "$OUT" 'names a different batch' 'wrong-batch refusal names the reason'
  assert_contains "$OUT" 'corrupt at line 2' 'wrong-batch record is reported by line number'
  assert_not_contains "$OUT" 'copy-src' 'wrong-batch refusal echoed the record content'
  assert_not_contains "$OUT" 'next:' "$cmd reported progress from another batch's record"
done
run 1 'mark refuses a record copied from another batch' mark copy-dst preflight
[ "$(grep -c '^step: ' "$RECORDS/copy-dst.ceremony")" = 5 ] || fail 'a wrong-batch record was appended to'
run 0 'the source batch is unaffected' check copy-src
assert_contains "$OUT" 'next: complete' 'the original record still reports its own completion'

# Conflicting or repeated headers leave the record ambiguous about what it is.
printf 'fm-bitwarden-ceremony v1\nbatch: hdr-dup\nbatch: hdr-dup\ncreated: 2026-01-01\n' > "$RECORDS/hdr-dup.ceremony"
run 1 'check refuses a repeated batch header' check hdr-dup
assert_contains "$OUT" 'corrupt at line 3' 'repeated batch header is reported by line number'
printf 'fm-bitwarden-ceremony v1\nbatch: hdr-created\ncreated: 2026-01-01\ncreated: 2030-01-01\n' > "$RECORDS/hdr-created.ceremony"
run 1 'check refuses a repeated created header' check hdr-created
assert_contains "$OUT" 'corrupt at line 4' 'repeated created header is reported by line number'
printf 'fm-bitwarden-ceremony v1\ncreated: 2026-01-01\nitem: db owner=ops collection=prod\n' > "$RECORDS/hdr-none.ceremony"
run 1 'check refuses a record with no batch header' check hdr-none
assert_contains "$OUT" 'no batch header' 'missing batch header names the reason'
printf 'fm-bitwarden-ceremony v1\nbatch: hdr-late\ncreated: 2026-01-01\nitem: db owner=ops collection=prod\nbatch: hdr-late\n' > "$RECORDS/hdr-late.ceremony"
run 1 'check refuses a header line after the record body' check hdr-late
assert_contains "$OUT" 'corrupt at line 5' 'misplaced header is reported by line number'

# --- items may not be registered after the credential has moved --------------

# add-item refuses this on the write path; a hand-edited record must not make
# a post-move registration look like a pre-move ownership target.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: item-late\n'
  printf 'created: 2026-01-01\n'
  printf 'item: prod-db owner=ops-team collection=prod-infra\n'
  printf 'step: preflight date=2026-01-01\n'
  printf 'step: approval date=2026-01-01 approved-by=captain\n'
  printf 'step: moved date=2026-01-01\n'
  printf 'item: added-after-move owner=ops collection=prod-infra\n'
} > "$RECORDS/item-late.ceremony"
for cmd in check status; do
  run 1 "$cmd refuses an item registered after the move" "$cmd" item-late
  assert_contains "$OUT" 'corrupt at line 8' 'post-move item is reported by line number'
  assert_contains "$OUT" 'after the batch was marked moved' 'post-move item refusal names the reason'
  assert_not_contains "$OUT" 'added-after-move' 'post-move refusal echoed record content'
done
run 1 'mark refuses to advance a record with a post-move item' mark item-late verified
! grep -q '^step: verified' "$RECORDS/item-late.ceremony" || fail 'a record with a post-move item was appended to'

# Registering an item after an earlier step is still legitimate, so the rule
# must not break the flow add-item actually permits.
run 0 'batch for a mid-ceremony item initializes' init item-mid
run 0 'mid-ceremony preflight' mark item-mid preflight
run 0 'an item may still be registered before the move' add-item item-mid late-but-legal --owner ops --collection prod-infra
run 0 'the record with a post-preflight item stays readable' status item-mid
assert_contains "$OUT" 'items: 1' 'a pre-move item registered after preflight is counted'

# --- a step argument is matched as a whole word ------------------------------

run 1 'a multi-word step argument is not a step' mark item-mid 'preflight approval'
assert_contains "$OUT" 'unknown step' 'a run of step names is refused as a step name'

# --- corrupt records are reported by line number, content withheld ----------

printf 'password=hunter2-super-secret\n' >> "$RECORDS/batch-part.ceremony"
run 1 'corrupt record fails check' check batch-part
assert_contains "$OUT" 'corrupt at line 7' 'corruption is reported by line number'
case $OUT in
  *hunter2*) fail 'corrupt-line diagnostic echoed the line content' ;;
esac
run 1 'corrupt record refuses further marks' mark batch-part moved

# A record with a foreign first line is rejected as not-a-ceremony-record.
printf 'something else\n' > "$RECORDS/batch-alien.ceremony"
run 1 'foreign file is not treated as a ceremony record' check batch-alien
run 1 'missing record demands init' check batch-none
assert_contains "$OUT" 'run init first' 'missing record points at init'

# --- --help publishes the record-format contract, not shell source ----------

run 0 'help renders the header contract' --help
assert_contains "$OUT" 'Record format (v1, line-based, append-only):' 'help publishes the record format'
assert_contains "$OUT" 'preflight -> approval -> moved -> verified -> retired' 'help publishes the ordered steps'
assert_not_contains "$OUT" 'set -eu' 'help leaked shell source past the header'
[ "$(printf '%s\n' "$OUT" | tail -n 1)" = 'which is the recovery entry point after an interruption.' ] || fail 'help output does not end with the final header sentence'

pass 'fm-bitwarden-ceremony behavior'
