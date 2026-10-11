import os, pathlib, subprocess, shutil, time, uuid, json
root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M4MEHR57QJFKWDE7ACAC08MS')
lab = root / '.live-lock-validation'
assert not lab.exists()
lab.mkdir()
subprocess.run([str(root/'bin/fm-lab-home.sh'), 'create', str(lab/'home')], check=True, capture_output=True)
home = lab/'home'
shutil.copytree(root/'bin', home/'bin')
shutil.copytree(root/'docs', home/'docs')
(home/'AGENTS.md').write_text('# Disposable validation home\n')
subprocess.run(['git','init','-q',str(home)], check=True)
(home/'.claude').mkdir()
owner_id, contender_id = str(uuid.uuid4()), str(uuid.uuid4())
probe = r'''#!/usr/bin/env bash
set -u
payload=$(cat)
label=${LIVE_LABEL:?}
phase=$1
out="$LIVE_EVIDENCE/$label-$phase"
printf '%s\n' "$payload" > "$out.payload.json"
. "$FM_HOME/bin/fm-session-lock-lib.sh"
printf 'session=%s\ntrusted=%s\nclaude_pid=%s\n' "$CLAUDE_CODE_SESSION_ID" "$(fm_session_lock_trusted_session_id || true)" "$CLAUDE_PID" > "$out.identity"
run() {
  local name=$1
  shift
  "$@" <<< "$payload" > "$LIVE_EVIDENCE/$label-$name.log" 2>&1
  printf '%s\n' "$?" > "$LIVE_EVIDENCE/$label-$name.rc"
}
if [ "$phase" = start ]; then
  if [ "$label" = recovery ]; then
    run startup "$FM_HOME/bin/fm-sessionstart-run.sh" --source startup
  else
    run acquire "$FM_HOME/bin/fm-lock.sh"
  fi
  exit 0
fi
run prompt "$FM_HOME/bin/fm-sessionstart-run.sh" --check-claude-lock
case "$label" in race-*)
  : > "$FM_HOME/$label.ready"
  if [ "$(cat "$LIVE_EVIDENCE/$label-acquire.rc")" = 0 ]; then
    for ((i=0;i<600;i++)); do
      [ ! -e "$FM_HOME/race.release" ] || break
      sleep 0.1
    done
  fi
  : > "$FM_HOME/$label.done"
  printf 'Validation intentionally blocks model execution.\n' >&2
  exit 2
  ;; esac
if [ "$label" = owner ]; then
  touch "$FM_HOME/config/supervision-host"
  run mirror "$FM_HOME/bin/fm-host-mirror.sh" hook claude
  cp "$FM_HOME/state/.lock" "$FM_HOME/state/.session-start-complete"
  printf 'away mandate is unchanged\n' > "$FM_HOME/state/.afk-contract"
  printf 'pending wake is unchanged\n' > "$FM_HOME/state/.wake-queue"
  run equal-pid-other env CLAUDE_CODE_SESSION_ID="$LIVE_OTHER_ID" "$FM_HOME/bin/fm-lock.sh"
  run equal-pid-clear env CLAUDE_CODE_SESSION_ID="$LIVE_OTHER_ID" "$FM_HOME/bin/fm-sessionstart-run.sh" --source clear
  run cached-foreign-prompt env CLAUDE_CODE_SESSION_ID="$LIVE_OTHER_ID" "$FM_HOME/bin/fm-sessionstart-run.sh" --check-claude-lock
  run untrusted-pid env CLAUDE_PID=1 "$FM_HOME/bin/fm-sessionstart-run.sh" --check-claude-lock
  run missing-id env -u CLAUDE_CODE_SESSION_ID "$FM_HOME/bin/fm-sessionstart-run.sh" --check-claude-lock
  cp "$FM_HOME/state/.lock-session" "$FM_HOME/owner-identity"
  rm "$FM_HOME/state/.lock-session"
  run legacy-own "$FM_HOME/bin/fm-lock.sh"
  run legacy-prompt "$FM_HOME/bin/fm-sessionstart-run.sh" --check-claude-lock
  mv "$FM_HOME/owner-identity" "$FM_HOME/state/.lock-session"
  : > "$FM_HOME/owner.ready"
  for ((i=0;i<1200;i++)); do
    [ ! -e "$FM_HOME/release" ] || break
    sleep 0.1
  done
elif [ "$label" = contender ]; then
  run mirror "$FM_HOME/bin/fm-host-mirror.sh" hook claude
  run clear "$FM_HOME/bin/fm-sessionstart-run.sh" --source clear
  run fork "$FM_HOME/bin/fm-sessionstart-run.sh" --source fork
  run resume "$FM_HOME/bin/fm-sessionstart-run.sh" --source resume
  run nudge "$FM_HOME/bin/fm-sessionstart-nudge.sh"
  run stop "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
  run guard "$FM_HOME/bin/fm-turnend-guard.sh" --claude
elif [ "$label" = continuity ]; then
  run confirm "$FM_HOME/bin/fm-lock.sh"
  run nudge "$FM_HOME/bin/fm-sessionstart-nudge.sh"
  rm "$FM_HOME/state/.wake-queue"
  run clear "$FM_HOME/bin/fm-sessionstart-run.sh" --source clear
elif [ "$label" = recovery ]; then
  run confirm "$FM_HOME/bin/fm-lock.sh"
fi
: > "$FM_HOME/$label.done"
printf 'Validation intentionally blocks model execution.\n' >&2
exit 2
'''
(home/'probe.sh').write_text(probe)
(home/'probe.sh').chmod(0o755)
settings = {'hooks': {event: [{'hooks':[{'type':'command','command': '"$FM_HOME"/probe.sh '+phase,'timeout':150}]}] for event,phase in [('SessionStart','start'),('UserPromptSubmit','prompt')]}}
(home/'.claude/settings.json').write_text(json.dumps(settings))
env = os.environ.copy()
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','CLAUDE_CODE_SESSION_ID','CLAUDE_PID','CLAUDE_CODE_CHILD_SESSION','CLAUDE_JOB_DIR','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    env.pop(key, None)
env.update(FM_HOME=str(home), LIVE_EVIDENCE=str(evidence), LIVE_OTHER_ID=contender_id)
procs=[]
files=[]
def launch(label, sid):
    logfile=(evidence/(label+'-claude.log')).open('w'); files.append(logfile)
    childenv=env.copy(); childenv['LIVE_LABEL']=label
    p=subprocess.Popen(['claude','-p','This prompt must be blocked by the validation hook.','--session-id',sid,'--no-session-persistence','--setting-sources','project','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--system-prompt','Do not act. The validation hook blocks this prompt.','--output-format','stream-json','--verbose','--include-hook-events'],cwd=home,env=childenv,stdout=logfile,stderr=subprocess.STDOUT)
    procs.append(p); return p

