#!/usr/bin/env bash
# Public behavior coverage for the local Claude Code Automic Vault opt-in.
# All credentials are synthetic and held only in process environment.
# Fake av and claude executables exercise the same executable paths operators
# and fm-spawn use; the tests never inspect production source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-automic-vault)
TEST_BIN="$TMP_ROOT/executable-boundary/bin"
mkdir -p "$TEST_BIN"
for test_target in "$ROOT"/bin/*; do
  ln -s "$test_target" "$TEST_BIN/${test_target##*/}"
done
rm "$TEST_BIN/fm-claude-automic-vault-lib.sh"
ln -s "$ROOT/tests/fixtures/fm-claude-automic-vault-lib.sh" \
  "$TEST_BIN/fm-claude-automic-vault-lib.sh"
AUTH="$TEST_BIN/fm-claude-automic-vault.sh"
SPAWN="$TEST_BIN/fm-spawn.sh"
REAL_SPAWN="$ROOT/bin/fm-spawn.sh"
export FM_CLAUDE_AV_TEST_PRODUCTION_ROOT=$ROOT
JQ_BIN=$(command -v jq) || fail "test needs jq"
NODE_BIN=$(command -v node) || fail "test needs node"
BASE_PATH="$(dirname "$JQ_BIN"):$(dirname "$NODE_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
SECRET='sk-ant-oat01-FM_SYNTHETIC_SENTINEL_NEVER_PERSIST'

sha256_file() {
  local output
  if [ "$(uname)" = Darwin ]; then
    output=$(/usr/bin/shasum -a 256 "$1") || return 1
  elif [ -x /usr/bin/sha256sum ]; then
    output=$(/usr/bin/sha256sum "$1") || return 1
  else
    output=$(/bin/sha256sum "$1") || return 1
  fi
  printf '%s\n' "${output%%[[:space:]]*}"
}

make_fake_tools() {  # <case-dir>
  local dir=$1 fakebin native_dir cc_bin checksum separator platform
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/fake-state"
  if [ "${FM_TEST_FORCE_PORTABLE_EXPECT:-0}" = 1 ] || ! command -v expect >/dev/null 2>&1; then
    command -v python3 >/dev/null 2>&1 || fail "test needs Expect or Python 3 for the synthetic terminal relay"
    cat > "$fakebin/expect" <<'PY'
#!/usr/bin/env python3
import os
import pty
import re
import select
import subprocess
import sys
import time

if len(sys.argv) != 4:
    sys.exit(2)

claude = sys.argv[2]
av = sys.argv[3]
setup = subprocess.run(
    [claude, "setup-token"],
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    timeout=10,
    check=False,
)
match = re.search(rb"(sk-ant-oat[0-9A-Za-z_-]+)(?:\r?\n)", setup.stdout)
if match is None:
    print(
        "error: Claude setup-token ended without producing a recognizable subscription token",
        file=sys.stderr,
    )
    sys.exit(20)
if setup.returncode != 0:
    print("error: Claude setup-token did not complete successfully", file=sys.stderr)
    sys.exit(20)

token = match.group(1)
pid, terminal = pty.fork()
if pid == 0:
    os.execv(av, [av, "save", "CLAUDE_CODE_OAUTH_TOKEN"])

deadline = time.monotonic() + 10
prompt = bytearray()
sent = False
while time.monotonic() < deadline:
    ready, _, _ = select.select([terminal], [], [], 0.1)
    if terminal in ready:
        try:
            chunk = os.read(terminal, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            _, status = os.waitpid(pid, 0)
            sys.exit(os.waitstatus_to_exitcode(status))
        if not sent:
            prompt.extend(chunk)
            if re.search(rb"(enter|secret|value|token|password)", prompt, re.IGNORECASE):
                os.write(terminal, token + b"\r")
                sent = True
    finished, status = os.waitpid(pid, os.WNOHANG)
    if finished:
        sys.exit(os.waitstatus_to_exitcode(status))

try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
os.waitpid(pid, 0)
if not sent:
    print("error: Automic Vault did not present its terminal value prompt", file=sys.stderr)
else:
    print("error: Automic Vault save timed out after receiving the token", file=sys.stderr)
sys.exit(21)
PY
    chmod +x "$fakebin/expect"
  fi
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_STATE:?}
fake_secret=${TEST_FAKE_SECRET:-sk-ant-oat01-FM_SYNTHETIC_"SENTINEL"_NEVER_PERSIST}
fail_at=${FM_FAKE_AV_FAIL_AT:-}
[ -n "$fail_at" ] || [ ! -f "$state/control-fail-at" ] || fail_at=$(cat "$state/control-fail-at")
block_file=${FM_FAKE_AV_BLOCK_FILE:-}
[ -n "$block_file" ] || [ ! -f "$state/control-block-file" ] || block_file=$(cat "$state/control-block-file")
swap_source=${FM_FAKE_AV_SWAP_SOURCE:-}
[ -n "$swap_source" ] || [ ! -f "$state/control-swap-source" ] || swap_source=$(cat "$state/control-swap-source")
swap_target=${FM_FAKE_AV_SWAP_TARGET:-}
[ -n "$swap_target" ] || [ ! -f "$state/control-swap-target" ] || swap_target=$(cat "$state/control-swap-target")
swap_marker=${FM_FAKE_SWAP_MARKER:-}
[ -n "$swap_marker" ] || [ ! -f "$state/control-swap-marker" ] || swap_marker=$(cat "$state/control-swap-marker")
case "${1:-} ${2:-}" in
  "help ")
    printf '%s\n' 'Commands: save inject'
    exit 0
    ;;
  "inject --help")
    if [ "${FM_FAKE_AV_HELP_MODE:-current}" = old ]; then
      printf '%s\n' 'Usage: av inject +KEY -- COMMAND'
    else
      printf '%s\n' 'Usage: av inject [--replace-existing-env] +KEY -- COMMAND'
    fi
    exit 0
    ;;
  "save CLAUDE_CODE_OAUTH_TOKEN")
    printf 'Enter secret value: ' >&2
    IFS= read -r supplied </dev/tty || exit 31
    [ "$supplied" = "$fake_secret" ] || exit 32
    save_count=0
    [ ! -f "$state/save-count" ] || save_count=$(cat "$state/save-count")
    printf '%s\n' "$((save_count + 1))" > "$state/save-count"
    : > "$state/save-ok"
    printf 'saved\n'
    exit 0
    ;;
esac
if [ "${1:-}" != inject ]; then
  printf 'Automic Vault fake: unsupported invocation\n' >&2
  exit 2
fi
shift
if [ "${LD_PRELOAD+x}" = x ] || [ "${BASH_ENV+x}" = x ]; then
  : > "$state/unsafe-inject-environment"
fi
case "$(/usr/bin/env)" in
  *BASH_FUNC_*) : > "$state/unsafe-inject-environment" ;;
esac
printf 'inject' >> "$state/av-argv.log"
for arg in "$@"; do printf ' <%s>' "$arg" >> "$state/av-argv.log"; done
printf '\n' >> "$state/av-argv.log"
count_file="$state/av-inject-count"
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "${fail_at:-0}" = "$count" ]; then
  printf 'Vault unavailable: failed to connect %s\n' "$fake_secret" >&2
  exit 43
fi
case "${FM_FAKE_AV_MODE:-ok}" in
  denied) printf 'Secret Gate access denied\n' >&2; exit 41 ;;
  missing) printf 'CLAUDE_CODE_OAUTH_TOKEN not found\n' >&2; exit 42 ;;
  unavailable) printf 'Vault unavailable: failed to connect\n' >&2; exit 43 ;;
esac
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
[ "${1:-}" = -- ] || exit 2
shift
[ "$#" -gt 0 ] || exit 2
if [ -n "$block_file" ]; then
  : > "$block_file"
  while [ ! -e "$block_file.release" ]; do
    sleep 0.02
  done
fi
export CLAUDE_CODE_OAUTH_TOKEN=$fake_secret
[ ! -f "$state/control-claude-mode" ] || export FM_FAKE_CLAUDE_MODE=$(cat "$state/control-claude-mode")
if [ -n "$swap_source" ] && [ -n "$swap_target" ]; then
  [ -z "$swap_marker" ] || export FM_FAKE_SWAP_MARKER=$swap_marker
  mv "$swap_target" "$swap_target.before-race" || exit 44
  mv "$swap_source" "$swap_target" || exit 44
