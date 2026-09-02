# shellcheck shell=bash
# fm-claude-automic-vault-lib.sh - the executable owner of Firstmate's
# opt-in Claude Code authentication through Automic Vault.
#
# The contract is deliberately narrow:
#   - config/claude-automic-vault must be a regular, singly linked file whose
#     exact bytes are "on\n"; absence is disabled and every other artifact is a
#     launch blocker for a concrete Claude harness;
#   - the concrete `av` and `claude` executables are resolved once before
#     endpoint creation, canonicalized through symlinks, and kept as absolute
#     paths in the launch command;
#   - the resolved Claude executable must be the canonical native executable in
#     Claude Code's versioned install tree, match Anthropic's release-manifest
#     checksum, and produce structured auth status from an isolated empty home
#     before any Vault command can run;
#   - the token value enters only the Claude process environment through
#     `av inject --replace-existing-env +CLAUDE_CODE_OAUTH_TOKEN`;
#   - higher-precedence API-key, cloud-provider, and endpoint overrides are
#     cleared, and inline settings disable apiKeyHelper and matching auth env
#     settings, so Vault failure can never fall back to another credential;
#   - preflight first verifies Claude's redacted auth classification and then
#     makes one minimal non-persistent request, because `auth status` reports an
#     arbitrary non-empty OAuth token as logged in without validating it;
#   - raw Automic Vault and Claude output is classified in memory and never
#     printed or written by this library.
#
# The operator workflow and security boundaries are documented once in
# docs/configuration.md under "Claude authentication through Automic Vault".
# bin/fm-claude-automic-vault.sh owns the captain-run ceremony and calls these
# functions; bin/fm-spawn.sh calls fm_claude_av_prepare_launch only after the
# concrete harness is known to be Claude.

FM_CLAUDE_AV_CONFIG_FILE=claude-automic-vault
FM_CLAUDE_AV_SECRET_NAME=CLAUDE_CODE_OAUTH_TOKEN
FM_CLAUDE_AV_TIMEOUT=${FM_CLAUDE_AV_TIMEOUT:-45}
FM_CLAUDE_AV_RELEASE_BASE=https://downloads.claude.ai/claude-code-releases
FM_CLAUDE_AV_MANIFEST_CHECKSUMS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-claude-automic-vault-manifests.sha256"
FM_CLAUDE_AV_SETTINGS='{"apiKeyHelper":null,"env":{"ANTHROPIC_API_KEY":null,"ANTHROPIC_AUTH_TOKEN":null,"ANTHROPIC_BASE_URL":null,"ANTHROPIC_BEDROCK_BASE_URL":null,"ANTHROPIC_VERTEX_BASE_URL":null,"ANTHROPIC_FOUNDRY_BASE_URL":null,"CLAUDE_CODE_USE_BEDROCK":null,"CLAUDE_CODE_USE_VERTEX":null,"CLAUDE_CODE_USE_FOUNDRY":null,"AWS_BEARER_TOKEN_BEDROCK":null}}'
FM_CLAUDE_AV_ERROR=
FM_CLAUDE_AV_BIN=
FM_CLAUDE_BIN=
FM_CLAUDE_AV_CURL_BIN=/usr/bin/curl
FM_CLAUDE_AV_CLAUDE_SHA256=
FM_CLAUDE_AV_BASH=/bin/bash
FM_CLAUDE_AV_ENV=/usr/bin/env
FM_CLAUDE_AV_LAUNCH_RELAY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-claude-automic-vault-launch.sh"
# shellcheck disable=SC2034 # Consumed by callers after fm_claude_av_prepare_launch returns.
FM_CLAUDE_AV_LAUNCH_COMMAND=

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

