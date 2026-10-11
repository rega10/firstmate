#!/usr/bin/env bash
set -euo pipefail
EVIDENCE=/Users/rega1011/.no-mistakes/evidence/01M4N87G9S5XAGQN3JVMYEBRDM
LAB=$(mktemp -d "$PWD/.test-phase/tmp/runner-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
printf '#!/bin/sh\nprintf "Selected check executed.\\n"\n' > "$LAB/selected.test.sh"
printf '#!/bin/sh\nsleep 5\n' > "$LAB/slow.test.sh"
chmod +x "$LAB/selected.test.sh" "$LAB/slow.test.sh"
rc=0
TMPDIR="$LAB" bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 1 --json "$EVIDENCE/runner-live.json" "$LAB/selected.test.sh" "$LAB/slow.test.sh" || rc=$?
[ "$rc" != 0 ]
python3 - "$EVIDENCE/runner-live.json" <<'PY'
import sys,json
r=json.load(open(sys.argv[1]))
assert r['summary']['failed']==1,r
assert len(r['scripts'])==2,r
assert r['scripts'][0]['exit']==0,r
assert r['scripts'][1]['exit']==124,r
print('The selected check completed. The slow check timed out with exit 124. The runner returned a failed aggregate.')
PY
