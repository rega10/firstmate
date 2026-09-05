#!/usr/bin/env bash
# fm-claude-automic-vault.sh - captain-run setup, renewal, and redacted
# validation for Firstmate's local Claude Code Automic Vault opt-in.
#
# Usage:
#   fm-claude-automic-vault.sh provision
#   fm-claude-automic-vault.sh renew
#   fm-claude-automic-vault.sh enable
#   fm-claude-automic-vault.sh disable
#   fm-claude-automic-vault.sh preflight
#   fm-claude-automic-vault.sh status
#
# `provision` and `renew` run the officially supported `claude setup-token`
# ceremony under a quiet Expect relay, capture its long-lived token only in
# memory, and send it directly to `av save CLAUDE_CODE_OAUTH_TOKEN` through the
# save process's controlling terminal.
# Raw child output stays suppressed from the first setup-token byte through the
# last save byte, so neither command can display the token through this path.
# The tracked Expect relay receives only resolved executable paths in argv.
#
# `provision` enables the local opt-in only after the newly saved token passes
# the same redacted live preflight that every Firstmate Claude launch runs.
# `renew` requires an existing opt-in and leaves it enabled, including when the
# replacement token fails validation, so subsequent launches remain blocked.
# `enable` is the one-time recovery path when the correct secret already exists
# in this machine's Automic Vault: it validates first, then writes the flag.
# `disable` removes only the local flag and never reads, changes, or revokes the
# Vault secret or any Claude account token.
# `preflight` loads the token only through `av inject`, suppresses raw output,
# verifies first-party oauth_token classification, and makes one minimal
# non-persistent request to prove the service accepts the token.
# `status` reads only the local flag and never contacts Automic Vault or Claude.
#
# config/claude-automic-vault is the explicit local opt-in.
# Its only valid bytes are "on\n"; absence means disabled.
# docs/configuration.md owns the complete operator contract, including account
# revocation, renewal, recovery, inheritance, and the intentional live-check
# limitation.
set +x
unset BASH_XTRACEFD 2>/dev/null || true
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
EXPECT_RELAY="$SCRIPT_DIR/fm-claude-automic-vault.expect"

# shellcheck source=bin/fm-claude-automic-vault-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-claude-automic-vault-lib.sh"

usage() {
  cat <<'EOF'
Usage: fm-claude-automic-vault.sh <command>

Commands:
  provision  Generate a subscription token, save it directly to Automic Vault,
             validate it, and enable Firstmate Claude injection.
  renew      Replace the enabled token through the same direct ceremony and
             validate it.
  enable     Validate an existing Vault token, then enable local injection.
  disable    Remove only the local opt-in; do not change or revoke the secret.
  preflight  Run the redacted auth classification and minimal live validation.
  status     Report only whether the local opt-in is enabled.

No command prints, logs, copies, or accepts credential material as an argument.
Provision and renew intentionally suppress all raw setup-token and av save output.
Complete browser and Automic Vault Secret Gate prompts in their own application UI.
EOF
}

config_dir_safe() {
  if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    [ -d "$CONFIG" ] && [ ! -L "$CONFIG" ] || {
      printf 'error: config directory is not a regular directory: %s\n' "$CONFIG" >&2
      return 1
    }
  else
    mkdir -p "$CONFIG" || {
      printf 'error: could not create config directory: %s\n' "$CONFIG" >&2
      return 1
    }
  fi
}

enable_flag() {
  local path="$CONFIG/$FM_CLAUDE_AV_CONFIG_FILE" tmp
  config_dir_safe || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_claude_av_config_file_valid "$path" || {
      printf 'error: refusing to replace unsafe or invalid config/%s: %s\n' \
        "$FM_CLAUDE_AV_CONFIG_FILE" "$FM_CLAUDE_AV_ERROR" >&2
      return 1
    }
  fi
  tmp=$(mktemp "$CONFIG/.claude-automic-vault.XXXXXX" 2>/dev/null) || return 1
  if ! printf 'on\n' > "$tmp" || ! chmod 0600 "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp" 2>/dev/null || true
    printf 'error: could not atomically enable config/%s.\n' "$FM_CLAUDE_AV_CONFIG_FILE" >&2
    return 1
  fi
}