def wait_file(path, timeout=100):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if path.exists(): return
        time.sleep(.1)
    raise RuntimeError('Timed out awaiting '+str(path))
def rc(label, name): return (evidence/(label+'-'+name+'.rc')).read_text().strip()
def log(label,name): return (evidence/(label+'-'+name+'.log')).read_text()
report={}
try:
    owner=launch('owner',owner_id)
    wait_file(home/'owner.ready')
    assert rc('owner','acquire')=='0' and rc('owner','prompt')=='0'
    (home/'state/task.meta').write_text('project=fixture\nwindow=fixture\nbackend=tmux\n')
    anchor=(home/'state/.lock').read_text()
    identity=(home/'state/.lock-session').read_bytes()
    mirror=(home/'state/.host-mirror.jsonl').read_bytes()
    (evidence/'owner-mirror.jsonl').write_bytes(mirror)
    away=(home/'state/.afk-contract').read_bytes()
    wake=(home/'state/.wake-queue').read_bytes()
    assert rc('owner','equal-pid-other')=='1'
    assert rc('owner','equal-pid-clear')=='0' and 'READ-ONLY SESSION' in log('owner','equal-pid-clear')
    assert 'CONTEXT RE-EMIT' not in log('owner','equal-pid-clear')
    assert rc('owner','cached-foreign-prompt')=='2' and 'READ-ONLY SESSION' in log('owner','cached-foreign-prompt')
    assert rc('owner','untrusted-pid')=='2'
    assert rc('owner','missing-id')=='2'
    assert rc('owner','legacy-own')=='1' and rc('owner','legacy-prompt')=='2'
    assert 'restart the owning Claude process' in log('owner','legacy-own')
    competitor=launch('contender',contender_id)
    wait_file(home/'contender.done'); competitor.wait(timeout=10)
    assert rc('contender','acquire')=='1' and rc('contender','prompt')=='2'
    for source in ['clear','fork','resume']:
        assert rc('contender',source)=='0' and 'READ-ONLY SESSION' in log('contender',source)
        assert 'CONTEXT RE-EMIT' not in log('contender',source)
    assert 'fm-session-start.sh' in log('contender','nudge')
    assert rc('contender','stop')=='0' and not log('contender','stop')
    assert rc('contender','guard')=='0' and 'OWNED BY ANOTHER LIVE SESSION' in log('contender','guard')
    assert (home/'state/.lock').read_text()==anchor
    assert (home/'state/.lock-session').read_bytes()==identity
    assert (home/'state/.afk-contract').read_bytes()==away
    assert (home/'state/.wake-queue').read_bytes()==wake
    assert (home/'state/.host-mirror.jsonl').read_bytes()==mirror
    (evidence/'contender-mirror-after.jsonl').write_bytes((home/'state/.host-mirror.jsonl').read_bytes())
    assert not (home/'state/.claude-autoarm-epoch').exists()
    report['mirror']={'owner_prompt_recorded':True,'contender_prompt_dropped':True}
    report['cached_startup_and_identity_boundaries']={'cached_completion_did_not_authorize_prompt':True,'same_pid_clear_refused':True,'missing_id_refused':True,'untrusted_pid_refused':True}
    report['competing_session']={'owner_anchor':anchor.strip(),'owner_id':owner_id,'contender_id':contender_id,'lock_and_away_and_wakes_unchanged':True,'no_autoarm_epoch':True}
    # The harness supplies the same conversation ID from a new real process.
    (home/'state/task.meta').unlink()
    continuity=launch('continuity',owner_id)
    wait_file(home/'continuity.done'); continuity.wait(timeout=10)
    assert rc('continuity','acquire')=='0' and rc('continuity','prompt')=='0' and rc('continuity','confirm')=='0'
    assert not log('continuity','nudge')
    assert 'SESSION START (CONTEXT RE-EMIT)' in log('continuity','clear')
    assert (home/'state/.lock').read_text()==anchor and (home/'state/.lock-session').read_bytes()==identity
    report['continuity']={'new_process_same_vendor_id':True,'live_anchor_preserved':True,'context_reemit':True}
    # Reproduce the supported upgrade record, then perform its exact restart recovery.
    (home/'state/.lock-session').unlink()
    (home/'release').touch()
    owner.wait(timeout=15)
    subprocess.run(['kill','-0',anchor.strip()],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0 or (_ for _ in ()).throw(AssertionError('owner still lives'))
    recovery=launch('recovery',str(uuid.uuid4()))
    wait_file(home/'recovery.done'); recovery.wait(timeout=10)
    assert rc('recovery','startup')=='0' and rc('recovery','prompt')=='0'
    assert 'lock acquired: harness pid' in log('recovery','startup')
    assert 'READ-ONLY SESSION' not in log('recovery','startup')
    assert 'digest above is complete' in log('recovery','startup')
    assert (home/'state/.lock-session').is_file()
    assert (home/'state/.lock').read_bytes()==(home/'state/.session-start-complete').read_bytes()
    report['legacy_upgrade']={'refused_while_owner_alive':True,'diagnostic_gives_exact_restart':True,'startup_reacquired_after_exit':True,'trusted_identity_persisted':True,'startup_completed':True}
    # Keep the winning real process alive until both simultaneous claims settle.
    (home/'state/.lock').unlink()
    (home/'state/.lock-session').unlink()
    race_ids={label:str(uuid.uuid4()) for label in ['race-a','race-b']}
    racers={label:launch(label,sid) for label,sid in race_ids.items()}
    for label in racers: wait_file(home/(label+'.ready'))
    assert sorted(rc(label,'acquire') for label in racers)==['0','1']
    winner=next(label for label in racers if rc(label,'acquire')=='0')
    loser=next(label for label in racers if rc(label,'acquire')=='1')
    assert rc(winner,'prompt')=='0' and rc(loser,'prompt')=='2'
    assert (home/'state/.lock-session').read_text().strip()==race_ids[winner]
    report['simultaneous_claims']={'winner':winner,'loser':loser,'only_one_acquired':True,'loser_prompt_blocked':True,'recorded_id':race_ids[winner]}
    (home/'race.release').touch()
    for p in racers.values(): p.wait(timeout=15)
    report['version']=subprocess.check_output(['claude','--version'],text=True).strip()
    (evidence/'live-lock-results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
finally:
    (home/'release').touch()
    (home/'race.release').touch()
    for p in procs:
        if p.poll() is None:
            p.terminate()
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait()
    for f in files: f.close()
    # No lab processes or state survive this check.
    shutil.rmtree(lab)
