#!/usr/bin/env bash
set -eu
RUN_ROOT=$PWD
LIVE_ROOT="$RUN_ROOT/.test-tmp/live"
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4ME09EZQSXMS2XFEBXR2HBD
export FM_HERDR_LAB_STATE_DIR="$LIVE_ROOT/tripwire"
export HERDR_CONFIG_PATH="$LIVE_ROOT/herdr.toml"
export TREEHOUSE_ROOT="$LIVE_ROOT/pool"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export SHELL=/bin/sh
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND
HELPER="$RUN_ROOT/bin/fm-herdr-lab.sh"
LAB_SESSION=$("$HELPER" name held-slot)
export LAB_SESSION
cleanup() {
  result=$?
  trap - EXIT
  teardown_result=0
  "$HELPER" teardown "$LAB_SESSION" >> "$EVIDENCE/live-stale-held-repeat.log" 2>&1 || teardown_result=$?
  [ "$teardown_result" = 0 ] || result=1
  printf 'lab teardown exit=%s\n' "$teardown_result" >> "$EVIDENCE/live-stale-held-repeat.log"
  exit "$result"
}
"$HELPER" provision "$LAB_SESSION"
trap cleanup EXIT
lab() { "$HELPER" run "$LAB_SESSION" "$@"; }
printf 'lab=%s\n' "$LAB_SESSION"
lab status --json
mkdir -p "$LIVE_ROOT/project" "$LIVE_ROOT/user-home" "$LIVE_ROOT/tools"
git -C "$LIVE_ROOT/project" init -q -b main
printf 'initial\n' > "$LIVE_ROOT/project/README.md"
git -C "$LIVE_ROOT/project" add README.md
git -C "$LIVE_ROOT/project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
git clone --quiet --bare "$LIVE_ROOT/project" "$LIVE_ROOT/origin.git"
git -C "$LIVE_ROOT/project" remote add origin "file://$LIVE_ROOT/origin.git"
# Treehouse's own public acquire initializes the real pool inside the worktree.
POOL_PATH=$(cd "$LIVE_ROOT/project" && HOME="$LIVE_ROOT/user-home" treehouse get --lease --no-fetch)
printf 'allocated=%s\n' "$POOL_PATH"
case "$POOL_PATH" in "$LIVE_ROOT"/*) ;; *) echo 'unsafe allocation' >&2; exit 1 ;; esac
(cd "$LIVE_ROOT/project" && treehouse return "$POOL_PATH")
printf '%s\n' "$POOL_PATH" > "$LIVE_ROOT/pool-path"
# Every Herdr operation used by spawn passes through the guarded lab helper.
python3 - "$LIVE_ROOT/tools/herdr" "$HELPER" "$LAB_SESSION" "$PATH" <<'PY'
import shlex,sys
path,helper,session,oldpath=sys.argv[1:]
import os
operator_home=os.environ["HOME"]
q=shlex.quote
open(path,'w').write('''#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$2" = '''+q(session)+''' ] || exit 2; shift 2 ;;
    --session=*) [ "${1#--session=}" = '''+q(session)+''' ] || exit 2; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
HOME='''+q(operator_home)+''' PATH='''+q(oldpath)+''' exec '''+q(helper)+''' run '''+q(session)+''' "${args[@]}"
''')
PY
chmod +x "$LIVE_ROOT/tools/herdr"
WORKSPACE=$(lab workspace create --cwd "$LIVE_ROOT/project" --label isolated-spawn --no-focus)
LAUNCHER=$(printf '%s' "$WORKSPACE" | jq -r '.result.root_pane.pane_id')
printf 'launcher=%s\n%s\n' "$LAUNCHER" "$WORKSPACE"
ROOT_HOME="$LIVE_ROOT/home"
CHILD="$LIVE_ROOT/child"
SIBLING="$LIVE_ROOT/sibling"
NESTED="$LIVE_ROOT/nested"
for home in "$ROOT_HOME" "$CHILD" "$SIBLING" "$NESTED"; do
  bin/fm-lab-home.sh create "$home"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
done
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT_HOME" > "$CHILD/.fm-secondmate-parent"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT_HOME" > "$SIBLING/.fm-secondmate-parent"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$CHILD" > "$NESTED/.fm-secondmate-parent"
printf '%s\n' "- child - fixture (home: $CHILD; scope: test; projects: ; added 2026-01-01)" \
 "- sibling - fixture (home: $SIBLING; scope: test; projects: ; added 2026-01-01)" \
 "- remote - fixture (host: unavailable; root: /unavailable; home: /unavailable; scope: test; projects: ; added 2026-01-01)" > "$ROOT_HOME/data/secondmates.md"
printf '%s\n' "- nested - fixture (home: $NESTED; scope: test; projects: ; added 2026-01-01)" > "$CHILD/data/secondmates.md"
ln -s "$POOL_PATH" "$LIVE_ROOT/slot-alias"
CLAIM="$(dirname "$POOL_PATH")/.fm-slot-owner"
if [ "${FM_LIVE_ADVANCE:-1}" = 1 ]; then
  printf 'advanced\n' > "$LIVE_ROOT/project/advanced.txt"
  git -C "$LIVE_ROOT/project" add advanced.txt
  git -C "$LIVE_ROOT/project" -c user.name=Test -c user.email=test@example.invalid commit -qm advance
  git -C "$LIVE_ROOT/project" push --quiet origin main
fi
OLD_HEAD=$(git -C "$POOL_PATH" rev-parse HEAD)
NEW_HEAD=$(git -C "$LIVE_ROOT/project" rev-parse HEAD)
printf 'pool before=%s; remote=%s\n' "$OLD_HEAD" "$NEW_HEAD"
cat > "$LIVE_ROOT/spawn-in-pane.sh" <<'DRIVER'
#!/usr/bin/env bash
. "$(dirname "$0")/scenario.env"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_HOME=$SPAWNING_HOME
export HOME="$LIVE_ROOT/user-home"
export TREEHOUSE_ROOT="$LIVE_ROOT/pool"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export PATH="$LIVE_ROOT/tools:$PATH"
export FM_SPAWN_NO_GUARD=1
cd "$RUN_ROOT"
"$RUN_ROOT/bin/fm-spawn.sh" "$ATTEMPT" "$LIVE_ROOT/project" "sh -c 'echo REAL_RAW_WORKER'" --mode no-mistakes --yolo off --backend herdr > "$LIVE_ROOT/spawn.out" 2>&1
printf '%s\n' "$?" > "$LIVE_ROOT/spawn.exit"
DRIVER
drive() {
  python3 - "$LIVE_ROOT/spawn.exit" <<'PY'
import os,sys
if os.path.exists(sys.argv[1]): os.unlink(sys.argv[1])
PY
  printf 'SPAWNING_HOME=%q\nATTEMPT=%q\nRUN_ROOT=%q\nLIVE_ROOT=%q\n' "$SPAWNING_HOME" "$ATTEMPT" "$RUN_ROOT" "$LIVE_ROOT" > "$LIVE_ROOT/scenario.env"
  printf '$ FM_HOME=%s bin/fm-spawn.sh %s %s "sh -c echo REAL_RAW_WORKER" --mode no-mistakes --yolo off --backend herdr\n' "$SPAWNING_HOME" "$ATTEMPT" "$LIVE_ROOT/project"
  lab pane run "$LAUNCHER" "bash '$LIVE_ROOT/spawn-in-pane.sh'" >/dev/null
  for n in $(seq 1 120); do [ ! -f "$LIVE_ROOT/spawn.exit" ] || break; sleep 0.5; done
  cat "$LIVE_ROOT/spawn.out"
  printf 'exit=%s\n' "$(cat "$LIVE_ROOT/spawn.exit")"
}
for variant in unclaimed alias parent child sibling nested same-id; do
  printf '\nSCENARIO=%s\n' "$variant"
  ATTEMPT="attempt-$variant"
  HELD="held-$variant"
  SPAWNING_HOME="$ROOT_HOME"
  OWNER_HOME="$ROOT_HOME"
  RECORDED="$POOL_PATH"
  case "$variant" in
    alias) RECORDED="$LIVE_ROOT/slot-alias/" ;;
    parent) SPAWNING_HOME="$CHILD" ;;
    child) OWNER_HOME="$CHILD" ;;
    sibling) SPAWNING_HOME="$CHILD"; OWNER_HOME="$SIBLING" ;;
    nested) OWNER_HOME="$NESTED" ;;
    same-id) OWNER_HOME="$CHILD"; HELD=$ATTEMPT ;;
  esac
  [ "$variant" = unclaimed ] || printf 'task=%s\nhome=%s\n' "$HELD" "$OWNER_HOME" > "$CLAIM"
  mkdir -p "$SPAWNING_HOME/data/$ATTEMPT"
  cat > "$SPAWNING_HOME/data/$ATTEMPT/brief.md" <<'BRIEF'
# Task
## Captain's intent
Preserve the slot another task still records.

## Firstmate spec
Refuse the allocation before changing the held checkout.
BRIEF
  printf 'worktree=%s\nkind=ship\nbackend=herdr\n' "$RECORDED" > "$OWNER_HOME/state/$HELD.meta"
  printf 'done: awaiting review\n' > "$OWNER_HOME/state/$HELD.status"
  mkdir -p "$LIVE_ROOT/unrelated"
  printf 'worktree=%s\nkind=scout\n' "$LIVE_ROOT/unrelated" > "$ROOT_HOME/state/unrelated.meta"
  cp "$OWNER_HOME/state/$HELD.meta" "$LIVE_ROOT/held.before"
  BEFORE_CLAIM=$(cat "$CLAIM" 2>/dev/null || true)
  BEFORE_REFLOG=$(git -C "$POOL_PATH" reflog)
  drive
  [ "$(cat "$LIVE_ROOT/spawn.exit")" != 0 ]
  grep -F "is still recorded by task $HELD in $OWNER_HOME/state/$HELD.meta" "$LIVE_ROOT/spawn.out"
  cmp "$OWNER_HOME/state/$HELD.meta" "$LIVE_ROOT/held.before"
  AFTER_HEAD=$(git -C "$POOL_PATH" rev-parse HEAD)
  if [ "$AFTER_HEAD" != "$OLD_HEAD" ]; then
    printf 'FAILED: held checkout changed despite refused spawn. HEAD before=%s after=%s\n' "$OLD_HEAD" "$AFTER_HEAD"
    printf 'held checkout file: '; cat "$POOL_PATH/advanced.txt"
    printf 'held task record:\n'; cat "$OWNER_HOME/state/$HELD.meta"
    printf 'new task metadata present='; [ ! -f "$SPAWNING_HOME/state/$ATTEMPT.meta" ] && printf 'false\n' || printf 'true\n'
    lab tab list
    lab pane read "$LAUNCHER" --source recent-unwrapped --lines 60
    exit 1
  fi
  [ "$(git -C "$POOL_PATH" reflog)" = "$BEFORE_REFLOG" ]
  [ "$(cat "$CLAIM" 2>/dev/null || true)" = "$BEFORE_CLAIM" ]
  [ ! -f "$SPAWNING_HOME/state/$ATTEMPT.meta" ]
  [ ! -d "$SPAWNING_HOME/state/$ATTEMPT.git-hooks" ]
  TABS=$(lab tab list)
  printf 'retained task record:\n'; cat "$OWNER_HOME/state/$HELD.meta"
  printf 'retained claim:\n%s\nHEAD before=%s after=%s\n' "$BEFORE_CLAIM" "$OLD_HEAD" "$(git -C "$POOL_PATH" rev-parse HEAD)"
  printf 'remaining tabs=%s\n' "$TABS"
  [ "$(printf '%s' "$TABS" | jq '.result.tabs | length')" = 1 ]
  python3 - "$OWNER_HOME/state/$HELD.meta" <<'PY'
import os,sys
os.unlink(sys.argv[1])
PY
  printf 'SCENARIO_PASS=%s\n' "$variant"
done
printf '\nSCENARIO=released-slot\n'
ATTEMPT=released-slot
SPAWNING_HOME="$ROOT_HOME"
mkdir -p "$SPAWNING_HOME/data/$ATTEMPT"
cp "$SPAWNING_HOME/data/attempt-unclaimed/brief.md" "$SPAWNING_HOME/data/$ATTEMPT/brief.md"
drive
[ "$(cat "$LIVE_ROOT/spawn.exit")" = 0 ]
cat "$SPAWNING_HOME/state/$ATTEMPT.meta"
cat "$CLAIM"
grep -Fx "worktree=$POOL_PATH" "$SPAWNING_HOME/state/$ATTEMPT.meta"
grep -Fx "task=$ATTEMPT" "$CLAIM"
[ "$(git -C "$POOL_PATH" rev-parse HEAD)" = "$NEW_HEAD" ]
WORKER_PANE=$(sed -n 's/^herdr_pane_id=//p' "$SPAWNING_HOME/state/$ATTEMPT.meta")
lab pane read "$WORKER_PANE" --source recent-unwrapped --lines 100
printf 'SCENARIO_PASS=released-slot\n'
