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
# The batch and created headers appear exactly once each, before any item or
# step line, and the batch header must name the batch being read - a record
# copied or renamed to another batch id is refused rather than reported as that
# batch's evidence. Every line must carry exactly the fields shown above, every
# label value must be a valid reference label, and every date must be a real
# YYYY-MM-DD calendar date that is not in the future, no earlier than the
# created header, and no earlier than the previous step's date, so the record
# cannot certify a history the ceremony could not have produced. The accepted
# dates are exactly the ones this tool can stamp, so it never appends a line
# its own readers would then refuse. Every line ends with a newline; a record
# whose final line does not is treated as truncated and refused, because
# appending to it would fuse two record lines into one. An item label may be
# registered at most once and never after the moved step, and the moved step
# requires at least one item already registered - the same rules `add-item`
# and `mark` apply when they write.
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
# Replaying a command with the same arguments is idempotent: re-running init on
# an initialized batch, re-adding an identical item, or re-marking a recorded
# step is a no-op success, so an interrupted ceremony can be resumed by
# replaying commands. A replay whose arguments contradict the record - another
# owner or collection for a registered item, another --approved-by for a
# recorded approval - is refused naming the conflicting field instead, so a
# replay is never reported as success while the evidence says something else.
# Mutating commands serialize on a per-record lock and replace records
# atomically, so concurrent retries converge on the same validated evidence.
# `check` re-validates any partial record and prints the next required step,
# which is the recovery entry point after an interruption.
set -eu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD_DIR="$DATA/bitwarden"
IO_HELPER="$SELF_DIR/fm-bitwarden-record-io.py"
SELF_PATH="$SELF_DIR/fm-bitwarden-ceremony.sh"
IO_ACTIVE=0

STEPS="preflight approval moved verified retired"

is_step() {  # <name> - exact whole-word membership in $STEPS
  local s
  for s in $STEPS; do
    if [ "$s" = "$1" ]; then return 0; fi
  done
  return 1
}

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

# Prints why $1 looks like secret material and returns 0; returns 1 when it
# does not. The reason never contains the value (see the safety contract).
secret_shape_defect() {
  case $1 in
    ghp_*|github_pat_*|sk-*|xox*|AKIA*|glpat-*|eyJ*) printf 'matches a well-known credential shape'; return 0 ;;
  esac
  if printf '%s' "$1" | grep -Eq -- '[A-Fa-f0-9]{32}'; then
    printf 'contains a long hexadecimal run'
    return 0
  fi
  return 1
}

# Prints why $1 is not a usable reference label and returns 0; returns 1 when it
# is one. Sole definition of a label, shared by the arguments this tool accepts
# and the values it reads back out of a record.
label_defect() {
  case $1 in
    '') printf 'is empty'; return 0 ;;
  esac
  if [ ${#1} -gt 64 ]; then
    printf 'is too long for a reference label (max 64)'
    return 0
  fi
  case $1 in
    *[!A-Za-z0-9._@/-]*) printf 'contains characters outside A-Za-z0-9 . _ @ / -'; return 0 ;;
  esac
  secret_shape_defect "$1"
}

is_leap_year() {  # <yyyy>
  if [ $(($1 % 400)) -eq 0 ]; then return 0; fi
  if [ $(($1 % 100)) -eq 0 ]; then return 1; fi
  [ $(($1 % 4)) -eq 0 ]
}

