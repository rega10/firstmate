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
SESSION=$("$LAB_HELPER" name afk-chunks-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-afk-chunks.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
PROJECT="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$PROJECT"
DAEMON_PID=

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
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

lab pane run "$PANE" "env $(unset_inherited)CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 DISABLE_AUTOUPDATER=1 claude --model haiku --session-id $SID --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch $WHO in the isolated Herdr pane"

# wait_idle: the rendered composer footer with no running turn. Herdr can
# report idle through a whole Claude turn, so the footer decides.
wait_idle() {  # <seconds>
  local limit=$1 i=0 trusted=0 screen st
  while [ "$i" -lt "$limit" ]; do
    screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
    case "$screen" in
      *'esc to interrupt'*) ;;
      *'bypass permissions on'*)
        st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
        case "$st" in idle|done) return 0 ;; esac
        ;;
      *'Yes, I trust this folder'*)
        if [ "$trusted" = 0 ]; then
          trusted=1
          lab pane send-keys "$PANE" down enter >/dev/null \
            || fail "could not accept Claude's folder-trust prompt"
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}
wait_idle 90 || fail "$WHO never rendered an idle composer in the lab pane"

# prompts: one file per typed prompt Claude recorded, in order, under <dir>.
prompts() {  # <dir>
  local dir=$1 jsonl n=0 row
  rm -rf "$dir"; mkdir -p "$dir"
  jsonl=$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name "$SID.jsonl" 2>/dev/null | head -1)
  [ -n "$jsonl" ] || return 0
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

export FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" FM_DAEMON_PRIMARY_HARNESS=claude
export FM_INJECT_CONFIRM_RETRIES=6 FM_INJECT_CONFIRM_SLEEP=0.5

# --- typed carrier: bounded chunks through a real terminal -------------------
# Claude is normally a record-backed primary; clearing that list makes the
# sender type the envelope itself, the carrier every other primary receives.
TYPED_STATE="$TMP_ROOT/typed"
mkdir -p "$TYPED_STATE"
LOG="$TYPED_STATE/daemon.log"
FM_OPERATIONAL_RECORD_HARNESSES=''
afk_enter "$TYPED_STATE"

drain_typed() {
  local n=0
  while [ -s "$TYPED_STATE/.subsuper-escalations" ]; do
    n=$((n + 1))
    [ "$n" -le 30 ] || fail "$WHO: typed chunks never drained: $(tail -5 "$LOG")"
    wait_idle 120 || fail "$WHO never returned to an idle composer between typed chunks"
    escalate_flush "$TYPED_STATE" || sleep 2
  done
  wait_idle 120 || fail "$WHO never finished the last typed chunk's turn"
}

TYPED_EXPECTED="$TMP_ROOT/typed-expected"
: > "$TYPED_EXPECTED"
for i in 1 2; do
  line="lab-$i.status: done: regression fixture event, reply with just OK (catch-all scan)"
  printf '%s\n' "$line" >> "$TYPED_EXPECTED"
  escalate_add "$TYPED_STATE" "$line"
