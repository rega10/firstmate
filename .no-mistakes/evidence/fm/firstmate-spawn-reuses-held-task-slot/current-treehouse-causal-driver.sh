#!/usr/bin/env bash
set -eu
LIVE_ROOT="$PWD/.test-tmp/live"
export HOME="$LIVE_ROOT/user-home" TREEHOUSE_ROOT="$LIVE_ROOT/pool"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
POOL_PATH=$(cat "$LIVE_ROOT/pool-path")
OLD_HEAD=$(git -C "$LIVE_ROOT/project" rev-list --max-parents=0 HEAD)
printf 'Causal control: reset only the disposable held checkout to its original fixture commit.\n'
git -C "$POOL_PATH" checkout --quiet --detach "$OLD_HEAD"
printf 'before direct Treehouse allocation HEAD=%s\n' "$(git -C "$POOL_PATH" rev-parse HEAD)"
printf '$ treehouse get --lease --no-fetch\n'
ALLOCATED=$(cd "$LIVE_ROOT/project" && treehouse get --lease --no-fetch)
printf 'allocated=%s\nafter direct Treehouse allocation HEAD=%s\n' "$ALLOCATED" "$(git -C "$POOL_PATH" rev-parse HEAD)"
[ "$ALLOCATED" = "$POOL_PATH" ]
printf 'Firstmate held record still present:\n'
cat "$LIVE_ROOT/home/state/held-unclaimed.meta"
(cd "$LIVE_ROOT/project" && treehouse return "$ALLOCATED")
