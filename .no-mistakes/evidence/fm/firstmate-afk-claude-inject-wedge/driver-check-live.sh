#!/usr/bin/env bash
set -u
source .live-validation/env.sh
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
lab() { env PATH="${PATH#*:}" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
. bin/fm-supervise-daemon.sh
fm_backend_source herdr
LOG="$E/live-guard-transcript.log"
cap() { lab pane read "$LIVE_PANE" --source visible > "$E/$1.txt"; lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/$1.ansi"; }
afk_enter "$FM_HOME/state"
cap titled-idle
fixed=$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")
( . .live-validation/base-composer.sh
  printf 'base classifier on live titled idle: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")"
  if inject_msg 'delivery baseline probe' "$FM_HOME/state"; then printf 'base unexpectedly submitted\n'; else printf 'base injection: %s\n' "$INJECT_LAST_FAILURE"; fi
) > "$E/baseline-comparison.log"
printf 'fixed classifier on same live titled idle: %s\n' "$fixed" >> "$E/baseline-comparison.log"
[ "$fixed" = empty ] || exit 1
lab pane send-text "$LIVE_PANE" 'CAPTAIN_DRAFT_DO_NOT_SUBMIT' >/dev/null
sleep 0.5
cap titled-draft
printf 'draft classifier: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")" > "$E/draft-protection.log"
printf 'needs-decision: live draft-protection event\n' > "$FM_HOME/state/.subsuper-escalations"
if escalate_flush "$FM_HOME/state"; then echo 'FAIL: alert submitted into draft'; exit 1; fi
printf 'draft injection refused: %s\n' "$INJECT_LAST_FAILURE" >> "$E/draft-protection.log"
printf 'buffer retained: '; cat "$FM_HOME/state/.subsuper-escalations"
lab pane read "$LIVE_PANE" --source visible > "$E/draft-after-refusal.txt"
lab pane send-keys "$LIVE_PANE" ctrl+u >/dev/null
sleep 0.3
printf 'after clearing draft: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")" >> "$E/draft-protection.log"
lab pane send-keys "$LIVE_PANE" left left >/dev/null
sleep 0.4
cap agents-view
printf 'agents-view classifier: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")" > "$E/agents-protection.log"
if escalate_flush "$FM_HOME/state"; then echo 'FAIL: alert submitted into agents view'; exit 1; fi
printf 'agents injection refused: %s\n' "$INJECT_LAST_FAILURE" >> "$E/agents-protection.log"
lab pane send-keys "$LIVE_PANE" esc >/dev/null
sleep 0.3
cap titled-return
printf 'restored titled composer: %s\n' "$(fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET")"
cat "$E/baseline-comparison.log" "$E/draft-protection.log" "$E/agents-protection.log"