done
drain_typed
[ "$(delivered_sums "$LOG" typed | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "$WHO: a batch below the typed bound was not one submission: $(cat "$LOG")"

i=3
while [ "$i" -le 11 ]; do
  line="done: PR https://example.invalid/fixture/pull/$i checks green, regression fixture event number $i ; literal prose, nothing to do, reply with just OK"
  printf '%s\n' "$line" >> "$TYPED_STATE/lab-batch.status"
  printf 'lab-batch.status: %s (catch-all scan)\n' "$line" >> "$TYPED_EXPECTED"
  i=$((i + 1))
done
FM_ESCALATE_BATCH_SECS=90 FM_MAX_DEFER_SECS=0 FM_HEARTBEAT_SCAN_SECS=0 housekeeping "$TYPED_STATE"
big="lab-12.status: blocked: regression fixture event, reply with just OK"
while [ "${#big}" -lt 1500 ]; do big+=" ; oversized fixture filler"; done
escalate_add "$TYPED_STATE" "$big"
line="lab-13.status: done: regression fixture event, reply with just OK (catch-all scan)"
printf '%s\n' "$line" >> "$TYPED_EXPECTED"
escalate_add "$TYPED_STATE" "$line"
drain_typed

TYPED_SENT=$(delivered_sums "$LOG" typed | wc -l | tr -d ' ')
[ "$TYPED_SENT" -ge 4 ] || fail "$WHO: a batch far above the typed bound was sent as only $TYPED_SENT submission(s)"


TYPED_ROWS=$(prompt_count "$TMP_ROOT/rows-typed")
[ "$TYPED_ROWS" -eq "$TYPED_SENT" ] \
  || fail "$WHO recorded $TYPED_ROWS typed prompt(s) for $TYPED_SENT delivered chunk(s): $(head -c 200 "$TMP_ROOT"/rows-typed/* 2>/dev/null)"
n=0
seen=
while IFS= read -r sum; do
  n=$((n + 1))
  row=$(cat "$TMP_ROOT/rows-typed/$(printf '%03d' "$n")"; printf x); row=${row%x}
  row=${row#"$FM_OPERATIONAL_MARK"}
  case "$row" in
    'FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate ('*) ;;
    *) fail "$WHO recorded typed chunk $n without the operational prefix at its start: ${row:0:80}" ;;
  esac
  escalate_fits "$FM_OPERATIONAL_MARK$row" "$ESCALATE_TYPED_BYTES" || fail "$WHO recorded an over-cap typed chunk"
  [ "$(sha256_of "$FM_OPERATIONAL_MARK$row")" = "$sum" ] \
    || fail "$WHO recorded typed chunk $n differently from the bytes the sender logged (sha256 $sum): ${row:0:80}"
  seen+=$(printf '%s' "$row" | grep -oE 'lab-[0-9]*\.status|fixture event number [0-9]*' | tr '\n' ';')
  full=$(printf '%s' "$row" | sed -n 's/.*full text of every event: \([^ )]*\).*/\1/p')
  [ -z "$full" ] || seen+=$(grep -o 'lab-[0-9]*\.status' "$full" | tr '\n' ';')
done < <(delivered_sums "$LOG" typed)
want=
i=1
while [ "$i" -le 13 ]; do
  if [ "$i" -ge 3 ] && [ "$i" -le 11 ]; then want+="fixture event number $i;"; else want+="lab-$i.status;"; fi
  i=$((i + 1))
