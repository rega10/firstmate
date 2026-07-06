#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written. Hosted
# Codex seatbelt shells may deny process inspection, so CODEX_THREAD_ID is used
# as the owner token when ancestry cannot provide a PID.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'
HOLDER_LIVE_KIND=

codex_owner_token() {
  [ -n "${CODEX_THREAD_ID:-}" ] || return 1
  [ "${CODEX_SANDBOX:-}" = seatbelt ] || return 1
  printf 'codex:%s\n' "$CODEX_THREAD_ID"
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in
      ''|*[!0-9]*) break ;;
    esac
    [ "$pid" -gt 1 ] || break
  done
  codex_owner_token && return 0
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  HOLDER_LIVE_KIND=
  case "$pid" in
    codex:*)
      HOLDER_LIVE_KIND=codex
      return 0
      ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || {
    if [ -n "${CODEX_THREAD_ID:-}" ] && [ "${CODEX_SANDBOX:-}" = seatbelt ]; then
      HOLDER_LIVE_KIND=uninspectable_pid
      return 0
    fi
    return 1
  }
  if printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"; then
    HOLDER_LIVE_KIND=harness_pid
    return 0
  fi
  return 1
}

holder_description() {
  local owner=$1
  case "$HOLDER_LIVE_KIND" in
    codex) printf 'hosted Codex session %s\n' "$owner" ;;
    uninspectable_pid) printf 'uninspectable live holder pid %s\n' "$owner" ;;
    harness_pid) printf 'live harness pid %s\n' "$owner" ;;
    *) printf 'live holder %s\n' "$owner" ;;
  esac
}

lock_error_owner() {
  local owner=$1
  case "$HOLDER_LIVE_KIND" in
    codex) printf 'hosted Codex session %s\n' "$owner" ;;
    uninspectable_pid) printf 'uninspectable live holder pid %s\n' "$owner" ;;
    harness_pid) printf 'pid %s\n' "$owner" ;;
    *) printf 'owner %s\n' "$owner" ;;
  esac
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then
    echo "lock: held by $(holder_description "$old")"
  else
    echo "lock: stale ($old dead or not a harness)"
  fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock ($(lock_error_owner "$old")); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
case "$me" in
  codex:*) echo "lock acquired: harness $me" ;;
  *) echo "lock acquired: harness pid $me" ;;
esac
