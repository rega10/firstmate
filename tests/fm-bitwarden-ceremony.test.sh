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

run 1 'retirement is refused before any earlier step' mark batch-a retired
! grep -q '^step: retired' "$RECORDS/batch-a.ceremony" || fail 'refused retirement was recorded anyway'
run 1 'verification cannot be recorded before the move' mark batch-a verified
run 1 'approval requires --approved-by' mark batch-a approval

run 0 'preflight records' mark batch-a preflight
run 0 'preflight re-mark is an idempotent no-op' mark batch-a preflight
[ "$(grep -c '^step: preflight' "$RECORDS/batch-a.ceremony")" = 1 ] || fail 'idempotent re-mark duplicated the step line'
run 1 'skipping ahead to moved is refused' mark batch-a moved
run 0 'approval records with approver' mark batch-a approval --approved-by captain
grep -q '^step: approval date=.* approved-by=captain$' "$RECORDS/batch-a.ceremony" || fail 'approval line missing approver'
run 1 'retirement is still refused before verification' mark batch-a retired
run 0 'moved records' mark batch-a moved
run 1 'items cannot be added after the move' add-item batch-a late-item --owner ops --collection team
run 1 'retirement is refused before post-move verification' mark batch-a retired
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

pass 'fm-bitwarden-ceremony behavior'
