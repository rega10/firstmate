#!/usr/bin/env bash
set -u
source .live-validation/env.sh
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
lab() { env PATH="${PATH#*:}" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
. bin/fm-supervise-daemon.sh
fm_backend_source herdr
LOG="$E/live-guard-transcript.log"
lab pane read "$LIVE_PANE" --source visible > "$E/agents-view.txt"
lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/agents-view.ansi"
printf 'needs-decision: live agents-protection event\n' > "$FM_HOME/state/.subsuper-escalations"
{
 printf 'agents-view classifier: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")"
 if escalate_flush "$FM_HOME/state"; then echo 'FAIL: submitted into agents view'; exit 1; fi
 printf 'agents injection refused: %s\n' "$INJECT_LAST_FAILURE"
 printf 'buffer retained: '; cat "$FM_HOME/state/.subsuper-escalations"
} > "$E/agents-protection.log"
lab pane send-keys "$LIVE_PANE" esc >/dev/null
sleep 0.4
lab pane read "$LIVE_PANE" --source visible > "$E/titled-return.txt"
lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/titled-return.ansi"
cat "$E/agents-protection.log"
printf 'restored titled composer: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")"
