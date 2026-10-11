#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4ME5F63K13TBCT6DGA2AVZ4
SCRATCH="$ROOT/.phase-test/live"
mkdir -p "$SCRATCH"
export FM_HERDR_LAB_STATE_DIR="$SCRATCH/herdr-state"
export TMPDIR="$ROOT/.phase-test/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEARDOWN_GUARD_DONE HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID FM_TASK_ID FM_SUPERVISION_ACTOR
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=Validation GIT_AUTHOR_EMAIL=validation@example.invalid GIT_COMMITTER_NAME=Validation GIT_COMMITTER_EMAIL=validation@example.invalid
LAB="$SCRATCH/home"
SESSION=$(bin/fm-herdr-lab.sh name empty-record)
PREPARED=0
BASE="$ROOT/bin/.phase-base-teardown.sh"
cleanup() {
  rc=$?
  if [ "$PREPARED" = 1 ]; then
    if bin/fm-herdr-lab.sh teardown "$SESSION"; then
      echo 'Lab removed; unchanged-default-session tripwire passed.'
    else
      echo 'Lab cleanup failed.'
      rc=1
    fi
  fi
  rm -f "$BASE"
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB"
printf 'manual\n' > "$LAB/config/backlog-backend"
PREPARED=1
bin/fm-herdr-lab.sh provision "$SESSION"
lab() { "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "$@"; }
PROJECT="$SCRATCH/project"
WT="$SCRATCH/wt"
git init -q -b main "$PROJECT"
printf 'base\n' > "$PROJECT/file.txt"
git -C "$PROJECT" add file.txt
git -C "$PROJECT" commit -qm 'Fixture base'
git -C "$PROJECT" worktree add -qb task "$WT"
printf 'uncommitted work\n' > "$WT/sentinel"
CREATE=$(lab workspace create --cwd "$WT" --label fm-empty-record --no-focus)
printf '%s\n' "$CREATE" > "$EVIDENCE/live-pane-created.json"
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id')
TAB=$(printf '%s' "$CREATE" | jq -er '.result.tab.tab_id')
PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id')
ID=empty-record
META="$LAB/state/$ID.meta"
write_meta() {
  local kind=$1 wt=$2 binding=${3:-$ID} mode=${4:-no-mistakes}
  printf '%s\n' "endpoint_task_id=$binding" "window=$SESSION:$PANE" "worktree=$wt" "project=$PROJECT" 'harness=codex' "kind=$kind" "mode=$mode" 'spawn_gen=s1.1.1' 'backend=herdr' "herdr_session=$SESSION" "herdr_workspace_id=$WS" "herdr_tab_id=$TAB" "herdr_pane_id=$PANE" > "$META"
}
write_meta ship ''
printf 'done: work ready\n' > "$LAB/state/$ID.status"
printf '# retained check\n' > "$LAB/state/$ID.check.sh"
cp "$LAB/state/$ID.status" "$SCRATCH/before.status"
cp "$LAB/state/$ID.check.sh" "$SCRATCH/before.check.sh"
preserve() {
  cmp "$META" "$SCRATCH/before.meta"
  cmp "$LAB/state/$ID.status" "$SCRATCH/before.status"
  cmp "$LAB/state/$ID.check.sh" "$SCRATCH/before.check.sh"
  [ "$(cat "$WT/sentinel")" = 'uncommitted work' ]
  lab pane list --workspace "$WS" > "$EVIDENCE/live-pane-after-$LABEL.json"
  jq -e --arg pane "$PANE" '.result.panes[] | select(.pane_id == $pane)' "$EVIDENCE/live-pane-after-$LABEL.json" >/dev/null
  echo 'Task record, status, check, unfinished work, and real pane remain intact.'
}
run_refusal() {
  local cli=$1
  shift
  local rc=0
  cp "$META" "$SCRATCH/before.meta"
  echo "Scenario: $LABEL"
  echo "Command: $cli $ID $*"
  "$cli" "$ID" "$@" > "$EVIDENCE/$LABEL.stdout" 2> "$EVIDENCE/$LABEL.stderr" || rc=$?
  echo "Exit: $rc"
  cat "$EVIDENCE/$LABEL.stderr"
  [ "$rc" -ne 0 ]
  preserve
}
git show 3f2d62a13ca048e1c77a8d09927d3501249bd798:bin/fm-teardown.sh > "$BASE"
chmod +x "$BASE"
for flag in normal force; do
  LABEL="baseline-$flag"
  if [ "$flag" = force ]; then run_refusal "$BASE" --force; else run_refusal "$BASE"; fi
  grep -q 'missing, empty, or ambiguous worktree identity' "$EVIDENCE/$LABEL.stderr"
done
for kind in ship scout; do
  write_meta "$kind" ''
  for flag in normal force; do
    LABEL="empty-$kind-$flag"
    if [ "$flag" = force ]; then run_refusal "$ROOT/bin/fm-teardown.sh" --force; else run_refusal "$ROOT/bin/fm-teardown.sh"; fi
    [ ! -s "$EVIDENCE/$LABEL.stdout" ]
    [ "$(grep -c '^REFUSED:' "$EVIDENCE/$LABEL.stderr")" = 1 ]
    grep -Fq "Restore the verified original worktree path in $META" "$EVIDENCE/$LABEL.stderr"
    grep -Fq 'retry teardown without --force' "$EVIDENCE/$LABEL.stderr"
  done
done
write_meta ship "$WT"
LABEL=restored-dirty
run_refusal "$ROOT/bin/fm-teardown.sh"
grep -q 'uncommitted changes present' "$EVIDENCE/$LABEL.stderr"
write_meta ship "$WT" foreign-task
LABEL=restored-foreign-binding
run_refusal "$ROOT/bin/fm-teardown.sh"
grep -q 'belongs to task foreign-task' "$EVIDENCE/$LABEL.stderr"
write_meta ship "$WT" "$ID" local-only
git -C "$WT" add sentinel
git -C "$WT" commit -qm 'Fixture unlanded work'
LABEL=restored-unlanded
run_refusal "$ROOT/bin/fm-teardown.sh"
grep -q 'commits not yet on main' "$EVIDENCE/$LABEL.stderr"
echo 'All live cleanup scenarios passed.'