disable_flag() {
  local path="$CONFIG/$FM_CLAUDE_AV_CONFIG_FILE" state=0
  fm_claude_av_enabled "$CONFIG" || state=$?
  case "$state" in
    0) rm -f "$path" || { printf 'error: could not remove %s.\n' "$path" >&2; return 1; } ;;
    1) ;;
    2)
      printf 'error: refusing to remove unsafe or invalid config/%s: %s\n' \
        "$FM_CLAUDE_AV_CONFIG_FILE" "$FM_CLAUDE_AV_ERROR" >&2
      return 1
      ;;
  esac
  printf 'Claude Automic Vault authentication is disabled for this Firstmate home; no Vault secret or Claude account token was changed.\n'
}

resolve_and_probe() {
  fm_claude_av_resolve_tools && fm_claude_av_probe_tools
}

run_ceremony() {
  command -v expect >/dev/null 2>&1 || {
    printf 'error: provision and renew require Expect for the no-display terminal relay.\n' >&2
    return 1
  }
  [ -x "$EXPECT_RELAY" ] || {
    printf 'error: the tracked no-display terminal relay is unavailable: %s\n' "$EXPECT_RELAY" >&2
    return 1
  }
  fm_claude_av_probe_ceremony_tools || return 1
  printf 'Starting Claude setup-token with credential output suppressed.\n'
  printf 'Complete browser and Automic Vault approval prompts in their application windows.\n'
  expect "$EXPECT_RELAY" "$FM_CLAUDE_BIN" "$FM_CLAUDE_AV_BIN"
}

command=${1:-}
[ "$#" -le 1 ] || { usage >&2; exit 2; }
case "$command" in
  -h|--help|help)
    usage
    ;;
  status)
    state=0
    fm_claude_av_enabled "$CONFIG" || state=$?
    case "$state" in
      0) printf 'Claude Automic Vault authentication: enabled.\n' ;;
      1) printf 'Claude Automic Vault authentication: disabled.\n' ;;
      2) printf 'error: Claude Automic Vault opt-in is unsafe or invalid: %s.\n' "$FM_CLAUDE_AV_ERROR" >&2; exit 1 ;;
    esac
    ;;
  preflight)
    state=0
    fm_claude_av_enabled "$CONFIG" || state=$?
    case "$state" in
      0) ;;
      1) printf 'error: Claude Automic Vault authentication is disabled; run provision or enable first.\n' >&2; exit 1 ;;
      2) printf 'error: Claude Automic Vault opt-in is unsafe or invalid: %s.\n' "$FM_CLAUDE_AV_ERROR" >&2; exit 1 ;;
    esac
    if ! resolve_and_probe || ! fm_claude_av_preflight; then
      exit 1
    fi
    ;;
  enable)
    if ! resolve_and_probe || ! fm_claude_av_preflight || ! enable_flag; then
      exit 1
    fi
    printf 'Claude Automic Vault authentication is enabled for this Firstmate home.\n'
    ;;
  disable)
    disable_flag
    ;;
  provision)
    state=0
    fm_claude_av_enabled "$CONFIG" || state=$?
    case "$state" in
      0) printf 'error: the opt-in is already enabled; use renew to replace its token.\n' >&2; exit 1 ;;
      1) ;;
      2) printf 'error: Claude Automic Vault opt-in is unsafe or invalid: %s.\n' "$FM_CLAUDE_AV_ERROR" >&2; exit 1 ;;
    esac
    if ! resolve_and_probe || ! run_ceremony || ! fm_claude_av_preflight || ! enable_flag; then
      exit 1
    fi
    printf 'Claude token saved directly to Automic Vault, validated, and enabled for Firstmate launches.\n'
    ;;
  renew)
    state=0
    fm_claude_av_enabled "$CONFIG" || state=$?
    case "$state" in
      0) ;;
      1) printf 'error: the opt-in is disabled; use provision for initial setup.\n' >&2; exit 1 ;;
      2) printf 'error: Claude Automic Vault opt-in is unsafe or invalid: %s.\n' "$FM_CLAUDE_AV_ERROR" >&2; exit 1 ;;
    esac
    if ! resolve_and_probe || ! run_ceremony || ! fm_claude_av_preflight; then
      exit 1
    fi
    printf 'Claude token replaced directly in Automic Vault and validated for Firstmate launches.\n'
    ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    printf 'error: unknown command: %s\n' "$command" >&2
    usage >&2
    exit 2
    ;;
esac
