#!/usr/bin/env bash
# fm-claude-automic-vault-launch.sh - redacted interactive launch boundary for
# an opted-in Claude Code worker.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-claude-automic-vault-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-claude-automic-vault-lib.sh"

if [ "${1:-}" = --injected ]; then
  [ "$#" -ge 4 ] || exit 2
  ready=$2
  claude=$3
  settings=$4
  shift 4
  : > "$ready" || exit 1
  exec 1>&3 2>&4 3>&- 4>&-
  exec "$claude" --settings "$settings" "$@"
fi

[ "$#" -ge 3 ] || exit 2
av=$1
claude=$2
settings=$3
shift 3

launch_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-launch.XXXXXX" 2>/dev/null) || {
  printf 'error: could not create the private temporary state required for Claude injection.\n' >&2
  exit 1
}
ready="$launch_root/injected"
output_pipe="$launch_root/output"
mkfifo "$output_pipe" || {
  find "$launch_root" -depth -delete 2>/dev/null || true
  printf 'error: could not initialize the private output channel required for Claude injection.\n' >&2
  exit 1
}

capture_inject_output() {
  local output
  output=$(sed -n '1,$p')
  if [ ! -e "$ready" ]; then
    fm_claude_av_classify_inject_failure "$output"
  fi
}

status=0
capture_inject_output < "$output_pipe" >&2 &
capture_pid=$!
"$av" inject --replace-existing-env "+$FM_CLAUDE_AV_SECRET_NAME" -- \
  "$0" --injected "$ready" "$claude" "$settings" "$@" \
  3>&1 4>&2 > "$output_pipe" 2>&1 || status=$?
wait "$capture_pid" || true
find "$launch_root" -depth -delete 2>/dev/null || true
exit "$status"
