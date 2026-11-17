#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.test-tmp/relaunch
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M7M5824TC6WV3KTE7Z09BQWQ
export FM_HERDR_LAB_STATE_DIR=$ROOT/.test-tmp/herdr-state
export FM_HOME=$LAB/home GROK_HOME=$LAB/grok-home
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE TASKS_AXI_FILE TASKS_AXI_BACKEND
HELPER=$ROOT/bin/fm-herdr-lab.sh
SESSION=$("$HELPER" name grok-switch)
cleanup() {
  local rc=$?
  trap - EXIT
  "$HELPER" teardown "$SESSION" || rc=1
  echo 'Isolated Herdr relaunch lab removed.'
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
lab workspace create --cwd "$LAB/wt" --label grok-switch --no-focus > "$LAB/workspace.json"
PANE=$(jq -er .result.root_pane.pane_id "$LAB/workspace.json")
TARGET=$SESSION:$PANE
lab pane run "$PANE" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$FM_HOME' GROK_HOME='$GROK_HOME' '$ROOT/.test-tmp/grok1077/node_modules/@xai-official/grok-darwin-arm64/bin/grok' --always-approve --no-subagents --tools ''" >/dev/null
"$HELPER" viewer start "$SESSION"
for ((i=0;i<80;i++)); do
  screen=$(lab pane read "$PANE" --source visible)
  if [[ "$screen" == *'Do you trust the contents'* ]]; then
    lab pane send-keys "$PANE" enter >/dev/null
  fi
  state=$(fm_backend_composer_state herdr "$TARGET")
  agent=$(fm_backend_agent_state herdr "$TARGET")
  [ "$state" = empty ] && [ "$agent" = alive ] && break
  sleep 0.2
done
printf 'Before relaunch: composer=%s agent=%s endpoint=%s\n' "$state" "$agent" "$TARGET"
[ "$state" = empty ] && [ "$agent" = alive ]
cat > "$FM_HOME/state/grok-switch.meta" <<META
window=$TARGET
endpoint_task_id=grok-switch
worktree=$LAB/wt
project=$LAB/project
harness=grok
kind=ship
mode=local-only
yolo=off
branch=fm/grok-switch
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=$PANE
META
printf 'Preserve this local draft file across relaunch.\n' > "$LAB/wt/preserved.txt"
"$ROOT/bin/fm-control.sh" grok-switch relaunch --harness codex --note 'This is a disposable live lifecycle check. Only reply READY and wait. Use no tools and change no files.' 2>&1 | tee "$EVIDENCE/grok1077-to-codex-relaunch.txt"
printf 'After relaunch agent: %s\n' "$(fm_backend_agent_state herdr "$TARGET")"
cat "$FM_HOME/state/grok-switch.meta" > "$EVIDENCE/grok1077-to-codex-meta.txt"
grep -qx harness=codex "$FM_HOME/state/grok-switch.meta"
grep -qx "window=$TARGET" "$FM_HOME/state/grok-switch.meta"
grep -Fq 'Preserve this local draft file' "$LAB/wt/preserved.txt"
lab agent get "$PANE" > "$EVIDENCE/codex-after-relaunch-agent.json"
jq -e '.result.agent.agent == "codex"' "$EVIDENCE/codex-after-relaunch-agent.json" >/dev/null
lab pane read "$PANE" --source visible > "$EVIDENCE/codex-after-relaunch.txt"
lab pane read "$PANE" --source visible --format ansi > "$EVIDENCE/codex-after-relaunch.ansi.txt"
printf 'Codex registered alive. Its first-use directory-trust dialog remains for the operator.\n'
printf 'Replacement uses the same endpoint and worktree. The local draft file survived.\n'