is_date() {  # <value> - a real YYYY-MM-DD calendar date
  local year day last_day
  case $1 in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  year=$((10#${1:0:4}))
  [ "$year" -ne 0 ] || return 1
  case ${1:5:2} in
    01|03|05|07|08|10|12) last_day=31 ;;
    04|06|09|11) last_day=30 ;;
    02) if is_leap_year "$year"; then last_day=29; else last_day=28; fi ;;
    *) return 1 ;;
  esac
  day=$((10#${1:8:2}))
  [ "$day" -ge 1 ] && [ "$day" -le "$last_day" ]
}

# Secret-shape refusals shared by every free-text argument. $1=field-name
# $2=value; on refusal, dies naming only the field, never the value.
refuse_secret_shape() {
  local field=$1 defect
  if defect=$(secret_shape_defect "$2"); then
    die "refused: value for $field $defect; secret values must never be passed to this tool"
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
  local field=$1 value=$2 defect
  if defect=$(label_defect "$value"); then
    [ -n "$value" ] || die "refused: $field is empty; pass a short reference label"
    die "refused: value for $field $defect; secret values must never be passed to this tool"
  fi
}

record_path() {
  if [ "$IO_ACTIVE" = 1 ]; then
    printf '%s' "$1.ceremony"
  else
    printf '%s/%s.ceremony' "$RECORD_DIR" "$1"
  fi
}

require_io_helper() {
  command -v python3 >/dev/null 2>&1 || die 'refused: python3 is required for no-follow ceremony record I/O'
  [ -f "$IO_HELPER" ] || die 'refused: ceremony record I/O helper is unavailable'
}

run_record_command() {  # <batch> <create-dir:0|1> <lock:0|1> <internal-command> <args...>
  local batch=$1 create_dir=$2 lock=$3 internal_command=$4
  shift 4
  require_io_helper
  python3 "$IO_HELPER" run "$RECORD_DIR" "$batch" "$create_dir" "$lock" "$SELF_PATH" "$internal_command" "$@"
}

atomic_append_line() {  # <batch> <line>
  local batch=$1 line=$2
  python3 "$IO_HELPER" append "$batch" "$PARSED_RECORD_HASH" "$line"
}

today() { date -u +%Y-%m-%d; }

# Parse and validate a record. Populates:
#   PARSED_ITEMS   - newline list of item labels
#   PARSED_ITEM_COUNT - how many item labels that list holds
#   PARSED_ITEM_LINES - newline list of complete item records
#   PARSED_STEPS   - space list of recorded step names, record order
#   PARSED_APPROVED_BY - approver label when the approval step is recorded
#   PARSED_CREATED_DATE - created header date
#   PARSED_LAST_STEP_DATE - latest recorded step date, when present
# The record must name the batch being read, carry each header exactly once
# ahead of the body, register no item after the moved step, and record steps as
# an ordered prefix of $STEPS with no repeat, gap, or trailing step, so every
# reader refuses a tampered or misfiled record rather than reporting progress
# from it.
# Dies with a line NUMBER (never content) on any malformed line.
parse_record() {
  local batch=$1 stream_fd=$2 lineno=0 line rest name pending=$STEPS expected
  local fields owner collection date_value approver='' defect
  local seen_batch=0 seen_created=0 in_body=0 moved_seen=0 unterminated=0
  local created_date='' prev_step_date='' today_date
  today_date=$(today)
  PARSED_ITEMS=""
  PARSED_ITEM_COUNT=0
  PARSED_ITEM_LINES=""
  PARSED_STEPS=""
  PARSED_APPROVED_BY=""
  while IFS= read -r line || { [ -n "$line" ] && unterminated=1; }; do
    lineno=$((lineno + 1))
    [ "$unterminated" -eq 0 ] || corrupt "$batch" "$lineno" 'final line has no terminating newline, so the record is truncated'
    if [ "$lineno" -eq 1 ]; then
      [ "$line" = 'fm-bitwarden-ceremony v1' ] || die "record for batch '$batch' is not a v1 ceremony record (line 1); $RECOVERY_HINT"
      continue
    fi
    case $line in
      'batch: '*)
        [ "$in_body" -eq 0 ] || corrupt "$batch" "$lineno" 'batch header after the record body'
        [ "$seen_batch" -eq 0 ] || corrupt "$batch" "$lineno" 'repeated batch header'
        seen_batch=1
        [ "${line#batch: }" = "$batch" ] || corrupt "$batch" "$lineno" "batch header names a different batch, so this record is not evidence for '$batch'"
        ;;
      'created: '*)
        [ "$in_body" -eq 0 ] || corrupt "$batch" "$lineno" 'created header after the record body'
        [ "$seen_created" -eq 0 ] || corrupt "$batch" "$lineno" 'repeated created header'
        seen_created=1
        created_date=${line#created: }
        is_date "$created_date" || corrupt "$batch" "$lineno" 'created header is not a YYYY-MM-DD calendar date'
        if [[ $created_date > $today_date ]]; then
          corrupt "$batch" "$lineno" 'created header is dated in the future, so the batch cannot have been created yet'
        fi
        ;;
      'item: '*)
        in_body=1
        [ "$moved_seen" -eq 0 ] || corrupt "$batch" "$lineno" 'item registered after the batch was marked moved'
        rest=${line#item: }
        name=${rest%% *}
        if defect=$(label_defect "$name"); then corrupt "$batch" "$lineno" "item label $defect"; fi
        fields=${rest#"$name" }
        owner=${fields#owner=}
        owner=${owner%% *}
        collection=${fields##*collection=}
        [ "$line" = "item: $name owner=$owner collection=$collection" ] || corrupt "$batch" "$lineno" 'malformed item line'
        if defect=$(label_defect "$owner"); then corrupt "$batch" "$lineno" "item owner $defect"; fi
        if defect=$(label_defect "$collection"); then corrupt "$batch" "$lineno" "item collection $defect"; fi
        case $'\n'"$PARSED_ITEMS" in
          *$'\n'"$name"$'\n'*) corrupt "$batch" "$lineno" 'item label already registered on an earlier line' ;;
        esac
        PARSED_ITEMS="$PARSED_ITEMS$name"$'\n'
        PARSED_ITEM_LINES="$PARSED_ITEM_LINES$line"$'\n'
        PARSED_ITEM_COUNT=$((PARSED_ITEM_COUNT + 1))
        ;;
      'step: '*)
        in_body=1
        rest=${line#step: }
        name=${rest%% *}
        is_step "$name" || corrupt "$batch" "$lineno" 'unknown step'
        fields=${rest#"$name" }
        date_value=${fields#date=}
        date_value=${date_value%% *}
        if [ "$name" = approval ]; then
          approver=${fields##* approved-by=}
          [ "$line" = "step: $name date=$date_value approved-by=$approver" ] || corrupt "$batch" "$lineno" 'malformed approval step line'
        else
          [ "$line" = "step: $name date=$date_value" ] || corrupt "$batch" "$lineno" 'malformed step line'
        fi
        is_date "$date_value" || corrupt "$batch" "$lineno" 'step date is not a YYYY-MM-DD calendar date'
        if [[ $date_value > $today_date ]]; then
          corrupt "$batch" "$lineno" 'step date is in the future, so the ceremony cannot have reached it'
        fi
        if [[ $date_value < $created_date ]]; then
          corrupt "$batch" "$lineno" 'step date is earlier than the created header, so the step predates the batch'
        fi
        if [ -n "$prev_step_date" ] && [[ $date_value < $prev_step_date ]]; then
          corrupt "$batch" "$lineno" 'step date is earlier than the previous step, so the recorded history runs backwards'
        fi
        prev_step_date=$date_value
        expected=${pending%% *}
        [ -n "$expected" ] || corrupt "$batch" "$lineno" 'step recorded after the ceremony is already complete'
        [ "$name" = "$expected" ] || corrupt "$batch" "$lineno" "steps out of order, expected '$expected' at this point"
        case $pending in
          *' '*) pending=${pending#* } ;;
          *) pending='' ;;
        esac
        if [ "$name" = approval ]; then
          if defect=$(label_defect "$approver"); then corrupt "$batch" "$lineno" "approval approved-by $defect"; fi
          PARSED_APPROVED_BY=$approver
        fi
        if [ "$name" = moved ]; then
          [ "$PARSED_ITEM_COUNT" -gt 0 ] || corrupt "$batch" "$lineno" 'batch marked moved with no registered item, so the record names no ownership or collection target'
          moved_seen=1
        fi
        PARSED_STEPS="$PARSED_STEPS$name "
        ;;
      *) corrupt "$batch" "$lineno" 'unrecognized line' ;;
    esac
  done <&"$stream_fd"
  [ "$seen_batch" -eq 1 ] || die "record for batch '$batch' has no batch header naming the batch it is evidence for; $RECOVERY_HINT"
  [ "$seen_created" -eq 1 ] || die "record for batch '$batch' has no created header; $RECOVERY_HINT"
  PARSED_CREATED_DATE=$created_date
  PARSED_LAST_STEP_DATE=$prev_step_date
}

load_record() {  # <batch>
  local batch=$1 stream_fd stream_pid protocol
  require_io_helper
  coproc BW_RECORD_STREAM { python3 "$IO_HELPER" stream "$batch"; }
  stream_fd=${BW_RECORD_STREAM[0]}
  stream_pid=$BW_RECORD_STREAM_PID
  if ! IFS= read -r protocol <&"$stream_fd"; then
    wait "$stream_pid" || true
    return 1
  fi
  case $protocol in
    'fm-bitwarden-snapshot-v1 sha256='*) ;;
    *) wait "$stream_pid" || true; die 'refused: ceremony record snapshot protocol is invalid' ;;
  esac
  PARSED_RECORD_HASH=${protocol#fm-bitwarden-snapshot-v1 sha256=}
  [ "${#PARSED_RECORD_HASH}" -eq 64 ] || die 'refused: ceremony record snapshot fingerprint is invalid'
  case $PARSED_RECORD_HASH in *[!A-Fa-f0-9]*) die 'refused: ceremony record snapshot fingerprint is invalid' ;; esac
  parse_record "$batch" "$stream_fd"
  exec {stream_fd}<&-
  wait "$stream_pid" || return 1
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

report_next() {
  local n
  if n=$(next_step); then printf 'next: %s\n' "$n"; else printf 'next: complete\n'; fi
}

cmd_init() {
  local batch=$1 path stamp rc=0
  require_batch_id "$batch"
  if [ "$IO_ACTIVE" != 1 ]; then
    run_record_command "$batch" 1 1 __io-init "$batch"
    return
  fi
  path=$(record_path "$batch")
  stamp=$(today)
  {
    printf 'fm-bitwarden-ceremony v1\n'
    printf 'batch: %s\n' "$batch"
    printf 'created: %s\n' "$stamp"
  } | python3 "$IO_HELPER" create "$batch" || rc=$?
  if [ "$rc" -eq 17 ]; then
    load_record "$batch"
    note "batch '$batch' already initialized; nothing to do"
    return 0
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  note "batch '$batch' initialized at ${FM_BITWARDEN_RECORD_DISPLAY:-$path}"
}

cmd_add_item() {
  local batch=$1 label=$2 owner='' collection=''
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
  if [ "$IO_ACTIVE" != 1 ]; then
    run_record_command "$batch" 0 1 __io-add-item "$batch" "$label" --owner "$owner" --collection "$collection"
    return
  fi
  load_record "$batch"
  local line="item: $label owner=$owner collection=$collection"
  case $'\n'"$PARSED_ITEM_LINES" in
    *$'\n'"$line"$'\n'*) note "batch '$batch': item '$label' already recorded; nothing to do"; return 0 ;;
  esac
  case $'\n'"$PARSED_ITEMS" in
    *$'\n'"$label"$'\n'*)
      die "batch '$batch': item '$label' already recorded with a different owner/collection; resolve the conflict in the record before continuing" ;;
  esac
  if step_recorded moved; then
    die "batch '$batch': items cannot be added after the batch is marked moved; start a new batch"
  fi
  atomic_append_line "$batch" "$line"
  note "batch '$batch': item '$label' registered (owner=$owner collection=$collection)"
}

