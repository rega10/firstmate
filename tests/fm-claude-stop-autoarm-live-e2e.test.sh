#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock receives the full session-start digest through the tracked
# SessionStart hook; session start reclaims the dead owner; at least two
# tokenless auto-arm and rewake cycles then complete with zero model-issued arm
# commands; and the cooperative guard consumes no forced continuation while the
# hook's launch is healthy.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E,FM_CLAUDE_SESSION_LOCK_LIVE_E2E,FM_CLAUDE_BACKGROUND_MOVE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# Focused live session-identity guard. The two real print-mode sessions submit
# no model work: their UserPromptSubmit hook always blocks after recording the
# real lock/guard verdict. This proves the vendor's hook environment, including
# session ids and CLAUDE_PID, without requiring a desktop app or shared daemon.
# The portable ancestry suite supplies the shared-app/recycled-process matrix.
if [ "${FM_CLAUDE_SESSION_LOCK_LIVE_E2E:-0}" = 1 ]; then
  LAB="$ROOT/.claude-session-lock-live.$$"
  mkdir -p "$LAB"
  LAB=$(cd "$LAB" && pwd -P)
  LIVE_PIDS=()
  # shellcheck disable=SC2329 # Invoked by the EXIT trap in this opt-in branch.
  cleanup_identity() {
    : > "$LAB/release"
    for pid in ${LIVE_PIDS[@]+"${LIVE_PIDS[@]}"}; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    rm -rf "$LAB"
    fm_test_cleanup
  }
  trap cleanup_identity EXIT
  "$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null || fail "cannot create live lock lab"
  cp -R "$ROOT/bin" "$LAB/home/bin"
  : > "$LAB/home/AGENTS.md"
  git init -q "$LAB/home"
  mkdir -p "$LAB/home/.claude"
  VERSION=$(claude --version)
  FIRST_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  SECOND_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  cat > "$LAB/home/probe.sh" <<'SH'
#!/usr/bin/env bash
set -u
payload=$(cat)
. "$FM_HOME/bin/fm-session-lock-lib.sh"
label=${FM_LIVE_LOCK_LABEL:?}
id=$(printf '%s' "$payload" | jq -r '.session_id')
trusted=$(fm_session_lock_trusted_session_id || true)
[ -n "$trusted" ] && [ "$trusted" = "$id" ] || exit 1
printf '%s\n' "$id" > "$FM_HOME/$label.id"
if [ "$1" = start ]; then
  "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/$label.lock.out" 2>&1
  printf '%s\n' "$?" > "$FM_HOME/$label.lock.rc"
  exit 0
fi
printf '%s\n' "$payload" | "$FM_HOME/bin/fm-sessionstart-run.sh" --check-claude-lock > "$FM_HOME/$label.prompt.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/$label.prompt.rc"
if [ "$label" = contender ]; then
  # Exercise transcript-data boundaries with real vendor hook identity and a
  # real live owner. Only the transcript data is disposable fixture input.
  owner=$(cat "$FM_HOME/state/.lock-session")
  cfg="$FM_HOME/move-config"
  mkdir -p "$cfg/projects/lab"
  printf '{"type":"continued-in","sessionId":"%s","continuedInSessionId":"elsewhere"}\n' "$owner" > "$cfg/projects/lab/$owner.jsonl"
  CLAUDE_CONFIG_DIR="$cfg" "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/move-elsewhere.out" 2>&1
  printf '%s\n' "$?" > "$FM_HOME/move-elsewhere.rc"
  printf '{"type":"continued-in","sessionId":"%s","continuedInSessionId":"%s"}\n{"type":"user","sessionId":"%s","message":{"content":"The original session spoke again."}}\n' "$owner" "$id" "$owner" > "$cfg/projects/lab/$owner.jsonl"
  CLAUDE_CONFIG_DIR="$cfg" "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/move-resumed.out" 2>&1
  printf '%s\n' "$?" > "$FM_HOME/move-resumed.rc"
  # A separate home allows a successful chained takeover without changing the
  # main fixture's owner, whose continued ownership is asserted below.
  move_home="$FM_HOME/chained-home"
  "$FM_HOME/bin/fm-lab-home.sh" create "$move_home" >/dev/null || exit 1
  cp "$FM_HOME/state/.lock" "$FM_HOME/state/.lock-session" "$move_home/state/"
  printf '{"type":"continued-in","sessionId":"%s","continuedInSessionId":"middle"}\n' "$owner" > "$cfg/projects/lab/$owner.jsonl"
  printf '{"type":"continued-in","sessionId":"middle","continuedInSessionId":"%s"}\n' "$id" > "$cfg/projects/lab/middle.jsonl"
  FM_HOME="$move_home" CLAUDE_CONFIG_DIR="$cfg" "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/move-chain.out" 2>&1
  printf '%s\n' "$?" > "$FM_HOME/move-chain.rc"
  kill -0 "$(cat "$FM_HOME/state/.lock")" || exit 1
  cp "$move_home/state/.lock-session" "$FM_HOME/move-chain.session"
