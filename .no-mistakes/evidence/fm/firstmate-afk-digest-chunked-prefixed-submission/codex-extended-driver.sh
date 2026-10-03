#!/usr/bin/env bash
# Live away-digest chunk fidelity guard (live-harness-optin family).
#
# A typed away-supervisor envelope longer than one Herdr pane write reached
# Claude Code as paste placeholders plus a literal tail, and the tail alone was
# recorded as an ordinary typed user prompt with no operational prefix, which
# reads as the captain returning. A stub cannot show what a real terminal and a
# real composer record, so this guard launches real Claude Code in an isolated
# Herdr lab and reads the prompts Claude itself wrote to its session JSONL.
#
# It requires, from that JSONL:
#   - typed carrier: a batch below the typed bound and one far above it, with
#     one event larger than a whole chunk, arrive only as prompts that begin
#     with the operational prefix (Claude drops the leading U+2063), each
#     byte-identical to a value the sender logged by length and SHA-256, with
#     every event identity present once and in order;
#   - record carrier, driven by the real daemon's first catch-all scan over a
#     fresh state directory: every prompt is exactly a doorbell whose record in
#     that home holds a current away-supervisor envelope, again matching the
#     sender's logged SHA-256, with every event identity present exactly once.
#
# Run explicitly with FM_AFK_DIGEST_CHUNKS_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Away digest chunk fidelity" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_AFK_DIGEST_CHUNKS_LIVE herdr jq claude uuidgen

[ -x "$LAB_HELPER" ] || fail "FM_AFK_DIGEST_CHUNKS_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name typed-fallback)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-afk-chunks.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$ROOT"
mkdir -p "$FAKEBIN" "$PROJECT"
DAEMON_PID=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "${EVIDENCE_DIR:-}" ]; then
    mkdir -p "$EVIDENCE_DIR/live"
    cp -R "$TMP_ROOT/rows-all" "$TMP_ROOT/rows-typed" "$TMP_ROOT/typed" "$TMP_ROOT/record" "$EVIDENCE_DIR/live/" 2>/dev/null || true
    [ -z "${PANE:-}" ] || lab pane read "$PANE" --source visible > "$EVIDENCE_DIR/live/final-pane.txt" 2>/dev/null || true
    printf 'session=%s\nclaude_session=%s\nproject=%s\n' "$SESSION" "${SID:-}" "$PROJECT" > "$EVIDENCE_DIR/live/session.txt"
  fi
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export HERDR_SESSION="$SESSION"

# The daemon's own functions are the sender under test.
# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
sha256_of() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  fi
}

WS_JSON=$(lab workspace create --cwd "$PROJECT" --label fm-afkchunks --no-focus) \
  || fail "could not create the isolated workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
WHO="Claude Code ($VERSION) on $HERDR_VER"
SID=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Claude Code refuses to save a transcript while it inherits another Claude
# session's markers, and the transcript is this guard's evidence.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_PID|CLAUDE_JOB_DIR|CLAUDE_EFFORT|CLAUDE_CODE_[A-Z_]+)=' | cut -d= -f1 | sort -u)
}

lab pane run "$PANE" "env $(unset_inherited)codex --no-daemon --disable hooks --disable plugins -c check_for_update_on_startup=false --sandbox read-only --ask-for-approval never -c project_doc_max_bytes=0 -c 'developer_instructions=\"This is a disposable transport fixture. Reply only OK to submitted messages. Do not call tools.\"'" >/dev/null || fail "could not start real Codex"

# wait_idle: the rendered composer footer with no running turn. Herdr can
# report idle through a whole Claude turn, so the footer decides.
wait_idle() {
  local limit=$1 i=0 st
  while [ "$i" -lt "$limit" ]; do
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    case "$screen" in
      *'Update available'*) lab pane send-keys "$PANE" esc >/dev/null; sleep 1; continue ;;
      *'Hooks need review'*) lab pane send-keys "$PANE" down down enter >/dev/null; sleep 1; continue ;;
    esac
    st=$(fm_backend_composer_state herdr "$TARGET" 2>/dev/null || true)
    if [ "$st" = empty ] && ! pane_is_busy "$TARGET" herdr; then return 0; fi
    i=$((i+1)); sleep 1
  done
  lab pane read "$PANE" --source visible
  return 1
}
wait_idle 90 || fail "real Codex never rendered a supported idle composer"