cmd_mark() {
  local batch=$1 step=$2 approved_by='' expected stamp
  shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --approved-by) approved_by=${2:?}; shift 2 ;;
      *) die "unknown mark argument (see --help)" ;;
    esac
  done
  require_batch_id "$batch"
  is_step "$step" || die "unknown step; steps in order are: $STEPS"
  if [ "$step" = approval ]; then
    [ -n "$approved_by" ] || die "refused: approval requires --approved-by with the captain's recorded identity label"
    require_label '--approved-by' "$approved_by"
  else
    [ -z "$approved_by" ] || die "--approved-by is only valid for the approval step"
  fi
  if [ "$IO_ACTIVE" != 1 ]; then
    if [ "$step" = approval ]; then
      run_record_command "$batch" 0 1 __io-mark "$batch" "$step" --approved-by "$approved_by"
    else
      run_record_command "$batch" 0 1 __io-mark "$batch" "$step"
    fi
    return
  fi
  load_record "$batch"
  if step_recorded "$step"; then
    if [ "$step" = approval ] && [ "$approved_by" != "$PARSED_APPROVED_BY" ]; then
      die "batch '$batch': approval is already recorded for a different approver; resolve the conflict in the record before continuing"
    fi
    note "batch '$batch': step '$step' already recorded; nothing to do"
    return 0
  fi
  if [ "$step" = moved ] && [ "$PARSED_ITEM_COUNT" -eq 0 ]; then
    die "batch '$batch': refused to mark moved with no registered items; every moved credential needs a recorded owner/collection target"
  fi
  if [ "$step" = retired ]; then
    step_recorded verified || die "batch '$batch': refused to record retirement before post-move verification"
    [ -n "$PARSED_APPROVED_BY" ] || die "batch '$batch': refused to record retirement without a recorded captain approval"
  fi
  expected=$(next_step) || die "batch '$batch' is already complete"
  [ "$step" = "$expected" ] || die "batch '$batch': next required step is '$expected', not '$step' (steps in order are: $STEPS)"
  stamp=$(today)
  is_date "$stamp" || die 'refused: current UTC date is not a YYYY-MM-DD calendar date'
  if [ -n "$PARSED_LAST_STEP_DATE" ] && [[ $stamp < $PARSED_LAST_STEP_DATE ]]; then
    die "batch '$batch': refused to record a step because the current UTC date is earlier than the previous step date"
  fi
  if [[ $stamp < $PARSED_CREATED_DATE ]]; then
    die "batch '$batch': refused to record a step because the current UTC date is earlier than the batch creation date"
  fi
  if [ "$step" = approval ]; then
    atomic_append_line "$batch" "step: $step date=$stamp approved-by=$approved_by"
  else
    atomic_append_line "$batch" "step: $step date=$stamp"
  fi
  note "batch '$batch': step '$step' recorded ($stamp)"
}