fi
if [ "$label" = owner ]; then
  # Hold the exact live anchor while the second real session tests refusal.
  # Also exercise equality with that anchor using the contender's real id.
  CLAUDE_CODE_SESSION_ID="$FM_LIVE_OTHER_ID" "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/shared-pid.out" 2>&1
  printf '%s\n' "$?" > "$FM_HOME/shared-pid.rc"
  : > "$FM_HOME/owner.ready"
  for ((i=0; i<600; i++)); do
    [ ! -e "$FM_HOME/../release" ] || break
    sleep 0.1
  done
fi
printf 'Live lock fixture deliberately blocks model execution.\n' >&2
exit 2
SH
  chmod +x "$LAB/home/probe.sh"
  cat > "$LAB/home/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"$FM_HOME\"/probe.sh start","timeout":90}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$FM_HOME\"/probe.sh prompt","timeout":90}]}]}}
JSON
  run_identity_session() {
    cd "$LAB/home" || exit 1
    exec env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_JOB_DIR \
      FM_HOME="$LAB/home" FM_LIVE_LOCK_LABEL="$1" FM_LIVE_OTHER_ID="$SECOND_ID" \
      claude -p 'This prompt must be blocked by the fixture hook.' --session-id "$2" \
      --setting-sources project --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --tools '' --system-prompt 'Do not act. The hook must block this prompt.' \
      > "$LAB/$1.out" 2>&1
  }
  wait_identity_file() {
    local i=0
    while [ ! -e "$1" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i+1)); done
    [ -e "$1" ] || fail "Claude $VERSION did not emit $(basename "$1")"
  }
  run_identity_session owner "$FIRST_ID" &
  LIVE_PIDS+=("$!")
  wait_identity_file "$LAB/home/owner.ready"
  cp "$LAB/home/state/.lock-session" "$LAB/owner-session"
  run_identity_session contender "$SECOND_ID" &
  LIVE_PIDS+=("$!")
  wait_identity_file "$LAB/home/contender.prompt.rc"
  expect_code 0 "$(cat "$LAB/home/owner.lock.rc")" "Claude $VERSION owner acquire"
  expect_code 0 "$(cat "$LAB/home/owner.prompt.rc")" "Claude $VERSION owner prompt"
  expect_code 1 "$(cat "$LAB/home/shared-pid.rc")" "Claude $VERSION shared-pid refusal"
  expect_code 1 "$(cat "$LAB/home/contender.lock.rc")" "Claude $VERSION competing acquire"
  expect_code 2 "$(cat "$LAB/home/contender.prompt.rc")" "Claude $VERSION competing prompt"
  wait_identity_file "$LAB/home/move-chain.session"
  expect_code 1 "$(cat "$LAB/home/move-elsewhere.rc")" "Claude $VERSION move to another session"
  expect_code 1 "$(cat "$LAB/home/move-resumed.rc")" "Claude $VERSION original session spoke after move"
  expect_code 0 "$(cat "$LAB/home/move-chain.rc")" "Claude $VERSION chained move takeover"
  [ "$(cat "$LAB/home/move-chain.session")" = "$SECOND_ID" ] || fail "Claude $VERSION chained move recorded the wrong owner"
  cmp -s "$LAB/owner-session" "$LAB/home/state/.lock-session" || fail "Claude $VERSION contender changed the session id"
  [ "$(cat "$LAB/home/owner.id")" != "$(cat "$LAB/home/contender.id")" ] || fail "Claude $VERSION sessions reused an id"
  : > "$LAB/release"
  for pid in "${LIVE_PIDS[@]}"; do wait "$pid" || true; done
  LIVE_PIDS=()
  pass "Claude $VERSION: trusted hook identities preserve one owner and refuse competing prompts and shared-pid claims"
  exit 0
