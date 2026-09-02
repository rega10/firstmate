#!/usr/bin/env bash
# Public behavior coverage for the local Claude Code Automic Vault opt-in.
# All credentials are synthetic and held only in process environment.
# Fake av and claude executables exercise the same executable paths operators
# and fm-spawn use; the tests never inspect production source text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTH="$ROOT/bin/fm-claude-automic-vault.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-automic-vault)
JQ_BIN=$(command -v jq) || fail "test needs jq"
BASE_PATH="$(dirname "$JQ_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
SECRET='sk-ant-oat01-FM_SYNTHETIC_SENTINEL_NEVER_PERSIST'

make_fake_tools() {  # <case-dir>
  local dir=$1 fakebin native_dir cc_bin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/fake-state"
  cat > "$fakebin/av" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_STATE:?}
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
    [ "$supplied" = "${FM_FAKE_SECRET:?}" ] || exit 32
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
printf 'inject' >> "$state/av-argv.log"
for arg in "$@"; do printf ' <%s>' "$arg" >> "$state/av-argv.log"; done
printf '\n' >> "$state/av-argv.log"
count_file="$state/av-inject-count"
count=0
[ ! -f "$count_file" ] || count=$(cat "$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "${FM_FAKE_AV_FAIL_AT:-0}" = "$count" ]; then
  printf 'Vault unavailable: failed to connect %s\n' "${FM_FAKE_SECRET:?}" >&2
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
export CLAUDE_CODE_OAUTH_TOKEN=${FM_FAKE_SECRET:?}
exec "$@"
SH
  native_dir="$dir/fake-home/.local/share/claude/versions"
  mkdir -p "$native_dir"
  cat > "$dir/fake-claude.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  const char *secret = getenv("FM_FAKE_SECRET");
  const char *mode = getenv("FM_FAKE_CLAUDE_MODE");
  char path[4096];
  int i;
  if (!state && has_arg(argc, argv, "auth") && has_arg(argc, argv, "status")) {
    puts("{\"loggedIn\":false,\"authMethod\":\"none\",\"apiProvider\":\"firstParty\"}");
    return 1;
  }
  if (argc == 2 && strcmp(argv[1], "--help") == 0) {
    if (getenv("FM_FAKE_CLAUDE_HELP_MODE") && strcmp(getenv("FM_FAKE_CLAUDE_HELP_MODE"), "old") == 0)
      puts("setup-token --print");
    else
      puts("setup-token --settings --safe-mode --no-session-persistence --output-format --tools --print");
    return 0;
  }
  if (argc >= 4 && strcmp(argv[1], "auth") == 0 && strcmp(argv[2], "status") == 0 && strcmp(argv[3], "--help") == 0) {
    puts("Usage: claude auth status --json");
    return 0;
  }
  if (argc >= 2 && strcmp(argv[1], "setup-token") == 0) {
    if (!secret) return 71;
    printf("Complete browser authentication.\n%s\n", secret);
    return 0;
  }
  if (!state || !secret) return 72;
  snprintf(path, sizeof(path), "%s/claude-argv.log", state);
  append_args(path, argc, argv);
  snprintf(path, sizeof(path), "%s/claude-env.log", state);
  append_line(path, getenv("CLAUDE_CODE_OAUTH_TOKEN") && strcmp(getenv("CLAUDE_CODE_OAUTH_TOKEN"), secret) == 0 ? "oauth=present" : "oauth=missing");
  {
    const char *names[] = {"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK"};
    for (i = 0; i < 4; i++) if (getenv(names[i]) && *getenv(names[i])) {
      char line[256];
      snprintf(line, sizeof(line), "conflict=%s", names[i]);
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
    if (mode && strcmp(mode, "revoked") == 0) {
      puts("{\"type\":\"result\",\"is_error\":true,\"api_error_status\":401,\"error\":\"authentication_error\"}");
      return 1;
    }
    puts("{\"type\":\"result\",\"is_error\":false,\"result\":\"OK\"}");
    return 0;
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
  has-session|new-session|new-window|kill-window)
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/av" "$fakebin/tmux" "$fakebin/treehouse"
  (cd "$fakebin" && pwd -P)
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
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_STATE="$state" FM_FAKE_SECRET="$SECRET" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_PATH="$pane" TMUX='fake,1,0' \
    PATH="$fakebin:$BASE_PATH" "$SPAWN" "$@"
}

test_provision_recovery_renewal_preflight_and_redaction() {
  local dir home fakebin state output status
  dir="$TMP_ROOT/provision"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  mkdir -p "$home/config"
  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    FM_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" provision 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "synthetic provision ceremony exited $status: ${output//$SECRET/[REDACTED]}"
  fi
  [ "$(cat "$home/config/claude-automic-vault")" = on ] || fail "provision did not enable exact local flag"
  [ -e "$state/save-ok" ] || fail "fake av did not receive the setup token through its terminal"
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
    FM_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" enable 2>&1)
  status=$?
  expect_code 0 "$status" "one-time enable recovery"
  [ "$(cat "$home/config/claude-automic-vault")" = on ] || fail "enable recovery did not restore the opt-in"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    FM_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" renew 2>&1)
  status=$?
  expect_code 0 "$status" "synthetic renewal ceremony"
  assert_contains "$output" "replaced directly" "renewal did not report direct replacement"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    FM_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" preflight 2>&1)
  status=$?
  expect_code 0 "$status" "redacted public preflight"
  assert_contains "$output" "credential material was not displayed" "preflight omitted its redaction guarantee"
  assert_secret_absent "$dir" "$output"
  pass "provision, recovery, renewal, and preflight keep the synthetic credential off every output and file"
}

test_enabled_disabled_and_non_claude_launches() {
  local dir home fakebin state record proj wt launchlog output status launch before executed
  dir="$TMP_ROOT/launches"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
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
  assert_contains "$launch" "fm-claude-automic-vault-launch.sh' '$fakebin/av' '${fakebin%/fakebin}/fake-home/.local/share/claude/versions/2.1.220'" \
    "enabled launch did not pin the redacted injection relay and resolved tools"
  assert_contains "$launch" "--model 'sonnet' --effort 'high'" "enabled launch did not preserve profile arguments"
  assert_not_contains "$launch" "$SECRET" "launch argv contains synthetic secret"
  executed=$(cd "$wt" && FM_FAKE_STATE="$state" FM_FAKE_SECRET="$SECRET" \
    ANTHROPIC_API_KEY=must-be-cleared ANTHROPIC_BASE_URL=https://invalid.example \
    PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1) || fail "captured enabled launch did not execute"
  assert_not_contains "$executed" "$SECRET" "executed worker launch displayed synthetic secret"
  assert_grep 'interactive=authenticated' "$state/claude-env.log" "launched fake Claude was not authenticated"
  assert_no_grep 'conflict=' "$state/claude-env.log" "higher-precedence auth environment reached Claude"

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
  local dir home fakebin state mode output status expected direct wrapper record proj wt launchlog before
  dir="$TMP_ROOT/blockers"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
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
    FM_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_MODE=revoked PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "revoked token did not block"
  assert_contains "$output" "invalid or revoked" "revoked token blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    FM_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_MODE=inconclusive PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "inconclusive auth did not block"
  assert_contains "$output" "inconclusive or selected a credential other" "inconclusive auth blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    FM_FAKE_SECRET="$SECRET" FM_FAKE_AV_HELP_MODE=old PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unsupported Automic Vault surface did not block"
  assert_contains "$output" "does not expose the required" "unsupported Vault blocker was not actionable"
  assert_secret_absent "$dir" "$output"

  output=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_STATE="$state" \
    FM_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_HELP_MODE=old PATH="$fakebin:$BASE_PATH" \
    "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unsupported Claude surface did not block"
  assert_contains "$output" "lacks the required" "unsupported Claude blocker was not actionable"
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
    FM_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" preflight 2>&1)
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
    FM_FAKE_SECRET="$SECRET" PATH="$fakebin:$BASE_PATH" "$AUTH" preflight 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "injecting Claude wrapper was accepted"
  assert_contains "$output" "positively identified" "wrapper recursion refusal was not actionable"
  [ "$(wc -l < "$state/av-argv.log" | tr -d ' ')" = "$before" ] \
    || fail "indirect wrapper reached Automic Vault before identity refusal"
  assert_secret_absent "$dir" "$output"
  pass "Vault, token, version-surface, inconclusive, and direct or forwarding wrapper failures all block before launch"
}

test_launch_time_failure_redaction_and_interactive_io() {
  local dir home fakebin state record proj wt launchlog output status launch hostilebin leak
  dir="$TMP_ROOT/launch-boundary"
  home="$dir/home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
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

  output=$(cd "$wt" && printf 'captain-input\n' | \
    FM_FAKE_STATE="$state" FM_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_MODE=interactive \
    PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  expect_code 0 "$status" "interactive relayed launch"
  assert_contains "$output" "interactive stdout: captain-input" "worker stdin or stdout was not preserved"
  assert_contains "$output" "interactive stderr: authenticated" "worker stderr was not preserved"

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
      FM_FAKE_SECRET="$SECRET" FM_FAKE_CLAUDE_MODE=interactive \
      PATH="$hostilebin:$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  expect_code 0 "$status" "startup-clean interactive launch"
  [ ! -e "$leak" ] || fail "hostile shell startup controls observed the injected token"
  assert_contains "$output" "interactive stdout: startup-clean-input" "startup-clean launch did not preserve interactive I/O"
  assert_not_contains "$output" "$SECRET" "shell tracing exposed the injected token"

  rm -f "$state/av-inject-count"
  output=$(cd "$wt" && FM_FAKE_STATE="$state" FM_FAKE_SECRET="$SECRET" \
    FM_FAKE_AV_FAIL_AT=1 PATH="$fakebin:$BASE_PATH" bash -c "$launch" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "launch-time injection failure did not block Claude exec"
  assert_contains "$output" "unavailable or locked" "launch-time Vault failure was not classified"
  assert_not_contains "$output" "$SECRET" "launch-time Vault failure exposed raw output"
  assert_secret_absent "$dir" "$output"
  pass "launch-time failures are redacted while successful worker I/O stays interactive"
}

make_secondmate_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

test_secondmate_inheritance_launch_relaunch_and_nested_worker() {
  local dir primary sm fakebin state launchlog output status launch record proj wt
  dir="$TMP_ROOT/secondmate"
  primary="$dir/primary"
  sm="$dir/secondmate-home"
  fakebin=$(make_fake_tools "$dir")
  state="$dir/fake-state"
  launchlog="$dir/launch.log"
  mkdir -p "$primary/data" "$primary/state" "$primary/config" "$primary/projects"
  printf 'claude\n' > "$primary/config/crew-harness"
  printf 'claude\n' > "$primary/config/secondmate-harness"
  printf 'on\n' > "$primary/config/claude-automic-vault"
  make_secondmate_home "$sm" sm-vault
  : > "$launchlog"

  output=$(run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
    sm-vault "$sm" claude --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "enabled Claude secondmate launch"
  [ "$(cat "$sm/config/claude-automic-vault")" = on ] || fail "secondmate did not inherit opt-in"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" "fm-claude-automic-vault-launch.sh' '$fakebin/av' '${fakebin%/fakebin}/fake-home/.local/share/claude/versions/2.1.220'" \
    "secondmate launch did not use the pinned Vault relay"

  : > "$launchlog"
  output=$(FM_FAKE_WINDOWS=fm-sm-vault run_spawn "$primary" "$fakebin" "$state" "$launchlog" "$sm" \
    sm-vault --relaunch --harness claude 2>&1)
  status=$?
  expect_code 0 "$status" "enabled Claude secondmate relaunch"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" "fm-claude-automic-vault-launch.sh' '$fakebin/av' '${fakebin%/fakebin}/fake-home/.local/share/claude/versions/2.1.220'" \
    "secondmate relaunch did not reuse the pinned Vault relay"

  : > "$launchlog"
  record=$(make_ship "$dir" "$sm" nested-worker)
  proj=${record%%$'\t'*}
  wt=${record#*$'\t'}
  output=$(run_spawn "$sm" "$fakebin" "$state" "$launchlog" "$wt" \
    nested-worker "$proj" claude --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "nested worker from inherited secondmate home"
  launch=$(last_launch_command "$launchlog")
  assert_contains "$launch" "fm-claude-automic-vault-launch.sh' '$fakebin/av' '${fakebin%/fakebin}/fake-home/.local/share/claude/versions/2.1.220'" \
    "nested worker did not use the inherited pinned Vault relay"
  assert_secret_absent "$dir" "$output"
  pass "secondmate launch, relaunch, inheritance, and nested worker all use the same local injection contract"
}

test_provision_recovery_renewal_preflight_and_redaction
test_enabled_disabled_and_non_claude_launches
test_actionable_fail_closed_paths
test_launch_time_failure_redaction_and_interactive_io
test_secondmate_inheritance_launch_relaunch_and_nested_worker

printf '# all fm-claude-automic-vault tests passed\n'
