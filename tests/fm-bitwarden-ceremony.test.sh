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
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CEREMONY="$ROOT/bin/fm-bitwarden-ceremony.sh"
export FM_DATA_OVERRIDE="$TMP_ROOT/data"
RECORDS="$FM_DATA_OVERRIDE/bitwarden"

run() {  # <expected-exit> <label> <args...>
  local expected=$1 label=$2 rc=0
  shift 2
  OUT=$("$CEREMONY" "$@" 2>&1) || rc=$?
  [ "$rc" -eq "$expected" ] || fail "$label: expected exit $expected, got $rc"$'\n'"--- output ---"$'\n'"$OUT"
}

wait_for_file() {  # <path> <label>
  local path=$1 label=$2 attempts=0
  while [ ! -f "$path" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 500 ] || fail "$label"
    sleep 0.02
  done
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

# --- record paths never follow symbolic links -------------------------------

SYMLINK_ROOT="$TMP_ROOT/symlink-paths"
mkdir -p "$SYMLINK_ROOT/destination-data/bitwarden" "$SYMLINK_ROOT/directory-data" "$SYMLINK_ROOT/external-dir"

printf 'outside sentinel\n' > "$SYMLINK_ROOT/dangling-target"
before=$(cat "$SYMLINK_ROOT/dangling-target")
ln -s "$SYMLINK_ROOT/dangling-target" "$SYMLINK_ROOT/destination-data/bitwarden/linked.ceremony"
rc=0
OUT=$(FM_DATA_OVERRIDE="$SYMLINK_ROOT/destination-data" "$CEREMONY" init linked 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'init accepted a symlinked destination record'
assert_contains "$OUT" 'symbolic link' 'symlinked destination refusal names the path defect'
[ "$(cat "$SYMLINK_ROOT/dangling-target")" = "$before" ] || fail 'init changed a symlink target outside the record directory'

ln -s "$SYMLINK_ROOT/external-dir" "$SYMLINK_ROOT/directory-data/bitwarden"
rc=0
OUT=$(FM_DATA_OVERRIDE="$SYMLINK_ROOT/directory-data" "$CEREMONY" init linked-dir 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'init accepted a symlinked record directory'
assert_contains "$OUT" 'symbolic link' 'symlinked record directory refusal names the path defect'
[ ! -e "$SYMLINK_ROOT/external-dir/linked-dir.ceremony" ] || fail 'init wrote through a symlinked record directory'

mkdir -p "$SYMLINK_ROOT/real-parent"
ln -s "$SYMLINK_ROOT/real-parent" "$SYMLINK_ROOT/linked-parent"
rc=0
OUT=$(FM_DATA_OVERRIDE="$SYMLINK_ROOT/linked-parent/data" "$CEREMONY" init linked-parent 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'init accepted a symlinked parent path component'
assert_contains "$OUT" 'symbolic link' 'symlinked parent component refusal names the path defect'
[ ! -e "$SYMLINK_ROOT/real-parent/data/bitwarden/linked-parent.ceremony" ] || fail 'init wrote through a symlinked parent path component'

RACE_ROOT="$TMP_ROOT/path-races"
mkdir -p "$RACE_ROOT/ancestor" "$RACE_ROOT/external/bitwarden"
printf 'outside ancestor sentinel\n' > "$RACE_ROOT/external/bitwarden/ancestor.ceremony"
FM_DATA_OVERRIDE="$RACE_ROOT/ancestor/data" "$CEREMONY" init ancestor >/dev/null
ancestor_marker="$RACE_ROOT/ancestor-pause"
FM_BITWARDEN_TEST_AFTER_LOCK="$ancestor_marker" FM_DATA_OVERRIDE="$RACE_ROOT/ancestor/data" \
  "$CEREMONY" mark ancestor preflight > "$RACE_ROOT/ancestor.out" 2>&1 &
ancestor_writer=$!
wait_for_file "$ancestor_marker.ready" 'ancestor-swap writer did not reach the locked pause'
mv "$RACE_ROOT/ancestor/data" "$RACE_ROOT/ancestor/data-stable"
ln -s "$RACE_ROOT/external" "$RACE_ROOT/ancestor/data"
: > "$ancestor_marker.go"
wait "$ancestor_writer" || fail 'ancestor-swap writer did not finish through its stable directory identity'
[ "$(cat "$RACE_ROOT/external/bitwarden/ancestor.ceremony")" = 'outside ancestor sentinel' ] || fail 'ancestor swap redirected the record write to the external sentinel'
grep -q '^step: preflight ' "$RACE_ROOT/ancestor/data-stable/bitwarden/ancestor.ceremony" || fail 'ancestor-swap writer did not update the directory it locked'
rm "$RACE_ROOT/ancestor/data"
mv "$RACE_ROOT/ancestor/data-stable" "$RACE_ROOT/ancestor/data"

mkdir -p "$RACE_ROOT/destination-data" "$RACE_ROOT/destination-external"
printf 'outside destination sentinel\n' > "$RACE_ROOT/destination-external/sentinel"
FM_DATA_OVERRIDE="$RACE_ROOT/destination-data" "$CEREMONY" init destination-race >/dev/null
destination_marker="$RACE_ROOT/destination-pause"
FM_BITWARDEN_TEST_BEFORE_REPLACE="$destination_marker" FM_DATA_OVERRIDE="$RACE_ROOT/destination-data" \
  "$CEREMONY" add-item destination-race prod-db --owner ops --collection prod > "$RACE_ROOT/destination.out" 2>&1 &
destination_writer=$!
wait_for_file "$destination_marker.ready" 'destination-swap writer did not reach the replacement pause'
mv "$RACE_ROOT/destination-data/bitwarden/destination-race.ceremony" "$RACE_ROOT/destination-data/bitwarden/destination-race.saved"
ln -s "$RACE_ROOT/destination-external/sentinel" "$RACE_ROOT/destination-data/bitwarden/destination-race.ceremony"
: > "$destination_marker.go"
wait "$destination_writer" || fail 'destination-swap writer did not finish with relative atomic replacement'
[ "$(cat "$RACE_ROOT/destination-external/sentinel")" = 'outside destination sentinel' ] || fail 'destination swap changed the external sentinel'
grep -q '^item: prod-db ' "$RACE_ROOT/destination-data/bitwarden/destination-race.ceremony" || fail 'destination-swap writer did not install the validated record update'
FM_DATA_OVERRIDE="$RACE_ROOT/destination-data" "$CEREMONY" check destination-race >/dev/null || fail 'destination-swap update left an unreadable record'

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

# A replay must be judged against the arguments the operator actually passed:
# identical is a no-op, conflicting is a refusal, invalid is refused either way.
run 0 'replaying approval with the same approver stays a no-op' mark batch-a approval --approved-by captain
assert_contains "$OUT" 'already recorded' 'identical approval replay is idempotent'
run 1 'replaying approval with a different approver is refused' mark batch-a approval --approved-by someone-else
assert_contains "$OUT" 'different approver' 'conflicting approval replay names the conflict'
grep -q '^step: approval date=.* approved-by=captain$' "$RECORDS/batch-a.ceremony" || fail 'a conflicting replay changed the recorded approver'
[ "$(grep -c '^step: approval' "$RECORDS/batch-a.ceremony")" = 1 ] || fail 'a conflicting replay appended a second approval line'
run 1 'replaying approval with a secret-shaped approver is refused' mark batch-a approval --approved-by ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
assert_contains "$OUT" 'refused' 'a secret-shaped approver is refused even on a recorded step'
assert_not_contains "$OUT" 'ghp_' 'the refusal echoed the secret-shaped approver'
run 1 '--approved-by is refused on an already-recorded non-approval step' mark batch-a preflight --approved-by captain
assert_contains "$OUT" 'only valid for the approval step' 'misplaced --approved-by is refused on a replay too'
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

# --- concurrent retries serialize and converge ------------------------------

CONCURRENT_DATA="$TMP_ROOT/concurrent-data"
init_pids=()
for i in $(seq 1 20); do
  FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" init retry-init > "$TMP_ROOT/retry-init-$i.out" 2>&1 &
  init_pids+=("$!")
done
for pid in "${init_pids[@]}"; do
  wait "$pid" || fail 'an identical concurrent init retry was refused'
done
[ "$(grep -c '^fm-bitwarden-ceremony v1$' "$CONCURRENT_DATA/bitwarden/retry-init.ceremony")" = 1 ] || fail 'concurrent init retries created an invalid record'
OUT=$(FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" check retry-init 2>&1) || fail 'concurrent init retries corrupted the record'
assert_contains "$OUT" 'next: preflight' 'concurrent identical init retries converge on one valid record'

FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" init retry-mark >/dev/null
pids=()
for i in $(seq 1 40); do
  FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" mark retry-mark preflight > "$TMP_ROOT/retry-mark-$i.out" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail 'an identical concurrent mark retry was refused'
done
[ "$(grep -c '^step: preflight' "$CONCURRENT_DATA/bitwarden/retry-mark.ceremony")" = 1 ] || fail 'concurrent mark retries recorded more than one step'
OUT=$(FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" check retry-mark 2>&1) || fail 'concurrent mark retries corrupted the record'
assert_contains "$OUT" 'next: approval' 'concurrent identical marks converge on one valid step'

FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" init retry-item >/dev/null
pids=()
for i in $(seq 1 40); do
  if [ $((i % 2)) -eq 0 ]; then owner=owner-a; else owner=owner-b; fi
  FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" add-item retry-item prod-db --owner "$owner" --collection prod > "$TMP_ROOT/retry-item-$i.out" 2>&1 &
  pids+=("$!")
done
accepted=0
refused=0
for pid in "${pids[@]}"; do
  if wait "$pid"; then accepted=$((accepted + 1)); else refused=$((refused + 1)); fi
done
[ "$accepted" -gt 0 ] || fail 'all conflicting concurrent item retries were refused'
[ "$refused" -gt 0 ] || fail 'conflicting concurrent item retries reported every owner as accepted'
[ "$(grep -c '^item: prod-db ' "$CONCURRENT_DATA/bitwarden/retry-item.ceremony")" = 1 ] || fail 'conflicting concurrent item retries recorded duplicate items'
OUT=$(FM_DATA_OVERRIDE="$CONCURRENT_DATA" "$CEREMONY" check retry-item 2>&1) || fail 'conflicting concurrent item retries corrupted the record'
assert_contains "$OUT" 'next: preflight' 'conflicting retries leave one valid ownership record'

LOCK_DATA="$TMP_ROOT/lock-recovery-data"
FM_DATA_OVERRIDE="$LOCK_DATA" "$CEREMONY" init killed-writer >/dev/null
killed_marker="$TMP_ROOT/killed-writer-pause"
FM_BITWARDEN_TEST_AFTER_LOCK="$killed_marker" FM_DATA_OVERRIDE="$LOCK_DATA" \
  "$CEREMONY" mark killed-writer preflight > "$TMP_ROOT/killed-writer.out" 2>&1 &
killed_command=$!
wait_for_file "$killed_marker.ready" 'hard-kill writer did not acquire its lock'
killed_owner=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$LOCK_DATA/bitwarden/killed-writer.ceremony.lock")
kill -9 "$killed_owner"
wait "$killed_command" 2>/dev/null && fail 'hard-killed writer command reported success'
FM_DATA_OVERRIDE="$LOCK_DATA" "$CEREMONY" mark killed-writer preflight >/dev/null || fail 'retry did not reclaim a positively stale writer lock'
[ ! -e "$LOCK_DATA/bitwarden/killed-writer.ceremony.lock" ] || fail 'stale writer recovery left the lock behind'

FM_DATA_OVERRIDE="$LOCK_DATA" "$CEREMONY" init live-writer >/dev/null
live_marker="$TMP_ROOT/live-writer-pause"
FM_BITWARDEN_TEST_AFTER_LOCK="$live_marker" FM_DATA_OVERRIDE="$LOCK_DATA" \
  "$CEREMONY" mark live-writer preflight > "$TMP_ROOT/live-writer.out" 2>&1 &
live_command=$!
wait_for_file "$live_marker.ready" 'live writer did not acquire its lock'
rc=0
OUT=$(FM_BITWARDEN_LOCK_WAIT_SECONDS=0.1 FM_DATA_OVERRIDE="$LOCK_DATA" "$CEREMONY" mark live-writer preflight 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'a second writer entered while the recorded owner was live'
assert_contains "$OUT" 'busy' 'live owner exclusion reports bounded contention'
: > "$live_marker.go"
wait "$live_command" || fail 'live lock owner did not finish after exclusion test'

FM_DATA_OVERRIDE="$LOCK_DATA" "$CEREMONY" init reused-pid >/dev/null
reuse_marker="$TMP_ROOT/reused-pid-pause"
FM_BITWARDEN_TEST_AFTER_LOCK="$reuse_marker" FM_DATA_OVERRIDE="$LOCK_DATA" \
  "$CEREMONY" mark reused-pid preflight > "$TMP_ROOT/reused-pid.out" 2>&1 &
reuse_command=$!
wait_for_file "$reuse_marker.ready" 'PID-reuse owner did not acquire its lock'
python3 - "$LOCK_DATA/bitwarden/reused-pid.ceremony.lock" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    owner = json.load(source)
owner["process_start"] += "-different"
temporary = path + ".replacement"
with open(temporary, "w", encoding="utf-8") as destination:
    json.dump(owner, destination, separators=(",", ":"), sort_keys=True)
    destination.write("\n")
os.replace(temporary, path)
PY
rc=0
OUT=$(FM_BITWARDEN_LOCK_WAIT_SECONDS=0.1 FM_DATA_OVERRIDE="$LOCK_DATA" "$CEREMONY" mark reused-pid preflight 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'a live PID with mismatched start identity was treated as stale'
assert_contains "$OUT" 'identity does not match' 'PID-reuse uncertainty names the refusal reason'
[ -f "$LOCK_DATA/bitwarden/reused-pid.ceremony.lock" ] || fail 'PID-reuse uncertainty stole the existing lock'
: > "$reuse_marker.go"
wait "$reuse_command" || fail 'identity-tampered live owner did not finish its record operation'

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
assert_contains "$OUT" 'approved-by is empty' 'empty-approver refusal names the reason'
run 1 'mark refuses to append to a record whose approval has no approver' mark tamper-approver retired
assert_contains "$OUT" 'approved-by is empty' 'the empty-approver record is refused when read, before any gate on the step itself'
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
printf 'fm-bitwarden-ceremony v1\nbatch: hdr-created\ncreated: 2026-01-01\ncreated: 2025-01-01\n' > "$RECORDS/hdr-created.ceremony"
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

# --- a moved batch must name what it moved -----------------------------------

# mark refuses to record moved with no registered item; a hand-edited record
# must not turn that into a completed ceremony that names no credential.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: moved-bare\n'
  printf 'created: 2026-01-01\n'
  printf 'step: preflight date=2026-01-01\n'
  printf 'step: approval date=2026-01-01 approved-by=captain\n'
  printf 'step: moved date=2026-01-01\n'
} > "$RECORDS/moved-bare.ceremony"
for cmd in check status; do
  run 1 "$cmd refuses a move recorded with no registered item" "$cmd" moved-bare
  assert_contains "$OUT" 'corrupt at line 6' 'itemless move is reported by line number'
  assert_contains "$OUT" 'no registered item' 'itemless move refusal names the reason'
  assert_not_contains "$OUT" 'next:' "$cmd reported progress from a move that names nothing"
done
run 1 'mark refuses to advance a move that names no item' mark moved-bare verified
! grep -q '^step: verified' "$RECORDS/moved-bare.ceremony" || fail 'an itemless moved record was advanced'

# --- item and step fields must carry real values -----------------------------

# An empty label made the item count and the moved gate disagree about the same
# record: status reported items: 0 while mark moved succeeded.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: empty-label\n'
  printf 'created: 2026-01-01\n'
  printf 'item:  owner=ops-team collection=prod-infra\n'
  printf 'step: preflight date=2026-01-01\n'
  printf 'step: approval date=2026-01-01 approved-by=captain\n'
} > "$RECORDS/empty-label.ceremony"
run 1 'status refuses an item line with no label' status empty-label
assert_contains "$OUT" 'corrupt at line 4' 'empty item label is reported by line number'
assert_contains "$OUT" 'item label is empty' 'empty item label refusal names the field'
assert_not_contains "$OUT" 'items:' 'status counted items from a record with an unlabelled item'
run 1 'mark refuses to record a move against an unlabelled item' mark empty-label moved
! grep -q '^step: moved' "$RECORDS/empty-label.ceremony" || fail 'a move was recorded against an unlabelled item'

# An item with no owner or collection is not the ownership target the ceremony
# requires, so it must not carry a batch through to retirement.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: empty-fields\n'
  printf 'created: 2026-01-01\n'
  printf 'item: prod-db owner= collection=\n'
  printf 'step: preflight date=2026-01-01\n'
} > "$RECORDS/empty-fields.ceremony"
run 1 'check refuses an item with no owner' check empty-fields
assert_contains "$OUT" 'item owner is empty' 'empty owner refusal names the field'
printf 'fm-bitwarden-ceremony v1\nbatch: empty-coll\ncreated: 2026-01-01\nitem: prod-db owner=ops-team collection=\n' > "$RECORDS/empty-coll.ceremony"
run 1 'check refuses an item with no collection' check empty-coll
assert_contains "$OUT" 'item collection is empty' 'empty collection refusal names the field'

# A record value that is secret-shaped is refused by the same rule the
# arguments face, and the refusal still withholds the content.
printf 'fm-bitwarden-ceremony v1\nbatch: item-secret\ncreated: 2026-01-01\nitem: prod-db owner=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA collection=prod-infra\n' > "$RECORDS/item-secret.ceremony"
run 1 'check refuses a secret-shaped owner recorded in the record' check item-secret
assert_contains "$OUT" 'credential shape' 'secret-shaped record value refusal names the reason'
assert_not_contains "$OUT" 'ghp_' 'refusal echoed the secret-shaped record value'

# Stray content on a line is not silently ignored.
printf 'fm-bitwarden-ceremony v1\nbatch: item-extra\ncreated: 2026-01-01\nitem: prod-db owner=ops-team extra=x collection=prod-infra\n' > "$RECORDS/item-extra.ceremony"
run 1 'check refuses an item line carrying unknown fields' check item-extra
assert_contains "$OUT" 'malformed item line' 'unknown item field is refused as malformed'

# Dates are the record's own evidence of when each gate was passed.
printf 'fm-bitwarden-ceremony v1\nbatch: no-date\ncreated: 2026-01-01\nitem: prod-db owner=ops-team collection=prod-infra\nstep: preflight date=\n' > "$RECORDS/no-date.ceremony"
run 1 'check refuses a step with an empty date' check no-date
assert_contains "$OUT" 'not a YYYY-MM-DD calendar date' 'empty step date refusal names the expected shape'
printf 'fm-bitwarden-ceremony v1\nbatch: bad-created\ncreated: sometime\n' > "$RECORDS/bad-created.ceremony"
run 1 'check refuses a created header that is not a date' check bad-created
assert_contains "$OUT" 'corrupt at line 3' 'malformed created header is reported by line number'

# The records this tool writes itself stay readable throughout.
run 0 'a tool-written batch initializes' init fields-ok
run 0 'a tool-written item registers' add-item fields-ok prod-db --owner ops-team --collection prod-infra
run 0 'a tool-written batch reaches the move' mark fields-ok preflight
run 0 'a tool-written approval records' mark fields-ok approval --approved-by captain
run 0 'a tool-written move records' mark fields-ok moved
run 0 'a tool-written record still reads back' status fields-ok
assert_contains "$OUT" 'items: 1' 'the tool-written record reports its registered item'
assert_contains "$OUT" 'next: verified' 'the tool-written record reports its true resume point'

# --- a record with no final newline is truncated, not appendable -------------

# The record is an append-only line-based file (see the script's --help), so a
# final line with no newline means the last line may be incomplete; appending
# to it would fuse two record lines into one.
printf 'fm-bitwarden-ceremony v1\nbatch: no-newline\ncreated: 2026-01-01\nitem: prod-db owner=ops-team collection=prod-infra' > "$RECORDS/no-newline.ceremony"
before=$(cat "$RECORDS/no-newline.ceremony")
for cmd in check status; do
  run 1 "$cmd refuses a record with no final newline" "$cmd" no-newline
  assert_contains "$OUT" 'corrupt at line 4' 'truncated record is reported by line number'
  assert_contains "$OUT" 'no terminating newline' 'truncated record refusal names the reason'
  assert_not_contains "$OUT" 'next:' "$cmd reported progress from a truncated record"
done
run 1 'mark refuses to append to a record with no final newline' mark no-newline preflight
run 1 'add-item refuses to append to a record with no final newline' add-item no-newline web --owner ops-team --collection prod-infra
[ "$(cat "$RECORDS/no-newline.ceremony")" = "$before" ] || fail 'a truncated record was modified instead of refused'
grep -q 'collection=prod-infra$' "$RECORDS/no-newline.ceremony" || fail 'the truncated record lost its recorded collection target'

# --- recorded dates must be real and must not run backwards ------------------

printf 'fm-bitwarden-ceremony v1\nbatch: date-range\ncreated: 9999-99-99\n' > "$RECORDS/date-range.ceremony"
run 1 'check refuses an out-of-range created date' check date-range
assert_contains "$OUT" 'corrupt at line 3' 'out-of-range created date is reported by line number'
printf 'fm-bitwarden-ceremony v1\nbatch: step-range\ncreated: 2026-01-01\nitem: prod-db owner=ops-team collection=prod-infra\nstep: preflight date=0000-00-00\n' > "$RECORDS/step-range.ceremony"
run 1 'check refuses an out-of-range step date' check step-range
assert_contains "$OUT" 'not a YYYY-MM-DD calendar date' 'out-of-range step date names the expected shape'

# A day that never occurred is not evidence of when a gate was passed.
for bad_date in 2026-02-30 2026-04-31 2025-02-29 2026-00-10 2026-13-01 0000-01-01; do
  printf 'fm-bitwarden-ceremony v1\nbatch: cal-bad\ncreated: %s\n' "$bad_date" > "$RECORDS/cal-bad.ceremony"
  run 1 "check refuses the impossible date $bad_date" check cal-bad
  assert_contains "$OUT" 'not a YYYY-MM-DD calendar date' "the impossible date $bad_date is refused as a calendar date"
done
# Leap days that did occur stay valid, as does the last day of a short month.
for good_date in 2024-02-29 2024-02-28 2024-04-30 2024-12-31; do
  printf 'fm-bitwarden-ceremony v1\nbatch: cal-ok\ncreated: %s\nitem: prod-db owner=ops-team collection=prod-infra\nstep: preflight date=%s\n' "$good_date" "$good_date" > "$RECORDS/cal-ok.ceremony"
  run 0 "check accepts the real date $good_date" check cal-ok
  assert_contains "$OUT" 'next: approval' "the record dated $good_date reports its resume point"
done

# A step cannot have happened before the batch it belongs to was created.
printf 'fm-bitwarden-ceremony v1\nbatch: date-early\ncreated: 2025-06-01\nitem: prod-db owner=ops-team collection=prod-infra\nstep: preflight date=2025-01-01\n' > "$RECORDS/date-early.ceremony"
run 1 'check refuses a step dated before the batch was created' check date-early
assert_contains "$OUT" 'earlier than the created header' 'pre-creation step refusal names the reason'

# Each gate is passed after the one before it, so the dates cannot decrease.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: date-back\n'
  printf 'created: 2024-01-01\n'
  printf 'item: prod-db owner=ops-team collection=prod-infra\n'
  printf 'step: preflight date=2025-06-01\n'
  printf 'step: approval date=2025-01-01 approved-by=captain\n'
} > "$RECORDS/date-back.ceremony"
for cmd in check status; do
  run 1 "$cmd refuses a history whose dates run backwards" "$cmd" date-back
  assert_contains "$OUT" 'corrupt at line 6' 'backwards date is reported by line number'
  assert_contains "$OUT" 'runs backwards' 'backwards date refusal names the reason'
  assert_not_contains "$OUT" 'next:' "$cmd reported progress from a backwards history"
done
run 1 'mark refuses to advance a backwards history' mark date-back moved
! grep -q '^step: moved' "$RECORDS/date-back.ceremony" || fail 'a backwards-dated record was appended to'

# A date this tool could not have stamped is not evidence. mark stamps today,
# so appending to a future-dated record would write a line its own readers then
# refuse - the record must be refused before that happens.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: date-future\n'
  printf 'created: 2026-01-01\n'
  printf 'item: prod-db owner=ops-team collection=prod-infra\n'
  printf 'step: preflight date=2099-12-31\n'
} > "$RECORDS/date-future.ceremony"
future_before=$(cat "$RECORDS/date-future.ceremony")
for cmd in check status; do
  run 1 "$cmd refuses a step dated in the future" "$cmd" date-future
  assert_contains "$OUT" 'corrupt at line 5' 'future step date is reported by line number'
  assert_contains "$OUT" 'in the future' 'future step date refusal names the reason'
  assert_not_contains "$OUT" 'next:' "$cmd reported progress from a future-dated record"
done
run 1 'mark refuses to append to a future-dated record' mark date-future approval --approved-by captain
[ "$(cat "$RECORDS/date-future.ceremony")" = "$future_before" ] || fail 'mark modified a future-dated record instead of refusing it'

printf 'fm-bitwarden-ceremony v1\nbatch: created-future\ncreated: 2099-12-31\n' > "$RECORDS/created-future.ceremony"
created_before=$(cat "$RECORDS/created-future.ceremony")
run 1 'check refuses a created header dated in the future' check created-future
assert_contains "$OUT" 'in the future' 'future created header refusal names the reason'
run 1 'mark refuses to append under a future created header' mark created-future preflight
[ "$(cat "$RECORDS/created-future.ceremony")" = "$created_before" ] || fail 'mark modified a record with a future created header'

# A ceremony cannot have been completed on a day that has not happened.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: all-future\n'
  printf 'created: 2099-12-31\n'
  printf 'item: prod-db owner=ops-team collection=prod-infra\n'
  printf 'step: preflight date=2099-12-31\n'
  printf 'step: approval date=2099-12-31 approved-by=captain\n'
  printf 'step: moved date=2099-12-31\n'
  printf 'step: verified date=2099-12-31\n'
  printf 'step: retired date=2099-12-31\n'
} > "$RECORDS/all-future.ceremony"
run 1 'status refuses an entirely future-dated completion record' status all-future
assert_not_contains "$OUT" 'next: complete' 'a future-dated ceremony was certified as complete'

# A record the tool wrote today is readable by the same rules that refuse the
# future, so the accepted set is exactly what the writer can produce.
run 0 'a batch stamped today initializes' init dated-today
run 0 'a step stamped today records' mark dated-today preflight
run 0 'a record stamped today reads back' check dated-today
assert_contains "$OUT" 'next: approval' "today's own stamp is not treated as future"

CLOCK_BIN="$TMP_ROOT/clock-bin"
mkdir -p "$CLOCK_BIN"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'count=0'
  printf '%s\n' '[ ! -f "$FM_CLOCK_COUNT" ] || count=$(cat "$FM_CLOCK_COUNT")'
  printf '%s\n' 'count=$((count + 1))'
  printf '%s\n' 'printf "%s\n" "$count" > "$FM_CLOCK_COUNT"'
  printf '%s\n' 'sed -n "${count}p" "$FM_CLOCK_VALUES"'
} > "$CLOCK_BIN/date"
chmod +x "$CLOCK_BIN/date"

CLOCK_DATA="$TMP_ROOT/clock-data"
FM_DATA_OVERRIDE="$CLOCK_DATA" "$CEREMONY" init midnight >/dev/null
printf '2026-08-29\n2026-08-30\n' > "$TMP_ROOT/midnight-values"
rc=0
OUT=$(PATH="$CLOCK_BIN:$PATH" FM_CLOCK_COUNT="$TMP_ROOT/midnight-count" FM_CLOCK_VALUES="$TMP_ROOT/midnight-values" \
  FM_DATA_OVERRIDE="$CLOCK_DATA" "$CEREMONY" mark midnight preflight 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "midnight mark failed: $OUT"
assert_contains "$OUT" 'recorded (2026-08-30)' 'mark reports the one timestamp captured for the write'
grep -q '^step: preflight date=2026-08-30$' "$CLOCK_DATA/bitwarden/midnight.ceremony" || fail 'mark persisted a date different from its reported timestamp'
[ "$(cat "$TMP_ROOT/midnight-count")" = 2 ] || fail 'mark sampled the UTC date more than once after parsing'

FM_DATA_OVERRIDE="$CLOCK_DATA" "$CEREMONY" init rollback-clock >/dev/null
FM_DATA_OVERRIDE="$CLOCK_DATA" "$CEREMONY" mark rollback-clock preflight >/dev/null
before=$(cat "$CLOCK_DATA/bitwarden/rollback-clock.ceremony")
printf '2026-08-29\n2026-08-28\n' > "$TMP_ROOT/rollback-values"
rc=0
OUT=$(PATH="$CLOCK_BIN:$PATH" FM_CLOCK_COUNT="$TMP_ROOT/rollback-count" FM_CLOCK_VALUES="$TMP_ROOT/rollback-values" \
  FM_DATA_OVERRIDE="$CLOCK_DATA" "$CEREMONY" mark rollback-clock approval --approved-by captain 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'mark accepted a clock rollback before the previous step date'
assert_contains "$OUT" 'earlier than the previous step date' 'clock rollback refusal names the violated ordering invariant'
[ "$(cat "$CLOCK_DATA/bitwarden/rollback-clock.ceremony")" = "$before" ] || fail 'clock rollback changed the ceremony record'
[ "$(cat "$TMP_ROOT/rollback-count")" = 2 ] || fail 'clock rollback path sampled the UTC date after its final validation'

# Repeated dates are legitimate: a whole batch can run within one day.
{
  printf 'fm-bitwarden-ceremony v1\n'
  printf 'batch: date-same\n'
  printf 'created: 2026-01-01\n'
  printf 'item: prod-db owner=ops-team collection=prod-infra\n'
  printf 'step: preflight date=2026-01-01\n'
  printf 'step: approval date=2026-01-01 approved-by=captain\n'
  printf 'step: moved date=2026-01-01\n'
} > "$RECORDS/date-same.ceremony"
run 0 'a same-day ceremony is valid' check date-same
assert_contains "$OUT" 'next: verified' 'the same-day record reports its true resume point'
run 0 'a same-day ceremony still advances' mark date-same verified

# --- the item count is the number of registered items ------------------------

run 0 'multi-item batch initializes' init count-many
run 0 'first item registers' add-item count-many prod-db --owner ops-team --collection prod-infra
run 0 'second item registers' add-item count-many prod-cache --owner ops-team --collection prod-infra
run 0 'third item registers' add-item count-many prod-queue --owner ops-team --collection prod-infra
run 0 'multi-item status reports the count' status count-many
assert_contains "$OUT" 'items: 3' 'every registered item is counted'
run 0 'an itemless batch initializes' init count-zero
run 0 'itemless status reports zero' status count-zero
assert_contains "$OUT" 'items: 0' 'a batch with no items counts zero'

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