done
[ "$seen" = "$want" ] || fail "$WHO: typed chunks did not reassemble every event once, in order: $seen"
while IFS= read -r line; do
  [ "$(grep -F -l "$line" "$TMP_ROOT"/rows-typed/* | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "$WHO: a short event from one status span did not arrive whole exactly once: $line"
done < "$TYPED_EXPECTED"
grep -F -l 'oversized event (digest bounded; full text of every event:' "$TMP_ROOT"/rows-typed/* >/dev/null \
  || fail "$WHO: the event larger than a chunk was not delivered as a minimal summary with a pointer"
full=$(sed -n 's/.*full text of every event: \([^ )]*\).*/\1/p' "$TMP_ROOT"/rows-typed/*)
[ -n "$full" ] && [ -f "$full" ] && [ "$(cat "$full")" = "$big" ] \
  || fail "$WHO: the structured summary lacks its verbatim durable event"
pass "live away digest chunks: $WHO recorded $TYPED_SENT typed chunks, each starting with the operational prefix and byte-identical to the sender's logged SHA-256, every event once and in order"

# --- record carrier: the real daemon's first catch-all scan ------------------
REC_STATE="$TMP_ROOT/record"
mkdir -p "$REC_STATE"
REC_EXPECTED="$TMP_ROOT/record-expected"
: > "$REC_EXPECTED"
i=1
while [ "$i" -le 12 ]; do
  line="done: PR https://example.invalid/fixture/pull/$i checks green, regression fixture event, nothing to do"
  while [ "${#line}" -lt 850 ]; do line+=" ; fixture filler"; done
  printf '%s\n' "$line" > "$REC_STATE/labrec-$i.status"
  printf 'labrec-%s.status: %s (catch-all scan)\n' "$i" "$line" >> "$REC_EXPECTED"
  i=$((i + 1))
done
afk_enter "$REC_STATE"
# shellcheck disable=SC2030,SC2031 # The subshell scopes the record harness list to this daemon launch.
(
  unset FM_OPERATIONAL_RECORD_HARNESSES LOG
  FM_STATE_OVERRIDE="$REC_STATE" FM_ESCALATE_BATCH_SECS=3 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_STALE_ESCALATE_SECS=999999 \
    FM_MAX_DEFER_SECS=0 exec "$DAEMON" >"$REC_STATE/daemon.out" 2>"$REC_STATE/daemon.err"
) &
DAEMON_PID=$!
REC_LOG="$REC_STATE/.supervise-daemon.log"

i=0
while [ "$i" -lt 300 ]; do
  kill -0 "$DAEMON_PID" 2>/dev/null \
    || fail "the daemon exited: $(cat "$REC_STATE/daemon.err" 2>/dev/null; tail -5 "$REC_LOG" 2>/dev/null)"
  if [ -f "$REC_LOG" ] && [ ! -s "$REC_STATE/.subsuper-escalations" ] \
    && [ "$(delivered_sums "$REC_LOG" record | wc -l | tr -d ' ')" -ge 2 ] \
    && [ "$(cat "$REC_STATE"/operational-inbox/*.msg 2>/dev/null | grep -o 'labrec-[0-9]*\.status' | sort -u | wc -l | tr -d ' ')" -eq 12 ]; then
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$i" -lt 300 ] || fail "$WHO: the daemon's first catch-all batch never fully arrived: $(tail -8 "$REC_LOG" 2>/dev/null)"
wait_idle 120 || fail "$WHO never finished the last doorbell's turn"
afk_exit "$REC_STATE"
kill "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=

REC_SENT=$(delivered_sums "$REC_LOG" record | wc -l | tr -d ' ')
ALL_ROWS=$(prompt_count "$TMP_ROOT/rows-all")
[ "$((ALL_ROWS - TYPED_ROWS))" -eq "$REC_SENT" ] \
  || fail "$WHO recorded $((ALL_ROWS - TYPED_ROWS)) prompt(s) for $REC_SENT delivered doorbell(s)"
n=$TYPED_ROWS
seen=
while IFS= read -r sum; do
  n=$((n + 1))
  row=$(cat "$TMP_ROOT/rows-all/$(printf '%03d' "$n")"; printf x); row=${row%x}
  kind=
  fm_operational_doorbell_kind "$row" "$REC_STATE" kind && [ "$kind" = away-supervisor ] \
    || fail "$WHO recorded a prompt that is not a doorbell for this home's away-supervisor record: ${row:0:120}"
  escalate_fits "$row" "$ESCALATE_TYPED_BYTES" || fail "$WHO recorded an over-cap doorbell"
  [ "$(sha256_of "$row")" = "$sum" ] \
    || fail "$WHO recorded a doorbell differently from the bytes the sender logged (sha256 $sum): ${row:0:120}"
  fm_operational_doorbell_path "$row" record
  seen+=$(grep -o 'labrec-[0-9]*\.status' "$record" | tr '\n' ';')
done < <(delivered_sums "$REC_LOG" record)
[ "$(printf '%s' "$seen" | tr ';' '\n' | sort)" = "$(i=1; while [ "$i" -le 12 ]; do printf 'labrec-%s.status\n' "$i"; i=$((i + 1)); done | sort)" ] \
  || fail "$WHO: the first catch-all batch's records do not hold every event exactly once: $seen"
while IFS= read -r line; do
  [ "$(grep -F -l "$line" "$REC_STATE"/operational-inbox/*.msg | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "$WHO: a record-carrier event did not arrive whole exactly once: $line"
done < "$REC_EXPECTED"
pass "live away digest chunks: $WHO recorded the real daemon's first catch-all batch as $REC_SENT doorbells, each naming a current away-supervisor record and byte-identical to the sender's logged SHA-256, every event exactly once"