fm_claude_av_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_claude_av_config_file_valid() {  # <path>
  local path=$1 bytes
  FM_CLAUDE_AV_ERROR=
  if [ -L "$path" ]; then
    FM_CLAUDE_AV_ERROR="file is symlinked"
    return 1
  fi
  if [ ! -f "$path" ]; then
    FM_CLAUDE_AV_ERROR="artifact is not a regular file"
    return 1
  fi
  if [ "$(fm_claude_av_link_count "$path")" != 1 ]; then
    FM_CLAUDE_AV_ERROR="file is hardlinked"
    return 1
  fi
  bytes=$(wc -c < "$path" 2>/dev/null) || {
    FM_CLAUDE_AV_ERROR="file is unreadable"
    return 1
  }
  bytes=${bytes//[[:space:]]/}
  if [ "$bytes" != 3 ] || [ "$(cat "$path" 2>/dev/null)" != on ]; then
    FM_CLAUDE_AV_ERROR='expected exact bytes "on\n"'
    return 1
  fi
  return 0
}

# Returns 0 for enabled, 1 for absent/disabled, and 2 for an unsafe or malformed
# opt-in that must block a concrete Claude launch.
fm_claude_av_enabled() {  # <config-dir>
  local config=$1 path="$1/$FM_CLAUDE_AV_CONFIG_FILE"
  FM_CLAUDE_AV_ERROR=
  if [ -e "$config" ] || [ -L "$config" ]; then
    if [ ! -d "$config" ] || [ -L "$config" ]; then
      FM_CLAUDE_AV_ERROR="config directory is not a regular directory"
      return 2
    fi
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 1
  fi
  if ! fm_claude_av_config_file_valid "$path"; then
    return 2
  fi
  return 0
}

fm_claude_av_realpath() {  # <path>
  local path=$1 link dir hops=0
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 32 ] || return 1
    link=$(readlink "$path" 2>/dev/null) || return 1
    case "$link" in
      /*) path=$link ;;
      *) path="$(dirname "$path")/$link" ;;
    esac
  done
  [ -f "$path" ] && [ -x "$path" ] || return 1
  dir=$(CDPATH='' cd -- "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$(basename "$path")"
}

fm_claude_av_resolve_named_executable() {  # <name>
  local candidate
  candidate=$(type -P -- "$1" 2>/dev/null) || return 1
  fm_claude_av_realpath "$candidate"
}

fm_claude_av_is_native_install_artifact() {  # <resolved-claude>
  local executable=$1 artifact_type version major minor patch
  version=${executable##*/}
  major=${version%%.*}
  minor=${version#*.}
  [ "$minor" != "$version" ] || return 1
  patch=${minor#*.}
  [ "$patch" != "$minor" ] || return 1
  minor=${minor%%.*}
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] || return 1
  case "$major:$minor:$patch" in *[!0-9:]*|::*|*::|*:*:*:*) return 1 ;; esac
  case "$executable" in
    */.local/share/claude/versions/"$version") ;;
    *) return 1 ;;
  esac
  artifact_type=$(/usr/bin/file -b -- "$executable" 2>/dev/null) || return 1
  case "$artifact_type" in
    *Mach-O*executable*|*ELF*executable*|*PE32*executable*) return 0 ;;
  esac
  return 1
}

fm_claude_av_release_platform() {
  local os arch translated=0 ldd_bin=
  os=$(/usr/bin/uname -s 2>/dev/null) || return 1
  arch=$(/usr/bin/uname -m 2>/dev/null) || return 1
  case "$os" in
    Darwin)
      if [ "$arch" = x86_64 ] && [ -x /usr/sbin/sysctl ]; then
        translated=$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || true)
        [ "$translated" != 1 ] || arch=arm64
      fi
      os=darwin
      ;;
    Linux) os=linux ;;
    *) return 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch=x64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) return 1 ;;
  esac
  if [ "$os" = linux ]; then
    if [ -e /lib/libc.musl-x86_64.so.1 ] || [ -e /lib/libc.musl-aarch64.so.1 ]; then
      os=linux-musl
    else
      [ ! -x /usr/bin/ldd ] || ldd_bin=/usr/bin/ldd
      [ -n "$ldd_bin" ] || [ ! -x /bin/ldd ] || ldd_bin=/bin/ldd
      if [ -n "$ldd_bin" ]; then
        case $("$ldd_bin" /bin/ls 2>&1) in *musl*) os=linux-musl ;; esac
      fi
    fi
  fi
  case "$os" in
    linux-musl) printf 'linux-%s-musl\n' "$arch" ;;
    *) printf '%s-%s\n' "$os" "$arch" ;;
  esac
}