fi
exec "$@"
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_STATE:?}
case "${*}" in
  *https://downloads.claude.ai/claude-code-releases/2.1.220/manifest.json) ;;
  *) exit 22 ;;
esac
cat "$state/release-manifest.json"
SH
  native_dir="$dir/fake-home/.local/share/claude/versions"
  mkdir -p "$native_dir"
  cat > "$dir/fake-claude.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int has_arg(int argc, char **argv, const char *wanted) {
  int i;
  for (i = 1; i < argc; i++) if (strcmp(argv[i], wanted) == 0) return 1;
  return 0;
}

static void append_args(const char *path, int argc, char **argv) {
  FILE *out = fopen(path, "a");
  int i;
  if (!out) exit(70);
  fputs("claude", out);
  for (i = 1; i < argc; i++) fprintf(out, " <%s>", argv[i]);
  fputc('\n', out);
  fclose(out);
}

static void append_line(const char *path, const char *line) {
  FILE *out = fopen(path, "a");
  if (!out) exit(70);
  fprintf(out, "%s\n", line);
  fclose(out);
}

int main(int argc, char **argv) {
  const char *state = getenv("FM_FAKE_STATE");
  const char *secret = getenv("TEST_FAKE_SECRET");
  const char *token = getenv("CLAUDE_CODE_OAUTH_TOKEN");
  const char *mode = getenv("FM_FAKE_CLAUDE_MODE");
  const char *setup_mode = getenv("FM_FAKE_SETUP_MODE");
  char path[4096];
  int i;
  if (!state && has_arg(argc, argv, "auth") && has_arg(argc, argv, "status")) {
    puts("{\"loggedIn\":false,\"authMethod\":\"none\",\"apiProvider\":\"firstParty\"}");
    return 1;
  }
  if (argc == 2 && strcmp(argv[1], "--help") == 0) {
    if (getenv("FM_FAKE_CLAUDE_HELP_MODE") && strcmp(getenv("FM_FAKE_CLAUDE_HELP_MODE"), "old") == 0)
      puts("setup-token --print");
    else if (getenv("FM_FAKE_CLAUDE_HELP_MODE") && strcmp(getenv("FM_FAKE_CLAUDE_HELP_MODE"), "no-permission") == 0)
      puts("setup-token --settings --safe-mode --no-session-persistence --output-format --tools --print");
    else
      puts("setup-token --settings --permission-mode --safe-mode --no-session-persistence --output-format --tools --print");
    return 0;
  }
  if (argc >= 4 && strcmp(argv[1], "auth") == 0 && strcmp(argv[2], "status") == 0 && strcmp(argv[3], "--help") == 0) {
    puts("Usage: claude auth status --json");
    return 0;
  }
  if (argc >= 2 && strcmp(argv[1], "setup-token") == 0) {
    size_t length, cut;
    if (!secret) return 71;
    printf("Complete browser authentication.\n");
    if (setup_mode && strcmp(setup_mode, "incomplete") == 0) {
      fputs(secret, stdout);
      fflush(stdout);
      return 0;
    }
    if (setup_mode && strcmp(setup_mode, "split") == 0) {
      length = strlen(secret);
      cut = length / 2;
      fwrite(secret, 1, cut, stdout);
      fflush(stdout);
      usleep(100000);
      fwrite(secret + cut, 1, length - cut, stdout);
      fputc('\n', stdout);
      return 0;
    }
    printf("%s\n", secret);
    return 0;
  }
  if (!state) return 72;
  snprintf(path, sizeof(path), "%s/claude-argv.log", state);
  append_args(path, argc, argv);
  snprintf(path, sizeof(path), "%s/claude-env.log", state);
  append_line(path, token && *token && (!secret || strcmp(token, secret) == 0) ? "oauth=present" : "oauth=missing");
  {
    const char *names[] = {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK"};
    for (i = 0; i < 4; i++) if (getenv(names[i]) && *getenv(names[i])) {
      char line[256];
      snprintf(line, sizeof(line), "conflict=%s", names[i]);
      append_line(path, line);
    }
  }
  {
    const char *names[] = {"FM_HOME", "FM_SUPERVISION_MODEL", "TRACEPARENT", "CLAUDE_CONFIG_DIR", "GOTMPDIR"};
    for (i = 0; i < 5; i++) if (getenv(names[i])) {
      char line[8192];
      snprintf(line, sizeof(line), "%s=%s", names[i], getenv(names[i]));
      append_line(path, line);
    }
  }
  if (has_arg(argc, argv, "auth") && has_arg(argc, argv, "status") && has_arg(argc, argv, "--json")) {
    if (mode && strcmp(mode, "inconclusive") == 0)
      puts("{\"loggedIn\":true,\"authMethod\":\"api_key\",\"apiProvider\":\"firstParty\",\"apiKeySource\":\"apiKeyHelper\"}");
    else
      puts("{\"loggedIn\":true,\"authMethod\":\"oauth_token\",\"apiProvider\":\"firstParty\"}");
    return 0;
  }
  if (has_arg(argc, argv, "-p")) {
    if (mode && strcmp(mode, "revoked-case") == 0) {
      printf("Invalid OAuth token: %s\n", secret ? secret : "missing");
      return 1;
    }
    if (mode && strcmp(mode, "revoked") == 0) {
      puts("{\"type\":\"result\",\"is_error\":true,\"api_error_status\":401,\"error\":\"authentication_error\"}");
      return 1;
    }
    puts("{\"type\":\"result\",\"is_error\":false,\"result\":\"OK\"}");
    return 0;
  }
  if (getenv("CLAUDE_CODE_SUBPROCESS_ENV_SCRUB")) {
    if (!has_arg(argc, argv, "--permission-mode") || !has_arg(argc, argv, "bypassPermissions") ||
        !has_arg(argc, argv, "--allowedTools") || !has_arg(argc, argv, "Bash")) {
      append_line(path, "approval=required");
      return 52;
    }
    append_line(path, "permission=bypassPermissions");
  }
  if (getenv("FM_FAKE_TOOL_NAME")) {
    const char *tool = getenv("FM_FAKE_TOOL_NAME");
    unsetenv("CLAUDE_CODE_OAUTH_TOKEN");
    if (system(tool) != 0) return 53;
    append_line(path, "tool=executed");
  }
  if (mode && strcmp(mode, "interactive") == 0) {
    char reply[1024];
    if (!fgets(reply, sizeof(reply), stdin)) return 51;
    reply[strcspn(reply, "\r\n")] = 0;
    printf("interactive stdout: %s\n", reply);
    fprintf(stderr, "interactive stderr: authenticated\n");
  }
  append_line(path, "interactive=authenticated");
  return 0;
}
C
  cc_bin=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null) || fail "test needs a C compiler for the native Claude fixture"
  "$cc_bin" -o "$native_dir/2.1.220" "$dir/fake-claude.c" || fail "could not build native Claude fixture"
  sha256_file "$native_dir/2.1.220" > "$dir/fake-state/expected-claude-sha256" \
    || fail "could not hash native Claude fixture"
  checksum=$(cat "$dir/fake-state/expected-claude-sha256")
  {
    printf '{"version":"2.1.220","platforms":{'
    separator=
    for platform in darwin-arm64 darwin-x64 linux-arm64 linux-x64 linux-arm64-musl linux-x64-musl; do
      printf '%s"%s":{"checksum":"%s"}' "$separator" "$platform" "$checksum"
      separator=,
    done
    printf '}}'
  } > "$dir/fake-state/release-manifest.json"
  printf '%s  2.1.220\n' "$(sha256_file "$dir/fake-state/release-manifest.json")" \
    > "$dir/fake-state/release-manifests.sha256"
  ln -s "$native_dir/2.1.220" "$fakebin/claude"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
      *pane_current_command*) printf 'zsh\n' ;;
      *pane_tty*) printf '\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  list-windows)
    [ -z "${FM_FAKE_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_WINDOWS"
    exit 0
    ;;
  send-keys)
    previous=
    for arg in "$@"; do
      if [ "$previous" = -l ]; then printf '%s\n' "$arg" >> "${FM_FAKE_LAUNCH_LOG:?}"; fi
      previous=$arg
    done
    exit 0
    ;;
  new-session|new-window)
    printf '%s\n' "$*" >> "${FM_FAKE_STATE:?}/endpoint.log"
    exit 0
    ;;
  has-session|kill-window)
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/worker-tool" <<'SH'
#!/bin/sh
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 91
: > "${FM_FAKE_STATE:?}/worker-tool-executed"
SH
  chmod +x "$fakebin/av" "$fakebin/curl" "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/worker-tool"
  (cd "$fakebin" && pwd -P)
}

