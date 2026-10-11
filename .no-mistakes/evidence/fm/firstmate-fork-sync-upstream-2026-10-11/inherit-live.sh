#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-phase/tmp/inherit.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 TMPDIR="$LAB"
FM_HOME=$(bin/fm-lab-home.sh create "$LAB/parent")
export FM_HOME
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
SOURCE="$LAB/source"
git clone -q --no-hardlinks "$ROOT" "$SOURCE"
CHILD="$LAB/child"
git clone -q --no-hardlinks "$ROOT" "$CHILD"
FM_SECONDMATE_CHARTER='Validate this disposable project-less home.' FM_SECONDMATE_SCOPE='Disposable validation only.' "$SOURCE/bin/fm-home-seed.sh" lab-child "$CHILD" --no-projects
printf 'on\n' > "$FM_HOME/config/supervision-host-off"
printf 'auto\n' > "$FM_HOME/config/claude-permission-mode"
printf '# Shared captain preferences\n\nThis file is main-authoritative in the main firstmate home.\nIn secondmate homes it is read-only in secondmate homes and must not be edited there.\nRoute new captain-preference discoveries to the main firstmate through marked status or a document pointer.\n\nretained shared preference\n' > "$FM_HOME/data/captain-shared.md"
printf 'domain preference\n' > "$CHILD/data/captain.md"
printf 'pi\n' > "$FM_HOME/config/secondmate-harness"
printf 'lab-child\n' > "$CHILD/.fm-secondmate-home"
printf 'kind=secondmate\nhome=%s\nwindow=\n' "$CHILD" > "$FM_HOME/state/lab-child.meta"
printf '\nPush inherited shared data with no config nudge needed:\n'
# Data-only push proves propagation without requiring an interactive worker.
mkdir -p "$CHILD/config"
cp "$FM_HOME/config/supervision-host-off" "$CHILD/config/supervision-host-off"
cp "$FM_HOME/config/claude-permission-mode" "$CHILD/config/claude-permission-mode"
"$SOURCE/bin/fm-config-push.sh"
cmp "$FM_HOME/data/captain-shared.md" "$CHILD/data/captain-shared.md"
[ "$(cat "$CHILD/data/captain.md")" = 'domain preference' ]
[ ! -f "$CHILD/config/secondmate-harness" ]
[ "$(stat -f '%Lp' "$CHILD/data/captain-shared.md")" = 444 ]
printf 'Shared data converged with mode 444. Domain data remained unchanged. The secondmate harness pin remained local to the parent.\n'
printf '\nRemove inherited config in parent and push absence:\n'
rm "$FM_HOME/config/claude-permission-mode"
rc=0
"$SOURCE/bin/fm-config-push.sh" || rc=$?
[ ! -f "$CHILD/config/claude-permission-mode" ]
printf 'Parent absence removed child config. Config reread exit=%s (no interactive endpoint in this data-only scenario).\n' "$rc"
