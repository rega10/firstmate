#!/usr/bin/env bash
# fm-claude-automic-vault-launch.sh - redacted interactive launch boundary for
# an opted-in Claude Code worker.
set -u

if [ "${1:-}" = --sanitize ]; then
  [ "$#" -ge 4 ] || exit 2
  clean_env=$2
  worker_path=$3
  shift 3
  clean_environment=(
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1
  )
  [ -z "$worker_path" ] || clean_environment+=("FM_CLAUDE_AV_WORKER_PATH=$worker_path")
  while IFS= read -r environment_name; do
    case "$environment_name" in
      CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|ANTHROPIC_BEDROCK_BASE_URL|ANTHROPIC_VERTEX_BASE_URL|ANTHROPIC_FOUNDRY_BASE_URL|CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_USE_VERTEX|CLAUDE_CODE_USE_FOUNDRY|FM_CLAUDE_AV_WORKER_PATH|BASH_FUNC_*|BASH_ENV|ENV|SHELLOPTS|BASHOPTS|PS4|CDPATH|IFS|PROMPT_COMMAND|LD_*|DYLD_*|PATH|CLAUDE_CODE_SUBPROCESS_ENV_SCRUB) continue ;;
      HOME|USER|LOGNAME|SHELL|TERM|COLORTERM|TERM_PROGRAM|TERM_PROGRAM_VERSION|COLORFGBG|TMPDIR|TMP|TEMP|GOTMPDIR|LANG|TZ|SSH_AUTH_SOCK|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|SSL_CERT_FILE|SSL_CERT_DIR|NODE_EXTRA_CA_CERTS|LC_*|XDG_*|CLAUDE_*|ANTHROPIC_*|FM_*|TRACEPARENT|TRACESTATE|TMUX|TMUX_PANE|HERDR_*|ZELLIJ*|CMUX_*) ;;
      *) continue ;;
    esac
    case "$(declare -p "$environment_name" 2>/dev/null)" in
      declare\ -x*) clean_environment+=("$environment_name=${!environment_name}") ;;
    esac
  done < <(compgen -A variable)
  builtin exec "$clean_env" -i "${clean_environment[@]}" "$@"
fi

if [ "${1:-}" = --injected ]; then
  [ "$#" -ge 4 ] || exit 2
  ready=$2
  claude=$3
  settings=$4
  shift 4
  worker_path=${FM_CLAUDE_AV_WORKER_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  unset FM_CLAUDE_AV_WORKER_PATH
  worker_args=()
  for worker_arg in "$@"; do
    [ "$worker_arg" = --dangerously-skip-permissions ] || worker_args+=("$worker_arg")
  done
  : > "$ready" || exit 1
  exec 1>&3 2>&4 3>&- 4>&-
  PATH=$worker_path
  export PATH
  exec "$claude" --settings "$settings" --permission-mode bypassPermissions "${worker_args[@]}"
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

launch_parent=${claude%/versions/*}
launch_root=
cleanup_launch_root() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$launch_root" ]; then
    find "$launch_root" -depth -delete 2>/dev/null || true
  fi
  exit "$status"
}
launch_root=$(mktemp -d "$launch_parent/.firstmate-launch.XXXXXX" 2>/dev/null) || {
  printf 'error: could not create the private same-filesystem state required for Claude injection.\n' >&2
  exit 1
}
trap cleanup_launch_root EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
pinned_claude="$launch_root/${claude##*/}"
if ! ln "$claude" "$pinned_claude" 2>/dev/null; then
  printf 'error: could not pin the attested Claude Code file object for launch.\n' >&2
  exit 1
fi
platform=$(fm_claude_av_release_platform) || {
  printf 'error: could not retain the attested Claude Code identity through launch on this platform.\n' >&2
  exit 1
}
actual_sha256=$(fm_claude_av_artifact_sha256 "$pinned_claude" "$platform") || {
  printf 'error: could not revalidate the attested Claude Code executable immediately before launch.\n' >&2
  exit 1
}
if [ "$actual_sha256" != "$expected_sha256" ]; then
  printf 'error: refusing Claude launch because the attested Claude Code executable changed after preflight.\n' >&2
  exit 1
fi

ready="$launch_root/injected"
output_pipe="$launch_root/output"
mkfifo "$output_pipe" || {
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
  --injected "$ready" "$pinned_claude" "$settings" "$@" \
  3>&1 4>&2 > "$output_pipe" 2>&1 || status=$?
wait "$capture_pid" || true
exit "$status"
