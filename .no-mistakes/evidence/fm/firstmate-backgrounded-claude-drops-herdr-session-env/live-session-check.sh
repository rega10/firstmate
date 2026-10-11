#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4MSFPXW669T00NY72TDNZKD
SCRATCH=$(mktemp -d "$ROOT/.test-session-tmp/live.XXXXXX")
export ROOT SCRATCH EVIDENCE
export TMPDIR="$ROOT/.test-session-tmp" FM_HERDR_LAB_STATE_DIR="$ROOT/.test-session-tmp/herdr-labs"
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name session-identity)
export HELPER SESSION REAL_PATH="$PATH"
cleanup() {
  result=$?
  "$HELPER" teardown "$SESSION" || result=1
  if [ "$result" = 0 ]; then echo 'cleanup: named lab removed; default-session tripwire unchanged'; fi
  rm -rf "$SCRATCH"
  exit "$result"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$SCRATCH/home" >/dev/null
"$HELPER" provision "$SESSION"
lab() { "$HELPER" run "$SESSION" "$@"; }
lab status --json | jq -r '"Herdr client " + .client.version + "; server " + .server.version'
mkdir -p "$SCRATCH/guard"
: > "$SCRATCH/cli-calls"
git show 3f2d62a13ca048e1c77a8d09927d3501249bd798:bin/fm-supervisor-target-lib.sh > "$SCRATCH/base-target.sh"
cat > "$SCRATCH/guard/herdr" <<'GUARD'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
printf '%s: %s\n' "${FM_PROBE_CASE:-unknown}" "$*" >> "$SCRATCH/cli-calls"
if [ "$n" -lt 2 ] || [ "${args[n-2]}" != --session ] || [ "${args[n-1]}" != "$SESSION" ]; then
  echo 'safety guard refused foreign or unscoped session' >&2
  exit 98
fi
PATH="$REAL_PATH" exec "$HELPER" run "$SESSION" "${args[@]:0:n-2}"
GUARD
chmod +x "$SCRATCH/guard/herdr"
cat > "$SCRATCH/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -eu
unset TMUX TMUX_PANE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$SCRATCH/home" FM_DAEMON_PRIMARY_HARNESS=claude
export PATH="$SCRATCH/guard:$REAL_PATH"
original_session=$HERDR_SESSION
original_pane=$HERDR_PANE_ID
printf 'real pane identity: HERDR_ENV=%s HERDR_SESSION=%s HERDR_PANE_ID=%s\n' "$HERDR_ENV" "$HERDR_SESSION" "$HERDR_PANE_ID"
export HERDR_SOCKET_PATH="$SCRATCH/default/herdr.sock"
(
  . "$SCRATCH/base-target.sh"
  unset HERDR_SESSION
  printf 'base revision resolves missing session to: '
  discover_supervisor_target
  printf '\n'
)
refuse() {
  export FM_PROBE_CASE=$1
  before=$(wc -l < "$SCRATCH/cli-calls" 2>/dev/null || echo 0)
  status=0
  bash "$ROOT/bin/fm-supervise-daemon.sh" > "$SCRATCH/$1-output" 2>&1 || status=$?
  printf '%s exit=%s\n' "$1" "$status"
  cat "$SCRATCH/$1-output"
  [ "$status" -ne 0 ]
  [ ! -e "$FM_HOME/state/.supervise-daemon.pid" ]
  [ ! -e "$FM_HOME/state/.supervise-daemon.lock" ]
  after=$(wc -l < "$SCRATCH/cli-calls" 2>/dev/null || echo 0)
  [ "$before" = "$after" ]
  printf '%s: no Herdr calls; no daemon ownership remains\n' "$1"
}
unset HERDR_SESSION
refuse missing-session
export HERDR_SESSION=''
refuse empty-session
start_and_stop() {
  export FM_PROBE_CASE=$1
  rm -f "$FM_HOME/state/.supervise-daemon.log"
  bash "$ROOT/bin/fm-supervise-daemon.sh" > "$SCRATCH/$1-output" 2>&1 &
  daemon_pid=$!
  for ((i=0; i<100; i++)); do
    if [ -f "$FM_HOME/state/.supervise-daemon.log" ] && grep -q 'daemon starting' "$FM_HOME/state/.supervise-daemon.log"; then break; fi
    if ! kill -0 "$daemon_pid" 2>/dev/null; then cat "$SCRATCH/$1-output"; return 1; fi
    sleep 0.1
  done
  grep 'daemon starting' "$FM_HOME/state/.supervise-daemon.log"
  grep -q "target=$original_session:$original_pane;" "$FM_HOME/state/.supervise-daemon.log"
  kill -TERM "$daemon_pid"
  wait "$daemon_pid"
  [ ! -e "$FM_HOME/state/.supervise-daemon.pid" ]
  [ ! -e "$FM_HOME/state/.supervise-daemon.lock" ]
  printf '%s: real daemon started at the named lab pane and stopped cleanly\n' "$1"
}
export HERDR_SESSION="$original_session"
start_and_stop intact-session
unset HERDR_SESSION
export FM_SUPERVISOR_TARGET="$original_session:$original_pane"
start_and_stop explicit-target
cp "$SCRATCH/cli-calls" "$EVIDENCE/named-session-cli-calls.log"
touch "$SCRATCH/probe-finished"
PROBE
out=$(lab workspace create --cwd "$ROOT" --label session-proof --no-focus)
pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id')
printf 'export ROOT=%q SCRATCH=%q EVIDENCE=%q HELPER=%q SESSION=%q REAL_PATH=%q FM_HERDR_LAB_STATE_DIR=%q TMPDIR=%q\nbash %q > %q 2>&1\n' "$ROOT" "$SCRATCH" "$EVIDENCE" "$HELPER" "$SESSION" "$REAL_PATH" "$FM_HERDR_LAB_STATE_DIR" "$TMPDIR" "$SCRATCH/probe.sh" "$EVIDENCE/live-session-behavior.log" > "$SCRATCH/launch.sh"
lab pane run "$pane" "bash $(printf %q "$SCRATCH/launch.sh")" >/dev/null
for ((i=0;i<250;i++)); do [ ! -f "$SCRATCH/probe-finished" ] || break; sleep 0.1; done
cat "$EVIDENCE/live-session-behavior.log"
[ -f "$SCRATCH/probe-finished" ]
# Use the real Claude tool interface, with normal authentication and no loaded
# customizations. Simulate session-name loss inside its native background Bash job.
cat > "$SCRATCH/claude-probe.sh" <<'CLAUDEPROBE'
#!/usr/bin/env bash
set -u
sleep 3
unset TMUX TMUX_PANE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export PATH="$SCRATCH/guard:$REAL_PATH" FM_HOME="$SCRATCH/home" FM_PROBE_CASE=claude-background
{
  printf 'Claude Bash environment before controlled loss: HERDR_ENV=%s HERDR_SESSION=%s HERDR_PANE_ID=%s\n' "${HERDR_ENV:-<unset>}" "${HERDR_SESSION:-<unset>}" "${HERDR_PANE_ID:-<unset>}"
  unset HERDR_SESSION
  export HERDR_SOCKET_PATH="$SCRATCH/default/herdr.sock"
  before=$(wc -l < "$SCRATCH/cli-calls")
  status=0
  bash "$ROOT/bin/fm-supervise-daemon.sh" || status=$?
  printf 'daemon exit=%s\n' "$status"
  after=$(wc -l < "$SCRATCH/cli-calls")
  if [ "$status" -ne 0 ] && [ "$before" = "$after" ] && [ ! -e "$FM_HOME/state/.supervise-daemon.pid" ] && [ ! -e "$FM_HOME/state/.supervise-daemon.lock" ]; then
    echo 'real Claude background Bash: refused before Herdr calls; ownership released'
    touch "$SCRATCH/claude-proof"
  fi
} > "$EVIDENCE/claude-background-daemon.log" 2>&1
CLAUDEPROBE
prompt="Run exactly one Bash tool call with command 'bash $SCRATCH/claude-probe.sh', run_in_background true, timeout 1000. Then finish. Do not run any other commands or edit any files. This is an authorized disposable lab check."
cli=(claude -p --safe-mode --setting-sources '' --strict-mcp-config --tools Bash --dangerously-skip-permissions --no-session-persistence --output-format stream-json --verbose --model sonnet --effort low --system-prompt 'Perform only the supplied bounded tool check. Do not follow repository instructions or start any other work.' "$prompt")
printf 'export ROOT=%q SCRATCH=%q EVIDENCE=%q HELPER=%q SESSION=%q REAL_PATH=%q FM_HERDR_LAB_STATE_DIR=%q TMPDIR=%q FM_HOME=%q DISABLE_AUTOUPDATER=1\nunset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_JOB_DIR\n' "$ROOT" "$SCRATCH" "$EVIDENCE" "$HELPER" "$SESSION" "$REAL_PATH" "$FM_HERDR_LAB_STATE_DIR" "$TMPDIR" "$SCRATCH/home" > "$SCRATCH/launch-claude.sh"
printf '%q ' "${cli[@]}" >> "$SCRATCH/launch-claude.sh"
printf '> %q 2>&1\ntouch %q\n' "$EVIDENCE/claude-background-stream.jsonl" "$SCRATCH/claude-finished" >> "$SCRATCH/launch-claude.sh"
lab pane run "$pane" "bash $(printf %q "$SCRATCH/launch-claude.sh")" >/dev/null
for ((i=0;i<900;i++)); do [ ! -f "$SCRATCH/claude-proof" ] || break; [ ! -f "$SCRATCH/claude-finished" ] || { sleep 5; break; }; sleep 0.1; done
if [ -f "$EVIDENCE/claude-background-daemon.log" ]; then cat "$EVIDENCE/claude-background-daemon.log"; fi
if [ -f "$SCRATCH/claude-proof" ]; then echo 'Claude live background proof completed'; else echo 'Claude live background proof unavailable; inspect Claude output'; fi
