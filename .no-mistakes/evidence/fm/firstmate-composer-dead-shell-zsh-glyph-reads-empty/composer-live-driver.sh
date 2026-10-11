#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4MSCKPP2EVVD8SJZ18502B1
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-composer/herdr-state"
export TMPDIR="$ROOT/.test-composer/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME
FM_HOME=$(bin/fm-lab-home.sh create "$ROOT/.test-composer/manual-home")
SESSION=$(bin/fm-herdr-lab.sh name composer-evidence)
cleanup() {
  local rc=$?
  trap - EXIT
  bin/fm-herdr-lab.sh teardown "$SESSION" || rc=1
  bin/fm-lab-home.sh teardown "$FM_HOME" || rc=1
  rm -rf "$FM_HOME"
  printf 'Cleanup finished with status %s.\n' "$rc"
  exit "$rc"
}
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$SESSION"
lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
. bin/fm-supervise-daemon.sh
fm_backend_source herdr
fm_backend_herdr_cli() {
  [ "$1" = "$SESSION" ] || return 97
  shift
  lab "$@"
}
PANE=$(lab workspace create --cwd "$FM_HOME" --label composer-proof --no-focus | jq -er '.result.root_pane.pane_id')
export FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$SESSION:$PANE" FM_DAEMON_PRIMARY_HARNESS=claude
TARGET=$FM_SUPERVISOR_TARGET
wait_text() {
  for ((i=0;i<100;i++)); do
    screen=$(lab pane read "$PANE" --source visible)
    case "$screen" in *"$1"*) return ;; esac
    sleep 0.1
  done
  printf 'Missing screen text: %s\n' "$1" >&2; exit 1
}
capture() {
  local name=$1 expected=$2 actual
  actual=$(fm_backend_herdr_composer_state "$TARGET")
  lab pane read "$PANE" --source visible --ansi > "$EVIDENCE/$name.ansi"
  lab pane process-info --pane "$PANE" > "$EVIDENCE/$name-process.json"
  printf '%s: expected=%s actual=%s\n' "$name" "$expected" "$actual"
  [ "$actual" = "$expected" ]
}
refuse_injection() {
  local before after rc
  before=$(lab pane read "$PANE" --source visible --ansi)
  touch "$FM_HOME/state/.afk"
  set +e
  inject_msg "printf injected > '$FM_HOME/UNSAFE-INJECTION'" "$FM_HOME/state"
  rc=$?
  set -e
  after=$(lab pane read "$PANE" --source visible --ansi)
  printf 'inject_msg: rc=%s attempted=%s reason=%s\n' "$rc" "$INJECT_SUBMIT_ATTEMPTED" "$INJECT_LAST_FAILURE"
  [ "$rc" != 0 ] && [ "$INJECT_SUBMIT_ATTEMPTED" = 0 ]
  [ "$before" = "$after" ] && [ ! -e "$FM_HOME/UNSAFE-INJECTION" ]
  printf 'The shell screen stayed identical. No command marker was created.\n'
  rm "$FM_HOME/state/.afk"
}
# Require the interactive shell to finish startup before sending a command.
ready=0
for ((i=0;i<100;i++)); do
  if lab pane process-info --pane "$PANE" | jq -e '.result.process_info as $p | ($p.foreground_processes|length)==1 and $p.foreground_processes[0].pid==$p.shell_pid' >/dev/null; then
    ready=$((ready+1)); [ "$ready" -lt 10 ] || break
  else ready=0; fi
  sleep 0.1
done
[ "$ready" -ge 10 ]
lab pane run "$PANE" "exec env PS1='❯ ' RPS1='' zsh -df" >/dev/null
for ((i=0;i<100;i++)); do
  if lab pane process-info --pane "$PANE" | jq -e '.result.process_info.foreground_processes as $p | ($p|length)==1 and ($p[0].argv|index("-df")!=null)' >/dev/null; then break; fi
  sleep 0.1
done
[ "$i" -lt 100 ]
sleep 0.2
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
capture shell-fresh unknown
baseline=$(. "$ROOT/.test-composer/base-composer-lib.sh"; fm_backend_herdr_composer_state "$TARGET")
printf 'Same live zsh pane with baseline composer library: %s\n' "$baseline"
[ "$baseline" = empty ]
refuse_injection
lab pane run "$PANE" "PS1=\$'\e[2m❯ \e[0m'" >/dev/null
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
capture shell-dim unknown
refuse_injection
lab pane run "$PANE" "PS1='❯ '; printf '\033[2J\033[H────────────────────────\n❯ \n────────────────────────\n'" >/dev/null
sleep 0.2
capture shell-stale-rules unknown
refuse_injection
mkdir -p "$FM_HOME/claude"
jq -n --arg path "$FM_HOME" '{hasCompletedOnboarding:true,theme:"dark",projects:{($path):{hasTrustDialogAccepted:true}}}' > "$FM_HOME/claude/.claude.json"
command_line=$(printf 'env CLAUDE_CONFIG_DIR=%q claude --bare --setting-sources ""' "$FM_HOME/claude")
lab pane run "$PANE" "$command_line" >/dev/null
wait_text 'for agents'
capture claude-empty empty
lab pane send-text "$PANE" 'Unsubmitted composer safety draft. This long draft must wrap and must remain protected from injection while the user edits the next sentence.' >/dev/null
wait_text 'Unsubmitted composer safety draft'
capture claude-draft pending
refuse_injection
fm_backend_herdr_composer_clear "$TARGET" 'Unsubmitted composer safety draft. This long draft must wrap and must remain protected from injection while the user edits the next sentence.'
capture claude-cleared empty
lab pane run "$PANE" /exit >/dev/null
for ((i=0;i<100;i++)); do
  if lab pane process-info --pane "$PANE" | jq -e '.result.process_info.foreground_processes as $p | ($p|length)==1 and $p[0].name=="zsh"' >/dev/null; then break; fi
  sleep 0.1
 done
[ "$i" -lt 100 ]
sleep 0.2
capture shell-after-exit unknown
refuse_injection
lab pane send-keys "$PANE" ctrl+l >/dev/null
sleep 0.2
capture shell-after-clear unknown
refuse_injection
printf 'Claude version: %s\n' "$(claude --version)"
printf 'All live scenarios passed.\n'