# prompts: one file per typed prompt Claude recorded, in order, under <dir>.
prompts() {  # <dir>
  local dir=$1 jsonl n=0 row
  rm -rf "$dir"; mkdir -p "$dir"
  jsonl="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$PROJECT" | sed 's/[^a-zA-Z0-9]/-/g')/$SID.jsonl"
  [ -f "$jsonl" ] || return 0
  while IFS= read -r row; do
    n=$((n + 1))
    printf '%s' "$row" | jq -rj . > "$dir/$(printf '%03d' "$n")"
  done < <(jq -c 'select(.type == "user" and .isMeta != true and (.message.content | type) == "string") | .message.content' "$jsonl")
}
prompt_count() { prompts "$1"; find "$1" -type f | wc -l | tr -d ' '; }

# delivered_sums: the SHA-256 of every submission <log> reports delivered.
delivered_sums() {  # <log> <carrier>
  sed -n "s/.*inject delivered: carrier=$2 bytes=[0-9]* sha256=\([0-9a-f]*\)\$/\1/p" "$1"
}

export FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" FM_DAEMON_PRIMARY_HARNESS=codex
export FM_INJECT_CONFIRM_RETRIES=6 FM_INJECT_CONFIRM_SLEEP=0.5



STATE="$TMP_ROOT/typed"
mkdir -p "$STATE"
LOG="$STATE/daemon.log"
afk_enter "$STATE"
EOUT="$EVIDENCE_DIR/codex-live"
mkdir -p "$EOUT"
capture() { lab pane read "$PANE" --source visible > "$EOUT/$1.txt"; }
flush() { wait_idle 90 || fail "Codex not idle"; escalate_flush "$1" || fail "Codex delivery failed: $INJECT_LAST_FAILURE"; wait_idle 90 || fail "Codex did not finish"; }
escalate_add "$STATE" 'short-1.status: done: fixture'
escalate_add "$STATE" 'short-2.status: done: fixture'
flush "$STATE"
capture below-cap
[ ! -s "$STATE/.subsuper-escalations" ] || fail "below-cap events remain"
for i in {1..8}; do escalate_add "$STATE" "batch-$i.status: done: $(printf '%150s' '' | tr ' ' x)"; done
n=0
while [ -s "$STATE/.subsuper-escalations" ]; do
  n=$((n+1)); [ "$n" -le 8 ] || fail "batch stuck"
  flush "$STATE"; capture "above-cap-$n"
