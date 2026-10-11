#!/usr/bin/env bash
# Reproduce a background tool losing HERDR_SESSION before starting the real
# supervisor daemon, inside a real named Herdr pane and a disposable FM_HOME.
# The CLI guard records and refuses every foreign target before it can reach
# Herdr. All permitted calls and lifecycle cleanup use fm-herdr-lab.sh.
# This simulates the reported environment loss; it does not launch Claude.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-backgrounded-claude-drops-herdr-session-env)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-supervisor-session.XXXXXX")
REAL_PATH=$PATH
cleanup() {
  local result=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || result=1
  "$LAB_HOME_HELPER" teardown "$SCRATCH/home" || result=1
  rm -rf "$SCRATCH"
  exit "$result"
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$SCRATCH/home" >/dev/null
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
lab status --json | jq -r '"Herdr client " + .client.version + "; server " + .server.version'

mkdir -p "$SCRATCH/guard"
cat > "$SCRATCH/guard/herdr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
printf '%s\n' "$*" >> "$SCRATCH/cli-calls"
if [ "$n" -lt 2 ] || [ "${args[n-2]}" != --session ] \
    || [ "${args[n-1]}" != "$HERDR_LAB_SESSION" ]; then
  echo 'test guard refused missing or foreign session' >&2
  exit 98
fi
PATH="$REAL_PATH" exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]:0:n-2}"
SH
chmod +x "$SCRATCH/guard/herdr"

cat > "$SCRATCH/probe.sh" <<'SH'
#!/usr/bin/env bash
set -u
unset TMUX TMUX_PANE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND \
  FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$SCRATCH/home" FM_DAEMON_PRIMARY_HARNESS=claude
export PATH="$SCRATCH/guard:$REAL_PATH"
. "$ROOT/bin/fm-supervisor-target-lib.sh"
# Keep Herdr's real pane identity and establish the successful counterfactual.
printf '%s\n' "${HERDR_ENV:-}:${HERDR_SESSION:-}:${HERDR_PANE_ID:-}" > "$SCRATCH/identity"
discover_supervisor_target > "$SCRATCH/intact-target"
# Drop only the session name first, isolating the cause from the socket value.
unset HERDR_SESSION
discover_supervisor_target > "$SCRATCH/lost-target" 2> "$SCRATCH/lost-error"
printf '%s\n' "$?" > "$SCRATCH/lost-status"
# A default-shaped socket must not let daemon startup recover a guessed target.
export HERDR_SOCKET_PATH="$SCRATCH/default/herdr.sock"
bash "$ROOT/bin/fm-supervise-daemon.sh" > "$SCRATCH/daemon-output" 2>&1
printf '%s\n' "$?" > "$SCRATCH/daemon-status"
touch "$SCRATCH/finished"
SH

out=$(lab workspace create --cwd "$SCRATCH/home" --label session-loss --no-focus)
pane=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id')
# Keep the terminal input short even when the worktree and inherited PATH are
# long: a large inline environment can exceed the pane's input capacity.
printf 'export ROOT=%q SCRATCH=%q REAL_PATH=%q HERDR_LAB_SESSION=%q HERDR_LAB_HELPER=%q\nexec bash %q\n' \
  "$ROOT" "$SCRATCH" "$REAL_PATH" "$HERDR_LAB_SESSION" "$HERDR_LAB_HELPER" "$SCRATCH/probe.sh" \
  > "$SCRATCH/launch.sh"
pane_command=$(printf 'bash %q' "$SCRATCH/launch.sh")
lab pane run "$pane" "$pane_command" >/dev/null
for ((i=0; i<300; i++)); do
  [ ! -f "$SCRATCH/finished" ] || break
  sleep 0.1
done
[ -f "$SCRATCH/finished" ] || { echo 'not ok - daemon probe did not finish' >&2; exit 1; }
[ "$(cat "$SCRATCH/identity")" = "1:$HERDR_LAB_SESSION:$pane" ] \
  || { echo 'not ok - real Herdr pane did not supply the expected identity' >&2; exit 1; }
[ "$(cat "$SCRATCH/intact-target")" = "$HERDR_LAB_SESSION:$pane" ] \
  || { echo 'not ok - intact session failed to resolve' >&2; exit 1; }
printf 'intact target: %s\nlost-session target: %s\n' \
  "$(cat "$SCRATCH/intact-target")" "$(cat "$SCRATCH/lost-target")"
if [ -s "$SCRATCH/cli-calls" ]; then
  cat "$SCRATCH/cli-calls"
  echo 'not ok - daemon attempted a Herdr call after losing session identity' >&2
  exit 1
fi
[ "$(cat "$SCRATCH/lost-status")" != 0 ] && [ ! -s "$SCRATCH/lost-target" ] \
  || { echo 'not ok - missing session resolved a target' >&2; exit 1; }
[ "$(cat "$SCRATCH/daemon-status")" != 0 ] \
  || { echo 'not ok - daemon accepted missing session identity' >&2; exit 1; }
grep -q 'HERDR_SESSION' "$SCRATCH/daemon-output" \
  || { cat "$SCRATCH/daemon-output"; echo 'not ok - daemon omitted session diagnostic' >&2; exit 1; }
[ ! -e "$SCRATCH/home/state/.supervise-daemon.pid" ] \
  && [ ! -d "$SCRATCH/home/state/.supervise-daemon.lock" ] \
  || { echo 'not ok - refused daemon retained its ownership record' >&2; exit 1; }
echo 'ok - real Herdr daemon refuses lost session identity before any backend call'
