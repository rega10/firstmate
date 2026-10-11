#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4ME5F63K13TBCT6DGA2AVZ4
SCRATCH="$ROOT/.test-empty-worktree/live"
mkdir -p "$SCRATCH"
export TMPDIR="$ROOT/.test-empty-worktree/tmp"
export FM_HERDR_LAB_STATE_DIR="$SCRATCH/herdr-state"
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
SESSION=$(bash bin/fm-herdr-lab.sh name empty-worktree)
LAB="$SCRATCH/home"
PREPARED=0
cleanup() {
  status=$?
  trap - EXIT
  if [ "$PREPARED" = 1 ]; then
    if bash bin/fm-herdr-lab.sh teardown "$SESSION"; then
      printf 'Lab teardown completed; unchanged-default-session tripwire passed.\n'
    else
      printf 'Lab teardown FAILED.\n'
      status=1
    fi
  fi
  bash bin/fm-lab-home.sh teardown "$LAB" || status=1
  rm -f "$ROOT/bin/.fm-teardown-before-test.sh"
  rm -rf "$LAB"
  exit "$status"
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB"
PREPARED=1
bash bin/fm-herdr-lab.sh provision "$SESSION"
git init -q -b main "$LAB/projects/project"
git -C "$LAB/projects/project" -c user.name=Lab -c user.email=lab@example.invalid commit -q --allow-empty -m 'Disposable baseline'
git -C "$LAB/projects/project" worktree add -q -b fm/task-x1 "$LAB/local-copy" main
printf 'uncommitted work\n' > "$LAB/local-copy/sentinel"
workspace=$(bash bin/fm-herdr-lab.sh run "$SESSION" workspace create --cwd "$LAB/local-copy" --label cleanup-record-lab --no-focus)
printf '%s\n' "$workspace"
wid=$(printf '%s' "$workspace" | jq -er '.result.workspace.workspace_id')
tab=$(bash bin/fm-herdr-lab.sh run "$SESSION" tab create --workspace "$wid" --cwd "$LAB/local-copy" --label fm-task-x1 --no-focus)
printf '%s\n' "$tab"
tid=$(printf '%s' "$tab" | jq -er '.result.tab.tab_id')
pid=$(printf '%s' "$tab" | jq -er '.result.root_pane.pane_id')
meta="$LAB/state/task-x1.meta"
cat > "$meta" <<EOF
endpoint_task_id=task-x1
window=$SESSION:$pid
worktree=
project=$LAB/projects/project
harness=codex
kind=ship
mode=no-mistakes
spawn_gen=s1.1.1
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$wid
herdr_tab_id=$tid
herdr_pane_id=$pid
EOF
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'done: retained work\n' > "$LAB/state/task-x1.status"
printf '# retained check\n' > "$LAB/state/task-x1.check.sh"
touch "$LAB/state/.last-watcher-beat"
cp "$meta" "$SCRATCH/before.meta"
cp "$LAB/state/task-x1.status" "$SCRATCH/before.status"
cp "$LAB/state/task-x1.check.sh" "$SCRATCH/before.check"
export FM_HOME="$LAB"
git show 81fa3fddbdefd27d5c507a427d4ec4baaa3d65df:bin/fm-teardown.sh > "$ROOT/bin/.fm-teardown-before-test.sh"
for revision in before after; do
  executable="$ROOT/bin/fm-teardown.sh"
  [ "$revision" != before ] || executable="$ROOT/bin/.fm-teardown-before-test.sh"
  for mode in normal force; do
    args=(task-x1)
    [ "$mode" != force ] || args+=(--force)
    rc=0
    bash "$executable" "${args[@]}" > "$SCRATCH/stdout" 2> "$SCRATCH/stderr" || rc=$?
    printf '\n%s cleanup %s: exit=%s\n' "$revision" "$mode" "$rc"
    cat "$SCRATCH/stderr"
    [ "$rc" = 1 ]
    [ ! -s "$SCRATCH/stdout" ]
    if [ "$revision" = after ]; then
      [ "$(grep -c '^REFUSED:' "$SCRATCH/stderr")" = 1 ]
      grep -F "Restore the verified original worktree path in $meta" "$SCRATCH/stderr" >/dev/null
      grep -F 'retry teardown without --force' "$SCRATCH/stderr" >/dev/null
    else
      grep -F 'missing, empty, or ambiguous worktree identity' "$SCRATCH/stderr" >/dev/null
    fi
    cmp "$meta" "$SCRATCH/before.meta"
    cmp "$LAB/state/task-x1.status" "$SCRATCH/before.status"
    cmp "$LAB/state/task-x1.check.sh" "$SCRATCH/before.check"
    [ "$(cat "$LAB/local-copy/sentinel")" = 'uncommitted work' ]
    bash bin/fm-herdr-lab.sh run "$SESSION" pane get "$pid"
    printf 'Preserved: task record, status, check, uncommitted sentinel, and real pane.\n'
  done
done
sed "s|^worktree=$|worktree=$LAB/local-copy|" "$SCRATCH/before.meta" > "$meta"
cp "$meta" "$SCRATCH/restored.meta"
rc=0
bash bin/fm-teardown.sh task-x1 > "$SCRATCH/stdout" 2> "$SCRATCH/stderr" || rc=$?
printf '\nRestored verified path; normal cleanup: exit=%s\n' "$rc"
cat "$SCRATCH/stderr"
[ "$rc" = 1 ]
grep -F 'uncommitted changes present' "$SCRATCH/stderr" >/dev/null
cmp "$meta" "$SCRATCH/restored.meta"
cmp "$LAB/state/task-x1.status" "$SCRATCH/before.status"
cmp "$LAB/state/task-x1.check.sh" "$SCRATCH/before.check"
[ "$(cat "$LAB/local-copy/sentinel")" = 'uncommitted work' ]
bash bin/fm-herdr-lab.sh run "$SESSION" pane get "$pid"
git -C "$LAB/local-copy" status --short
printf 'Dirty-work refusal preserved the restored record, uncommitted work, and real pane.\n'
