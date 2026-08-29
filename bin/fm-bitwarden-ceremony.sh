#!/usr/bin/env bash
# fm-bitwarden-ceremony.sh - structure/status validator for Bitwarden migration
# ceremony records (docs/bitwarden-rollout.md owns the ceremony itself).
#
# Usage:
#   bin/fm-bitwarden-ceremony.sh init <batch-id>
#   bin/fm-bitwarden-ceremony.sh add-item <batch-id> <item-label> --owner <label> --collection <label>
#   bin/fm-bitwarden-ceremony.sh mark <batch-id> <step> [--approved-by <label>]
#   bin/fm-bitwarden-ceremony.sh status <batch-id>
#   bin/fm-bitwarden-ceremony.sh check <batch-id>
#   bin/fm-bitwarden-ceremony.sh --help
#
# One record per migration batch at $FM_HOME/data/bitwarden/<batch-id>.ceremony
# (FM_HOME defaults to the repo root; FM_DATA_OVERRIDE overrides the data root
# for tests). The record is the auditable no-secret completion evidence for one
# batch of the phased migration ceremony in docs/bitwarden-rollout.md.
#
# HARD SAFETY CONTRACT - this tool never touches secrets:
#   - It never reads from, writes to, or talks to Bitwarden, Automic Vault, or
#     any credential store. It validates a local text record, nothing else.
#   - Every free-text argument is a short reference LABEL (an item name, a
#     person, a collection). Values that look like secret material - wrong
#     charset, excessive length, long hex runs, or well-known token prefixes -
#     are refused, and the refusal message never echoes the offending value,
#     so a mistakenly pasted secret is neither persisted nor logged.
#   - A structurally invalid record line is reported by line number only,
#     never by content, for the same reason.
#
# Record format (v1, line-based, append-only):
#   fm-bitwarden-ceremony v1
#   batch: <batch-id>
#   created: <YYYY-MM-DD>
#   item: <label> owner=<label> collection=<label>
#   step: <name> date=<YYYY-MM-DD> [approved-by=<label>]
#
# Steps are batch-level and strictly ordered:
#   preflight -> approval -> moved -> verified -> retired
# Every command that reads a record requires its recorded steps to be exactly
# that order with nothing skipped, repeated, or added after `retired`, so a
# hand-edited or tampered history is refused by `check` and `status` instead of
# being reported as progress. A refused record is corrected back to its last
# valid prefix, or quarantined and replaced by a new batch, per the recovery
# procedure in docs/bitwarden-rollout.md; this tool never normalizes one.
# Further gates on `mark`:
#   - approval requires --approved-by (the captain's recorded identity label);
#     no other step accepts it.
#   - moved requires at least one registered item, so a batch cannot be
#     "moved" with no recorded per-item ownership/collection target.
#   - retired is the destructive gate: it is refused unless verified is marked
#     AND an approval line with approved-by exists, so old-custody retirement
#     can never be recorded before post-move verification and captain approval.
# Every command is idempotent: re-running init on an initialized batch,
# re-adding an identical item, or re-marking a recorded step is a no-op
# success, so an interrupted ceremony can be resumed by replaying commands.
# `check` re-validates any partial record and prints the next required step,
# which is the recovery entry point after an interruption.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD_DIR="$DATA/bitwarden"

STEPS="preflight approval moved verified retired"

die() { printf 'fm-bitwarden-ceremony: %s\n' "$*" >&2; exit 1; }
note() { printf 'fm-bitwarden-ceremony: %s\n' "$*"; }

RECOVERY_HINT='correct the record back to its last valid prefix, or quarantine it and start a new batch (see docs/bitwarden-rollout.md); this tool never repairs a record for you'

# $1=batch $2=line-number $3=reason. Names the line and the expected shape,
# never the line content (see the safety contract above).
corrupt() {
  die "record for batch '$1' is corrupt at line $2 ($3; content withheld in case it holds secret material); $RECOVERY_HINT"
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

# Secret-shape refusals shared by every free-text argument. $1=field-name
# $2=value; on refusal, dies naming only the field, never the value.
refuse_secret_shape() {
  local field=$1 value=$2
  case $value in
    ghp_*|github_pat_*|sk-*|xox*|AKIA*|glpat-*|eyJ*) die "refused: value for $field matches a well-known credential shape; secret values must never be passed to this tool" ;;
  esac
  if printf '%s' "$value" | grep -Eq -- '[A-Fa-f0-9]{32}'; then
    die "refused: value for $field contains a long hexadecimal run; secret values must never be passed to this tool"
  fi
}

