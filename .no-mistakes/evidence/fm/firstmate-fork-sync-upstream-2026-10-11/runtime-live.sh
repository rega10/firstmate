#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4N87G9S5XAGQN3JVMYEBRDM
LAB=$(mktemp -d "$ROOT/.test-phase/tmp/runtime.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-phase/herdr"
SESSION=$(bin/fm-herdr-lab.sh name fork-sync)
REAL_PATH=$PATH
REAL_HERDR=$(command -v herdr)
export REAL_PATH REAL_HERDR SESSION ROOT
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$REAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
export TREEHOUSE_ROOT="$LAB/pool" TMPDIR="$LAB"
bin/fm-herdr-lab.sh provision "$SESSION"
FM_HOME=$(bin/fm-lab-home.sh create "$LAB/home")
export FM_HOME TREEHOUSE_ROOT="$LAB/pool" TMPDIR="$LAB"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_ENV
export HERDR_SESSION="$SESSION"
mkdir -p "$LAB/shim"
cat > "$LAB/shim/herdr" <<'WRAP'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "$2" = "$SESSION" ] || exit 97
    shift 2
  else
    args+=("$1")
    shift
  fi
done
if [ "${args[0]}" = --version ]; then
  exec "$REAL_HERDR" --version
fi
exec env PATH="$REAL_PATH" "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "${args[@]}"
WRAP
chmod +x "$LAB/shim/herdr"
export PATH="$LAB/shim:$REAL_PATH"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
PROJECT="$LAB/project"
git init -q -b main "$PROJECT"
printf 'initial\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" -c user.name='Live Test' -c user.email=test@example.invalid commit -qm initial
git clone -q --bare "$PROJECT" "$LAB/origin.git"
git -C "$PROJECT" remote add origin "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$LAB/publisher"
printf 'upstream advancement\n' > "$LAB/publisher/new.txt"
git -C "$LAB/publisher" add new.txt
git -C "$LAB/publisher" -c user.name='Live Test' -c user.email=test@example.invalid commit -qm advancement
git -C "$LAB/publisher" push -q origin main
ADVANCED=$(git -C "$LAB/publisher" rev-parse HEAD)
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
ID=gate-live-fork-sync
bin/fm-brief.sh "$ID" project --scout --herdr-lab
python3 - "$FM_HOME/data/$ID/brief.md" <<'PY'
import sys
p=sys.argv[1]
s=open(p).read().replace('{TASK}', 'Validate this disposable local project.').replace('{FIRSTMATE_SPEC}', 'Do not change project files.')
open(p,'w').write(s)
PY
PAYLOAD=$(python3 -c 'print("long-launch-" * 512, end="")')
COMMAND=$(printf "sh -c 'printf %%s %s > %s; while :; do sleep 60; done'" "$PAYLOAD" "$LAB/long-launch-result")
bin/fm-spawn.sh "$ID" "$PROJECT" "$COMMAND" --scout --backend herdr
for ((i=0;i<100;i++)); do
  [ -f "$LAB/long-launch-result" ] && break
  sleep .1
done
[ "$i" -lt 100 ]
[ "$(cat "$LAB/long-launch-result")" = "$PAYLOAD" ]
printf 'Real worker shell received the complete %s-byte launch payload.\n' "${#PAYLOAD}"
shasum -a 256 "$LAB/long-launch-result"
cat "$FM_HOME/state/$ID.meta"
WT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$ID.meta")
TARGET=$(sed -n 's/^window=//p' "$FM_HOME/state/$ID.meta")
[ "$WT" != "$PROJECT" ]
[ "$(git -C "$WT" rev-parse HEAD)" = "$ADVANCED" ]
printf 'spawned pooled HEAD=%s expected origin HEAD=%s\n' "$(git -C "$WT" rev-parse HEAD)" "$ADVANCED"
cp "$FM_HOME/state/$ID.meta" "$EVIDENCE/scout-live.meta"
printf '\nAttempt cleanup before scout report:\n'
if bin/fm-teardown.sh "$ID"; then echo 'ERROR: missing report accepted'; exit 1; fi
[ -f "$FM_HOME/state/$ID.meta" ]
printf '# Report\n\nDisposable scout completed.\n' > "$FM_HOME/data/$ID/report.md"
printf '\nAttempt cleanup with an empty worktree path:\n'
cp "$FM_HOME/state/$ID.meta" "$LAB/original.meta"
sed 's/^worktree=.*/worktree=/' "$LAB/original.meta" > "$FM_HOME/state/$ID.meta"
if bin/fm-teardown.sh "$ID"; then echo 'ERROR: empty worktree accepted'; exit 1; fi
[ -f "$FM_HOME/state/$ID.meta" ]
cp "$LAB/original.meta" "$FM_HOME/state/$ID.meta"
printf '\nAttempt cleanup without completed inventory:\n'
if bin/fm-teardown.sh "$ID"; then echo 'ERROR: missing inventory accepted'; exit 1; fi
bin/fm-captain-hold.sh complete "$ID" --none
printf '\nCleanup completed scout:\n'
bin/fm-teardown.sh "$ID"
[ ! -f "$FM_HOME/state/$ID.meta" ]
if PATH="$REAL_PATH" bin/fm-herdr-lab.sh run "$SESSION" pane get "${TARGET#*:}"; then echo 'ERROR: retired pane exists'; exit 1; fi
printf 'Completed scout retained report=%s and removed metadata and exact pane.\n' "$(test -f "$FM_HOME/data/$ID/report.md" && echo yes)"
