#!/usr/bin/env bash
# Real Claude-to-zsh composer regression. No model prompt is submitted.
# Runs by default when Claude, Herdr, jq, and zsh are installed; force with
# FM_COMPOSER_CLAUDE_SHELL_LIVE=1 or disable with =0 (tests/lib.sh owns gating).
# All Herdr calls use the lab helper, including the adapter's capture calls.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "${PHASE_WORKTREE:?set PHASE_WORKTREE to the gate worktree}/tests/lib.sh"
fm_live_gate default-on FM_COMPOSER_CLAUDE_SHELL_LIVE claude herdr jq zsh

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
TMP_ROOT=$(fm_test_tmproot fm-claude-shell)
FM_HOME=$("$HOME_HELPER" create "$TMP_ROOT/home")
export FM_HOME
SESSION=$("$LAB_HELPER" name firstmate-composer-dead-shell-zsh-glyph-reads-empty)
cleanup() {
  local rc=$?
  trap - EXIT
  "$HOME_HELPER" teardown "$FM_HOME" || rc=1
  "$LAB_HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
# Replace only the transport, preserving production capture and classification.
fm_backend_herdr_cli() {
  [ "$1" = "$SESSION" ] || return 97
  shift
  lab "$@"
}
VERSION=$(claude --version)
PANE=$(lab workspace create --cwd "$FM_HOME" --label composer-shell --no-focus | jq -er '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"
lab pane run "$PANE" "exec env PS1='❯ ' RPS1='' zsh -df" >/dev/null

wait_for_screen() {  # <literal>
  local i
  for ((i=0; i<100; i++)); do
    SCREEN=$(lab pane read "$PANE" --source visible)
    case "$SCREEN" in *"$1"*) return 0 ;; esac
    sleep 0.1
  done
  fail "Claude ($VERSION): expected screen text '$1' never appeared"
}
assert_state() {  # <expected> <label>
  local actual i
  for ((i=0; i<40; i++)); do
    actual=$(fm_backend_herdr_composer_state "$TARGET")
    if [ "$actual" = "$1" ]; then
      label=$(printf '%s' "$2" | tr ' ' '-')
      lab pane read "$PANE" --source visible --format ansi > "$PHASE_EVIDENCE/$label.ansi"
      lab pane read "$PANE" --source visible > "$PHASE_EVIDENCE/$label.txt"
      lab pane process-info --pane "$PANE" > "$PHASE_EVIDENCE/$label-process.json"
      if [ "$actual" = unknown ]; then
        (
          . "$ROOT/bin/fm-supervise-daemon.sh"
          fm_backend_source herdr
          fm_backend_herdr_cli() {
            [ "$1" = "$SESSION" ] || return 97
            shift
            lab "$@"
          }
          export FM_SUPERVISOR_TARGET="$TARGET" FM_SUPERVISOR_BACKEND=herdr FM_DAEMON_PRIMARY_HARNESS=claude
          LOG="$PHASE_EVIDENCE/injection-guard.log"
          touch "$FM_HOME/state/.afk"
          before=$(lab pane read "$PANE" --source visible --format ansi)
          if inject_msg 'isolated composer safety probe' "$FM_HOME/state"; then
            fail 'the injection guard accepted a real shell'
          fi
          [ "$INJECT_SUBMIT_ATTEMPTED" = 0 ] || fail 'the guard attempted a submission'
          case "$INJECT_LAST_FAILURE" in *state=unknown*) ;; *) fail "the composer did not defer injection: $INJECT_LAST_FAILURE" ;; esac
          after=$(lab pane read "$PANE" --source visible --format ansi)
          [ "$before" = "$after" ] || fail 'the rejected injection changed the shell screen'
          printf 'Injection refused for %s; submission attempted=%s; screen unchanged; %s\n' "$2" "$INJECT_SUBMIT_ATTEMPTED" "$INJECT_LAST_FAILURE"
        )
      fi
      printf '%s: %s\n'  "$2" "$actual"
      return 0
    fi
    sleep 0.1
  done
  lab pane read "$PANE" --source visible >&2
  fail "Claude ($VERSION): $2 read $actual, expected $1"
}

for ((i=0; i<100; i++)); do
  SCREEN=$(lab pane read "$PANE" --source visible)
  if printf '%s\n' "$SCREEN" | grep -Eq '^❯[[:space:]]*$'; then break; fi
  sleep 0.1
done
[ "$i" -lt 100 ] || fail 'real zsh did not draw a standalone arrow prompt'
lab pane process-info --pane "$PANE" | jq -e '.result.process_info.foreground_processes | length == 1 and .[0].name == "zsh"' >/dev/null || fail 'zsh was not the foreground process' 
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
assert_state unknown 'bare zsh arrow'
baseline=$(bash -c '. "$1"; fm_composer_classify_screen "styled=1
cursor=0
identity=1" "$(cat "$2")"' _ "$PHASE_BASELINE" "$PHASE_EVIDENCE/bare-zsh-arrow.ansi")
[ "$baseline" = empty ] || fail "baseline did not reproduce the unsafe empty verdict: $baseline"
printf 'Before fix: real zsh arrow=%s; after fix: real zsh arrow=unknown\n' "$baseline"

lab pane run "$PANE" "PS1=$'\\e[2m❯ \\e[0m'" >/dev/null
sleep 0.5
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
assert_state unknown 'dim zsh arrow'
lab pane run "$PANE" "PS1=$'❯ \\e[2mghost suggestion\\nwrapped shell suggestion\\e[0m'" >/dev/null
sleep 0.5
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
assert_state unknown 'wrapped ghost zsh arrow'
lab pane run "$PANE" "PS1='❯ '" >/dev/null
sleep 0.5
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
assert_state unknown 'restored zsh arrow'

# Private settings suppress onboarding and register only this throwaway home.
# --bare disables hooks, memory, and keychain access. The actual TUI renders
# without credentials because this guard never submits a model prompt.
mkdir -p "$FM_HOME/claude"
jq -n --arg path "$FM_HOME" '{hasCompletedOnboarding:true,theme:"dark",projects:{($path):{hasTrustDialogAccepted:true}}}' \
  > "$FM_HOME/claude/.claude.json"
command_line=$(printf 'env CLAUDE_CONFIG_DIR=%q claude --bare --setting-sources ""' "$FM_HOME/claude")
lab pane run "$PANE" "$command_line" >/dev/null
wait_for_screen 'for agents'
assert_state empty 'real idle Claude composer'
lab pane send-text "$PANE" 'unsubmitted composer regression draft' >/dev/null
wait_for_screen 'unsubmitted composer regression draft'
assert_state pending 'real Claude draft'
fm_backend_herdr_composer_clear "$TARGET" 'unsubmitted composer regression draft' \
  || fail "Claude ($VERSION): could not clear the lab draft"
assert_state empty 'cleared Claude draft'
lab pane run "$PANE" /exit >/dev/null
for ((i=0; i<100; i++)); do
  if lab pane process-info --pane "$PANE" | jq -e '
    .result.process_info.foreground_processes as $p |
    ($p | length) == 1 and $p[0].name == "zsh"
  ' >/dev/null; then break; fi
  sleep 0.1
done
[ "$i" -lt 100 ] || fail "Claude ($VERSION): /exit did not leave the zsh shell"
assert_state unknown 'zsh arrow below exited Claude output'
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
assert_state unknown 'cleared zsh arrow after Claude exited'
pass "Claude ($VERSION): idle=empty, draft=pending, exited zsh=unknown, cleared zsh=unknown"