# A batch id is a filename component; anything else risks path traversal.
valid_batch_id() {
  case $1 in
    *[!a-z0-9-]*|-*|'') return 1 ;;
  esac
  [ ${#1} -le 64 ]
}

# A batch id is persisted as a filename and echoed in progress messages, so it
# faces the same secret-shape refusals as a label.
require_batch_id() {
  valid_batch_id "$1" || die "refused: batch id must match [a-z0-9][a-z0-9-]* (max 64 chars)"
  refuse_secret_shape 'batch id' "$1"
}

# Labels are short human references. Refuse anything shaped like secret
# material WITHOUT echoing it (see the safety contract above).
# $1=field-name $2=value; on refusal, dies naming only the field.
require_label() {
  local field=$1 value=$2
  [ -n "$value" ] || die "refused: $field is empty; pass a short reference label"
  [ ${#value} -le 64 ] || die "refused: value for $field is too long for a reference label (max 64); secret values must never be passed to this tool"
  case $value in
    *[!A-Za-z0-9._@/-]*) die "refused: value for $field contains characters outside A-Za-z0-9 . _ @ / -; secret values must never be passed to this tool" ;;
  esac
  refuse_secret_shape "$field" "$value"
}

record_path() { printf '%s/%s.ceremony' "$RECORD_DIR" "$1"; }

today() { date -u +%Y-%m-%d; }

# Parse and validate a record. Populates:
#   PARSED_ITEMS   - newline list of item labels
#   PARSED_STEPS   - space list of recorded step names, record order
#   PARSED_APPROVED_BY - approver label when the approval step is recorded
# Recorded steps must form an ordered prefix of $STEPS with no repeat, gap, or
# trailing step, and each item label may appear once, so every reader refuses a
# tampered history rather than reporting progress from it.
# Dies with a line NUMBER (never content) on any malformed line.
parse_record() {
  local path=$1 batch=$2 lineno=0 line rest name pending=$STEPS expected
  PARSED_ITEMS=""
  PARSED_STEPS=""
  PARSED_APPROVED_BY=""
  [ -f "$path" ] || die "no ceremony record for batch '$batch'; run init first"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$lineno" -eq 1 ]; then
      [ "$line" = 'fm-bitwarden-ceremony v1' ] || die "record for batch '$batch' is not a v1 ceremony record (line 1); $RECOVERY_HINT"
      continue
    fi
    case $line in
      'batch: '*|'created: '*) ;;
      'item: '*)
        rest=${line#item: }
        case $rest in
          *' owner='*' collection='*) ;;
          *) corrupt "$batch" "$lineno" 'malformed item line' ;;
        esac
        name=${rest%% *}
        case $'\n'"$PARSED_ITEMS" in
          *$'\n'"$name"$'\n'*) corrupt "$batch" "$lineno" 'item label already registered on an earlier line' ;;
        esac
        PARSED_ITEMS="$PARSED_ITEMS$name"$'\n'
        ;;
      'step: '*)
        rest=${line#step: }
        name=${rest%% *}
        case " $STEPS " in
          *" $name "*) ;;
          *) corrupt "$batch" "$lineno" 'unknown step' ;;
        esac
        case $rest in
          *' date='*) ;;
          *) corrupt "$batch" "$lineno" 'step line has no date' ;;
        esac
        expected=${pending%% *}
        [ -n "$expected" ] || corrupt "$batch" "$lineno" 'step recorded after the ceremony is already complete'
        [ "$name" = "$expected" ] || corrupt "$batch" "$lineno" "steps out of order, expected '$expected' at this point"
        case $pending in
          *' '*) pending=${pending#* } ;;
          *) pending='' ;;
        esac
        if [ "$name" = approval ]; then
          case $rest in
            *' approved-by='*) PARSED_APPROVED_BY=${rest##* approved-by=} ;;
            *) corrupt "$batch" "$lineno" 'approval step has no approved-by' ;;
          esac
          [ -n "$PARSED_APPROVED_BY" ] || corrupt "$batch" "$lineno" 'approval step has an empty approved-by'
        fi
        PARSED_STEPS="$PARSED_STEPS$name "
        ;;
      *) corrupt "$batch" "$lineno" 'unrecognized line' ;;
    esac
  done < "$path"
}

