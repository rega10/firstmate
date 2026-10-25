#!/bin/bash
case "$*" in *'/.watcher-down.tmp.'*) [ ! -e "$FM_HOME/fail-write" ] || exit 1 ;; esac
exec "/usr/bin/mktemp" "$@"
