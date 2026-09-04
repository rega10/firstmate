#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
PROJECT_POSTURE="$ROOT/bin/fm-project-posture.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_project_mode_ignores_lifecycle_for_every_registry_form() {
  local home output expected project
  home="$TMP_ROOT/project-mode-lifecycle/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- legacy - fixture (added 2026-01-01)
- flat [direct-PR] - fixture (added 2026-01-01)
- yolo [local-only +yolo] - fixture (added 2026-01-01)
- parked-default [parked] - fixture (added 2026-01-01)
- parked-mode [direct-PR parked] - fixture (added 2026-01-01)
- parked-yolo [no-mistakes +yolo parked:2026-10-01] - fixture (added 2026-01-01)
- archived [local-only archived] - fixture (added 2026-01-01)
- conditional [no-mistakes-prod-only parked] - fixture (added 2026-01-01)
EOF
  while IFS='|' read -r project expected; do
    output=$(FM_HOME="$home" "$PROJECT_MODE" "$project" 2>/dev/null)
    [ "$output" = "$expected" ] || fail "$project changed delivery output to '$output', expected '$expected'"
  done <<'ROWS'
legacy|no-mistakes off
flat|direct-PR off
yolo|local-only on
parked-default|no-mistakes off
parked-mode|direct-PR off
parked-yolo|no-mistakes on
archived|local-only off
conditional|no-mistakes off
ROWS
  pass "fm-project-mode: lifecycle tokens leave every legacy delivery output unchanged"
}

test_project_posture_round_trips_without_touching_delivery() {
  local home before after output inode_before inode_after
  home="$TMP_ROOT/project-posture-roundtrip/home"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
- legacy - legacy fixture (added 2026-01-01)
- app [direct-PR +yolo] - app fixture (added 2026-01-01)
EOF
  [ "$(FM_HOME="$home" "$PROJECT_POSTURE" get app)" = active ] \
    || fail "missing lifecycle token did not read as active"
  inode_before=$(stat -f '%i' "$home/data/projects.md" 2>/dev/null || stat -c '%i' "$home/data/projects.md")
  output=$(FM_HOME="$home" "$PROJECT_POSTURE" set app parked:2026-10-01)
  inode_after=$(stat -f '%i' "$home/data/projects.md" 2>/dev/null || stat -c '%i' "$home/data/projects.md")
  [ "$inode_before" != "$inode_after" ] || fail "registry update did not publish by atomic replacement"
  assert_contains "$output" 'previous: - app [direct-PR +yolo] - app fixture' \
    "posture mutation did not retain the previous line in output"
  assert_contains "$output" 'current: - app [direct-PR +yolo parked:2026-10-01] - app fixture' \
    "posture mutation did not print the current line"
  [ "$(FM_HOME="$home" "$PROJECT_POSTURE" get app)" = parked:2026-10-01 ] \
    || fail "dated park did not round trip"
  [ "$(FM_HOME="$home" "$PROJECT_MODE" app)" = 'direct-PR on' ] \
    || fail "dated park changed delivery mode or yolo"

  FM_HOME="$home" "$PROJECT_POSTURE" set app archived >/dev/null
  [ "$(FM_HOME="$home" "$PROJECT_POSTURE" get app)" = archived ] \
    || fail "archived posture did not round trip"
  [ "$(FM_HOME="$home" "$PROJECT_MODE" app)" = 'direct-PR on' ] \
    || fail "archive changed delivery mode or yolo"

  FM_HOME="$home" "$PROJECT_POSTURE" clear app >/dev/null
  [ "$(FM_HOME="$home" "$PROJECT_POSTURE" get app)" = active ] \
    || fail "clear did not restore active"
  assert_grep '- app [direct-PR +yolo] - app fixture' "$home/data/projects.md" \
    "clear changed or removed the delivery annotation"

  FM_HOME="$home" "$PROJECT_POSTURE" set legacy parked >/dev/null
  assert_grep '- legacy [parked] - legacy fixture' "$home/data/projects.md" \
    "a legacy line did not gain a lifecycle-only annotation"
  [ "$(FM_HOME="$home" "$PROJECT_MODE" legacy)" = 'no-mistakes off' ] \
    || fail "lifecycle-only annotation changed the legacy delivery default"
  FM_HOME="$home" "$PROJECT_POSTURE" set legacy active >/dev/null
  assert_grep '- legacy - legacy fixture' "$home/data/projects.md" \
    "set active did not remove the lifecycle-only annotation cleanly"
  pass "fm-project-posture: set, get, active, and clear preserve delivery bytes and defaults"
}

test_project_posture_preserves_exact_legacy_annotation_bytes() {
  local home before output expected
  home="$TMP_ROOT/project-posture-exact-bytes/home"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
- spaced [direct-PR   +yolo] - irregular spacing fixture (added 2026-01-01)
- bare - no annotation fixture (added 2026-01-01)
EOF
  before=$(cat "$home/data/projects.md")

  output=$(FM_HOME="$home" "$PROJECT_POSTURE" set spaced parked)
  expected='previous: - spaced [direct-PR   +yolo] - irregular spacing fixture (added 2026-01-01)
current: - spaced [direct-PR   +yolo parked] - irregular spacing fixture (added 2026-01-01)'
  [ "$output" = "$expected" ] || fail "set normalized irregular delivery annotation bytes: $output"
  FM_HOME="$home" "$PROJECT_POSTURE" clear spaced >/dev/null
  [ "$(sed -n '1p' "$home/data/projects.md")" = \
    '- spaced [direct-PR   +yolo] - irregular spacing fixture (added 2026-01-01)' ] \
    || fail "clear did not restore irregular delivery annotation bytes"

  output=$(FM_HOME="$home" "$PROJECT_POSTURE" set bare archived)
  expected='previous: - bare - no annotation fixture (added 2026-01-01)
current: - bare [archived] - no annotation fixture (added 2026-01-01)'
  [ "$output" = "$expected" ] || fail "set changed bytes around a legacy annotation-free line: $output"
  FM_HOME="$home" "$PROJECT_POSTURE" clear bare >/dev/null
  [ "$(cat "$home/data/projects.md")" = "$before" ] \
    || fail "posture round trips changed legacy registry bytes"
  pass "fm-project-posture: lifecycle edits preserve exact legacy annotation bytes"
}