step_recorded() {  # <step> - against PARSED_STEPS
  case " $PARSED_STEPS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

next_step() {  # first unrecorded step in order, or nothing when complete
  local s
  for s in $STEPS; do
    if ! step_recorded "$s"; then printf '%s' "$s"; return 0; fi
  done
  return 1
}

cmd_init() {
  local batch=$1 path
  require_batch_id "$batch"
  path=$(record_path "$batch")
  if [ -f "$path" ]; then
    parse_record "$path" "$batch"
    note "batch '$batch' already initialized; nothing to do"
    return 0
  fi
  mkdir -p "$RECORD_DIR"
  {
    printf 'fm-bitwarden-ceremony v1\n'
    printf 'batch: %s\n' "$batch"
    printf 'created: %s\n' "$(today)"
  } > "$path"
  note "batch '$batch' initialized at $path"
}

cmd_add_item() {
  local batch=$1 label=$2 owner='' collection='' path
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --owner) owner=${2:?}; shift 2 ;;
      --collection) collection=${2:?}; shift 2 ;;
      *) die "unknown add-item argument (see --help)" ;;
    esac
  done
  require_batch_id "$batch"
  require_label 'item label' "$label"
  require_label '--owner' "$owner"
  require_label '--collection' "$collection"
  path=$(record_path "$batch")
  parse_record "$path" "$batch"
  local line="item: $label owner=$owner collection=$collection"
  if grep -Fqx -- "$line" "$path"; then
    note "batch '$batch': item '$label' already recorded; nothing to do"
    return 0
  fi
  if printf '%s\n' "$PARSED_ITEMS" | grep -Fqx -- "$label"; then
    die "batch '$batch': item '$label' already recorded with a different owner/collection; resolve the conflict in the record before continuing"
  fi
  if step_recorded moved; then
    die "batch '$batch': items cannot be added after the batch is marked moved; start a new batch"
  fi
  printf '%s\n' "$line" >> "$path"
  note "batch '$batch': item '$label' registered (owner=$owner collection=$collection)"
}

cmd_mark() {
  local batch=$1 step=$2 approved_by='' path expected
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --approved-by) approved_by=${2:?}; shift 2 ;;
      *) die "unknown mark argument (see --help)" ;;
    esac
  done
  require_batch_id "$batch"
  case " $STEPS " in
    *" $step "*) ;;
    *) die "unknown step; steps in order are: $STEPS" ;;
  esac
  path=$(record_path "$batch")
  parse_record "$path" "$batch"
  if step_recorded "$step"; then
    note "batch '$batch': step '$step' already recorded; nothing to do"
    return 0
  fi
  if [ "$step" = approval ]; then
    [ -n "$approved_by" ] || die "refused: approval requires --approved-by with the captain's recorded identity label"
    require_label '--approved-by' "$approved_by"
  else
    [ -z "$approved_by" ] || die "--approved-by is only valid for the approval step"
  fi
  if [ "$step" = moved ] && [ -z "$(printf '%s' "$PARSED_ITEMS")" ]; then
    die "batch '$batch': refused to mark moved with no registered items; every moved credential needs a recorded owner/collection target"
  fi
  if [ "$step" = retired ]; then
    step_recorded verified || die "batch '$batch': refused to record retirement before post-move verification"
    [ -n "$PARSED_APPROVED_BY" ] || die "batch '$batch': refused to record retirement without a recorded captain approval"
  fi
  expected=$(next_step) || die "batch '$batch' is already complete"
  [ "$step" = "$expected" ] || die "batch '$batch': next required step is '$expected', not '$step' (steps in order are: $STEPS)"
  if [ "$step" = approval ]; then
    printf 'step: %s date=%s approved-by=%s\n' "$step" "$(today)" "$approved_by" >> "$path"
  else
    printf 'step: %s date=%s\n' "$step" "$(today)" >> "$path"
  fi
  note "batch '$batch': step '$step' recorded ($(today))"
}

cmd_status() {
  local batch=$1 path s marker
  require_batch_id "$batch"
  path=$(record_path "$batch")
  parse_record "$path" "$batch"
  printf 'batch: %s\n' "$batch"
  printf 'record: %s\n' "$path"
  printf 'items: %s\n' "$(printf '%s' "$PARSED_ITEMS" | grep -c -- . || true)"
  for s in $STEPS; do
    if step_recorded "$s"; then marker='x'; else marker=' '; fi
    printf '  [%s] %s\n' "$marker" "$s"
  done
  if next_step >/dev/null; then
    printf 'next: %s\n' "$(next_step)"
  else
    printf 'next: complete\n'
  fi
}

cmd_check() {
  local batch=$1
  require_batch_id "$batch"
  parse_record "$(record_path "$batch")" "$batch"
  if next_step >/dev/null; then
    printf 'next: %s\n' "$(next_step)"
  else
    printf 'next: complete\n'
  fi
}

case ${1:-} in
  -h|--help|help|'') usage; exit 0 ;;
  init) [ $# -eq 2 ] || die "usage: init <batch-id>"; cmd_init "$2" ;;
  add-item) [ $# -ge 3 ] || die "usage: add-item <batch-id> <item-label> --owner <label> --collection <label>"; shift; cmd_add_item "$@" ;;
  mark) [ $# -ge 3 ] || die "usage: mark <batch-id> <step> [--approved-by <label>]"; shift; cmd_mark "$@" ;;
  status) [ $# -eq 2 ] || die "usage: status <batch-id>"; cmd_status "$2" ;;
  check) [ $# -eq 2 ] || die "usage: check <batch-id>"; cmd_check "$2" ;;
  *) die "unknown command; commands are: init add-item mark status check --help" ;;
esac
