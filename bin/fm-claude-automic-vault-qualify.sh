#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-claude-automic-vault-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-claude-automic-vault-lib.sh"

[ "$#" -eq 1 ] || {
  printf 'usage: %s /absolute/path/to/supported/canonical/claude-executable\n' "${0##*/}" >&2
  exit 2
}

candidate=$1
case "$candidate" in /*) ;; *) printf 'error: candidate must be an absolute Claude Code path.\n' >&2; exit 1 ;; esac
[ ! -L "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ] || {
  printf 'error: candidate must be one executable file, not a symlink.\n' >&2
  exit 1
}
fm_claude_av_is_native_install_artifact "$candidate" || {
  printf 'error: candidate is not a supported canonical Claude Code native or Homebrew cask artifact.\n' >&2
  exit 1
}
version=$(fm_claude_av_artifact_version "$candidate") || exit 1
case "$(/usr/bin/file -b -- "$candidate" 2>/dev/null)" in
  *Mach-O*executable*|*ELF*executable*|*PE32*executable*) ;;
  *) printf 'error: candidate is not a native executable.\n' >&2; exit 1 ;;
esac
reported_version=$(/usr/bin/env -i HOME=/dev/null PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$candidate" --version 2>/dev/null) || {
  printf 'error: candidate Claude Code %s did not report its version.\n' "$version" >&2
  exit 1
}
[ "$reported_version" = "$version (Claude Code)" ] || {
  printf 'error: candidate Claude Code version report does not match its canonical path.\n' >&2
  exit 1
}
fm_claude_av_attest_native_artifact "$candidate" || exit 1

python_bin=$(command -v python3 2>/dev/null) || {
  printf 'error: python3 is required for the loopback qualification fixture.\n' >&2
  exit 1
}
root=$(mktemp -d "${TMPDIR:-/tmp}/fm-claude-av-qualify.XXXXXX") || exit 1
server_pid=
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  [ -z "$server_pid" ] || wait "$server_pid" 2>/dev/null || true
  find "$root" -depth -delete 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$root/home" "$root/config"

cat > "$root/tool" <<'SH'
#!/bin/sh
result=${0%/*}/result
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  printf 'credential-present\n' > "$result"
  exit 91
fi
printf 'scrubbed\n' > "$result"
SH
chmod 700 "$root/tool"

cat > "$root/server.py" <<'PY'
import http.server
import json
import sys

port_file, tool, count_file = sys.argv[1:]

class Handler(http.server.BaseHTTPRequestHandler):
    count = 0

    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        self.rfile.read(length)
        if "count_tokens" in self.path:
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"input_tokens":1}')
            return
        Handler.count += 1
        with open(count_file, "w", encoding="utf-8") as stream:
            stream.write(str(Handler.count))
        if Handler.count == 1:
            blocks = [
                ("message_start", {"type":"message_start","message":{"id":"msg_firstmate_qualification","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"stop_reason":None,"stop_sequence":None,"usage":{"input_tokens":1,"output_tokens":1}}}),
                ("content_block_start", {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_firstmate_qualification","name":"Bash","input":{}}}),
                ("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":json.dumps({"command":tool,"description":"Verify subprocess credential scrubbing"})}}),
                ("content_block_stop", {"type":"content_block_stop","index":0}),
                ("message_delta", {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":None},"usage":{"output_tokens":1}}),
                ("message_stop", {"type":"message_stop"}),
            ]
        else:
            blocks = [
                ("message_start", {"type":"message_start","message":{"id":"msg_firstmate_qualification_done","type":"message","role":"assistant","model":"claude-sonnet-4-5","content":[],"stop_reason":None,"stop_sequence":None,"usage":{"input_tokens":1,"output_tokens":1}}}),
                ("content_block_start", {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
                ("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"QUALIFIED"}}),
                ("content_block_stop", {"type":"content_block_stop","index":0}),
                ("message_delta", {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":None},"usage":{"output_tokens":1}}),
                ("message_stop", {"type":"message_stop"}),
            ]
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()
        for event, data in blocks:
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode())
        self.wfile.flush()

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as stream:
    stream.write(str(server.server_address[1]))
server.serve_forever()
PY

"$python_bin" "$root/server.py" "$root/port" "$root/tool" "$root/request-count" &
server_pid=$!
attempt=0
while [ ! -s "$root/port" ] && [ "$attempt" -lt 100 ]; do
  kill -0 "$server_pid" 2>/dev/null || {
    printf 'error: loopback qualification fixture exited before startup.\n' >&2
    exit 1
  }
  sleep 0.02
  attempt=$((attempt + 1))
done
[ -s "$root/port" ] || {
  printf 'error: loopback qualification fixture did not start.\n' >&2
  exit 1
}
port=$(cat "$root/port")

status=0
output=$(fm_run_timed 30 /bin/bash --noprofile --norc -p \
  "$SCRIPT_DIR/fm-claude-automic-vault-launch.sh" \
  --sanitize /usr/bin/env '' /usr/bin/env \
    HOME="$root/home" USER=firstmate LOGNAME=firstmate SHELL=/bin/sh \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin CLAUDE_CONFIG_DIR="$root/config" \
    ANTHROPIC_BASE_URL="http://127.0.0.1:$port" \
    CLAUDE_CODE_OAUTH_TOKEN=fm-qualification-placeholder-not-a-secret \
    CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    "$candidate" --settings '{"apiKeyHelper":null}' \
    --permission-mode bypassPermissions --allowedTools Bash --tools Bash --output-format json \
    --no-session-persistence -p 'Run the Bash tool exactly once as requested, then report completion.' \
  2>&1) || status=$?
if [ "$status" -ne 0 ]; then
  printf 'error: candidate Claude Code %s did not complete approval-free loopback tool qualification.\n' "$version" >&2
  exit 1
fi
[ "$(cat "$root/result" 2>/dev/null)" = scrubbed ] || {
  printf 'error: candidate Claude Code %s did not execute a credential-scrubbed tool subprocess.\n' "$version" >&2
  exit 1
}
[ "$(cat "$root/request-count" 2>/dev/null)" -ge 2 ] 2>/dev/null || {
  printf 'error: candidate Claude Code %s did not return the tool result to the loopback model fixture.\n' "$version" >&2
  exit 1
}
case "$output" in
  *fm-qualification-placeholder-not-a-secret*)
    printf 'error: candidate Claude Code %s displayed the non-secret qualification placeholder.\n' "$version" >&2
    exit 1
    ;;
esac
printf 'qualified: %s at %s matched Anthropic release attestation and executed one approval-free tool with its OAuth environment scrubbed.\n' "$reported_version" "$candidate"
