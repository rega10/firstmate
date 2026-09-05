#!/usr/bin/env bash
# Regression: the Claude launch sanitizes inherited parent session identity.
#
# When a firstmate primary (or any ancestor) still carries Claude Code's
# intentional child-session environment, an unsanitized Claude crewmate or
# secondmate launch inherits CLAUDE_CODE_CHILD_SESSION and its identity pack.
# Claude then disables transcript saving with
#   "Transcript saving is off - inherited CLAUDE_CODE_CHILD_SESSION marker"
# and the worker has no independently resumable session.
#
# bin/fm-spawn.sh drops that pack on the claude launch only, via the
# `env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID
# -u CLAUDE_JOB_DIR` addition to the Claude identity-sanitize wrapper. That the
# spawn actually EMITS that prefix on the launched command is pinned
# behaviorally by tests/fm-spawn-dispatch-profile.test.sh (the launch-log
# assertions). This file proves the complementary half: that the emitted prefix,
# when executed, unsets exactly the parent identity pack and preserves unrelated
# environment. Live CLI transcript evidence stays in maintainer verification
# docs; no transcript contents or credentials here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-session-env)
PYTHON_BIN_DIR=$(command -v python3 >/dev/null 2>&1 && dirname "$(command -v python3)" || true)
BASE_PATH=${FM_TEST_BASE_PATH:-${PYTHON_BIN_DIR:+$PYTHON_BIN_DIR:}/usr/bin:/bin:/usr/sbin:/sbin}

# The claude launch's identity-sanitize prefix, exactly as bin/fm-spawn.sh emits
# it (verified against the real launched command in fm-spawn-dispatch-profile).
CLAUDE_SANITIZE_PREFIX='env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_JOB_DIR CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0'

test_sanitize_prefix_drops_parent_markers_and_preserves_unrelated_env() {
  # Run the same env prefix the launch emits against a polluted parent
  # environment and a fake claude that records its effective environment.
  local case_dir fakebin marker_file launch
  case_dir="$TMP_ROOT/env-eval"
  fakebin="$case_dir/fakebin"
  marker_file="$case_dir/claude-env.txt"
  mkdir -p "$fakebin"
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'CHILD=%s\n' "${CLAUDE_CODE_CHILD_SESSION-<unset>}"
  printf 'SID=%s\n' "${CLAUDE_CODE_SESSION_ID-<unset>}"
  printf 'PID=%s\n' "${CLAUDE_PID-<unset>}"
  printf 'JOB=%s\n' "${CLAUDE_JOB_DIR-<unset>}"
  printf 'PROMPT_SUGGESTION=%s\n' "${CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION-<unset>}"
  printf 'UNRELATED=%s\n' "${FM_TEST_UNRELATED_ENV-<unset>}"
  printf 'CLAUDECODE=%s\n' "${CLAUDECODE-<unset>}"
} > "${FM_FAKE_CLAUDE_ENV_OUT:?}"
exit 0
SH
  chmod +x "$fakebin/claude"

  launch="$CLAUDE_SANITIZE_PREFIX claude --dangerously-skip-permissions"
  env \
    CLAUDE_CODE_CHILD_SESSION=1 \
    CLAUDE_CODE_SESSION_ID=parent-session-id-for-test \
    CLAUDE_PID=12345 \
    CLAUDE_JOB_DIR=/tmp/parent-job-dir \
    CLAUDECODE=1 \
    FM_TEST_UNRELATED_ENV=keep-me \
    FM_FAKE_CLAUDE_ENV_OUT="$marker_file" \
    PATH="$fakebin:$BASE_PATH" \
    bash -c "$launch"

  [ -f "$marker_file" ] || fail "fake claude did not write env capture"
  # assert_grep is fixed-string (grep -F); match whole lines without regex anchors.
  assert_grep 'CHILD=<unset>' "$marker_file" "CHILD_SESSION was not cleared"
  assert_grep 'SID=<unset>' "$marker_file" "SESSION_ID was not cleared"
  assert_grep 'PID=<unset>' "$marker_file" "CLAUDE_PID was not cleared"
  assert_grep 'JOB=<unset>' "$marker_file" "CLAUDE_JOB_DIR was not cleared"
  assert_grep 'PROMPT_SUGGESTION=false' "$marker_file" "prompt-suggestion suppress missing"
  assert_grep 'UNRELATED=keep-me' "$marker_file" "unrelated environment was not preserved"
  assert_grep 'CLAUDECODE=1' "$marker_file" "unrelated CLAUDECODE should still pass through"
  pass "sanitize prefix unsets parent Claude identity and preserves unrelated environment"
}

test_sanitize_prefix_drops_parent_markers_and_preserves_unrelated_env
