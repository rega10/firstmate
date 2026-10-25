#!/bin/bash
n=$(cat "$FM_HOME/stops" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FM_HOME/stops"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$FM_HOME/hook.$n.out" 2> "$FM_HOME/hook.$n.err"
rc=$?
cat "$FM_HOME/hook.$n.err" >&2
echo "$rc" > "$FM_HOME/hook.$n.rc"
if [ "$rc" = 2 ]; then mv "$FM_HOME/state/demo.meta" "$FM_HOME/demo.meta.saved" 2>/dev/null || true; fi
exit "$rc"
