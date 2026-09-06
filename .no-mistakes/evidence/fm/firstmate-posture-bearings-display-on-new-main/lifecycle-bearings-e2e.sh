#!/usr/bin/env bash
# End-to-end demonstration of the Bearings project-lifecycle display integration.
# Builds a real main home with active / parked / archived projects, then runs the
# real bin/fm-bearings-snapshot.sh (over bin/fm-fleet-snapshot.sh) and captures the
# actual agent-facing TOON projection plus the JSON parity form.
set -eu

ROOT="/Users/rega1011/.no-mistakes/worktrees/422718388d14/01M1W8ES3MBX9DF63G2G0DWHFJ"
EVID="/Users/rega1011/.no-mistakes/evidence/01M1W8ES3MBX9DF63G2G0DWHFJ"
. "$ROOT/tests/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bearings-evid)
export FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"; mkdir -p "$FM_ROOT_OVERRIDE"

home="$TMP_ROOT/lifecycle"
mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
: > "$home/data/secondmates.md"
mkdir -p "$home/projects/due-live" "$home/projects/permanent-live" \
  "$home/projects/future-live" "$home/projects/active-live"

fb=$(fm_fakebin "$home")
for t in no-mistakes tmux gh gh-axi curl; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/$t"; chmod +x "$fb/$t"
done

cat > "$home/data/projects.md" <<'EOF'
- active [no-mistakes +yolo] - Active project (added 2026-07-01)
- due [direct-PR parked:2026-07-11] - Due project, park expires today (added 2026-07-01)
- permanent [local-only parked] - Permanently parked project (added 2026-07-01)
- future [no-mistakes parked:2026-08-01] - Future-parked project (added 2026-07-01)
- archived [direct-PR archived] - Archived project (added 2026-07-01)
EOF

cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-live - Active project work underway (repo: active) (kind: ship) (since 2026-07-10)
- [ ] due-live - Due parked work resumes today (repo: due) (kind: ship) (since 2026-07-10)
- [ ] permanent-live - Permanently parked live work (repo: permanent) (kind: ship) (since 2026-07-10)
- [ ] future-live - Future parked live work (repo: future) (kind: ship) (since 2026-07-10)

## Queued
- [ ] active-next - Active queued work (repo: active) (kind: ship)
- [ ] due-next - Due parked work resurfaces (repo: due) (kind: ship)
- [ ] permanent-next - Permanent parked work (repo: permanent) (kind: ship)
- [ ] future-call - Future parked captain work (repo: future) (kind: captain) (hold: captain chooses route) (hold-kind: captain)
- [ ] archived-next - Archived queued work (repo: archived) (kind: ship)

## Done
- [x] active-done - Active completion (repo: active) (kind: ship) (done 2026-07-10)
EOF

fm_write_meta "$home/state/active-live.meta" \
  "window=firstmate:fm-active-live" "worktree=$home/projects/active-live" "project=active" \
  "harness=codex" "kind=ship" "mode=no-mistakes"
printf 'working: active project underway\n' > "$home/state/active-live.status"
fm_write_meta "$home/state/due-live.meta" \
  "window=firstmate:fm-due-live" "worktree=$home/projects/due-live" "project=due" \
  "harness=codex" "kind=ship" "mode=direct-PR"
printf 'working: due project resumed\n' > "$home/state/due-live.status"
fm_write_meta "$home/state/permanent-live.meta" \
  "window=firstmate:fm-permanent-live" "worktree=$home/projects/permanent-live" "project=permanent" \
  "harness=codex" "kind=ship" "mode=local-only"
printf 'working: permanently parked task still has a live status\n' > "$home/state/permanent-live.status"
fm_write_meta "$home/state/future-live.meta" \
  "window=firstmate:fm-future-live" "worktree=$home/projects/future-live" "project=future" \
  "harness=codex" "kind=ship" "mode=no-mistakes"
printf 'working: future parked task still has a live status\n' > "$home/state/future-live.status"

echo "===== TOON (default agent-facing Bearings projection) ====="
PATH="$fb:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" \
  "$ROOT/bin/fm-bearings-snapshot.sh"

echo
echo "===== JSON parity: projects[] posture surface + Charted Next gate ordering ====="
PATH="$fb:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" \
  "$ROOT/bin/fm-bearings-snapshot.sh" --json | jq '{
    projects: .projects,
    underway: [.in_flight[].id],
    charted_next: [.gates[] | {id, reason}],
    omitted: [.omitted[].surface]
  }'
