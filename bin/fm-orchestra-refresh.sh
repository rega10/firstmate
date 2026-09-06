#!/usr/bin/env bash
# fm-orchestra-refresh.sh - best-effort live Orchestra board refresh.
#
# The optional local config/orchestra-dashboard file contains exactly one line:
# the absolute path of an Orchestra checkout whose bin/orchestra-dashboard is
# executable. An absent or invalid configuration is a silent successful no-op.
#
# Each invocation makes one best-effort `orchestra-dashboard refresh` call and
# discards its output. Every configured outcome exits zero so this side band can
# never change its watcher's result. Orchestra owns rebuild rate limiting and
# coalescing, including the guaranteed trailing rebuild for overlapping calls.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/orchestra-dashboard"

[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || exit 0
checkout=$(sed -n '1p' "$CONFIG_FILE" 2>/dev/null) || exit 0
lines=$(awk 'END { print NR }' "$CONFIG_FILE" 2>/dev/null) || exit 0
[ "$lines" -eq 1 ] || exit 0
case "$checkout" in /*) ;; *) exit 0 ;; esac
DASHBOARD="$checkout/bin/orchestra-dashboard"
[ -x "$DASHBOARD" ] || exit 0
"$DASHBOARD" refresh >/dev/null 2>&1 || true
exit 0
