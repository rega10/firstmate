#!/usr/bin/env bash
set -u
source .live-validation/env.sh
E=/Users/rega1011/.no-mistakes/evidence/01M3Y5SF2JZ46B611HN6SRDQFX
lab() { env PATH="${PATH#*:}" bin/fm-herdr-lab.sh run "$LIVE_SESSION" "$@"; }
printf 'off\n' > "$FM_HOME/config/wedge-alarm"
rm -f "$FM_HOME/state/.subsuper-escalations" "$FM_HOME/state/.subsuper-escalations.since"
export FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_MAX_DEFER_SECS=30 FM_STALE_ESCALATE_SECS=999999
bin/fm-supervise-daemon.sh > "$E/daemon-stdout.log" 2> "$E/daemon-stderr.log" &
daemon=$!
cleanup() { rm -f "$FM_HOME/state/.afk"; kill "$daemon" 2>/dev/null || true; wait "$daemon" 2>/dev/null || true; }
trap cleanup EXIT
sleep 2
printf 'needs-decision: LIVE_AFK_DELIVERY_1790941000 choose proceed or wait\n' > "$FM_HOME/state/lab-event.status"
sleep 12
lab pane read "$LIVE_PANE" --source visible > "$E/daemon-delivery.txt"
lab pane read "$LIVE_PANE" --source visible --format ansi > "$E/daemon-delivery.ansi"
cp "$FM_HOME/state/.supervise-daemon.log" "$E/daemon.log"
if [ -d "$FM_HOME/state/operational-inbox" ]; then
 for f in "$FM_HOME/state/operational-inbox/"*.msg; do [ -f "$f" ] && cp "$f" "$E/$(basename "$f")"; done
fi
printf 'daemon delivery output:\n'
cat "$E/daemon.log"