fi

# Focused live background-move guard. One real interactive session acquires the
# lock, the agent view's left arrow moves its conversation into a background
# session under a new id while the front-end stays alive, and the moved
# conversation's prompt must take the lock over through the real prompt hook.
# This proves the vendor surfaces the takeover depends on: the continued-in
# record Claude appends to the old transcript and the moved session's trusted
# hook identity. Only the first prompt reaches the model; the probe blocks the
# rest after recording the verdict.
if [ "${FM_CLAUDE_BACKGROUND_MOVE_LIVE_E2E:-0}" = 1 ]; then
  # Outside the repository, so no parent CLAUDE.md import dialog is raised.
  LAB=$(fm_test_tmproot fm-claude-background-move) || fail "cannot create live move lab root"
  VERSION=$(claude --version)
  # shellcheck disable=SC2329 # Invoked by the EXIT trap in this opt-in branch.
  cleanup_move() {
    local moved
    moved=$(cat "$LAB/home/moved.id" 2>/dev/null || true)
    [ -z "$moved" ] || pkill -f -- "--session-id $moved" 2>/dev/null || true
    fm_test_cleanup
  }
  trap cleanup_move EXIT
  "$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null || fail "cannot create live move lab"
  cp -R "$ROOT/bin" "$LAB/home/bin"
  : > "$LAB/home/AGENTS.md"
  git init -q "$LAB/home"
  mkdir -p "$LAB/home/.claude"
  cat > "$LAB/home/probe.sh" <<'SH'
#!/usr/bin/env bash
set -u
# The moved session is spawned by Claude's shared background daemon, whose
# environment is not this lab's, so the home is always the probe's own root.
FM_HOME=$(cd "$(dirname "$0")" && pwd -P)
export FM_HOME
payload=$(cat)
id=$(printf '%s' "$payload" | jq -r '.session_id')
case "$1" in
  start)
    printf '%s %s\n' "$(printf '%s' "$payload" | jq -r '.source')" "${CLAUDE_PID:-}" > "$FM_HOME/start-$id"
    exit 0
    ;;
  stop)
    : > "$FM_HOME/stop-$id"
    exit 0
    ;;
esac
printf '%s\n' "$payload" | "$FM_HOME/bin/fm-sessionstart-run.sh" --check-claude-lock > "$FM_HOME/prompt-$id.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/prompt-$id.rc"
if [ ! -e "$FM_HOME/owner.id" ]; then
  printf '%s\n' "$id" > "$FM_HOME/owner.id"
  exit 0
fi
printf 'Live move fixture deliberately blocks model execution.\n' >&2
exit 2
SH
  chmod +x "$LAB/home/probe.sh"
  cat > "$LAB/home/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/probe.sh start","timeout":90}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/probe.sh prompt","timeout":90}]}],"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/probe.sh stop","timeout":30}]}]}}
JSON
  # A pty driver: every step waits on a hook-written file, not on rendered
  # output, except accepting the folder-trust dialog when it is shown.
  cat > "$LAB/drive.py" <<'PY'
