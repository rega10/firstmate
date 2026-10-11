#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVID=/Users/rega1011/.no-mistakes/evidence/01M4ME7QJJSVHJPJFN5267GEYE
export TMPDIR="$ROOT/.test-session-tmp" FM_HERDR_LAB_STATE_DIR="$ROOT/.test-session-tmp/herdr-lab-state"
SCRATCH=$(mktemp -d "$TMPDIR/manual.XXXXXX")
REAL_PATH=$PATH
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name daemon-matrix)
cleanup() {
  rc=$?
  "$HELPER" teardown "$SESSION" || rc=1
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT
for case_name in missing empty intact explicit; do "$ROOT/bin/fm-lab-home.sh" create "$SCRATCH/$case_name" >/dev/null; done
mkdir -p "$SCRATCH/guard"
cat > "$SCRATCH/guard/herdr" <<'GUARD'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
printf '%s\n' "$*" >> "$SCRATCH/calls"
if [ "$n" -lt 2 ] || [ "${args[n-2]}" != --session ] || [ "${args[n-1]}" != "$SESSION" ]; then
  echo 'guard refused a missing or foreign session' >&2
  exit 98
fi
PATH="$REAL_PATH" exec "$HELPER" run "$SESSION" "${args[@]:0:n-2}"
GUARD
chmod +x "$SCRATCH/guard/herdr"
cat > "$SCRATCH/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
unset TMUX TMUX_PANE FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_DAEMON_PRIMARY_HARNESS=claude PATH="$SCRATCH/guard:$REAL_PATH"
printf 'real pane identity: %s:%s:%s\n' "$HERDR_ENV" "$HERDR_SESSION" "$HERDR_PANE_ID"
[ "$HERDR_SESSION" = "$SESSION" ]
PANE=$HERDR_PANE_ID
for case_name in missing empty; do
  export FM_HOME="$SCRATCH/$case_name"
  if [ "$case_name" = missing ]; then unset HERDR_SESSION; else export HERDR_SESSION=''; fi
  export HERDR_SOCKET_PATH="$SCRATCH/default/herdr.sock"
  rc=0
  bash "$ROOT/bin/fm-supervise-daemon.sh" > "$SCRATCH/$case_name.out" 2>&1 || rc=$?
  cat "$SCRATCH/$case_name.out"
  [ "$rc" -ne 0 ] && [ ! -s "$SCRATCH/calls" ]
  [ ! -e "$FM_HOME/state/.supervise-daemon.pid" ] && [ ! -d "$FM_HOME/state/.supervise-daemon.lock" ]
  printf '%s session: daemon exit=%s; no backend calls; pid and lock absent\n' "$case_name" "$rc"
done
for case_name in intact explicit; do
  export FM_HOME="$SCRATCH/$case_name"
  if [ "$case_name" = intact ]; then export HERDR_SESSION="$SESSION"; unset FM_SUPERVISOR_TARGET; else unset HERDR_SESSION; export FM_SUPERVISOR_TARGET="$SESSION:$PANE"; fi
  bash "$ROOT/bin/fm-supervise-daemon.sh" > "$SCRATCH/$case_name.out" 2>&1 &
  daemon_pid=$!
  cleanup_daemon() { kill -TERM "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" || true; }
  trap cleanup_daemon EXIT
  started=0
  for ((i=0; i<100; i++)); do
    if grep -q 'daemon starting' "$FM_HOME/state/.supervise-daemon.log" 2>/dev/null; then started=1; break; fi
    kill -0 "$daemon_pid" 2>/dev/null || break
    sleep .1
  done
  [ "$started" = 1 ] || { cat "$SCRATCH/$case_name.out"; exit 1; }
  cat "$FM_HOME/state/.supervise-daemon.log"
  cleanup_daemon
  trap - EXIT
  [ ! -e "$FM_HOME/state/.supervise-daemon.pid" ] && [ ! -d "$FM_HOME/state/.supervise-daemon.lock" ]
  printf '%s session: real daemon started against %s:%s and cleaned up\n' "$case_name" "$SESSION" "$PANE"
done
cat "$SCRATCH/calls"
touch "$SCRATCH/finished"
PROBE
printf 'export ROOT=%q SCRATCH=%q REAL_PATH=%q SESSION=%q HELPER=%q\nexec bash %q > %q 2>&1\n' "$ROOT" "$SCRATCH" "$REAL_PATH" "$SESSION" "$HELPER" "$SCRATCH/probe.sh" "$SCRATCH/results" > "$SCRATCH/launch.sh"
"$HELPER" provision "$SESSION"
ws=$("$HELPER" run "$SESSION" workspace create --cwd "$SCRATCH/intact" --label daemon-matrix --no-focus)
pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
"$HELPER" run "$SESSION" pane run "$pane" "$(printf 'bash %q' "$SCRATCH/launch.sh")" >/dev/null
for ((i=0; i<300; i++)); do [ ! -f "$SCRATCH/finished" ] || break; sleep .1; done
cat "$SCRATCH/results" | tee "$EVID/manual-daemon-matrix.log"
[ -f "$SCRATCH/finished" ]