configure_fake_attestation() {  # <fakebin> <state>
  export FM_CLAUDE_AV_TEST_CURL_BIN=$1/curl
  export FM_CLAUDE_AV_TEST_MANIFEST_CHECKSUMS=$2/release-manifests.sha256
}

assert_secret_absent() {  # <case-dir> <captured-output>
  local dir=$1 output=$2
  assert_not_contains "$output" "$SECRET" "synthetic credential leaked to command output"
  if LC_ALL=C grep -R -a -F -- "$SECRET" "$dir" >/dev/null 2>&1; then
    fail "synthetic credential leaked to a fixture file under $dir"
  fi
}

last_launch_command() {
  grep -v '^export GOTMPDIR=' "$1" | grep -v '^$' | tail -1
}

assert_sanitized_launch() {
  local launch=$1 fakebin=$2
  assert_contains "$launch" \
    "fm-claude-automic-vault-launch.sh' --sanitize '/usr/bin/env' \"\${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}\" '/bin/bash' --noprofile --norc" \
    "enabled launch did not use the startup-clean injection boundary"
  assert_contains "$launch" \
    "'$fakebin/av' '${fakebin%/fakebin}/fake-home/.local/share/claude/versions/2.1.220'" \
    "enabled launch did not pin the resolved Vault and Claude tools"
}

make_ship() {  # <case-dir> <home> <id>
  local dir=$1 home=$2 id=$3 proj wt
  proj="$dir/project-$id"
  wt="$dir/wt-$id"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  printf '# Task\n\nExercise synthetic authentication.\n' > "$home/data/$id/brief.md"
  printf '%s\t%s\n' "$proj" "$wt"
}

run_spawn() {  # <home> <fakebin> <state> <launchlog> <pane-path> <args...>
  local home=$1 fakebin=$2 state=$3 launchlog=$4 pane=$5
  shift 5
  FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_STATE="$state" TEST_FAKE_SECRET="$SECRET" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_PATH="$pane" TMUX='fake,1,0' \
    FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$fakebin:$BASE_PATH" "$SPAWN" "$@"
}

run_real_spawn() {  # <home> <fakebin> <state> <launchlog> <pane-path> <args...>
  local home=$1 fakebin=$2 state=$3 launchlog=$4 pane=$5
  shift 5
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_STATE="$state" TEST_FAKE_SECRET="$SECRET" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_PATH="$pane" TMUX='fake,1,0' \
    FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" "$REAL_SPAWN" "$@"
}

test_provision_recovery_renewal_preflight_and_redaction() {
  local dir home fakebin state output status before
  dir="$TMP_ROOT/provision"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  configure_fake_attestation "$fakebin" "$state"
  mkdir -p "$home/config"
  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_SETUP_MODE=split PATH="$fakebin:$BASE_PATH" \
    "$AUTH" provision 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "synthetic provision ceremony exited $status: ${output//$SECRET/[REDACTED]}"
  fi
  [ "$(cat "$home/config/claude-automic-vault")" = on ] || fail "provision did not enable exact local flag"
  [ -e "$state/save-ok" ] || fail "fake av did not receive the setup token through its terminal"
  [ "$(cat "$state/save-count")" = 1 ] || fail "split setup token was not saved exactly once"
  assert_contains "$output" "credential output suppressed" "ceremony did not disclose suppression"
  assert_contains "$output" "validated" "ceremony did not report redacted validation"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" PATH="$fakebin:$BASE_PATH" \
    "$AUTH" disable 2>&1)
  status=$?
  expect_code 0 "$status" "disable before one-time recovery"
  [ ! -e "$home/config/claude-automic-vault" ] || fail "disable left the local opt-in in place"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" enable 2>&1)
  status=$?
  expect_code 0 "$status" "one-time enable recovery"
  [ "$(cat "$home/config/claude-automic-vault")" = on ] || fail "enable recovery did not restore the opt-in"
  assert_secret_absent "$dir" "$output"

  before=$(cat "$state/save-count")
  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_SETUP_MODE=incomplete PATH="$fakebin:$BASE_PATH" \
    "$AUTH" renew 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "delimiter-free setup token was accepted"
  [ "$(cat "$state/save-count")" = "$before" ] || fail "incomplete renewal replaced the prior Vault value"
  [ "$(cat "$home/config/claude-automic-vault")" = on ] || fail "incomplete renewal removed the fail-closed opt-in"
  assert_contains "$output" "without producing a recognizable subscription token" \
    "incomplete renewal did not report its delimiter failure"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" renew 2>&1)
  status=$?
  expect_code 0 "$status" "synthetic renewal ceremony"
  assert_contains "$output" "replaced directly" "renewal did not report direct replacement"
  assert_secret_absent "$dir" "$output"

  # shellcheck disable=SC2329 # Exported to verify startup-clean function removal.
  preflight_probe() { :; }
  export -f preflight_probe
  rm -f "$state/unsafe-inject-environment"
  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" LD_PRELOAD='' PATH="$fakebin:$BASE_PATH" "$AUTH" preflight 2>&1)
  status=$?
  unset -f preflight_probe
  expect_code 0 "$status" "redacted public preflight"
  [ ! -e "$state/unsafe-inject-environment" ] \
    || fail "preflight injection inherited a loader or shell startup control"
  assert_contains "$output" "credential material was not displayed" "preflight omitted its redaction guarantee"
  assert_secret_absent "$dir" "$output"
  pass "provision, recovery, renewal, and preflight keep the synthetic credential off every output and file"
}

