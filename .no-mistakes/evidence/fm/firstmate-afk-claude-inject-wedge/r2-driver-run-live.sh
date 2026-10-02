#!/usr/bin/env bash
set -e
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
D="$PWD/.live-validation-r2"
daemon=
cleanup() {
 rc=$?
 trap - EXIT
 if [ -n "$daemon" ]; then kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true; fi
 if [ -n "${LIVE_SESSION:-}" ]; then PATH="$ORIGINAL_PATH" bin/fm-herdr-lab.sh teardown "$LIVE_SESSION" >> "$E/r2-cleanup.log" 2>&1 || rc=1; fi
 [ -z "${LAB:-}" ] || rm -rf "$LAB"
 printf 'lab removed; cleanup exit=%s\n' "$rc" >> "$E/r2-cleanup.log"
 exit "$rc"
}
trap cleanup EXIT
. "$D/setup.sh"
. "$D/env.sh"
lab() { env PATH="$ORIGINAL_PATH" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
cap() { lab pane read "$LIVE_PANE" --source visible > "$E/r2-$1.txt"; lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/r2-$1.ansi"; }
. bin/fm-supervise-daemon.sh
fm_backend_source herdr
LOG="$E/r2-live.log"
fail() { echo "FAIL: $*" | tee -a "$LOG"; exit 1; }
for i in $(seq 1 50); do
 cap initial
 if rg -q 'Claude Code v2' "$E/r2-initial.txt" && ! rg -q 'Welcome to Claude|Choose the text style' "$E/r2-initial.txt"; then break; fi
 sleep 0.4
done
cat "$E/r2-initial.txt"
# Accept disposable config-only onboarding when it appears.
if rg -q 'Choose the text style|Choose.*theme' "$E/r2-initial.txt"; then lab pane send-keys "$LIVE_PANE" enter >/dev/null; sleep 1; cap initial; fi
if rg -q 'Quick safety check|Is this a project' "$E/r2-initial.txt"; then lab pane send-keys "$LIVE_PANE" enter >/dev/null; sleep 1; fi
cap titled-idle
fixed=$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")
process=$(fm_backend_herdr_pane_process_state "$LIVE_SESSION" "$LIVE_PANE")
printf 'titled composer: target=%s process=%s\n' "$fixed" "$process" | tee "$LOG"
[ "$fixed" = empty ] || fail 'titled idle not empty'
[ "$process" = agent ] || fail 'real Claude not detected'
afk_enter "$FM_HOME/state"
(
 . "$D/base-composer.sh"
 printf 'base on live composer: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")"
) > "$E/r2-baseline.log"
cat "$E/r2-baseline.log"
# Draft and persistent-defer behavior from a real running daemon.
lab pane send-text "$LIVE_PANE" CAPTAIN_DRAFT_DO_NOT_SUBMIT >/dev/null
sleep 0.5
cap draft-before
export FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_MAX_DEFER_SECS=3 FM_STALE_ESCALATE_SECS=999999
bin/fm-supervise-daemon.sh > "$E/r2-daemon-stdout.log" 2> "$E/r2-daemon-stderr.log" &
daemon=$!
sleep 2
printf 'needs-decision: R2_LIVE_AFK_DELIVERY choose proceed or wait\n' > "$FM_HOME/state/lab-event.status"
sleep 12
cap draft-after
cp "$FM_HOME/state/.supervise-daemon.log" "$E/r2-daemon-pending.log"
[ -s "$FM_HOME/state/.subsuper-escalations" ] || fail 'pending escalation lost'
[ -s "$FM_HOME/state/.subsuper-inject-wedged" ] || fail 'persistent draft did not raise wedge alarm'
rg -q 'CAPTAIN_DRAFT_DO_NOT_SUBMIT' "$E/r2-draft-after.txt" || fail 'draft altered'
if rg -q 'Firstmate operational input waiting:' "$E/r2-draft-after.txt"; then fail 'injected into draft'; fi
cp "$FM_HOME/state/.subsuper-escalations" "$E/r2-buffer-pending.txt"
echo 'PASS: draft preserved, escalation retained, wedge alarm raised without injection' | tee -a "$LOG"
lab pane send-keys "$LIVE_PANE" ctrl+u >/dev/null
sleep 12
cap delivered
cp "$FM_HOME/state/.supervise-daemon.log" "$E/r2-daemon-delivered.log"
rg -q 'Firstmate operational input waiting:' "$E/r2-delivered.txt" || fail 'daemon alert did not reach Claude'
[ ! -s "$FM_HOME/state/.subsuper-escalations" ] || fail 'delivered buffer not cleared'
[ ! -s "$FM_HOME/state/.subsuper-inject-wedged" ] || fail 'wedge not cleared after delivery'
records=$(ls "$FM_HOME/state/operational-inbox/"*.msg | wc -l | tr -d ' ')
[ "$records" = 1 ] || fail "duplicate deliveries: $records records"
for f in "$FM_HOME/state/operational-inbox/"*.msg; do cp "$f" "$E/r2-$(basename "$f")"; done
echo 'PASS: titled idle received one daemon alert; buffer and wedge cleared' | tee -a "$LOG"
kill "$daemon"; wait "$daemon" 2>/dev/null || true; daemon=
# Overlay and presence guards execute the real production injection function.
lab pane send-keys "$LIVE_PANE" left >/dev/null
sleep 1
lab pane send-keys "$LIVE_PANE" left >/dev/null
sleep 1
cap agents-view
if ! rg -q 'describe a task for a new session|Agents|agents view|agent sessions' "$E/r2-agents-view.txt"; then
 lab pane send-keys "$LIVE_PANE" left >/dev/null
 sleep 1
 cap agents-view
fi
if ! rg -q 'describe a task for a new session' "$E/r2-agents-view.txt"; then
 echo 'Agents overlay did not open; retaining running lab for inspection'
 sleep 45
 cap agents-view
fi
rg -q 'describe a task for a new session' "$E/r2-agents-view.txt" || fail 'setup could not open agents overlay'
printf 'needs-decision: agents view refusal\n' > "$FM_HOME/state/.subsuper-escalations"
if escalate_flush "$FM_HOME/state"; then fail 'injected into agents view'; fi
printf 'PASS: agents view refusal: %s; submit-attempt=%s\n' "$INJECT_LAST_FAILURE" "$INJECT_SUBMIT_ATTEMPTED" | tee -a "$LOG"
[ -s "$FM_HOME/state/.subsuper-escalations" ] || fail 'agents buffer lost'
lab pane send-keys "$LIVE_PANE" esc >/dev/null
sleep 0.4
afk_exit "$FM_HOME/state"
cap attended-before
if inject_msg ATTENDED_REFUSAL "$FM_HOME/state"; then fail 'injected while attended'; fi
printf 'PASS: attended refusal: %s; submit-attempt=%s\n' "$INJECT_LAST_FAILURE" "$INJECT_SUBMIT_ATTEMPTED" | tee -a "$LOG"
cap attended-after
cmp "$E/r2-attended-before.txt" "$E/r2-attended-after.txt" || fail 'attended pane changed'
afk_enter "$FM_HOME/state"
# Exit to the actual login shell and preserve any remaining agent registration.
lab pane send-text "$LIVE_PANE" /exit >/dev/null
sleep 0.5
lab pane send-keys "$LIVE_PANE" enter >/dev/null
sleep 1.5
cap shell-before
lab pane process-info --pane "$LIVE_PANE" > "$E/r2-shell-process.json"
lab agent get "$LIVE_PANE" > "$E/r2-shell-agent.json" 2>&1 || true
process=$(fm_backend_herdr_pane_process_state "$LIVE_SESSION" "$LIVE_PANE")
composer=$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")
printf 'after exit: process=%s composer=%s\n' "$process" "$composer" | tee -a "$LOG"
[ "$process" = shell ] || fail 'Claude did not exit to shell'
if escalate_flush "$FM_HOME/state"; then fail 'escalation injected into shell'; fi
printf 'PASS: exited shell refused: %s; submit-attempt=%s\n' "$INJECT_LAST_FAILURE" "$INJECT_SUBMIT_ATTEMPTED" | tee -a "$LOG"
[ "$INJECT_SUBMIT_ATTEMPTED" = 0 ] || fail 'transport attempted into shell'
[ -s "$FM_HOME/state/.subsuper-escalations" ] || fail 'shell guard lost escalation'
cap shell-after
cmp "$E/r2-shell-before.txt" "$E/r2-shell-after.txt" || fail 'shell received text'
lab pane close "$LIVE_PANE" >/dev/null
if inject_msg CLOSED_PANE_REFUSAL "$FM_HOME/state"; then fail 'closed pane accepted injection'; fi
printf 'PASS: closed pane refused: %s; submit-attempt=%s\n' "$INJECT_LAST_FAILURE" "$INJECT_SUBMIT_ATTEMPTED" | tee -a "$LOG"
echo 'COMPLETE' | tee -a "$LOG"
