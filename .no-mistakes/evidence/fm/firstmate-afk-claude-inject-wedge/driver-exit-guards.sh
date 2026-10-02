#!/usr/bin/env bash
set -u
source .live-validation/env.sh
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
lab() { env PATH="${PATH#*:}" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
. bin/fm-supervise-daemon.sh
fm_backend_source herdr
afk_enter "$FM_HOME/state"
LOG="$E/live-guard-transcript.log"
lab pane send-text "$LIVE_PANE" /exit >/dev/null
lab pane send-keys "$LIVE_PANE" enter >/dev/null
sleep 1
lab pane read "$LIVE_PANE" --source visible > "$E/exited-shell.txt"
lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/exited-shell.ansi"
lab pane process-info --pane "$LIVE_PANE" > "$E/exited-process.json"
state=$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")
printf 'exited-shell classifier: %s\n' "$state" > "$E/exit-guards.log"
if [ "$state" = empty ]; then echo 'FAIL: dead-shell is injectable'; exit 1; fi
if inject_msg 'dead-shell guard probe' "$FM_HOME/state"; then echo 'FAIL: injected into dead shell'; exit 1; fi
printf 'exited injection refused: %s\n' "$INJECT_LAST_FAILURE" >> "$E/exit-guards.log"
lab pane close "$LIVE_PANE" >/dev/null
printf 'closed-pane classifier: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")" >> "$E/exit-guards.log"
if inject_msg 'closed-pane guard probe' "$FM_HOME/state"; then echo 'FAIL: injected into closed pane'; exit 1; fi
printf 'closed-pane injection refused: %s\n' "$INJECT_LAST_FAILURE" >> "$E/exit-guards.log"
cat "$E/exit-guards.log"
