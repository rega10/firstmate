#!/usr/bin/env bash
# Behavior tests for structured and legacy no-mistakes PR body verification.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-no-mistakes-pr-body-verify.sh"
MARKER='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

run_body() {
  PR_BODY=$1 PR_AUTHOR=fixture PR_NUMBER=11 /bin/bash "$VERIFY" 2>&1
}

legacy_body() {
  review=$1
  printf '%s\n' \
    '## Pipeline' \
    "$MARKER" \
    '<details>' \
    "$review" \
    '✅ Re-checked - no issues remain.' \
    '</details>' \
    '<details>' \
    '<summary>✅ **Test** - passed</summary>' \
    '</details>' \
    '<details>' \
    '<summary>✅ **Document** - passed</summary>' \
    '</details>'
}

test_structured_attestation_passes() {
  local body out
  body=$(printf '%s\n%s\n' "$MARKER" \
    '<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"abc","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->')
  out=$(run_body "$body") || fail "completed structured attestation was rejected: $out"
  assert_contains "$out" "Pipeline step attestation is valid" \
    "structured success was not reported"
  pass "completed structured attestation passes"
}

test_legacy_completed_blocks_pass() {
  local body out
  body=$(legacy_body '<summary>🔧 **Review** - findings auto-fixed ✅</summary>')
  out=$(run_body "$body") || fail "completed legacy pipeline evidence was rejected: $out"
  assert_contains "$out" "Legacy pipeline evidence is valid" \
    "legacy success was not reported"
  pass "completed legacy pipeline blocks pass"
}

test_structured_attestation_fails_closed() {
  local body out rc=0
  body=$(printf '%s\n%s\n' "$MARKER" \
    '<!-- no-mistakes-pipeline-attestation:v1 {bad json} -->')
  out=$(run_body "$body") || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed structured attestation fell back to legacy evidence"
  assert_contains "$out" "Structured no-mistakes pipeline step attestation is unparseable" \
    "malformed structured failure was unclear"
  pass "malformed structured attestation fails closed"
}

test_legacy_incomplete_step_fails() {
  local body out rc=0
  body=$(legacy_body '<summary>⏭️ **Review** - skipped</summary>')
  body=$(printf '%s\n' "$body" | grep -Fvx '✅ Re-checked - no issues remain.')
  out=$(run_body "$body") || rc=$?
  [ "$rc" -ne 0 ] || fail "skipped legacy review was accepted"
  assert_contains "$out" "review=incomplete" "legacy failure did not identify review"
  pass "incomplete legacy step fails"
}

test_missing_signature_fails() {
  local out rc=0
  out=$(run_body '## Pipeline') || rc=$?
  [ "$rc" -ne 0 ] || fail "body without no-mistakes signature was accepted"
  assert_contains "$out" "This PR was not raised through no-mistakes" \
    "missing-signature failure was unclear"
  pass "missing no-mistakes signature fails"
}

test_structured_attestation_passes
test_legacy_completed_blocks_pass
test_structured_attestation_fails_closed
test_legacy_incomplete_step_fails
test_missing_signature_fails