fm_claude_av_artifact_sha256() {  # <path> <release-platform>
  local path=$1 platform=$2 hash_output
  case "$platform" in
    darwin-*) hash_output=$(/usr/bin/shasum -a 256 "$path" 2>/dev/null) || return 1 ;;
    linux-*)
      if [ -x /usr/bin/sha256sum ]; then
        hash_output=$(/usr/bin/sha256sum "$path" 2>/dev/null) || return 1
      elif [ -x /bin/sha256sum ]; then
        hash_output=$(/bin/sha256sum "$path" 2>/dev/null) || return 1
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${hash_output%%[[:space:]]*}"
}

fm_claude_av_manifest_sha256() {  # <manifest>
  local manifest=$1 hash_output
  if [ "$(/usr/bin/uname -s 2>/dev/null)" = Darwin ]; then
    hash_output=$(printf '%s' "$manifest" | /usr/bin/shasum -a 256 2>/dev/null) || return 1
  elif [ -x /usr/bin/sha256sum ]; then
    hash_output=$(printf '%s' "$manifest" | /usr/bin/sha256sum 2>/dev/null) || return 1
  elif [ -x /bin/sha256sum ]; then
    hash_output=$(printf '%s' "$manifest" | /bin/sha256sum 2>/dev/null) || return 1
  else
    return 1
  fi
  printf '%s\n' "${hash_output%%[[:space:]]*}"
}

fm_claude_av_expected_manifest_sha256() {  # <version>
  local version=$1 checksum pinned_version extra found=
  [ -f "$FM_CLAUDE_AV_MANIFEST_CHECKSUMS" ] || return 1
  while read -r checksum pinned_version extra; do
    [ -z "$extra" ] || return 1
    case "$checksum" in
      *[!a-f0-9]*|'') return 1 ;;
    esac
    [ "${#checksum}" -eq 64 ] || return 1
    case "$pinned_version" in
      ''|*[!0-9.]*) return 1 ;;
    esac
    if [ "$pinned_version" = "$version" ]; then
      [ -z "$found" ] || return 1
      found=$checksum
    fi
  done < "$FM_CLAUDE_AV_MANIFEST_CHECKSUMS"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

