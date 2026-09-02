#!/usr/bin/env bash
# fm-claude-automic-vault-launch.sh - redacted interactive launch boundary for
# an opted-in Claude Code worker.
set -u

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-claude-automic-vault-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-claude-automic-vault-lib.sh"

[ "$#" -ge 4 ] || exit 2
av=$1
claude=$2
expected_sha256=$3
settings=$4
shift 4

platform=$(fm_claude_av_release_platform) || {
  printf 'error: could not retain the attested Claude Code identity through launch on this platform.\n' >&2
  exit 1
}
actual_sha256=$(fm_claude_av_artifact_sha256 "$claude" "$platform") || {
  printf 'error: could not revalidate the attested Claude Code executable immediately before launch.\n' >&2
  exit 1
}
if [ "$actual_sha256" != "$expected_sha256" ]; then
  printf 'error: refusing Claude launch because the attested Claude Code executable changed after preflight.\n' >&2
  exit 1
fi

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
  "$FM_CLAUDE_AV_BASH" --noprofile --norc "$0" \
  --injected "$ready" "$claude" "$settings" "$@" \
  3>&1 4>&2 > "$output_pipe" 2>&1 || status=$?
wait "$capture_pid" || true
find "$launch_root" -depth -delete 2>/dev/null || true
exit "$status"
