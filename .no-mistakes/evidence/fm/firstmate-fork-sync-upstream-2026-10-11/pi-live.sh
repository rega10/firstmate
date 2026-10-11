#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4N87G9S5XAGQN3JVMYEBRDM
LAB=$(mktemp -d "$ROOT/.test-phase/tmp/pi-live.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-phase/herdr" TMPDIR="$LAB"
SESSION=$(bin/fm-herdr-lab.sh name pi-render)
cleanup() {
  local rc=$?
  trap - EXIT
  bin/fm-herdr-lab.sh teardown "$SESSION" || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$SESSION"
HOME_DIR=$(bin/fm-lab-home.sh create "$LAB/home")
mkdir -p "$LAB/pi-config"
printf '%s\n' '{"hideThinkingBlock":true}' > "$LAB/pi-config/settings.json"
printf 'on\n' > "$HOME_DIR/config/calm"
python3 - "$LAB/session.jsonl" "$LAB" <<'PY'
import sys,json,datetime,uuid
p,cwd=sys.argv[1:]
now=datetime.datetime.now(datetime.timezone.utc).isoformat()
rows=[dict(type='session',version=3,id=str(uuid.uuid4()),cwd=cwd,timestamp=now)]
parent=None
msgs=[dict(role='user',content=[dict(type='text',text='Explain the disposable rendering check.')],timestamp=1),dict(role='assistant',content=[dict(type='thinking',thinking='Internal rendering detail'),dict(type='toolCall',id='call-check',name='bash',arguments={'command':'printf "example"'})],api='anthropic-messages',provider='anthropic',model='claude-sonnet-4-5',usage=dict(input=2,output=1,cacheRead=0,cacheWrite=0,totalTokens=3,cost=dict(input=0,output=0,cacheRead=0,cacheWrite=0,total=0)),stopReason='toolUse',timestamp=2),dict(role='toolResult',toolCallId='call-check',toolName='bash',content=[dict(type='text',text='example')],isError=False,timestamp=3),dict(role='assistant',content=[dict(type='text',text='The disposable rendering check is complete.')],api='anthropic-messages',provider='anthropic',model='claude-sonnet-4-5',usage=dict(input=2,output=1,cacheRead=0,cacheWrite=0,totalTokens=3,cost=dict(input=0,output=0,cacheRead=0,cacheWrite=0,total=0)),stopReason='stop',timestamp=4)]
for i,m in enumerate(msgs):
    ident=f'{i+1:08x}'
    rows.append(dict(type='message',id=ident,parentId=parent,timestamp=now,message=m))
    parent=ident
with open(p,'w') as f:
    for r in rows:f.write(json.dumps(r)+'\n')
PY
PANE=$(bin/fm-herdr-lab.sh run "$SESSION" workspace create --cwd "$LAB" --label pi-render --no-focus | jq -er '.result.root_pane.pane_id')
CMD=$(printf 'env FM_HOME=%q PI_CODING_AGENT_DIR=%q PI_OFFLINE=1 PI_TELEMETRY=0 pi --approve --no-context-files --no-skills --no-prompt-templates --no-extensions -e %q --session %q' "$HOME_DIR" "$LAB/pi-config" "$ROOT/.pi/extensions/fm-calm.ts" "$LAB/session.jsonl")
bin/fm-herdr-lab.sh run "$SESSION" pane run "$PANE" "$CMD" >/dev/null
for ((i=0;i<100;i++)); do
  bin/fm-herdr-lab.sh run "$SESSION" pane read "$PANE" --source visible > "$EVIDENCE/pi-calm-on.txt"
  if grep -q 'The disposable rendering check is complete.' "$EVIDENCE/pi-calm-on.txt" && ! grep -q 'Internal rendering detail\|Thinking\.\.\.' "$EVIDENCE/pi-calm-on.txt"; then break; fi
  sleep .2
done
[ "$i" -lt 100 ]
if grep -q 'Internal rendering detail\|Thinking\.\.\.' "$EVIDENCE/pi-calm-on.txt"; then echo 'ERROR: Calm exposed reasoning'; exit 1; fi
bin/fm-herdr-lab.sh run "$SESSION" pane run "$PANE" /calm >/dev/null
for ((i=0;i<100;i++)); do
  [ "$(cat "$HOME_DIR/config/calm")" = off ] && break
  sleep .1
done
[ "$i" -lt 100 ]
bin/fm-herdr-lab.sh run "$SESSION" pane read "$PANE" --source visible --format ansi > "$EVIDENCE/pi-calm-off.ansi"
bin/fm-herdr-lab.sh run "$SESSION" pane read "$PANE" --source visible > "$EVIDENCE/pi-calm-off.txt"
grep -q 'Thinking' "$EVIDENCE/pi-calm-off.txt"
CMD=$(printf '/export %s' "$EVIDENCE/pi-session.html")
bin/fm-herdr-lab.sh run "$SESSION" pane run "$PANE" "$CMD" >/dev/null
for ((i=0;i<100;i++)); do
  [ -s "$EVIDENCE/pi-session.html" ] && break
  sleep .1
done
[ "$i" -lt 100 ]
bin/fm-herdr-lab.sh run "$SESSION" pane read "$PANE" --source recent-unwrapped > "$EVIDENCE/pi-export.txt"
printf 'Pi version: '; pi --version
printf 'Real Pi restored the disposable session, hid reasoning with Calm on, restored stock reasoning with Calm off, and exported HTML.\n'
