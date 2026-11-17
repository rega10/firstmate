#!/usr/bin/env bash
# Real Grok composer regression on isolated Herdr and tmux backends.
# No model prompt is submitted. Set FM_COMPOSER_GROK_LIVE=0 to disable or =1
# to require tools instead of capability-skipping (tests/lib.sh owns gating).
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_COMPOSER_GROK_LIVE grok herdr jq

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
TMP_ROOT=$(fm_test_tmproot fm-grok-composer)
FM_HOME=$("$HOME_HELPER" create "$TMP_ROOT/home")
export FM_HOME
SESSION=$("$LAB_HELPER" name firstmate-grok-herdr-exit-composer-unknown)
TMUX_TMPDIR=$("$HOME_HELPER" tmux-dir "$FM_HOME")
export TMUX_TMPDIR
unset TMUX TMUX_PANE
REAL_TMUX=$(command -v tmux || true)
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$REAL_TMUX" ]; then "$REAL_TMUX" kill-server 2>/dev/null || true; fi
  "$HOME_HELPER" teardown "$FM_HOME" || rc=1
  "$LAB_HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  [ "$1" = "$SESSION" ] || return 97
  shift
  lab "$@"
}
GROK_BINARY=${FM_COMPOSER_GROK_BINARY:-$(command -v grok)}
VERSION=$("$GROK_BINARY" --version)
LAUNCH=$(printf '%q --always-approve --no-subagents' "$GROK_BINARY")
DRAFT='unsubmitted composer regression draft'
PANE=$(lab workspace create --cwd "$ROOT" --label grok-composer --no-focus | jq -er '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"
lab pane run "$PANE" "$LAUNCH" >/dev/null

assert_state() {  # <backend> <target> <expected>
  local actual='' i
  for ((i=0; i<100; i++)); do
    actual=$(fm_backend_composer_state "$1" "$2")
    [ "$actual" = "$3" ] && return 0
    sleep 0.1
  done
  if [ "$1" = herdr ]; then
    lab pane read "$PANE" --source visible >&2
  else
    tmux capture-pane -p -t "$2" >&2
  fi
  fail "Grok ($VERSION): $1 composer read $actual, expected $3"
}
assert_state herdr "$TARGET" empty
lab pane send-text "$PANE" "$DRAFT" >/dev/null
assert_state herdr "$TARGET" pending
pass "Grok ($VERSION): Herdr idle=empty, unsubmitted draft=pending"

# The lab's short TMUX_TMPDIR is the sole isolation boundary. Inherited
# parent selectors were removed before the cleanup trap was installed.
if [ -z "$REAL_TMUX" ]; then
  printf '# tmux absent: live tmux composer unverified; portable adapter replay covers its capture path\n'
  exit 0
fi
fm_backend_source tmux
tmux new-session -d -s grok-composer -x 120 -y 40 -c "$ROOT" \
  "$LAUNCH"
assert_state tmux grok-composer empty
tmux send-keys -t grok-composer -l "$DRAFT"
assert_state tmux grok-composer pending
pass "Grok ($VERSION): tmux idle=empty, unsubmitted draft=pending"
