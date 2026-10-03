#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M3Y4Q2SWE72H5FAK6A4D2HPN
export TMPDIR="$ROOT/.test-phase/tmp" FM_HERDR_LAB_STATE_DIR="$ROOT/.test-phase/herdr"
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$(bash "$HELPER" name phase-lifecycle)
LAB="$ROOT/.test-phase/lifecycle-home"
bash bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME="$LAB"
PID=
cleanup() {
  rc=$?
  trap - EXIT
  [ -z "$PID" ] || { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; }
  env PATH="${ORIGINAL_PATH:-$PATH}" bash "$HELPER" teardown "$SESSION" || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
bash "$HELPER" provision "$SESSION"
ORIGINAL_PATH=$PATH
mkdir -p "$LAB/routebin"
cat > "$LAB/routebin/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
args=("\${args[@]:0:\$((n-2))}")
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$LAB/routebin/herdr"
export PATH="$LAB/routebin:$ORIGINAL_PATH"
WS=$(bash "$HELPER" run "$SESSION" workspace create --cwd "$ROOT" --label lifecycle --no-focus)
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id')
export FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$SESSION:$PANE" HERDR_SESSION="$SESSION" FM_DAEMON_PRIMARY_HARNESS=codex FM_POLL=1 FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=9999 FM_MAX_DEFER_SECS=0 FM_WEDGE_ALARM_CHANNEL=off
# Real daemon, real Herdr target, disposable interrupted-delivery records.
printf '%s\n' "$(date +%s)" > "$LAB/state/.afk"
printf 'old.status: done: captured before interruption\n' > "$LAB/state/.subsuper-escalations"
printf 'undelivered remainder\n' > "$LAB/state/.subsuper-escalations.remaining.interrupted"
printf 'in-flight head\n' > "$LAB/state/.subsuper-escalations.chunk.interrupted"
mkdir -p "$LAB/state/.subsuper-digests"
printf 'source A retained after return\n' > "$LAB/state/.subsuper-digests/digest-retained"
bash bin/fm-supervise-daemon.sh > "$LAB/daemon.out" 2> "$LAB/daemon.err" & PID=$!
for i in {1..30}; do [ ! -f "$LAB/state/.supervise-daemon.pid" ] || break; sleep 0.2; done
[ -f "$LAB/state/.supervise-daemon.pid" ]
printf 'Before return: daemon PID=%s, both interrupted checkpoints exist\n' "$PID"
bash bin/fm-afk-return.sh begin
wait "$PID"; PID=
[ ! -e "$LAB/state/.subsuper-escalations.remaining.interrupted" ]
[ ! -e "$LAB/state/.subsuper-escalations.chunk.interrupted" ]
[ "$(cat "$LAB/state/.subsuper-digests/digest-retained")" = 'source A retained after return' ]
printf 'After return: checkpoint files removed; durable source retained\n'
# Seed another prior-session interruption to drive the fresh-entry boundary.
printf 'prior remainder\n' > "$LAB/state/.subsuper-escalations.remaining.previous"
printf 'prior head\n' > "$LAB/state/.subsuper-escalations.chunk.previous"
bash bin/fm-afk-start.sh > "$LAB/start.out" 2> "$LAB/start.err" & PID=$!
for i in {1..30}; do [ ! -f "$LAB/state/.supervise-daemon.pid" ] || break; sleep 0.2; done
[ -f "$LAB/state/.supervise-daemon.pid" ]
[ ! -e "$LAB/state/.subsuper-escalations.remaining.previous" ]
[ ! -e "$LAB/state/.subsuper-escalations.chunk.previous" ]
printf 'done: fresh-entry-event\n' > "$LAB/state/new.status"
for i in {1..40}; do
  if [ -f "$LAB/state/.subsuper-escalations" ] && rg -q 'fresh-entry-event' "$LAB/state/.subsuper-escalations"; then break; fi
  sleep 0.25
done
cat "$LAB/state/.subsuper-escalations"
rg -q 'fresh-entry-event' "$LAB/state/.subsuper-escalations"
printf 'Fresh entry: real daemon re-derived and buffered the new status event\n'
rm -f "$LAB/state/.afk"
kill "$PID"; wait "$PID"; PID=
cp "$LAB/state/.supervise-daemon.log" "$EVIDENCE/lifecycle-daemon.log"
# Drive real startup on both sides of the approved record-carrier path bound.
export FM_DAEMON_PRIMARY_HARNESS=claude
for length in 616 617 800; do
  home="$ROOT/.test-phase/long-$length"
  while [ "${#home}" -lt "$((length - 6))" ]; do
    amount=$((length - 6 - ${#home} - 1)); [ "$amount" -le 80 ] || amount=80
    home="$home/$(printf '%*s' "$amount" '' | tr ' ' p)"
  done
  bash bin/fm-lab-home.sh create "$home" >/dev/null
  state="$home/state"
  printf 'Record startup with physical state path %s bytes\n' "${#state}"
  if [ "$length" -eq 616 ]; then
    FM_HOME="$home" bash bin/fm-supervise-daemon.sh > "$home/out" 2> "$home/err" & PID=$!
    for i in {1..30}; do [ ! -f "$state/.supervise-daemon.pid" ] || break; sleep 0.2; done
    [ -f "$state/.supervise-daemon.pid" ]; kill "$PID"; wait "$PID"; PID=
    printf 'Accepted: daemon acquired supervision ownership at the boundary\n'
  else
    set +e
    FM_HOME="$home" bash bin/fm-supervise-daemon.sh > "$home/out" 2> "$home/err"
    code=$?
    set -e
    cat "$home/err"
    [ "$code" -ne 0 ]
    [ "$(rg -c '^error:' "$home/err")" -eq 1 ]
    [ ! -e "$state/.supervise-daemon.pid" ] && [ ! -e "$state/.supervise-daemon.lock" ]
    printf 'Refused once before ownership; exit=%s\n' "$code"
  fi
  rm -rf "$ROOT/.test-phase/long-$length"
done