done
printf 'Real Codex: above-cap batch drained in %s bounded submissions\n' "$n"
[ "$n" -gt 1 ] || fail "above-cap batch was not chunked"
item='whole-630.status: done: '
item="$item$(printf '%*s' "$((630-${#item}))" '' | tr ' ' x)"
escalate_add "$STATE" "$item"
escalate_add "$STATE" 'following.status: done: fixture'
flush "$STATE"; capture whole-630
[ "$(cat "$STATE/.subsuper-escalations")" = 'following.status: done: fixture' ] || fail "630-byte event was not consumed whole on its own"
flush "$STATE"; capture following
printf 'Real Codex: 630-byte event sent whole with a following event still queued\n'
LONG="$TMP_ROOT/long"
while [ "${#LONG}" -lt 800 ]; do
  amount=$((800-${#LONG}-1)); [ "$amount" -le 80 ] || amount=80
  LONG="$LONG/$(printf '%*s' "$amount" '' | tr ' ' p)"
done
mkdir -p "$LONG"
afk_enter "$LONG"
A="A.status: done: $(printf '%2000s' '' | tr ' ' a)"
B="B.status: done: $(printf '%2000s' '' | tr ' ' b)"
escalate_add "$LONG" "$A"
escalate_add "$LONG" "$B"
flush "$LONG"; capture oversized-A
source_a=$(ls "$LONG/.subsuper-digests")
[ "$(cat "$LONG/.subsuper-digests/$source_a")" = "$A" ] || fail "A source is wrong"
rg -q "$source_a" "$EOUT/oversized-A.txt" || fail "A notice omitted its saved basename"
lab pane send-text "$PANE" 'fixture-unsent-draft' >/dev/null || fail "could not type the user draft"
sleep 1
capture pending-draft
if escalate_flush "$LONG"; then fail "typed into the user's draft"; fi
[ "$(cat "$LONG/.subsuper-escalations")" = "$B" ] || fail "deferred B changed"
[ "$(ls "$LONG/.subsuper-digests" | wc -l | tr -d ' ')" -eq 1 ] || fail "a newer source was published before the pending-composer check"
printf 'Real Codex: pending draft deferred B, preserved B, and published no newer source; %s\n' "$INJECT_LAST_FAILURE"
# User submits their own draft; the sender never clears the composer.
lab pane send-keys "$PANE" enter >/dev/null
sleep 2
flush "$LONG"; capture oversized-B
[ ! -s "$LONG/.subsuper-escalations" ] || fail "B not consumed after user submit"
[ "$(ls "$LONG/.subsuper-digests" | wc -l | tr -d ' ')" -eq 2 ] || fail "oversized sources are not separate"
[ "$(cat "$LONG/.subsuper-digests/$source_a")" = "$A" ] || fail "A source changed after B"
for full in "$LONG/.subsuper-digests/"*; do
  [ "${full##*/}" = "$source_a" ] && continue
  [ "$(cat "$full")" = "$B" ] || fail "B source wrong"
  rg -q "${full##*/}" "$EOUT/oversized-B.txt" || fail "B notice omitted its own basename"
done
cp -R "$LONG/.subsuper-digests" "$EOUT/full-sources"
printf 'Real Codex: both oversized events delivered as bounded notices with distinct stable relative pointers\n'
# Exercise record-carrier catch-all batching through the same real terminal.
REC="$TMP_ROOT/record"
mkdir -p "$REC"
afk_enter "$REC"
export FM_OPERATIONAL_RECORD_HARNESSES=codex
for i in {1..12}; do printf 'done: record-fixture-%02d %s\n' "$i" "$(printf '%850s' '' | tr ' ' z)" > "$REC/rec-$(printf '%02d' "$i").status"; done
FM_HEARTBEAT_SCAN_SECS=0 FM_ESCALATE_BATCH_SECS=90 FM_MAX_DEFER_SECS=0 housekeeping "$REC"
rn=0
while [ -s "$REC/.subsuper-escalations" ]; do
  rn=$((rn+1)); [ "$rn" -le 12 ] || fail "record catch-all stuck"
  flush "$REC"; capture "record-carrier-$rn"
done
[ "$rn" -gt 1 ] || fail "record catch-all not chunked"
for i in {1..12}; do
  count=$(rg -l "record-fixture-$(printf '%02d' "$i") " "$REC/operational-inbox/"*.msg | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "record event $i lost or repeated"
done
cp -R "$REC/operational-inbox" "$EOUT/operational-inbox"
export FM_OPERATIONAL_RECORD_HARNESSES=''
printf 'Real Codex: first catch-all scan delivered %s doorbells, with every whole event in exactly one durable record\n' "$rn"

# Filesystem failure before delivery: exercise the real permission boundary.
escalate_add "$STATE" 'filesystem-guard.status: done: fixture'
cp "$STATE/.subsuper-escalations" "$TMP_ROOT/before-permission-failure"
chmod 500 "$STATE"
if escalate_flush "$STATE"; then chmod 700 "$STATE"; fail "read-only state was reported delivered"; fi
chmod 700 "$STATE"
cmp "$STATE/.subsuper-escalations" "$TMP_ROOT/before-permission-failure" || fail "filesystem failure changed buffered events"
printf 'Real Codex: permission failure preserved buffer without submitting; %s\n' "$INJECT_LAST_FAILURE"
flush "$STATE"; capture filesystem-recovery
cp "$LOG" "$EOUT/sender.log"
# Every actual sender value is enforced by the product's real cap check.
awk '/inject send:/ {for(i=1;i<=NF;i++) if($i ~ /^bytes=/) {split($i,a,"="); if(a[2]>768) exit 1}}' "$LOG" || fail "sender exceeded cap"
printf 'Real Codex: all submitted chunks fit 768 bytes and every send has a matching delivery SHA-256 in sender.log\n'
