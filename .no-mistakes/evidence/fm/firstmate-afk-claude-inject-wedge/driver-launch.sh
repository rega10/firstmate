#!/usr/bin/env bash
set -e
source .live-validation/env.sh
lab() { env PATH="${PATH#*:}" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
lab workspace create --cwd "$PWD" --label fm-away-test --no-focus > .live-validation/workspace.json
PANE=$(python3 -c 'import json; print(json.load(open(".live-validation/workspace.json"))["result"]["root_pane"]["pane_id"])')
printf '\nexport LIVE_PANE=%s\nexport FM_SUPERVISOR_TARGET="$LIVE_SESSION:$LIVE_PANE"\n' "$PANE" >> .live-validation/env.sh
source .live-validation/env.sh
lab pane run "$LIVE_PANE" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID FM_HOME='$FM_HOME' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 CLAUDE_SECURESTORAGE_CONFIG_DIR='' CLAUDE_CONFIG_DIR='$FM_HOME/claude-config' claude --safe-mode --name 'Firstmate operational input' --permission-mode auto --settings '{\"disableAllHooks\":true,\"feedbackDrafts\":\"off\",\"theme\":\"dark-ansi\"}' --tools '' --system-prompt 'You are an isolated delivery validation session. Reply briefly to each message with DELIVERED. Do not run tools or change files.'"
