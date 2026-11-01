#!/bin/bash
set -eu
FIX="$PWD/.test-tmp/manual"
mkdir -p "$FIX/claude-empty" "$FIX/pi-empty"
for harness in claude pi; do
  printf '\nRunner: %s. Direct vendor check with an ambient synthetic key:\n' "$harness"
  if [ "$harness" = claude ]; then
    env -i HOME="$FIX/home" PATH="$PATH" CLAUDE_CONFIG_DIR="$FIX/claude-empty" ANTHROPIC_API_KEY=sk-ant-fm-synthetic claude auth status
    printf '%s\n' "$FIX/claude-empty" > "$FIX/config/claude-account"
  else
    env -i HOME="$FIX/home" PATH="$PATH" PI_CODING_AGENT_DIR="$FIX/pi-empty" OPENAI_API_KEY=sk-fm-synthetic pi auth check --provider openai --json --no-refresh
    printf '%s\nopenai\n' "$FIX/pi-empty" > "$FIX/config/pi-account"
  fi
  printf 'Firstmate selection for the same empty root and ambient key:\n'
  rc=0
  env -i HOME="$FIX/home" PATH="$PATH" ANTHROPIC_API_KEY=sk-ant-fm-synthetic OPENAI_API_KEY=sk-fm-synthetic bash -c '. "$1"; fm_worker_account_select "$2" "$3" openai/gpt-5.5 "$2"' bash "$PWD/bin/fm-worker-account-lib.sh" "$harness" "$FIX/config" 2>&1 || rc=$?
  printf 'Firstmate exit: %s\n' "$rc"
  [ "$rc" = 1 ]
done