cmd_status() {
  local batch=$1 path s marker
  require_batch_id "$batch"
  if [ "$IO_ACTIVE" != 1 ]; then
    run_record_command "$batch" 0 0 __io-status "$batch"
    return
  fi
  path=$(record_path "$batch")
  load_record "$batch"
  printf 'batch: %s\n' "$batch"
  printf 'record: %s\n' "${FM_BITWARDEN_RECORD_DISPLAY:-$path}"
  printf 'items: %s\n' "$PARSED_ITEM_COUNT"
  for s in $STEPS; do
    if step_recorded "$s"; then marker='x'; else marker=' '; fi
    printf '  [%s] %s\n' "$marker" "$s"
  done
  report_next
}

cmd_check() {
  local batch=$1
  require_batch_id "$batch"
  if [ "$IO_ACTIVE" != 1 ]; then
    run_record_command "$batch" 0 0 __io-check "$batch"
    return
  fi
  load_record "$batch"
  report_next
}

case ${1:-} in
  -h|--help|help|'') usage; exit 0 ;;
  init) [ $# -eq 2 ] || die "usage: init <batch-id>"; cmd_init "$2" ;;
  add-item) [ $# -ge 3 ] || die "usage: add-item <batch-id> <item-label> --owner <label> --collection <label>"; shift; cmd_add_item "$@" ;;
  mark) [ $# -ge 3 ] || die "usage: mark <batch-id> <step> [--approved-by <label>]"; shift; cmd_mark "$@" ;;
  status) [ $# -eq 2 ] || die "usage: status <batch-id>"; cmd_status "$2" ;;
  check) [ $# -eq 2 ] || die "usage: check <batch-id>"; cmd_check "$2" ;;
  __io-init) [ "${FM_BITWARDEN_IO_ACTIVE:-0}" = 1 ] && [ $# -eq 2 ] || die 'refused: invalid internal ceremony invocation'; IO_ACTIVE=1; cmd_init "$2" ;;
  __io-add-item) [ "${FM_BITWARDEN_IO_ACTIVE:-0}" = 1 ] && [ $# -ge 3 ] || die 'refused: invalid internal ceremony invocation'; IO_ACTIVE=1; shift; cmd_add_item "$@" ;;
  __io-mark) [ "${FM_BITWARDEN_IO_ACTIVE:-0}" = 1 ] && [ $# -ge 3 ] || die 'refused: invalid internal ceremony invocation'; IO_ACTIVE=1; shift; cmd_mark "$@" ;;
  __io-status) [ "${FM_BITWARDEN_IO_ACTIVE:-0}" = 1 ] && [ $# -eq 2 ] || die 'refused: invalid internal ceremony invocation'; IO_ACTIVE=1; cmd_status "$2" ;;
  __io-check) [ "${FM_BITWARDEN_IO_ACTIVE:-0}" = 1 ] && [ $# -eq 2 ] || die 'refused: invalid internal ceremony invocation'; IO_ACTIVE=1; cmd_check "$2" ;;
  *) die "unknown command; commands are: init add-item mark status check --help" ;;
esac