import fcntl, os, pty, re, select, struct, sys, termios, time
home, log = sys.argv[1], sys.argv[2]
argv = sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    # A non-TTY test runner otherwise supplies a 0x0 grid to Claude's TUI.
    # Establish the grid before exec, so Claude cannot race the parent resize.
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 120, 0, 0))
    os.chdir(home)
    os.execvp(argv[0], argv)
out = open(log, 'ab')
seen = b''
def pump(seconds):
    global seen
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            out.write(data); out.flush(); seen = (seen + data)[-200000:]
def send(text):
    # Keep escape sequences together; a separated Escape dismisses dialogs.
    os.write(fd, text.encode()); time.sleep(0.03)
def wait_for(predicate, what, seconds=120):
    end = time.time() + seconds
    while time.time() < end:
        pump(0.5)
        if predicate():
            return
    print('timeout waiting for ' + what); sys.exit(1)
def starts():
    return {n[6:]: open(os.path.join(home, n)).read().split() for n in os.listdir(home) if n.startswith('start-')}
def shown(*words):
    # The TUI positions words with cursor moves, so compare without escapes or spaces.
    flat = re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]|\s', b'', seen)
    return any(w in flat for w in words)
def first_start():
    if shown(b'Itrustthisfolder', b'Quicksafetycheck'):
        send('\x1b[B'); pump(1); send('\r'); seen_reset()
    elif shown(b'AllowexternalCLAUDE.mdfileimports'):
        send('\r'); seen_reset()
    return len(starts()) > 0
def seen_reset():
    global seen
    seen = b''
wait_for(first_start, 'the first SessionStart')
pump(3)
send('Reply with just the word OK'); pump(1); send('\r')
wait_for(lambda: os.path.exists(os.path.join(home, 'owner.id')), 'the owner prompt hook')
owner = open(os.path.join(home, 'owner.id')).read().strip()
wait_for(lambda: os.path.exists(os.path.join(home, 'stop-' + owner)), 'the owner turn to end')
pump(2)
send('\x1b[D')
def moved():
    for sid, fields in starts().items():
        if sid != owner and fields and fields[0] == 'fork':
            open(os.path.join(home, 'moved.id'), 'w').write(sid + '\n')
            return True
    return False
wait_for(moved, 'a forked background session after the left arrow')
moved_id = open(os.path.join(home, 'moved.id')).read().strip()
owner_pid = int(starts()[owner][1])
os.kill(owner_pid, 0)
pump(3)
send('\r'); pump(4)
send('Reply with just the word SECOND'); pump(1); send('\r')
wait_for(lambda: os.path.exists(os.path.join(home, 'prompt-' + moved_id + '.rc')), 'the moved prompt hook')
os.kill(owner_pid, 0)
open(os.path.join(home, 'frontend-alive'), 'w').write(str(owner_pid) + '\n')
pump(2)
send('/stop'); pump(1); send('\r'); pump(4)
send('\x03'); pump(0.5); send('\x03'); pump(3)
try:
    os.kill(pid, 15)
except OSError:
    pass
print('driven')
PY
  DRIVE_OUT=$(cd "$LAB/home" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_JOB_DIR \
    FM_HOME="$LAB/home" TERM=xterm-256color python3 "$LAB/drive.py" "$LAB/home" "$LAB/pty.log" \
    claude --model haiku --setting-sources project --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools '' 2>&1)
  [ "$DRIVE_OUT" = driven ] || fail "Claude $VERSION live move was not driven: $DRIVE_OUT"
  OWNER_ID=$(cat "$LAB/home/owner.id")
  MOVED_ID=$(cat "$LAB/home/moved.id")
  read -r _ MOVED_PID < "$LAB/home/start-$MOVED_ID"
  [ "$OWNER_ID" != "$MOVED_ID" ] || fail "Claude $VERSION moved the conversation without a new id"
  expect_code 0 "$(cat "$LAB/home/prompt-$OWNER_ID.rc")" "Claude $VERSION owner prompt"
  got=$(bash -c '. "$1/bin/fm-session-lock-lib.sh" && fm_claude_session_continued_in "$2"' _ "$LAB/home" "$OWNER_ID") \
    || fail "Claude $VERSION wrote no last-word continued-in record for the moved conversation"
  [ "$got" = "$MOVED_ID" ] || fail "Claude $VERSION recorded the move to '$got', expected $MOVED_ID"
  expect_code 0 "$(cat "$LAB/home/prompt-$MOVED_ID.rc")" \
    "Claude $VERSION moved prompt: $(cat "$LAB/home/prompt-$MOVED_ID.out")"
  [ "$(cat "$LAB/home/state/.lock")" = "$MOVED_PID" ] || fail "Claude $VERSION takeover did not anchor the moved session pid $MOVED_PID"
  [ "$(cat "$LAB/home/state/.lock-session")" = "$MOVED_ID" ] || fail "Claude $VERSION takeover did not record the moved id"
  pass "Claude $VERSION: a conversation moved to the background keeps the fleet lock through its new session id"
  exit 0