fm_claude_av_attest_native_artifact() {  # <resolved-claude>
  local executable=$1 version platform manifest compact expected actual expected_manifest actual_manifest
  version=${executable##*/}
  platform=$(fm_claude_av_release_platform) || {
    printf 'error: Claude Code artifact attestation does not support this operating system or architecture.\n' >&2
    return 1
  }
  manifest=$(fm_run_timed 15 "$FM_CLAUDE_AV_CURL_BIN" -q -fsSL --max-time 10 \
    --proto '=https' --tlsv1.2 -- "$FM_CLAUDE_AV_RELEASE_BASE/$version/manifest.json" 2>/dev/null) || {
    printf 'error: could not retrieve Claude Code release attestation for version %s; check network access and retry.\n' "$version" >&2
    return 1
  }
  [ "${#manifest}" -le 131072 ] || {
    printf 'error: Claude Code release attestation for version %s was unexpectedly large.\n' "$version" >&2
    return 1
  }
  expected_manifest=$(fm_claude_av_expected_manifest_sha256 "$version") || {
    printf 'error: Claude Code version %s has no checked-in release-manifest checksum; update Firstmate before enabling this version.\n' "$version" >&2
    return 1
  }
  actual_manifest=$(fm_claude_av_manifest_sha256 "$manifest") || {
    printf 'error: SHA-256 verification is unavailable for the Claude Code release manifest.\n' >&2
    return 1
  }
  if [ "$actual_manifest" != "$expected_manifest" ]; then
    printf 'error: refusing Claude Automic Vault authentication because the downloaded release manifest for version %s does not match Firstmate release attestation.\n' "$version" >&2
    return 1
  fi
  compact=${manifest//$'\n'/}
  compact=${compact//$'\r'/}
  compact=${compact//$'\t'/}
  if [[ ! $compact =~ \"version\"[[:space:]]*:[[:space:]]*\"$version\" ]] \
     || [[ ! $compact =~ \"$platform\"[[:space:]]*:[[:space:]]*\{[^\{\}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    printf 'error: Claude Code release attestation did not contain a valid %s checksum for version %s.\n' "$platform" "$version" >&2
    return 1
  fi
  expected=${BASH_REMATCH[1]}
  actual=$(fm_claude_av_artifact_sha256 "$executable" "$platform") || {
    printf 'error: SHA-256 verification is unavailable for Claude Code artifact attestation.\n' >&2
    return 1
  }
  if [ "$actual" != "$expected" ]; then
    printf 'error: refusing Claude Automic Vault authentication because the resolved claude executable does not match Anthropic release attestation for version %s on %s.\n' "$version" "$platform" >&2
    return 1
  fi
  FM_CLAUDE_AV_CLAUDE_SHA256=$actual
}

fm_claude_av_probe_identity() {  # <resolved-claude>
  local executable=$1 probe_root output rc=0
  command -v jq >/dev/null 2>&1 || {
    printf 'error: Claude Automic Vault authentication requires jq for redacted authentication validation.\n' >&2
    return 1
  }
  probe_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-av.identity.XXXXXX" 2>/dev/null) || {
    printf 'error: could not create the private temporary directory required to identify Claude Code.\n' >&2
    return 1
  }
  mkdir -p "$probe_root/config" || {
    fm_claude_av_remove_probe_root "$probe_root"
    printf 'error: could not initialize the private temporary directory required to identify Claude Code.\n' >&2
    return 1
  }
  output=$(fm_run_timed 10 \
    env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$probe_root" \
      CLAUDE_CONFIG_DIR="$probe_root/config" CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
      "$executable" --settings "$FM_CLAUDE_AV_SETTINGS" auth status --json 2>&1) || rc=$?
  fm_claude_av_remove_probe_root "$probe_root"
  if { [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; } || ! printf '%s' "$output" | jq -e \
    '(.loggedIn | type == "boolean") and (.authMethod | type == "string") and .apiProvider == "firstParty"' \
    >/dev/null 2>&1; then
    printf 'error: refusing Claude Automic Vault authentication because the resolved claude executable could not be positively identified as the standalone Claude Code CLI; restore the real Claude Code executable on PATH before retrying.\n' >&2
    return 1
  fi
}

fm_claude_av_resolve_tools() {
  case "$FM_CLAUDE_AV_CURL_BIN" in
    /*) ;;
    *)
      printf 'error: Claude Automic Vault authentication requires an absolute curl path for Claude Code release attestation.\n' >&2
      return 1
      ;;
  esac
  FM_CLAUDE_AV_CURL_BIN=$(fm_claude_av_realpath "$FM_CLAUDE_AV_CURL_BIN") || {
    printf 'error: Claude Automic Vault authentication requires curl at %s for Claude Code release attestation.\n' "$FM_CLAUDE_AV_CURL_BIN" >&2
    return 1
  }
  FM_CLAUDE_AV_BIN=$(fm_claude_av_resolve_named_executable av) || {
    printf 'error: Claude Automic Vault authentication is enabled, but av is unavailable; install or repair Automic Vault, then run bin/fm-claude-automic-vault.sh preflight.\n' >&2
    return 1
  }
  FM_CLAUDE_BIN=$(fm_claude_av_resolve_named_executable claude) || {
    printf 'error: Claude Automic Vault authentication is enabled, but claude is unavailable; install or repair Claude Code, then run bin/fm-claude-automic-vault.sh preflight.\n' >&2
    return 1
  }
  if [ "$FM_CLAUDE_AV_BIN" = "$FM_CLAUDE_BIN" ]; then
    printf 'error: refusing Claude Automic Vault authentication because av and claude resolve to the same executable; restore the real Claude Code executable on PATH before retrying.\n' >&2
    return 1
  fi
  if ! fm_claude_av_is_native_install_artifact "$FM_CLAUDE_BIN"; then
    printf 'error: refusing Claude Automic Vault authentication because the resolved claude executable could not be positively identified as the canonical native Claude Code artifact under .local/share/claude/versions; install Claude Code with the official native installer and retry.\n' >&2
    return 1
  fi
  fm_claude_av_attest_native_artifact "$FM_CLAUDE_BIN" || return 1
  [ -x "$FM_CLAUDE_AV_BASH" ] || {
    printf 'error: the pinned startup-clean shell required for Claude Automic Vault authentication is unavailable: %s\n' "$FM_CLAUDE_AV_BASH" >&2
    return 1
  }
  [ -x "$FM_CLAUDE_AV_ENV" ] || {
    printf 'error: the pinned environment sanitizer required for Claude Automic Vault authentication is unavailable: %s\n' "$FM_CLAUDE_AV_ENV" >&2
    return 1
  }
  [ -x "$FM_CLAUDE_AV_LAUNCH_RELAY" ] || {
    printf 'error: the tracked Claude Automic Vault launch relay is unavailable: %s\n' "$FM_CLAUDE_AV_LAUNCH_RELAY" >&2
    return 1
  }
  fm_claude_av_probe_identity "$FM_CLAUDE_BIN"
}

fm_claude_av_probe_tools() {
  local output rc=0
  command -v jq >/dev/null 2>&1 || {
    printf 'error: Claude Automic Vault authentication requires jq for redacted authentication validation.\n' >&2
    return 1
  }
  case "$FM_CLAUDE_AV_TIMEOUT" in
    ''|*[!0-9]*|0*)
      printf 'error: FM_CLAUDE_AV_TIMEOUT must be a positive integer.\n' >&2
      return 1
      ;;
  esac
  output=$(fm_run_timed 10 "$FM_CLAUDE_AV_BIN" inject --help 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || [[ "$output" != *"--replace-existing-env"* ]]; then
    printf 'error: the installed Automic Vault CLI does not expose the required av inject --replace-existing-env surface; update Automic Vault before enabling Claude launches.\n' >&2
    return 1
  fi
  rc=0
  output=$(fm_run_timed 10 "$FM_CLAUDE_BIN" --help 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || [[ "$output" != *"setup-token"* ]] \
     || [[ "$output" != *"--settings"* ]] || [[ "$output" != *"--safe-mode"* ]] \
     || [[ "$output" != *"--no-session-persistence"* ]] || [[ "$output" != *"--output-format"* ]] \
     || [[ "$output" != *"--tools"* ]] || [[ "$output" != *"--print"* ]]; then
    printf 'error: the installed Claude Code CLI lacks the required setup-token or redacted validation surfaces; update Claude Code before enabling Vault authentication.\n' >&2
    return 1
  fi
  rc=0
  output=$(fm_run_timed 10 "$FM_CLAUDE_BIN" auth status --help 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || [[ "$output" != *"--json"* ]]; then
    printf 'error: the installed Claude Code CLI lacks auth status --json; update Claude Code before enabling Vault authentication.\n' >&2
    return 1
  fi
}

fm_claude_av_probe_ceremony_tools() {
  local output rc=0
  output=$(fm_run_timed 10 "$FM_CLAUDE_AV_BIN" help 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || [[ "$output" != *"save"* ]]; then
    printf 'error: the installed Automic Vault CLI does not expose av save; update Automic Vault before provisioning a Claude token.\n' >&2
    return 1
  fi
}

fm_claude_av_classify_inject_failure() {  # <captured-output>
  local output=$1 lowered
  lowered=$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    *"secret gate"*"denied"*|*"secret gate"*"not granted"*|*"secret gate"*"rejected"*|*"access denied"*|*"permission denied"*)
      printf 'error: Automic Vault Secret Gate denied Claude token access; approve this Firstmate launch in Automic Vault, then retry.\n' >&2
      ;;
    *"claude_code_oauth_token"*"not found"*|*"claude_code_oauth_token"*"does not exist"*|*"could not find"*"claude_code_oauth_token"*|*"missing"*"claude_code_oauth_token"*|*"no secret"*)
      printf 'error: Automic Vault has no CLAUDE_CODE_OAUTH_TOKEN; run bin/fm-claude-automic-vault.sh provision, or renew if the opt-in was already active.\n' >&2
      ;;
    *"vault"*"locked"*|*"vault"*"unavailable"*|*"vault"*"not configured"*|*"not running"*|*"failed to connect"*|*"no vault"*|*"no default vault"*)
      printf 'error: Automic Vault is unavailable or locked; open and unlock it, then run bin/fm-claude-automic-vault.sh preflight.\n' >&2
      ;;
    *)
      printf 'error: Automic Vault could not inject the Claude token and returned no safely classifiable result; inspect Automic Vault Authorization History, then run bin/fm-claude-automic-vault.sh preflight.\n' >&2
      ;;
  esac
}

fm_claude_av_remove_probe_root() {  # <mktemp-dir>
  local root=$1
  case "$root" in
    "${TMPDIR:-/tmp}"/fm-claude-av.*) find "$root" -depth -delete 2>/dev/null || true ;;
  esac
}

fm_claude_av_preflight() {  # [quiet]
  local display=${1:-show} probe_root output status_rc=0 live_rc=0
  probe_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-av.XXXXXX" 2>/dev/null) || {
    printf 'error: could not create the private temporary directory required for Claude authentication validation.\n' >&2
    return 1
  }
  mkdir -p "$probe_root/config" || {
    fm_claude_av_remove_probe_root "$probe_root"
    printf 'error: could not initialize the private temporary directory required for Claude authentication validation.\n' >&2
    return 1
  }

  output=$(fm_run_timed "$FM_CLAUDE_AV_TIMEOUT" \
    env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
      -u ANTHROPIC_BASE_URL -u ANTHROPIC_BEDROCK_BASE_URL \
      -u ANTHROPIC_VERTEX_BASE_URL -u ANTHROPIC_FOUNDRY_BASE_URL \
      -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
      -u CLAUDE_CODE_USE_FOUNDRY -u AWS_BEARER_TOKEN_BEDROCK \
      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CONFIG_DIR="$probe_root/config" \
      "$FM_CLAUDE_AV_BIN" inject --replace-existing-env \
      "+$FM_CLAUDE_AV_SECRET_NAME" -- "$FM_CLAUDE_BIN" \
      --settings "$FM_CLAUDE_AV_SETTINGS" auth status --json 2>&1) || status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    fm_claude_av_remove_probe_root "$probe_root"
    if [ "$status_rc" -eq 124 ]; then
      printf 'error: Claude authentication preflight timed out; unlock Automic Vault, resolve any Secret Gate prompt, and retry.\n' >&2
    else
      fm_claude_av_classify_inject_failure "$output"
    fi
    return 1
  fi
  if ! printf '%s' "$output" | jq -e \
    '.loggedIn == true and .authMethod == "oauth_token" and .apiProvider == "firstParty" and ((.apiKeySource // null) == null)' \
    >/dev/null 2>&1; then
    fm_claude_av_remove_probe_root "$probe_root"
    printf 'error: Claude authentication preflight was inconclusive or selected a credential other than the injected first-party OAuth token; remove conflicting managed authentication settings and retry.\n' >&2
    return 1
  fi

  output=$(fm_run_timed "$FM_CLAUDE_AV_TIMEOUT" \
    env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
      -u ANTHROPIC_BASE_URL -u ANTHROPIC_BEDROCK_BASE_URL \
      -u ANTHROPIC_VERTEX_BASE_URL -u ANTHROPIC_FOUNDRY_BASE_URL \
      -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX \
      -u CLAUDE_CODE_USE_FOUNDRY -u AWS_BEARER_TOKEN_BEDROCK \
      CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CONFIG_DIR="$probe_root/config" \
      "$FM_CLAUDE_AV_BIN" inject --replace-existing-env \
      "+$FM_CLAUDE_AV_SECRET_NAME" -- "$FM_CLAUDE_BIN" \
      --settings "$FM_CLAUDE_AV_SETTINGS" --safe-mode --no-session-persistence \
      --tools '' --output-format json -p 'Reply with the single word OK.' 2>&1) || live_rc=$?
  fm_claude_av_remove_probe_root "$probe_root"
  if [ "$live_rc" -ne 0 ]; then
    if [ "$live_rc" -eq 124 ]; then
      printf 'error: live Claude token validation timed out; check network access and Automic Vault authorization, then retry.\n' >&2
    elif [[ "$output" == *'401'* ]] || [[ "$output" == *'authentication_error'* ]] \
         || [[ "$output" == *'invalid'*"token"* ]] || [[ "$output" == *'revoked'* ]]; then
      printf 'error: Claude rejected the injected subscription token as invalid or revoked; run bin/fm-claude-automic-vault.sh renew before launching a Claude worker.\n' >&2
    else
      fm_claude_av_classify_inject_failure "$output"
    fi
    return 1
  fi
  if ! printf '%s' "$output" | jq -e \
    '.type == "result" and (.is_error == false or .is_error == null) and (.result | type == "string")' \
    >/dev/null 2>&1; then
    printf 'error: live Claude token validation returned an inconclusive redacted result; retry preflight before launching a worker.\n' >&2
    return 1
  fi
  if [ "$display" != quiet ]; then
    printf 'Claude Automic Vault preflight: authenticated via injected first-party OAuth token; credential material was not displayed.\n'
  fi
}

fm_claude_av_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_claude_av_build_launch_command() {
  local env_q bash_q relay_q av_q claude_q checksum_q settings_q
  env_q=$(fm_claude_av_shell_quote "$FM_CLAUDE_AV_ENV")
  bash_q=$(fm_claude_av_shell_quote "$FM_CLAUDE_AV_BASH")
  relay_q=$(fm_claude_av_shell_quote "$FM_CLAUDE_AV_LAUNCH_RELAY")
  av_q=$(fm_claude_av_shell_quote "$FM_CLAUDE_AV_BIN")
  claude_q=$(fm_claude_av_shell_quote "$FM_CLAUDE_BIN")
  checksum_q=$(fm_claude_av_shell_quote "$FM_CLAUDE_AV_CLAUDE_SHA256")
  settings_q=$(fm_claude_av_shell_quote "$FM_CLAUDE_AV_SETTINGS")
  printf '%s' "$env_q -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL -u ANTHROPIC_BEDROCK_BASE_URL -u ANTHROPIC_VERTEX_BASE_URL -u ANTHROPIC_FOUNDRY_BASE_URL -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY -u AWS_BEARER_TOKEN_BEDROCK -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u BASH_XTRACEFD -u PROMPT_COMMAND -u CDPATH -u GLOBIGNORE PATH=/usr/bin:/bin:/usr/sbin:/sbin CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 $bash_q --noprofile --norc $relay_q $av_q $claude_q $checksum_q $settings_q"
}

# Returns 0 with FM_CLAUDE_AV_LAUNCH_COMMAND set for an enabled, authenticated
# home, 1 on a fail-closed blocker, and 2 when the opt-in is absent.
fm_claude_av_prepare_launch() {  # <config-dir> <launch-template>
  local config=$1 launch_template=${2:-__CLAUDELAUNCH__} enabled_rc=0
  fm_claude_av_enabled "$config" || enabled_rc=$?
  case "$enabled_rc" in
    0) ;;
    1) return 2 ;;
    2)
      printf 'error: unsafe or invalid config/%s: %s; remove it to disable the opt-in or recreate it with bin/fm-claude-automic-vault.sh enable.\n' \
        "$FM_CLAUDE_AV_CONFIG_FILE" "$FM_CLAUDE_AV_ERROR" >&2
      return 1
      ;;
  esac
  case "$launch_template" in
    *__CLAUDELAUNCH__*) ;;
    *)
      printf 'error: Claude Automic Vault authentication is enabled, but this Claude launch has no supported injection boundary; use the verified Claude harness template or disable the opt-in before using a raw command.\n' >&2
      return 1
      ;;
  esac
  fm_claude_av_resolve_tools || return 1
  fm_claude_av_probe_tools || return 1
  fm_claude_av_preflight quiet || return 1
  # shellcheck disable=SC2034 # Read by fm-spawn after this sourced function returns.
  FM_CLAUDE_AV_LAUNCH_COMMAND=$(fm_claude_av_build_launch_command) || return 1
}
