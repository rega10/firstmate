#!/bin/bash
case "$*" in *fm-branch-dispatch.mjs\ offer*)
n=$(cat "$FM_HOME/offers" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FM_HOME/offers"
if [ "$n" = 2 ] && [ -e "$FM_HOME/pause-offer" ]; then
 touch "$FM_HOME/second-offer-ready"
 while [ ! -e "$FM_HOME/release-offer" ]; do sleep 0.05; done
fi
;; esac
exec "/Users/rega1011/.nvm/versions/node/v24.20.0/bin/node" "$@"