test_project_posture_rejects_unknown_values_and_bad_dates() {
  local home before after value status
  home="$TMP_ROOT/project-posture-invalid/home"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '- app [no-mistakes +yolo] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  before=$(cat "$home/data/projects.md")
  for value in waiting parked:2026-2-03 parked:2026-02-30 parked:hello; do
    FM_HOME="$home" "$PROJECT_POSTURE" set app "$value" >/dev/null 2>&1
    status=$?
    [ "$status" -ne 0 ] || fail "invalid lifecycle value was accepted: $value"
  done
  FM_HOME="$home" "$PROJECT_POSTURE" set missing parked >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "unknown project was accepted"
  after=$(cat "$home/data/projects.md")
  [ "$before" = "$after" ] || fail "a rejected lifecycle mutation changed the registry"
  pass "fm-project-posture: unknown values, malformed dates, and unknown projects fail closed"
}

test_project_posture_rejects_duplicate_projects_for_every_command() {
  local home before after command status
  home="$TMP_ROOT/project-posture-duplicate/home"
  mkdir -p "$home/data" "$home/state"
  cat > "$home/data/projects.md" <<'EOF'
- app [direct-PR] - first fixture (added 2026-01-01)
- app [direct-PR parked] - duplicate fixture (added 2026-01-02)
EOF
  before=$(cat "$home/data/projects.md")
  for command in get set clear; do
    case "$command" in
      set) FM_HOME="$home" "$PROJECT_POSTURE" set app archived >/dev/null 2>&1 ;;
      *) FM_HOME="$home" "$PROJECT_POSTURE" "$command" app >/dev/null 2>&1 ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "$command accepted a duplicate project registration"
    after=$(cat "$home/data/projects.md")
    [ "$before" = "$after" ] || fail "$command changed a duplicate project registry"
  done
  pass "fm-project-posture: get, set, and clear reject duplicate projects without mutation"
}

test_project_posture_expiry_check_fires_once_per_effective_date() {
  local home check first second third fourth watcher_out watcher_err status
  home="$TMP_ROOT/project-posture-expiry/home"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '- app [direct-PR +yolo] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  FM_HOME="$home" "$PROJECT_POSTURE" set app parked:2026-10-01 >/dev/null
  check="$home/state/project-posture-expiry.check.sh"
  assert_present "$check" "dated park did not arm the custom check"
  assert_present "$home/state/project-posture-expiry.check-trust" \
    "dated park did not register the custom check bytes"
  first=$(FM_PROJECT_POSTURE_TODAY=2026-09-30 "$check")
  [ -z "$first" ] || fail "future park woke early: $first"
  watcher_out="$home/watcher.out"
  watcher_err="$home/watcher.err"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=0 FM_CHECK_INTERVAL=0 FM_SIGNAL_GRACE=0 \
    FM_PROJECT_POSTURE_TODAY=2026-10-01 "$ROOT/bin/fm-watch.sh" > "$watcher_out" 2> "$watcher_err"
  status=$?
  [ "$status" -eq 0 ] || fail "watcher did not execute the registered expiry check: $(cat "$watcher_err")"
  assert_grep "check: $check: project posture expired: app (parked until 2026-10-01)" "$watcher_out" \
    "due park did not become a check wake"
  second=$(FM_PROJECT_POSTURE_TODAY=2026-10-02 "$check")
  [ -z "$second" ] || fail "expired park repeated on a later poll: $second"

  FM_HOME="$home" "$PROJECT_POSTURE" set app parked:2026-10-01 >/dev/null
  third=$(FM_PROJECT_POSTURE_TODAY=2026-10-02 "$check")
  [ -z "$third" ] || fail "an unchanged dated park emitted a second wake: $third"

  FM_HOME="$home" "$PROJECT_POSTURE" set app parked:2026-10-03 >/dev/null
  fourth=$(FM_PROJECT_POSTURE_TODAY=2026-10-03 "$check")
  assert_contains "$fourth" 'project posture expired: app (parked until 2026-10-03)' \
    "a changed park date did not reset the once-only receipt"
  [ -z "$(FM_PROJECT_POSTURE_TODAY=2026-10-04 "$check")" ] \
    || fail "the changed park date emitted more than once"

  FM_HOME="$home" "$PROJECT_POSTURE" clear app >/dev/null
  assert_absent "$check" "clearing the final dated park left its check armed"
  assert_absent "$home/state/project-posture-expiry.check-trust" \
    "clearing the final dated park left its trust binding"
  pass "fm-project-posture: each effective due date emits exactly one registered check wake"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_project_mode_maps_the_conditional_policy
test_project_mode_ignores_lifecycle_for_every_registry_form
test_project_posture_round_trips_without_touching_delivery
test_project_posture_preserves_exact_legacy_annotation_bytes
test_project_posture_rejects_unknown_values_and_bad_dates
test_project_posture_rejects_duplicate_projects_for_every_command
test_project_posture_expiry_check_fires_once_per_effective_date
echo "# all fm-task-delivery tests passed"
