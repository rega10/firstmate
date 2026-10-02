#!/usr/bin/env bash
set -u
source .live-validation/env.sh
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
LIVE_PANE=w2:p1
export FM_SUPERVISOR_TARGET="$LIVE_SESSION:$LIVE_PANE"
lab() { env PATH="${PATH#*:}" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
. bin/fm-supervise-daemon.sh
fm_backend_source herdr
LOG="$E/live-guard-transcript.log"
afk_enter "$FM_HOME/state"
lab pane read "$LIVE_PANE" --source visible > "$E/dead-shell-before.txt"
lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/dead-shell-before.ansi"
lab pane process-info --pane "$LIVE_PANE" > "$E/dead-shell-process.json"
{
 printf 'fixed classifier on real exited Claude shell: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")"
 ( . .live-validation/base-composer.sh; printf 'base classifier on same shell: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")" )
 # Claude's record-backed doorbell begins with ':' and is harmless shell input.
 if inject_msg 'DEAD_SHELL_REFUSAL_PROBE' "$FM_HOME/state"; then echo 'injection returned success'; else printf 'injection returned failure: %s\n' "$INJECT_LAST_FAILURE"; fi
 printf 'transport attempted: %s\n' "$INJECT_SUBMIT_ATTEMPTED"
} > "$E/dead-shell-guard.log"
lab pane read "$LIVE_PANE" --source visible > "$E/dead-shell-after.txt"
lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/dead-shell-after.ansi"
cat "$E/dead-shell-guard.log"
