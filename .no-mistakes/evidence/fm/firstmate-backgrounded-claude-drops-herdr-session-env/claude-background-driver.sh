#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVID=/Users/rega1011/.no-mistakes/evidence/01M4ME7QJJSVHJPJFN5267GEYE
export TMPDIR="$ROOT/.test-session-tmp" FM_HERDR_LAB_STATE_DIR="$ROOT/.test-session-tmp/herdr-lab-state"
SCRATCH=$(mktemp -d "$TMPDIR/claude.XXXXXX")
REAL_PATH=$PATH
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name claude-env-loss)
UUID=$(python3 -c 'import uuid; print(uuid.uuid4())')
cleanup() {
  rc=$?
  if [ -f "$SCRATCH/launched" ]; then claude stop "$UUID" >> "$EVID/claude-background-cleanup.log" 2>&1 || true; fi
  "$HELPER" teardown "$SESSION" || rc=1
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$SCRATCH/home" >/dev/null
mkdir -p "$SCRATCH/guard"
cat > "$SCRATCH/guard/herdr" <<'GUARD'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
printf '%s\n' "$*" >> "$SCRATCH/calls"
if [ "$n" -lt 2 ] || [ "${args[n-2]}" != --session ] || [ "${args[n-1]}" != "$SESSION" ]; then
  echo 'guard refused missing or foreign session' >&2
  exit 98
fi
PATH="$REAL_PATH" exec "$HELPER" run "$SESSION" "${args[@]:0:n-2}"
GUARD
chmod +x "$SCRATCH/guard/herdr"
cat > "$SCRATCH/claude-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
printf 'Claude Bash environment: HERDR_ENV=%s HERDR_SESSION=%s HERDR_PANE_ID=%s HERDR_SOCKET_PATH=%s\n' "${HERDR_ENV:-<unset>}" "${HERDR_SESSION:-<unset>}" "${HERDR_PANE_ID:-<unset>}" "${HERDR_SOCKET_PATH:-<unset>}" > "$SCRATCH/result"
# Keep only this lab's durable variables; never allow inherited fleet homes.
unset TMUX TMUX_PANE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$SCRATCH/home" PATH="$SCRATCH/guard:$REAL_PATH" FM_DAEMON_PRIMARY_HARNESS=claude
# Exercise the acceptance boundary even if this Claude build preserves identity.
unset HERDR_SESSION
export HERDR_ENV=1 HERDR_PANE_ID="$LAB_PANE" HERDR_SOCKET_PATH="$SCRATCH/default/herdr.sock"
rc=0
bash "$ROOT/bin/fm-supervise-daemon.sh" >> "$SCRATCH/result" 2>&1 || rc=$?
printf 'daemon exit=%s\n' "$rc" >> "$SCRATCH/result"
if [ "$rc" -ne 0 ] && [ ! -s "$SCRATCH/calls" ] && [ ! -e "$FM_HOME/state/.supervise-daemon.pid" ] && [ ! -d "$FM_HOME/state/.supervise-daemon.lock" ]; then
  echo 'refusal confirmed: no backend call, no pidfile, no lock' >> "$SCRATCH/result"
  touch "$SCRATCH/probe-pass"
fi
touch "$SCRATCH/probe-finished"
cat "$SCRATCH/result"
PROBE
"$HELPER" provision "$SESSION"
ws=$("$HELPER" run "$SESSION" workspace create --cwd "$SCRATCH/home" --label claude-env-loss --no-focus)
pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
# Launch from a short command, and avoid project/global hooks and MCP servers.
printf 'export ROOT=%q SCRATCH=%q REAL_PATH=%q SESSION=%q HELPER=%q LAB_PANE=%q FM_HOME=%q\n' "$ROOT" "$SCRATCH" "$REAL_PATH" "$SESSION" "$HELPER" "$pane" "$SCRATCH/home" > "$SCRATCH/launch.sh"
cat >> "$SCRATCH/launch.sh" <<'LAUNCH'
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_JOB_DIR
LAUNCH
prompt="Use only the Bash tool to execute this exact command once: bash '$SCRATCH/claude-probe.sh'. Do not run any other command or modify any other file. Then state the command output. This is an isolated validation scenario."
printf 'claude --background --session-id %q --dangerously-skip-permissions --setting-sources %q --settings %q --strict-mcp-config --mcp-config %q --tools Bash --allowedTools Bash --disable-slash-commands --system-prompt %q %q > %q 2>&1\nprintf "%%s\\n" "$?" > %q\ntouch %q\n' "$UUID" '' '{"disableAllHooks":true}' '{"mcpServers":{}}' 'You are a product test driver. Follow the supplied command exactly. Do not delegate, load skills, run startup routines, or read unrelated files.' "$prompt" "$SCRATCH/launch-output" "$SCRATCH/launch-status" "$SCRATCH/launched" >> "$SCRATCH/launch.sh"
"$HELPER" run "$SESSION" pane run "$pane" "$(printf 'bash %q' "$SCRATCH/launch.sh")" >/dev/null
for ((i=0; i<600; i++)); do [ ! -f "$SCRATCH/probe-finished" ] || break; sleep .1; done
cat "$SCRATCH/launch-output" | tee "$EVID/claude-background-launch.log"
if [ -f "$SCRATCH/result" ]; then cat "$SCRATCH/result" | tee "$EVID/claude-background-result.log"; fi
if [ -f "$SCRATCH/launched" ]; then claude logs "$UUID" > "$EVID/claude-background-transcript.log" 2>&1 || true; fi
"$HELPER" run "$SESSION" pane read "$pane" --source visible > "$EVID/claude-background-pane.txt"
[ -f "$SCRATCH/probe-pass" ]
