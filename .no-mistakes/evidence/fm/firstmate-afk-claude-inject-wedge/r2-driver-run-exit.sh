#!/usr/bin/env bash
set -e
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
D="$PWD/.live-validation-r2"
cleanup() {
 rc=$?
 trap - EXIT
 if [ -n "${LIVE_SESSION:-}" ]; then PATH="$ORIGINAL_PATH" bin/fm-herdr-lab.sh teardown "$LIVE_SESSION" >> "$E/r2-exit-cleanup.log" 2>&1 || rc=1; fi
 [ -z "${LAB:-}" ] || rm -rf "$LAB"
 printf 'lab removed; cleanup exit=%s\n' "$rc" >> "$E/r2-exit-cleanup.log"
 exit "$rc"
}
trap cleanup EXIT
. "$D/setup.sh"
. "$D/env.sh"
lab() { env PATH="$ORIGINAL_PATH" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
cap() { lab pane read "$LIVE_PANE" --source visible > "$E/r2-exit-$1.txt"; lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/r2-exit-$1.ansi"; }
. bin/fm-supervise-daemon.sh
fm_backend_source herdr
LOG="$E/r2-exit-live.log"
for i in $(seq 1 60); do
 cap initial
 if rg -q 'Claude Code v2' "$E/r2-exit-initial.txt"; then break; fi
 sleep 0.4
done
sleep 1
afk_enter "$FM_HOME/state"
# Use the real adapter's slash settle and submit confirmation rather than
# assuming that the popup's first Enter has exited the CLI.
verdict=$(fm_backend_send_text_submit herdr "$FM_SUPERVISOR_TARGET" /exit 6 0.5 0.5)
printf 'exit submit verdict=%s\n' "$verdict" | tee "$LOG"
for i in $(seq 1 20); do
 process=$(fm_backend_herdr_pane_process_state "$LIVE_SESSION" "$LIVE_PANE")
 [ "$process" = shell ] && break
 sleep 0.3
done
cap shell-before
lab pane process-info --pane "$LIVE_PANE" > "$E/r2-exit-shell-process.json"
lab agent get "$LIVE_PANE" > "$E/r2-exit-shell-agent.json" 2>&1 || true
composer=$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")
printf 'after Claude exit: process=%s composer=%s\n' "$process" "$composer" | tee -a "$LOG"
[ "$process" = shell ] || { echo 'FAIL: harness did not exit' | tee -a "$LOG"; exit 1; }
printf 'needs-decision: dead-shell refusal probe\n' > "$FM_HOME/state/.subsuper-escalations"
if escalate_flush "$FM_HOME/state"; then echo 'FAIL: injected into shell' | tee -a "$LOG"; exit 1; fi
printf 'PASS: shell refusal: %s; submit-attempt=%s\n' "$INJECT_LAST_FAILURE" "$INJECT_SUBMIT_ATTEMPTED" | tee -a "$LOG"
[ "$INJECT_SUBMIT_ATTEMPTED" = 0 ]
[ -s "$FM_HOME/state/.subsuper-escalations" ]
cap shell-after
cmp "$E/r2-exit-shell-before.txt" "$E/r2-exit-shell-after.txt"
lab pane close "$LIVE_PANE" >/dev/null
if inject_msg CLOSED_PANE_REFUSAL "$FM_HOME/state"; then echo 'FAIL: closed pane accepted injection' | tee -a "$LOG"; exit 1; fi
printf 'PASS: closed pane refused: %s; submit-attempt=%s\n' "$INJECT_LAST_FAILURE" "$INJECT_SUBMIT_ATTEMPTED" | tee -a "$LOG"
echo COMPLETE | tee -a "$LOG"