test_enabled_disabled_and_non_claude_launches() {
  local dir home fakebin state record proj wt launchlog output status launch before executed raw id before_claude before_endpoint raw_heredoc tasktmp gotmp raw_index=0
  dir="$TMP_ROOT/launches"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  configure_fake_attestation "$fakebin" "$state"
  record=$(make_ship "$dir" "$home" auth-ship)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  launchlog="$dir/launch.log"
  : > "$launchlog"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'on\n' > "$home/config/claude-automic-vault"

  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    auth-ship "$proj" claude --model sonnet --effort high --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "enabled Claude spawn"
  launch=$(last_launch_command "$launchlog")
  assert_sanitized_launch "$launch" "$fakebin"
  assert_contains "$launch" "--model 'sonnet' --effort 'high'" "enabled launch did not preserve profile arguments"
  assert_not_contains "$launch" "$SECRET" "launch argv contains synthetic secret"
  tasktmp=$(sed -n 's/^tasktmp=//p' "$home/state/auth-ship.meta")
  gotmp="$tasktmp/gotmp"
  executed=$(cd "$wt" && FM_FAKE_STATE="$state" FM_FAKE_TOOL_NAME=worker-tool \
    GOTMPDIR="$gotmp" \
    ANTHROPIC_API_KEY=must-be-cleared ANTHROPIC_BASE_URL=https://invalid.example \
    PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1) || fail "captured enabled launch did not execute"
  assert_not_contains "$executed" "$SECRET" "executed worker launch displayed synthetic secret"
  assert_grep 'interactive=authenticated' "$state/claude-env.log" "launched fake Claude was not authenticated"
  assert_grep "GOTMPDIR=$gotmp" "$state/claude-env.log" \
    "enabled Claude launch dropped task-managed GOTMPDIR"
  [ -e "$state/worker-tool-executed" ] || fail "enabled Claude launch did not restore the worker tool PATH"
  assert_grep 'permission=bypassPermissions' "$state/claude-env.log" \
    "enabled Claude launch did not preserve non-interactive permission mode"
  assert_no_grep 'approval=required' "$state/claude-env.log" \
    "enabled Claude launch required an approval prompt"
  assert_no_grep 'conflict=' "$state/claude-env.log" "higher-precedence auth environment reached Claude"

  : > "$launchlog"
  record=$(make_ship "$dir" "$home" production-attestation)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(FM_CLAUDE_AV_CURL_BIN="$fakebin/curl" \
    FM_CLAUDE_AV_MANIFEST_CHECKSUMS="$state/release-manifests.sha256" \
    FM_CLAUDE_AV_QUALIFIED_VERSIONS="$ROOT/tests/fixtures/fm-claude-automic-vault-qualified-versions" \
    HTTPS_PROXY=http://127.0.0.1:1 ALL_PROXY=http://127.0.0.1:1 NO_PROXY='' \
    https_proxy=http://127.0.0.1:1 all_proxy=http://127.0.0.1:1 no_proxy='' \
    run_real_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
      production-attestation "$proj" claude --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "production spawn honored caller-controlled identity inputs"
  assert_contains "$output" "version 2.1.220 is not qualified" \
    "production spawn did not use the checked-in qualification boundary"
  [ ! -s "$launchlog" ] || fail "production attestation refusal sent a launch command"
  [ ! -e "$home/state/production-attestation.meta" ] \
    || fail "production attestation refusal published worker metadata"
  assert_secret_absent "$dir" "$output"

  : > "$launchlog"
  before=$(wc -l < "$state/av-argv.log")
  record=$(make_ship "$dir" "$home" raw-claude-ship)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    raw-claude-ship "$proj" 'claude --dangerously-skip-permissions' \
    --harness codex --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "enabled raw Claude launch bypassed the injection boundary"
  assert_contains "$output" "cannot be combined with --harness" \
    "enabled raw Claude refusal was not actionable"
  [ ! -s "$launchlog" ] || fail "enabled raw Claude refusal still sent a launch command"
  [ ! -e "$home/state/raw-claude-ship.meta" ] || fail "enabled raw Claude refusal published worker metadata"
  [ "$(wc -l < "$state/av-argv.log")" = "$before" ] \
    || fail "enabled raw Claude refusal contacted Automic Vault"
  assert_secret_absent "$dir" "$output"

  for raw in \
    'env FOO=bar claude --dangerously-skip-permissions' \
    'FOO=bar /usr/bin/env -u OLD_TOKEN claude --dangerously-skip-permissions' \
    '/usr/bin/env -i -- claude --dangerously-skip-permissions' \
    '/usr/bin/env --unset=OLD_TOKEN claude --dangerously-skip-permissions' \
    "/usr/bin/env -S 'claude --dangerously-skip-permissions'" \
    "env --split-string='claude --dangerously-skip-permissions'" \
    "/bin/sh -c 'exec claude --dangerously-skip-permissions'" \
    "bash -lc 'FOO=bar claude --dangerously-skip-permissions'" \
    "zsh -c 'env FOO=bar claude --dangerously-skip-permissions'" \
    "/bin/bash -c \"env -S 'claude --dangerously-skip-permissions'\"" \
    "eval 'exec claude --dangerously-skip-permissions'" \
    'nice claude --dangerously-skip-permissions' \
    '/usr/bin/nice -n 5 claude --dangerously-skip-permissions'; do
    raw_index=$((raw_index + 1))
    id="raw-prefixed-$raw_index"
    : > "$launchlog"
    before=$(wc -l < "$state/av-argv.log")
    before_claude=$(wc -l < "$state/claude-argv.log")
    before_endpoint=0
    [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
    record=$(make_ship "$dir" "$home" "$id")
    proj=${record%%$'\t'*}
    wt=${record#*$'\t'}
    output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
      "$id" "$proj" "$raw" --mode local-only --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "enabled prefixed raw Claude launch bypassed the injection boundary: $raw"
    assert_contains "$output" "raw launch commands are refused" \
      "enabled prefixed raw Claude refusal was not actionable: $raw"
    [ ! -s "$launchlog" ] || fail "enabled prefixed raw Claude refusal sent a launch command: $raw"
    [ ! -e "$home/state/$id.meta" ] || fail "enabled prefixed raw Claude refusal published worker metadata: $raw"
    [ "$(wc -l < "$state/av-argv.log")" = "$before" ] \
      || fail "enabled prefixed raw Claude refusal contacted Automic Vault: $raw"
    [ "$(wc -l < "$state/claude-argv.log")" = "$before_claude" ] \
      || fail "enabled prefixed raw Claude refusal started ordinary Claude: $raw"
    if [ -f "$state/endpoint.log" ]; then
      [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
        || fail "enabled prefixed raw Claude refusal created an endpoint: $raw"
    fi
    assert_secret_absent "$dir" "$output"
  done

  raw_heredoc=$'/bin/sh <<\'EOF\'\nclaude --dangerously-skip-permissions\nEOF'
  # shellcheck disable=SC2016 # These raw commands must reach the parser without expansion.
  for raw in \
    '"$(printf clau%s de)" --dangerously-skip-permissions' \
    '"$(printf custom-%s agent)" --flag' \
    'true; "$(printf clau%s de)" --dangerously-skip-permissions' \
    "/bin/sh -c 'true; \"\$(printf clau%s de)\" --dangerously-skip-permissions'" \
    "$raw_heredoc" \
    "printf '%s\\n' 'claude --dangerously-skip-permissions' | sh" \
    'printf x | xargs claude --dangerously-skip-permissions' \
    'find . -maxdepth 0 -exec claude --dangerously-skip-permissions \;' \
    "awk 'BEGIN { system(\"claude --dangerously-skip-permissions\") }'" \
    'custom-agent --flag' \
    'if true; then claude --dangerously-skip-permissions; fi' \
    'if true; then custom-agent --flag; fi' \
    'while false; do custom-agent --flag; done' \
    'worker() { custom-agent --flag; }; worker'; do
    raw_index=$((raw_index + 1))
    id="raw-ambiguous-$raw_index"
    : > "$launchlog"
    before=$(wc -l < "$state/av-argv.log")
    before_claude=$(wc -l < "$state/claude-argv.log")
    before_endpoint=0
    [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
    record=$(make_ship "$dir" "$home" "$id")
    proj=${record%%$'\t'*}
    wt=${record#*$'\t'}
    output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
      "$id" "$proj" "$raw" --mode local-only --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "enabled ambiguous raw launch was accepted: $raw"
    assert_contains "$output" "raw launch commands are refused" \
      "enabled ambiguous raw launch refusal was not actionable: $raw"
    [ ! -s "$launchlog" ] || fail "enabled ambiguous raw launch sent a launch command: $raw"
    [ ! -e "$home/state/$id.meta" ] || fail "enabled ambiguous raw launch published worker metadata: $raw"
    [ "$(wc -l < "$state/av-argv.log")" = "$before" ] \
      || fail "enabled ambiguous raw launch contacted Automic Vault: $raw"
    [ "$(wc -l < "$state/claude-argv.log")" = "$before_claude" ] \
      || fail "enabled ambiguous raw launch started ordinary Claude: $raw"
    if [ -f "$state/endpoint.log" ]; then
      [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
        || fail "enabled ambiguous raw launch created an endpoint: $raw"
    fi
    assert_secret_absent "$dir" "$output"
  done

  : > "$launchlog"
  before=$(wc -l < "$state/av-argv.log")
  record=$(make_ship "$dir" "$home" raw-prefixed-non-claude)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  before_endpoint=0
  [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    raw-prefixed-non-claude "$proj" "env --split-string='custom-agent --flag'" \
    --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "enabled raw non-Claude launch was accepted"
  assert_contains "$output" "raw launch commands are refused" \
    "enabled raw non-Claude refusal was not actionable"
  [ ! -s "$launchlog" ] || fail "enabled raw non-Claude refusal sent a launch command"
  [ ! -e "$home/state/raw-prefixed-non-claude.meta" ] \
    || fail "enabled raw non-Claude refusal published worker metadata"
  if [ -f "$state/endpoint.log" ]; then
    [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
      || fail "enabled raw non-Claude refusal created an endpoint"
  fi
  [ "$(wc -l < "$state/av-argv.log")" = "$before" ] \
    || fail "enabled raw non-Claude refusal contacted Automic Vault"
  assert_secret_absent "$dir" "$output"

  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exit 127
SH
  chmod +x "$fakebin/node"
  : > "$launchlog"
  before=$(wc -l < "$state/av-argv.log")
  before_claude=$(wc -l < "$state/claude-argv.log")
  before_endpoint=0
  [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
  record=$(make_ship "$dir" "$home" raw-no-node-claude)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    raw-no-node-claude "$proj" "eval 'exec claude --dangerously-skip-permissions'" \
    --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Node-unavailable raw Claude launch bypassed the injection boundary"
  assert_contains "$output" "raw launch commands are refused" \
    "Node-unavailable raw Claude refusal was not actionable"
  [ ! -s "$launchlog" ] || fail "Node-unavailable raw Claude refusal sent a launch command"
  [ ! -e "$home/state/raw-no-node-claude.meta" ] || fail "Node-unavailable raw Claude refusal published worker metadata"
  [ "$(wc -l < "$state/av-argv.log")" = "$before" ] \
    || fail "Node-unavailable raw Claude refusal contacted Automic Vault"
  [ "$(wc -l < "$state/claude-argv.log")" = "$before_claude" ] \
    || fail "Node-unavailable raw Claude refusal started ordinary Claude"
  if [ -f "$state/endpoint.log" ]; then
    [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
      || fail "Node-unavailable raw Claude refusal created an endpoint"
  fi
  assert_secret_absent "$dir" "$output"

  : > "$launchlog"
  before=$(wc -l < "$state/av-argv.log")
  record=$(make_ship "$dir" "$home" raw-no-node-non-claude)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    raw-no-node-non-claude "$proj" "eval 'exec custom-agent --flag'" \
    --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "enabled Node-unavailable ambiguous non-Claude raw launch was accepted"
  assert_contains "$output" "raw launch commands are refused" \
    "enabled Node-unavailable ambiguous non-Claude refusal was not actionable"
  [ ! -s "$launchlog" ] || fail "enabled Node-unavailable ambiguous non-Claude launch sent a launch command"
  [ ! -e "$home/state/raw-no-node-non-claude.meta" ] \
    || fail "enabled Node-unavailable ambiguous non-Claude launch published worker metadata"
  [ "$(wc -l < "$state/av-argv.log")" = "$before" ] \
    || fail "enabled Node-unavailable ambiguous non-Claude launch contacted Automic Vault"
  assert_secret_absent "$dir" "$output"

  rm -f "$home/config/claude-automic-vault"
  : > "$launchlog"
  record=$(make_ship "$dir" "$home" raw-no-node-disabled-non-claude)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    raw-no-node-disabled-non-claude "$proj" "eval 'exec custom-agent --flag'" \
    --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "disabled Node-unavailable non-Claude raw launch"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" "eval 'exec custom-agent --flag'" \
    "disabled Node-unavailable non-Claude raw launch changed"
  rm -f "$fakebin/node"

  : > "$launchlog"
  record=$(make_ship "$dir" "$home" raw-disabled-shell-claude)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    raw-disabled-shell-claude "$proj" "/bin/sh -c 'claude --dangerously-skip-permissions'" \
    --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "disabled shell-wrapped Claude raw launch"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" "/bin/sh -c 'claude --dangerously-skip-permissions'" \
    "disabled shell-wrapped Claude launch changed"
  assert_grep 'harness=sh' "$home/state/raw-disabled-shell-claude.meta" \
    "disabled shell-wrapped Claude metadata changed from historical first-command classification"
  [ ! -e "$wt/.claude/settings.local.json" ] \
    || fail "disabled shell-wrapped Claude received Claude harness wiring"

  : > "$launchlog"
  record=$(make_ship "$dir" "$home" raw-disabled-declared-harness)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    raw-disabled-declared-harness "$proj" "custom-agent --flag" --harness codex \
    --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "disabled raw launch with declared harness"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" 'codex --dangerously-bypass-approvals-and-sandbox' \
    "disabled raw positional did not yield to the declared canonical harness"
  assert_not_contains "$launch" "custom-agent --flag" \
    "disabled raw positional overrode the declared canonical harness"
  assert_grep 'harness=codex' "$home/state/raw-disabled-declared-harness.meta" \
    "disabled raw positional changed historical declared-harness metadata"

  printf 'off\n' > "$home/config/claude-automic-vault"
  # shellcheck disable=SC2016 # These raw commands must reach the parser without expansion.
  for raw in \
    '"$(printf clau%s de)" --dangerously-skip-permissions' \
    '"$(printf custom-%s agent)" --flag' \
    'true; "$(printf clau%s de)" --dangerously-skip-permissions'; do
    raw_index=$((raw_index + 1))
    id="raw-malformed-$raw_index"
    : > "$launchlog"
    before=$(wc -l < "$state/av-argv.log")
    before_claude=$(wc -l < "$state/claude-argv.log")
    before_endpoint=0
    [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
    record=$(make_ship "$dir" "$home" "$id")
    proj=${record%%$'\t'*}
    wt=${record#*$'\t'}
    output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
      "$id" "$proj" "$raw" --mode local-only --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "malformed-state ambiguous raw launch was accepted: $raw"
    assert_contains "$output" "unsafe or invalid config/claude-automic-vault" \
      "malformed-state ambiguous raw launch refusal did not identify the opt-in state: $raw"
    assert_contains "$output" "remove it to disable" \
      "malformed-state ambiguous raw launch refusal omitted recovery: $raw"
    [ ! -s "$launchlog" ] || fail "malformed-state ambiguous raw launch sent a launch command: $raw"
    [ ! -e "$home/state/$id.meta" ] || fail "malformed-state ambiguous raw launch published worker metadata: $raw"
    [ "$(wc -l < "$state/av-argv.log")" = "$before" ] \
      || fail "malformed-state ambiguous raw launch contacted Automic Vault: $raw"
    [ "$(wc -l < "$state/claude-argv.log")" = "$before_claude" ] \
      || fail "malformed-state ambiguous raw launch started ordinary Claude: $raw"
    if [ -f "$state/endpoint.log" ]; then
      [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
        || fail "malformed-state ambiguous raw launch created an endpoint: $raw"
    fi
    assert_secret_absent "$dir" "$output"
  done
  rm -f "$home/config/claude-automic-vault"

  : > "$launchlog"
  before=$(wc -l < "$state/av-argv.log")
  record=$(make_ship "$dir" "$home" bare-ship)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    bare-ship "$proj" claude --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "disabled Claude spawn"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions' \
    "disabled launch changed the historical bare Claude path"
  assert_not_contains "$launch" 'av inject' "disabled launch used Automic Vault"
  [ "$(wc -l < "$state/av-argv.log")" = "$before" ] || fail "disabled launch contacted Automic Vault"

  printf 'on\n' > "$home/config/claude-automic-vault"
  : > "$launchlog"
  before=$(wc -l < "$state/av-argv.log")
  record=$(make_ship "$dir" "$home" codex-ship)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    codex-ship "$proj" codex --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "non-Claude spawn with opt-in present"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" 'codex --dangerously-bypass-approvals-and-sandbox' "non-Claude command changed"
  assert_not_contains "$launch" 'av inject' "non-Claude launch used Automic Vault"
  [ "$(wc -l < "$state/av-argv.log")" = "$before" ] || fail "non-Claude launch contacted Automic Vault"
  assert_secret_absent "$dir" "$output"
  pass "enabled Claude launches inject narrowly while disabled and non-Claude launches remain unchanged"
}

test_actionable_fail_closed_paths() {
  local dir home fakebin state mode output status expected direct wrapper record proj wt launchlog before cc_bin native unqualified
  dir="$TMP_ROOT/blockers"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  configure_fake_attestation "$fakebin" "$state"
  mkdir -p "$home/config"
  printf 'on\n' > "$home/config/claude-automic-vault"
  for mode in denied missing unavailable; do
    case "$mode" in
      denied) expected='Secret Gate denied' ;;
      missing) expected='has no CLAUDE_CODE_OAUTH_TOKEN' ;;
      unavailable) expected='unavailable or locked' ;;
    esac
    record=$(make_ship "$dir" "$home" "vault-$mode")
    proj=${record%%$'\t'*}
    wt=${record#*$'\t'}
    launchlog="$dir/$mode-launch.log"
    : > "$launchlog"
    output=$(FM_FAKE_AV_MODE="$mode" run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
      "vault-$mode" "$proj" claude --mode local-only --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$mode Vault failure did not block the launch"
    assert_contains "$output" "$expected" "$mode Vault failure was not actionable"
    [ ! -s "$launchlog" ] || fail "$mode Vault failure still sent a worker launch command"
    [ ! -e "$home/state/vault-$mode.meta" ] || fail "$mode Vault failure still published worker metadata"
    assert_secret_absent "$dir" "$output"
  done

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_MODE=revoked PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "revoked token did not block"
  assert_contains "$output" "invalid or revoked" "revoked token blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_MODE=revoked-case PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mixed-case invalid token did not block"
  assert_contains "$output" "invalid or revoked" \
    "mixed-case invalid token blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_MODE=inconclusive PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "inconclusive auth did not block"
  assert_contains "$output" "inconclusive or selected a credential other" "inconclusive auth blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_AV_HELP_MODE=old PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unsupported Automic Vault surface did not block"
  assert_contains "$output" "does not expose the required" "unsupported Vault blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_HELP_MODE=old PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unsupported Claude surface did not block"
  assert_contains "$output" "lacks the required" "unsupported Claude blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_HELP_MODE=no-permission PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Claude without explicit permission mode was accepted"
  assert_contains "$output" "permission-mode" "permission-mode blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  native="${fakebin%/fakebin}/fake-home/.local/share/claude/versions/2.1.220"
  unqualified="${native%/*}/2.1.231"
  cp "$native" "$unqualified" || fail "could not create unqualified native Claude fixture"
  rm "$fakebin/claude"
  ln -s "$unqualified" "$fakebin/claude"
  record=$(make_ship "$dir" "$home" unqualified-version)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  launchlog="$dir/unqualified-version-launch.log"
  : > "$launchlog"
  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    unqualified-version "$proj" claude --mode local-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unqualified Claude version did not block the launch"
  assert_contains "$output" "version 2.1.231 is not qualified" \
    "unqualified Claude version blocker did not name the detected version"
  assert_contains "$output" "docs/verification/claude-automic-vault.md" \
    "unqualified Claude version blocker omitted the qualification procedure"
  [ ! -s "$launchlog" ] || fail "unqualified Claude version sent a worker launch command"
  [ ! -e "$home/state/unqualified-version.meta" ] \
    || fail "unqualified Claude version published worker metadata"
  rm "$fakebin/claude"
  ln -s "$native" "$fakebin/claude"
  assert_secret_absent "$dir" "$output"

  mv "$fakebin/claude" "$fakebin/claude-real"
  direct="$fakebin/claude-direct-wrapper"
  cat > "$direct" <<'SH'
#!/usr/bin/env bash
exec av inject +CLAUDE_CODE_OAUTH_TOKEN -- claude "$@"
SH
  chmod +x "$direct"
  ln -s "$direct" "$fakebin/claude"
  before=$(wc -l < "$state/av-argv.log" | tr -d ' ')
  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct injecting Claude wrapper was accepted"
  assert_contains "$output" "positively identified" "direct wrapper refusal was not actionable"
  [ "$(wc -l < "$state/av-argv.log" | tr -d ' ')" = "$before" ] \
    || fail "direct wrapper reached Automic Vault before artifact refusal"
  rm "$fakebin/claude"

  wrapper="$fakebin/claude-wrapper"
  cat > "$wrapper" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" --help "*|*" --help"|*" auth status "*|*" -p "*) exec "$(dirname "$0")/claude-real" "$@" ;;
esac
vault=av
exec "$vault" inject +CLAUDE_CODE_OAUTH_TOKEN -- claude "$@"
SH
  chmod +x "$wrapper"
  ln -s "$wrapper" "$fakebin/claude"
  before=$(wc -l < "$state/av-argv.log" | tr -d ' ')
  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "injecting Claude wrapper was accepted"
  assert_contains "$output" "positively identified" "wrapper recursion refusal was not actionable"
  [ "$(wc -l < "$state/av-argv.log" | tr -d ' ')" = "$before" ] \
    || fail "indirect wrapper reached Automic Vault before identity refusal"
  assert_secret_absent "$dir" "$output"

  rm "$fakebin/claude"
  native=$(readlink "$fakebin/claude-real")
  mv "$native" "$native.real"
  cat > "$dir/compiled-claude-wrapper.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int has_arg(int argc, char **argv, const char *wanted) {
  int i;
  for (i = 1; i < argc; i++) if (strcmp(argv[i], wanted) == 0) return 1;
  return 0;
}

int main(int argc, char **argv) {
  char real[4096], invoked[4096];
  char **wrapped;
  FILE *marker;
  int i;
  snprintf(invoked, sizeof(invoked), "%s.invoked", argv[0]);
  marker = fopen(invoked, "w");
  if (marker) fclose(marker);
  snprintf(real, sizeof(real), "%s.real", argv[0]);
  if (has_arg(argc, argv, "--help") ||
      (has_arg(argc, argv, "auth") && has_arg(argc, argv, "status")) ||
      has_arg(argc, argv, "-p")) {
    execv(real, argv);
    return 81;
  }
  wrapped = calloc((size_t)argc + 7, sizeof(char *));
  if (!wrapped) return 82;
  wrapped[0] = "av";
  wrapped[1] = "inject";
  wrapped[2] = "+CLAUDE_CODE_OAUTH_TOKEN";
  wrapped[3] = "--";
  wrapped[4] = "claude";
  for (i = 1; i < argc; i++) wrapped[i + 4] = argv[i];
  execvp(wrapped[0], wrapped);
  return 83;
}
C
  cc_bin=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null) \
    || fail "test needs a C compiler for the compiled wrapper fixture"
  "$cc_bin" -o "$native" "$dir/compiled-claude-wrapper.c" \
    || fail "could not build compiled Claude wrapper fixture"
  rm "$fakebin/claude-real"
  ln -s "$native" "$fakebin/claude"
  before=$(wc -l < "$state/av-argv.log" | tr -d ' ')
  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    TEST_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "compiled forwarding Claude wrapper was accepted"
  assert_contains "$output" "does not match Anthropic release attestation" \
    "compiled wrapper attestation refusal was not actionable"
  [ ! -e "$native.invoked" ] || fail "compiled wrapper ran before artifact attestation refused it"
  [ "$(wc -l < "$state/av-argv.log" | tr -d ' ')" = "$before" ] \
    || fail "compiled wrapper reached Automic Vault before attestation refusal"
  assert_secret_absent "$dir" "$output"
  pass "Vault, token, version-surface, inconclusive, and direct or forwarding wrapper failures all block before launch"
}

test_preflight_xtrace_redaction() {
  local dir home fakebin state fail_at stdout stderr trace status output
  dir="$TMP_ROOT/preflight-xtrace"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  configure_fake_attestation "$fakebin" "$state"
  mkdir -p "$home/config"
  printf 'on\n' > "$home/config/claude-automic-vault"
  for fail_at in 1 2; do
    rm -f "$state/av-inject-count"
    stdout="$dir/preflight-$fail_at.out"
    stderr="$dir/preflight-$fail_at.err"
    trace="$dir/preflight-$fail_at.trace"
    (
      builtin exec 9>"$trace"
      BASH_XTRACEFD=9
      export BASH_XTRACEFD SHELLOPTS
      set -x
      FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
        FM_FAKE_AV_FAIL_AT="$fail_at" PATH="$fakebin:$BASE_PATH" \
        "$AUTH" preflight
    ) >"$stdout" 2>"$stderr"
    status=$?
    [ "$status" -ne 0 ] || fail "xtraced preflight stage $fail_at did not fail closed"
    output=$(cat "$stdout" "$stderr" "$trace")
    assert_contains "$output" "Automic Vault is unavailable or locked" \
      "xtraced preflight stage $fail_at omitted its redacted classification"
    assert_not_contains "$output" "$SECRET" \
      "xtraced preflight stage $fail_at exposed raw injection output"
  done
  assert_secret_absent "$dir" ""
  pass "auth and live preflight classification remain redacted under inherited xtrace controls"
}

test_launch_time_failure_redaction_and_interactive_io() {
  local dir home fakebin state record proj wt launchlog output status launch hostilebin leak native before cc_bin replacement marker expected signal expected_status block relay_pid attempt pidfile watcher_pid watcher_status
  dir="$TMP_ROOT/launch-boundary"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  configure_fake_attestation "$fakebin" "$state"
  record=$(make_ship "$dir" "$home" launch-boundary)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  launchlog="$dir/launch.log"
  : > "$launchlog"
  printf 'on\n' > "$home/config/claude-automic-vault"

  output=$(run_spawn "$home" "$fakebin" "$state" "$launchlog" "$wt" \
    launch-boundary "$proj" claude --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "launch-boundary spawn"
  launch=$(last_launch_command "$launchlog")
  printf 'interactive\n' > "$state/control-claude-mode"

  output=$(cd "$wt" && printf 'captain-input\n' | \
    FM_FAKE_STATE="$state" FM_FAKE_CLAUDE_MODE=interactive \
    PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  expect_code 0 "$status" "interactive relayed launch"
  assert_contains "$output" "interactive stdout: captain-input" "worker stdin or stdout was not preserved"
  assert_contains "$output" "interactive stderr: authenticated" "worker stderr was not preserved"

  native="${fakebin%/fakebin}/fake-home/.local/share/claude/versions/2.1.220"
  for signal in HUP INT TERM; do
    case "$signal" in
      HUP) expected_status=129 ;;
      INT) expected_status=130 ;;
      TERM) expected_status=143 ;;
    esac
    block="$dir/interrupted-$signal"
    pidfile="$block.pid"
    rm -f "$block" "$block.release" "$pidfile"
    printf '%s\n' "$block" > "$state/control-block-file"
    (
      cd "$wt" || exit 1
      (
        attempt=0
        while { [ ! -e "$block" ] || [ ! -e "$pidfile" ]; } && [ "$attempt" -lt 250 ]; do
          sleep 0.02
          attempt=$((attempt + 1))
        done
        if [ ! -e "$block" ] || [ ! -e "$pidfile" ]; then
          : > "$block.release"
          exit 91
        fi
        if ! find "${native%/versions/*}" -maxdepth 1 -type d -name '.firstmate-launch.*' -print -quit | grep -q .; then
          : > "$block.release"
          exit 92
        fi
        relay_pid=$(cat "$pidfile")
        kill -s "$signal" "$relay_pid" || {
          : > "$block.release"
          exit 93
        }
        : > "$block.release"
      ) &
      watcher_pid=$!
      FM_TEST_PIDFILE="$pidfile" FM_TEST_LAUNCH="$launch" FM_FAKE_STATE="$state" \
        FM_FAKE_AV_BLOCK_FILE="$block" \
        PATH="$fakebin:$BASE_PATH" bash -c \
        'printf "%s\n" "$$" > "$FM_TEST_PIDFILE"; exec bash -c "$FM_TEST_LAUNCH"'
      status=$?
      wait "$watcher_pid"
      watcher_status=$?
      [ "$watcher_status" -eq 0 ] || exit "$watcher_status"
      exit "$status"
    ) > "$dir/interrupted-$signal.out" 2>&1
    status=$?
    expect_code "$expected_status" "$status" "$signal launch interruption"
    rm -f "$state/control-block-file"
    if find "${native%/versions/*}" -maxdepth 1 -type d -name '.firstmate-launch.*' -print -quit | grep -q .; then
      fail "$signal launch interruption left private launch state"
    fi
  done

  hostilebin="$dir/hostile-bin"
  leak="$dir/startup-token-leak"
  mkdir -p "$hostilebin"
  cat > "$dir/hostile-startup.sh" <<'SH'
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "${FM_HOSTILE_LEAK:?}"
fi
SH
  cat > "$hostilebin/bash" <<'SH'
#!/bin/sh
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "${FM_HOSTILE_LEAK:?}"
fi
exec /bin/bash "$@"
SH
  chmod +x "$hostilebin/bash"
  output=$(cd "$wt" && printf 'startup-clean-input\n' | \
    env BASH_ENV="$dir/hostile-startup.sh" ENV="$dir/hostile-startup.sh" \
      SHELLOPTS=xtrace FM_HOSTILE_LEAK="$leak" FM_FAKE_STATE="$state" \
      FM_FAKE_CLAUDE_MODE=interactive \
      PATH="$hostilebin:$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  expect_code 0 "$status" "startup-clean interactive launch"
  [ ! -e "$leak" ] || fail "hostile shell startup controls observed the injected token"
  assert_contains "$output" "interactive stdout: startup-clean-input" "startup-clean launch did not preserve interactive I/O"
  assert_not_contains "$output" "$SECRET" "shell tracing exposed the injected token"

  leak="$dir/exported-function-token-leak"
  # shellcheck disable=SC2329 # Exported for indirect invocation by the child shell.
  exec() {
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "${FM_HOSTILE_LEAK:?}"
    fi
    builtin exec "$@"
  }
  export -f exec
  output=$(cd "$wt" && printf 'function-clean-input\n' | \
    env FM_HOSTILE_LEAK="$leak" FM_FAKE_STATE="$state" \
      FM_FAKE_CLAUDE_MODE=interactive PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  unset -f exec
  expect_code 0 "$status" "exported-function-clean interactive launch"
  [ ! -e "$leak" ] || fail "exported exec function observed the injected token"
  assert_contains "$output" "interactive stdout: function-clean-input" \
    "exported-function-clean launch did not preserve interactive I/O"
  assert_not_contains "$output" "$SECRET" "exported exec function exposed the injected token"

  rm -f "$state/av-inject-count"
  printf '1\n' > "$state/control-fail-at"
  output=$(cd "$wt" && FM_FAKE_STATE="$state" \
    FM_FAKE_AV_FAIL_AT=1 PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  rm -f "$state/control-fail-at"
  [ "$status" -ne 0 ] || fail "launch-time injection failure did not block Claude exec"
  assert_contains "$output" "unavailable or locked" "launch-time Vault failure was not classified"
  assert_not_contains "$output" "$SECRET" "launch-time Vault failure exposed raw output"

  replacement="$dir/race-replacement"
  marker="$dir/race-replacement-ran"
  cat > "$dir/race-replacement.c" <<'C'
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  const char *marker = getenv("FM_FAKE_SWAP_MARKER");
  FILE *out;
  if (!marker) return 91;
  out = fopen(marker, "w");
  if (!out) return 92;
  fputs(getenv("CLAUDE_CODE_OAUTH_TOKEN") ? "token-present\n" : "token-absent\n", out);
  fclose(out);
  return 0;
}
C
  cc_bin=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null) \
    || fail "test needs a C compiler for the launch-race fixture"
  "$cc_bin" -o "$replacement" "$dir/race-replacement.c" \
    || fail "could not build launch-race replacement fixture"
  expected=$(cat "$state/expected-claude-sha256")
  printf '%s\n' "$replacement" > "$state/control-swap-source"
  printf '%s\n' "$native" > "$state/control-swap-target"
  printf '%s\n' "$marker" > "$state/control-swap-marker"
  output=$(cd "$wt" && printf 'race-input\n' | \
    FM_FAKE_STATE="$state" FM_FAKE_CLAUDE_MODE=interactive \
    FM_FAKE_AV_SWAP_SOURCE="$replacement" FM_FAKE_AV_SWAP_TARGET="$native" \
    FM_FAKE_SWAP_MARKER="$marker" PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  rm -f "$state/control-swap-source" "$state/control-swap-target" "$state/control-swap-marker"
  expect_code 0 "$status" "pathname replacement during injected launch"
  [ ! -e "$marker" ] || fail "replacement executable ran during the attestation-to-exec race"
  [ "$(sha256_file "$native")" != "$expected" ] || fail "race fixture did not replace the version pathname"
  assert_contains "$output" "interactive stdout: race-input" \
    "pinned Claude file object did not preserve interactive execution through the race"

  before=$(cat "$state/av-inject-count")
  printf 'changed-after-attestation' >> "$native"
  output=$(cd "$wt" && FM_FAKE_STATE="$state" \
    PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "changed Claude artifact was launched after preflight"
  assert_contains "$output" "executable changed after preflight" \
    "launch-time artifact replacement was not actionable"
  [ "$(cat "$state/av-inject-count")" = "$before" ] \
    || fail "changed Claude artifact reached Automic Vault injection"
  assert_secret_absent "$dir" "$output"
  pass "launch-time failures are redacted, identity stays pinned, and successful worker I/O stays interactive"
}

make_secondmate_home() {  # <home> <id>
  local home=$1 id=$2 rel
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'config/\ndata/\nstate/\nprojects/\n.fm-secondmate-home\n' > "$home/.gitignore"
  for rel in \
    fm-claude-automic-vault-owner-version \
    fm-claude-automic-vault-lib.sh \
    fm-claude-automic-vault-launch.sh \
    fm-config-inherit-lib.sh \
    fm-spawn.sh; do
    cp "$ROOT/bin/$rel" "$home/bin/$rel"
  done
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
  git init -q -b main "$home"
  git -C "$home" add .gitignore AGENTS.md bin
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm compatible-owner
}

test_secondmate_inheritance_launch_relaunch_and_nested_worker() {
  local dir primary sm sm_abs fakebin state launchlog output status launch record proj wt before after before_endpoint traceparent store leak executed
  dir="$TMP_ROOT/secondmate"
  primary="$dir/primary"
  sm="$dir/secondmate-home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  configure_fake_attestation "$fakebin" "$state"
  launchlog="$dir/launch.log"
  mkdir -p "$primary/data" "$primary/state" "$primary/config" "$primary/projects"
  printf 'claude\n' > "$primary/config/crew-harness"
  printf 'claude\n' > "$primary/config/secondmate-harness"
  printf 'on\n' > "$primary/config/claude-automic-vault"
  make_secondmate_home "$sm" sm-vault
  : > "$launchlog"
  traceparent=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01
  store="$dir/claude-store"

  rm "$sm/bin/fm-claude-automic-vault-owner-version"
  before_endpoint=0
  [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
  output=$(run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
    sm-vault "$sm" claude --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate without a compatible Vault owner launched"
  assert_contains "$output" "destination home $(cd "$sm" && pwd -P) lacks the compatible tracked authentication owner version 1" \
    "secondmate owner compatibility refusal did not name the destination and version"
  [ ! -e "$sm/config/claude-automic-vault" ] \
    || fail "incompatible secondmate home received the Claude Vault opt-in"
  [ ! -s "$launchlog" ] || fail "incompatible secondmate owner sent a launch command"
  if [ -f "$state/endpoint.log" ]; then
    [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
      || fail "incompatible secondmate owner created an endpoint"
  fi
  printf '2\n' > "$sm/bin/fm-claude-automic-vault-owner-version"
  output=$(run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
    sm-vault "$sm" claude --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate with an incompatible Vault owner launched"
  assert_contains "$output" "compatible tracked authentication owner version 1" \
    "incompatible secondmate owner version was not refused"
  [ ! -e "$sm/config/claude-automic-vault" ] \
    || fail "incompatible secondmate owner received the Claude Vault opt-in"
  cp "$ROOT/bin/fm-claude-automic-vault-owner-version" "$sm/bin/fm-claude-automic-vault-owner-version"

  before=0
  [ ! -f "$state/av-argv.log" ] || before=$(wc -l < "$state/av-argv.log")
  before_endpoint=0
  [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
  output=$(FM_INHERITABLE_CONFIG=crew-harness \
    run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
      sm-vault "$sm" claude --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate launched without inherited Claude Vault opt-in"
  assert_contains "$output" "requires the enabled Claude Automic Vault flag to converge" \
    "secondmate inheritance refusal was not actionable"
  [ ! -s "$launchlog" ] || fail "secondmate inheritance refusal sent a launch command"
  after=0
  [ ! -f "$state/av-argv.log" ] || after=$(wc -l < "$state/av-argv.log")
  [ "$after" = "$before" ] || fail "secondmate inheritance refusal contacted Automic Vault"
  if [ -f "$state/endpoint.log" ]; then
    [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
      || fail "secondmate inheritance refusal created an endpoint"
  fi

  output=$(CLAUDE_CONFIG_DIR="$store" run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
    sm-vault "$sm" claude --secondmate --traceparent "$traceparent" 2>&1)
  status=$?
  expect_code 0 "$status" "enabled Claude secondmate launch"
  [ "$(cat "$sm/config/claude-automic-vault")" = on ] || fail "secondmate did not inherit opt-in"
  sm_abs=$(sed -n 's/^home=//p' "$primary/state/sm-vault.meta")
  launch=$(last_launch_command "$launchlog")
  assert_sanitized_launch "$launch" "$fakebin"
  leak="$dir/secondmate-exported-function-token-leak"
  # shellcheck disable=SC2120,SC2329 # Exported for indirect invocation by the child shell.
  exec() {
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
      printf '%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" > "${FM_HOSTILE_LEAK:?}"
    fi
    builtin exec "$@"
  }
  export -f exec
  executed=$(cd "$sm" && FM_FAKE_STATE="$state" FM_HOSTILE_LEAK="$leak" \
    TRACEPARENT="$traceparent" PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  unset -f exec
  expect_code 0 "$status" "enabled Claude secondmate environment"
  [ ! -e "$leak" ] || fail "exported exec function observed the secondmate token"
  assert_grep "FM_HOME=$sm_abs" "$state/claude-env.log" \
    "secondmate launch dropped FM_HOME"
  assert_grep 'FM_SUPERVISION_MODEL=autoarm' "$state/claude-env.log" \
    "secondmate launch dropped FM_SUPERVISION_MODEL"
  assert_grep "TRACEPARENT=$traceparent" "$state/claude-env.log" \
    "secondmate launch dropped TRACEPARENT"
  assert_grep "CLAUDE_CONFIG_DIR=$store" "$state/claude-env.log" \
    "secondmate launch dropped CLAUDE_CONFIG_DIR"
  assert_not_contains "$executed" "$SECRET" \
    "secondmate environment execution exposed the synthetic token"

  printf '\n' >> "$sm/bin/fm-spawn.sh"
  : > "$launchlog"
  before_endpoint=0
  [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
  output=$(FM_FAKE_WINDOWS=fm-sm-vault run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
    sm-vault --relaunch --harness claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate relaunched with dirty Vault owner code"
  assert_contains "$output" \
    "launch requires destination home $sm_abs to retain the compatible tracked authentication owner version 1" \
    "secondmate launch did not independently recheck the tracked Vault owner"
  [ ! -s "$launchlog" ] || fail "dirty secondmate owner sent a relaunch command"
  if [ -f "$state/endpoint.log" ]; then
    [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
      || fail "dirty secondmate owner created an endpoint"
  fi
  git -C "$sm" show HEAD:bin/fm-spawn.sh > "$sm/bin/fm-spawn.sh"

  rm "$sm/config/claude-automic-vault"
  : > "$launchlog"
  before=0
  [ ! -f "$state/av-argv.log" ] || before=$(wc -l < "$state/av-argv.log")
  before_endpoint=0
  [ ! -f "$state/endpoint.log" ] || before_endpoint=$(wc -l < "$state/endpoint.log")
  output=$(FM_INHERITABLE_CONFIG=crew-harness FM_FAKE_WINDOWS=fm-sm-vault \
    run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
      sm-vault --relaunch --harness claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate relaunched without inherited Claude Vault opt-in"
  assert_contains "$output" "requires the enabled Claude Automic Vault flag to converge" \
    "secondmate relaunch inheritance refusal was not actionable"
  [ ! -s "$launchlog" ] || fail "secondmate relaunch inheritance refusal sent a launch command"
  after=0
  [ ! -f "$state/av-argv.log" ] || after=$(wc -l < "$state/av-argv.log")
  [ "$after" = "$before" ] || fail "secondmate relaunch inheritance refusal contacted Automic Vault"
  if [ -f "$state/endpoint.log" ]; then
    [ "$(wc -l < "$state/endpoint.log")" = "$before_endpoint" ] \
      || fail "secondmate relaunch inheritance refusal created an endpoint"
  fi

  : > "$launchlog"
  output=$(FM_FAKE_WINDOWS=fm-sm-vault run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
    sm-vault --relaunch --harness claude 2>&1)
  status=$?
  expect_code 0 "$status" "enabled Claude secondmate relaunch"
  launch=$(last_launch_command "$launchlog")
  assert_sanitized_launch "$launch" "$fakebin"

  : > "$launchlog"
  record=$(make_ship "$dir" "$sm" nested-worker)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$sm" "$fakebin" "$state" "$launchlog" "$wt" \
    nested-worker "$proj" claude --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "nested worker from inherited secondmate home"
  launch=$(last_launch_command "$launchlog")
  assert_sanitized_launch "$launch" "$fakebin"
  assert_secret_absent "$dir" "$output"
  pass "secondmate launch, relaunch, inheritance, and nested worker all use the same local injection contract"
}

test_provision_recovery_renewal_preflight_and_redaction
test_enabled_disabled_and_non_claude_launches
test_actionable_fail_closed_paths
test_preflight_xtrace_redaction
test_launch_time_failure_redaction_and_interactive_io
test_secondmate_inheritance_launch_relaunch_and_nested_worker

printf '# all fm-claude-automic-vault tests passed\n'
