#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.test-tmp/manual
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M7M5824TC6WV3KTE7Z09BQWQ
export FM_HERDR_LAB_STATE_DIR=$ROOT/.test-tmp/herdr-state
export FM_HOME=$LAB/fmhome GROK_HOME=$LAB/grok-home
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
HELPER=$ROOT/bin/fm-herdr-lab.sh
SESSION=$(cat "$LAB/session")
cleanup() {
  local rc=$?
  trap - EXIT
  "$HELPER" teardown "$SESSION" || rc=1
  printf 'Herdr lab teardown status: %s\n' "$?"
  exit "$rc"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION"
lab() { "$HELPER" run "$SESSION" "$@"; }
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  [ "$1" = "$SESSION" ] || return 97
  shift
  lab "$@"
}
lab workspace create --cwd "$LAB/project" --label grok-live-manual --no-focus > "$LAB/workspace.json"
PANE=$(jq -er .result.root_pane.pane_id "$LAB/workspace.json")
TARGET=$SESSION:$PANE
lab pane run "$PANE" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$FM_HOME' GROK_HOME='$GROK_HOME' grok --always-approve --no-subagents --tools '' --leader-socket '$LAB/leader.sock'" >/dev/null
for ((i=0;i<80;i++)); do
  screen=$(lab pane read "$PANE" --source visible)
  if [[ "$screen" == *'Do you trust the contents'* ]]; then
    printf '%s\n' 'Accepted directory trust only in disposable GROK_HOME.'
    lab pane send-keys "$PANE" enter >/dev/null
  fi
  state=$(fm_backend_composer_state herdr "$TARGET")
  [ "$state" = empty ] && break
  sleep 0.2
done
lab pane read "$PANE" --source visible > "$EVIDENCE/grok-idle.txt"
lab pane read "$PANE" --source visible --format ansi > "$EVIDENCE/grok-idle.ansi.txt"
printf 'Grok version: %s\nIdle composer: %s\n' "$(grok --version)" "$state"
[ "$state" = empty ] || exit 2
lab pane read "$PANE" --source visible --format ansi > "$LAB/live-idle.ansi.txt"
git show 592b9eca7338480d59f8b079636c40adfdaae816:bin/fm-composer-lib.sh > "$LAB/base-composer.sh"
BASE_VERDICT=$(bash -c '. "$1"; fm_composer_classify_screen "styled=1" "$(cat "$2")"' _ "$LAB/base-composer.sh" "$LAB/live-idle.ansi.txt")
printf 'Base classifier on this live idle capture: %s\n' "$BASE_VERDICT"
lab agent get "$PANE" > "$EVIDENCE/grok-agent.json"
lab pane process-info --pane "$PANE" > "$EVIDENCE/grok-process.json"
lab agent explain "$PANE" > "$EVIDENCE/grok-agent-explain.json"
printf 'Agent state before viewer: %s\n' "$(fm_backend_agent_state herdr "$TARGET")"
"$HELPER" viewer start "$SESSION"
sleep 2
printf 'Agent state with viewer: %s\n' "$(fm_backend_agent_state herdr "$TARGET")"
lab agent get "$PANE" > "$EVIDENCE/grok-agent-with-viewer.json"
cat > "$FM_HOME/state/grok-live.meta" <<META
window=$TARGET
endpoint_task_id=grok-live
worktree=$LAB/project
project=$LAB/project
harness=grok
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=$PANE
META
fm_backend_send_text_submit herdr "$TARGET" 'For an isolated regression check, reply with exactly these three lines: Upgrade tier, Buy more credits, Try Again. Put each label on its own line. Do not use tools.' 3 1 1
for ((i=0;i<40;i++)); do
  screen=$(lab pane read "$PANE" --source visible)
  dialog=$(fm_composer_blocking_dialog "$screen" || true)
  if [ -n "$dialog" ]; then
    printf 'Live dialog detected: %s\n' "$dialog"
    break
  fi
  if [[ "$screen" == *'Worked for'* ]] && [ "$(fm_backend_composer_state herdr "$TARGET")" = empty ]; then
    break
  fi
  sleep 0.5
done
lab pane read "$PANE" --source visible > "$EVIDENCE/grok-quota-probe.txt"
lab pane read "$PANE" --source visible --format ansi > "$EVIDENCE/grok-quota-probe.ansi.txt"
if [ -n "$dialog" ]; then
  if fm_backend_send_text_submit herdr "$TARGET" /exit 3 1 1 > "$EVIDENCE/grok-quota-refusal.txt" 2>&1; then exit 5; fi
  cat "$EVIDENCE/grok-quota-refusal.txt"
else
  printf 'Completed transcript quote. Current composer: %s\n' "$(fm_backend_composer_state herdr "$TARGET")"
fi
[ -z "$dialog" ]
"$ROOT/bin/fm-control.sh" grok-live exit 2>&1 | tee "$EVIDENCE/grok-quote-exit.txt"
printf 'The real quoted labels did not block exit.\n'
