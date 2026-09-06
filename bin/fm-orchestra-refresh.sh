#!/usr/bin/env bash
# fm-orchestra-refresh.sh - best-effort live Orchestra board refresh.
#
# The optional local config/orchestra-dashboard file contains exactly one line:
# the absolute path of an Orchestra checkout whose bin/orchestra-dashboard is
# executable. An absent or invalid configuration is a silent successful no-op.
#
# Each invocation makes at most one foreground `orchestra-dashboard refresh`
# call. A home-local nonblocking lock drops overlapping triggers, including
# triggers from a successor watcher, because Orchestra's active caller already
# guarantees its own trailing rebuild. FM_ORCHESTRA_REFRESH_TIMEOUT (default 60
# seconds) bounds the call through bin/fm-timeout-lib.sh. Exit 0 (rebuilt) and 3
# (coalesced into Orchestra's trailing rebuild) are success. Exit 2, timeout,
# and every unexpected nonzero exit append a bounded, rate-limited line to
# state/.orchestra-dashboard-refresh.log. The notice interval is controlled by
# FM_ORCHESTRA_FAILURE_NOTICE_SECS (default 3600 seconds) and resets after a
# success. Every configured outcome exits zero so this side band can never
# change its watcher's result.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/orchestra-dashboard"
REFRESH_TIMEOUT=${FM_ORCHESTRA_REFRESH_TIMEOUT:-60}
FAILURE_NOTICE_SECS=${FM_ORCHESTRA_FAILURE_NOTICE_SECS:-3600}
FAILURE_LOG="$STATE/.orchestra-dashboard-refresh.log"
FAILURE_NOTICE_MARKER="$STATE/.orchestra-dashboard-refresh-failure-noticed"
FAILURE_LOG_MAX_BYTES=${FM_ORCHESTRA_FAILURE_LOG_MAX_BYTES:-16384}
REFRESH_LOCK="$STATE/.orchestra-dashboard-refresh.lock"
REFRESH_LOCK_HELD=0

case "$REFRESH_TIMEOUT" in ''|*[!0-9]*|0) REFRESH_TIMEOUT=60 ;; esac
case "$FAILURE_NOTICE_SECS" in ''|*[!0-9]*|0) FAILURE_NOTICE_SECS=3600 ;; esac
case "$FAILURE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) FAILURE_LOG_MAX_BYTES=16384 ;; esac

[ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || exit 0
checkout=$(sed -n '1p' "$CONFIG_FILE" 2>/dev/null) || exit 0
lines=$(awk 'END { print NR }' "$CONFIG_FILE" 2>/dev/null) || exit 0
[ "$lines" -eq 1 ] || exit 0
case "$checkout" in /*) ;; *) exit 0 ;; esac
DASHBOARD="$checkout/bin/orchestra-dashboard"
[ -x "$DASHBOARD" ] || exit 0
mkdir -p "$STATE" 2>/dev/null || exit 0

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

orchestra_refresh_cleanup() {
  if [ "$REFRESH_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REFRESH_LOCK"
    REFRESH_LOCK_HELD=0
  fi
}

orchestra_failure_notice_due() {
  local marker_mtime now
  [ -e "$FAILURE_NOTICE_MARKER" ] || return 0
  if [ "$(uname)" = Darwin ]; then
    marker_mtime=$(stat -f %m "$FAILURE_NOTICE_MARKER" 2>/dev/null) || return 0
  else
    marker_mtime=$(stat -c %Y "$FAILURE_NOTICE_MARKER" 2>/dev/null) || return 0
  fi
  now=$(date +%s 2>/dev/null) || return 0
  [ "$(( now - marker_mtime ))" -ge "$FAILURE_NOTICE_SECS" ]
}

orchestra_log_failure() {  # <exit-status>
  local rc=$1 detail size tmp
  orchestra_failure_notice_due || return 0
  case "$rc" in
    2) detail="refresh failed before publishing a complete replacement" ;;
    124) detail="refresh exceeded its ${REFRESH_TIMEOUT}-second deadline" ;;
    *) detail="refresh failed with unexpected exit $rc" ;;
  esac
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$detail" \
    >> "$FAILURE_LOG" 2>/dev/null || return 0
  touch "$FAILURE_NOTICE_MARKER" 2>/dev/null || true
  size=$(wc -c < "$FAILURE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge "$FAILURE_LOG_MAX_BYTES" ]; then
    tmp="$FAILURE_LOG.tmp.${BASHPID:-$$}"
    tail -n 100 "$FAILURE_LOG" > "$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$FAILURE_LOG" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

fm_lock_try_acquire "$REFRESH_LOCK" || exit 0
REFRESH_LOCK_HELD=1
trap orchestra_refresh_cleanup EXIT
trap 'exit 0' HUP INT TERM

if fm_run_timed "$REFRESH_TIMEOUT" "$DASHBOARD" refresh >/dev/null 2>&1; then
  refresh_rc=0
else
  refresh_rc=$?
fi
case "$refresh_rc" in
  0|3) rm -f -- "$FAILURE_NOTICE_MARKER" 2>/dev/null || true ;;
  *) orchestra_log_failure "$refresh_rc" ;;
esac
exit 0
