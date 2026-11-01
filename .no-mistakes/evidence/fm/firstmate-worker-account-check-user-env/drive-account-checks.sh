#!/usr/bin/env bash
set -eu
ROOT=$PWD
FIX=$ROOT/.test-tmp/manual
CLAUDE_REAL=$(command -v claude)
PI_REAL=$(command -v pi)
mkdir -p "$FIX/home/.claude" "$FIX/claude-root" "$FIX/pi-root" "$FIX/bin" "$FIX/config" "$FIX/failed-id" "$FIX/empty-id" "$FIX/baseline"
printf '{"apiKeyHelper":"echo sk-ant-fm-synthetic"}\n' > "$FIX/claude-root/settings.json"
cp "$FIX/claude-root/settings.json" "$FIX/home/.claude/settings.json"
printf '{"openai":{"type":"api_key","key":"sk-fm-synthetic"}}\n' > "$FIX/pi-root/auth.json"
printf '#!/bin/sh\nprintf "invalid-login\\n"\nexit 1\n' > "$FIX/failed-id/id"
printf '#!/bin/sh\nexit 0\n' > "$FIX/empty-id/id"
chmod +x "$FIX/failed-id/id" "$FIX/empty-id/id"
for harness in claude pi; do
  if [ "$harness" = claude ]; then real=$CLAUDE_REAL; else real=$PI_REAL; fi
  cat > "$FIX/bin/$harness" <<SCRIPT
#!/bin/bash
printf 'vendor=$harness USER=%s LOGNAME=%s CLAUDE_ROOT=%s PI_ROOT=%s API=%s OAUTH=%s\\n' "\${USER-unset}" "\${LOGNAME-unset}" "\${CLAUDE_CONFIG_DIR-unset}" "\${PI_CODING_AGENT_DIR-unset}" "\${ANTHROPIC_API_KEY-unset}" "\${CLAUDE_CODE_OAUTH_TOKEN-unset}" >> '$FIX/vendor-environment.log'
exec '$real' "\$@"
SCRIPT
  chmod +x "$FIX/bin/$harness"
done
git show 6ea2ad23:bin/fm-worker-account-lib.sh > "$FIX/baseline/fm-worker-account-lib.sh"
cp bin/fm-timeout-lib.sh "$FIX/baseline/fm-timeout-lib.sh"
check() {
  local lib=$1 harness=$2 path=$3 expected=$4 names=$5 out rc=0
  local -a args=()
  [ "$names" = absent ] || args+=(USER=caller-user LOGNAME=caller-logname)
  out=$(env -i HOME="$FIX/home" PATH="$path" ANTHROPIC_API_KEY=caller-key CLAUDE_CODE_OAUTH_TOKEN=caller-token "${args[@]}" bash -c '
    . "$1"
    fm_worker_account_select "$2" "$3" openai/gpt-5.5 "$4"
  ' bash "$lib" "$harness" "$FIX/config" "$FIX/bin/$harness" 2>&1) || rc=$?
  printf 'library=%s runner=%s identity=%s caller_names=%s exit=%s result=%s\n' "${lib#"$ROOT/"}" "$harness" "${path%%:*}" "$names" "$rc" "$out"
  [ "$rc" = "$expected" ]
}
for harness in claude pi; do
  if [ "$harness" = claude ]; then
    printf '%s\n' "$FIX/claude-root" > "$FIX/config/claude-account"
  else
    printf '%s\nopenai\n' "$FIX/pi-root" > "$FIX/config/pi-account"
  fi
  for names in absent supplied; do
    check "$ROOT/bin/fm-worker-account-lib.sh" "$harness" "$PATH" 0 "$names"
    check "$ROOT/bin/fm-worker-account-lib.sh" "$harness" "$FIX/failed-id:$PATH" 1 "$names"
    check "$ROOT/bin/fm-worker-account-lib.sh" "$harness" "$FIX/empty-id:$PATH" 1 "$names"
  done
  check "$FIX/baseline/fm-worker-account-lib.sh" "$harness" "$FIX/failed-id:$PATH" 0 supplied
done
printf 'ordinary\n' > "$FIX/config/claude-account"
for names in absent supplied; do
  check "$ROOT/bin/fm-worker-account-lib.sh" claude "$PATH" 0 "$names"
done
printf '\nActual environment at the real vendor executable boundary:\n'
cat "$FIX/vendor-environment.log"