fi

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart run hook,
# Stop guard, and asyncRewake auto-arm registration.
# The only local hook records model-issued Bash calls without acquiring the
# session lock or otherwise changing lifecycle behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Runs 1-2 close actionable; run 3 closes clean so
# a misbehaving session can never loop forever.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: session start invokes it once, then the model invokes it once
# per rewake. The third total drain ends the in-flight need after two complete
# Stop-owned cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='After reading the complete session-start digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 hook-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
DRAIN_RUNS=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "$DRAIN_RUNS" = 3 ] || fail "expected one session-start drain plus two model wake drains, got $DRAIN_RUNS drains"
REWAKES=$(jq -r '
  select(.type == "user")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT" 2>/dev/null | awk '/^Stop hook feedback:/{count++} END{print count+0}')
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ -s "$HOME_DIR/state/tool-calls.log" ] \
  || fail "Claude emitted no logged Bash tool calls"
! grep -q 'fm-session-start.sh' "$HOME_DIR/state/tool-calls.log" \
  || fail "model issued a redundant session-start command: $(cat "$HOME_DIR/state/tool-calls.log")"
DIGEST_EVENTS=$(jq -c --arg heading "SESSION START - $HOME_DIR" '
  select(.type == "system" and .subtype == "hook_response" and .hook_event == "SessionStart")
  | select(.stdout | contains($heading))
' "$TRANSCRIPT" 2>/dev/null)
[ "$(printf '%s' "$DIGEST_EVENTS" | jq -s 'length')" = 1 ] \
  || fail "expected exactly one SessionStart hook_response carrying the session-start digest"
DIGEST=$(printf '%s' "$DIGEST_EVENTS" | jq -r '.stdout')
printf '%s' "$DIGEST" | grep -q '^lock acquired: harness pid [0-9][0-9]*$' \
  || fail "SessionStart hook digest lacks the stale-lock reclaim"
! printf '%s' "$DIGEST" | grep -q '^●  STARTUP TRUNCATED - ' \
  || fail "SessionStart hook digest was truncated"
printf '%s' "$DIGEST" | grep -q '^The digest above is complete for this session start\.' \
  || fail "SessionStart hook digest lacks its completion marker"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

# Live-owner negative control: a separate supported-harness process owns a
# second isolated home while another Stop hook fires from the same primary
# project. The competing hook must not replace the session lock, arm, write an
# epoch, or rewake.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
"$FAKE_CLAUDE" -c 'sleep 3; :' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" || LIVE_OWNER_RC=$?
[ "$LIVE_OWNER_RC" -eq 0 ] || fail "competing Stop hook returned $LIVE_OWNER_RC while another live session owned the home"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing Stop hook replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/arm-ran" ] || fail "competing Stop hook armed while another live session owned the home"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-autoarm-epoch" ] || fail "competing Stop hook wrote an epoch while another live session owned the home"
[ ! -s "$LAB/live-owner.out" ] && [ ! -s "$LAB/live-owner.err" ] || fail "competing Stop hook produced a rewake while another live session owned the home"
wait "$LIVE_OWNER_PID"

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary\n' "$CLAUDE_VERSION"
