#!/usr/bin/env bash
set -e
ROOT=$PWD
D="$ROOT/.live-validation-r2"
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
export FM_HERDR_LAB_STATE_DIR="$D/lab-state"
S=$(bin/fm-herdr-lab.sh name afk-r2)
LAB=$(mktemp -d "$D/home.XXXXXX")
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/claude-config"
python3 - "$LAB/claude-config/.claude.json" "$ROOT" <<'PYCONFIG'
import json,sys
json.dump({"hasCompletedOnboarding":True,"theme":"dark-ansi","projects":{sys.argv[2]:{"hasTrustDialogAccepted":True}}},open(sys.argv[1],'w'))
PYCONFIG
export TMPDIR="$D/tmp"
bin/fm-herdr-lab.sh provision "$S"
printf 'export LIVE_SESSION=%q FM_HOME=%q FM_HERDR_LAB_STATE_DIR=%q TMPDIR=%q\n' "$S" "$LAB" "$D/lab-state" "$D/tmp" > "$D/env.sh"
printf 'export ORIGINAL_PATH=%q\n' "$PATH" >> "$D/env.sh"
bin/fm-herdr-lab.sh viewer start "$S"
bin/fm-herdr-lab.sh run "$S" workspace create --cwd "$ROOT" --label afk-r2 > "$D/workspace.json"
PANE=$(jq -r '.result.root_pane.pane_id' "$D/workspace.json")
printf 'export LIVE_PANE=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=herdr FM_DAEMON_PRIMARY_HARNESS=claude\n' "$PANE" "$S:$PANE" >> "$D/env.sh"
cat > "$D/shim/herdr" <<'SHIM'
#!/usr/bin/env bash
set -e
args=()
session=
while [ "$#" -gt 0 ]; do
 case "$1" in
  --session) session=$2; shift 2 ;;
  --session=*) session=${1#*=}; shift ;;
  *) args+=("$1"); shift ;;
 esac
done
[ "$session" = "$LIVE_SESSION" ] || { echo 'refused non-lab call' >&2; exit 1; }
PATH="$ORIGINAL_PATH" exec "$PWD/bin/fm-herdr-lab.sh" run "$session" "${args[@]}"
SHIM
chmod +x "$D/shim/herdr"
printf 'export PATH=%q:"$PATH"\n' "$D/shim" >> "$D/env.sh"
cat > "$D/start-claude.sh" <<START
#!/usr/bin/env bash
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID FM_HOME='$LAB' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 CLAUDE_SECURESTORAGE_CONFIG_DIR='' CLAUDE_CONFIG_DIR='$LAB/claude-config' claude --safe-mode --name 'Firstmate operational input' --permission-mode auto --settings '{"disableAllHooks":true,"feedbackDrafts":"off","theme":"dark-ansi"}' --tools '' --system-prompt 'You are an isolated alert delivery validation session. Respond briefly with DELIVERED to each message. Do not change files or run tools.'
START
chmod +x "$D/start-claude.sh"
bin/fm-herdr-lab.sh run "$S" pane run "$PANE" "bash '$D/start-claude.sh'"
git show 7fe423cdb73a6fef168a5b25ee77b40a25a71596:bin/fm-composer-lib.sh > "$D/base-composer.sh"
printf 'off\n' > "$LAB/config/wedge-alarm"
printf 'session=%s\npane=%s\nhome=%s\n' "$S" "$PANE" "$LAB"
