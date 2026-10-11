#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-phase/tmp/ff-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TMPDIR="$LAB"
FM_HOME=$(bin/fm-lab-home.sh create "$LAB/home")
export FM_HOME FM_FLEET_PRUNE=0
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
BASE=c4498d09cfa2afabac6d7586f5d2995cceefc60a
TARGET=6b9c65871656d79696ea605ec74236e564b532c7
UPSTREAM=072a7da3eee2632fc02a6e0674d7601ca25a30ba
git clone -q --bare --no-hardlinks "$ROOT" "$LAB/origin.git"
git -C "$LAB/origin.git" update-ref refs/heads/main "$TARGET"
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$FM_HOME/projects/fork"
CONSUMER="$FM_HOME/projects/fork"
git -C "$CONSUMER" reset -q --hard "$BASE"
printf 'disposable uncommitted work\n' >> "$CONSUMER/README.md"
printf '\nAttempt sync with uncommitted work:\n'
bin/fm-fleet-sync.sh fork
[ "$(git -C "$CONSUMER" rev-parse HEAD)" = "$BASE" ]
grep -q 'disposable uncommitted work' "$CONSUMER/README.md"
printf 'The dirty checkout remained at the fork base and retained the edit.\n'
git -C "$CONSUMER" checkout -- README.md
printf '\nFast-forward clean fork checkout:\n'
bin/fm-fleet-sync.sh fork
[ "$(git -C "$CONSUMER" rev-parse HEAD)" = "$TARGET" ]
git -C "$CONSUMER" merge-base --is-ancestor "$BASE" HEAD
git -C "$CONSUMER" merge-base --is-ancestor "$UPSTREAM" HEAD
printf 'Fast-forward result HEAD=%s\n' "$(git -C "$CONSUMER" rev-parse HEAD)"
printf 'Merge commit and parents: '
git -C "$CONSUMER" rev-list --parents -n 1 HEAD
printf 'Retained fork corrections:\n'
git -C "$CONSUMER" log -7 --format='%h %s' "$BASE"
