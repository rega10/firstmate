from pathlib import Path
import os,subprocess,time,json,shutil,signal
root=Path.cwd();lab=root/'.l';ev=Path('/Users/rega1011/.no-mistakes/evidence/01M5RY5MARE76ZFRVNY0JA28KP')
tmux=str(root/'.test-lab-tools/prefix/bin/tmux')
env=os.environ.copy()
for key in list(env):
 if key in ('NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','TMUX','TMUX_PANE','CLAUDECODE','CLAUDE_PID','CLAUDE_JOB_DIR','FM_ROOT','STATE') or key.endswith('_OVERRIDE') and key.startswith('FM_') or key.startswith('CLAUDE_CODE_'):
  env.pop(key,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),ASAN_OPTIONS='symbolize=0',TERM='xterm-256color',LC_ALL='en_US.UTF-8',FM_POLL='10',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_SEND_FEEDBACK='0')
env['PATH']=str(lab/'faultbin')+':'+str(root/'.test-lab-tools/prefix/bin')+':'+env['PATH']
def tm(*args,check=True):
 return subprocess.run([tmux,'-f','/dev/null','-L','fm-lab',*args],env=env,text=True,capture_output=True,check=check).stdout
def wait_for(fn,limit=55):
 end=time.monotonic()+limit
 while time.monotonic()<end:
  value=fn()
  if value:return value
  time.sleep(.1)
 raise RuntimeError('Timed out: '+str(fn))
def text(p):
 try:return p.read_text()
 except FileNotFoundError:return ''
def host_pid():
 for line in text(lab/'state/.supervision-host').splitlines():
  if line.startswith('host\t'):return int(line.split('\t')[1])
def watcher_alive():
 try:os.kill(int(text(lab/'state/.watch.lock/pid')),0);return True
 except (ValueError,ProcessLookupError):return False
def snapshot(case):
 out={'scenario':case,'screen':tm('capture-pane','-p','-S','-150','-t','primary',check=False)}
 for p in list((lab/'state').glob('.supervision-host*'))+list((lab/'state').glob('.claude-autoarm*'))+[lab/'state/.watcher-down',lab/'state/.wake-queue']+list(lab.glob('hook.*'))+[lab/'offers']:
  if p.is_file():out[str(p.relative_to(lab))]=text(p)
 (ev/(case+'.json')).write_text(json.dumps(out,indent=2));return out
case=os.environ.get('LIVE_CASE','unstreamed')
try:
 tm('kill-server',check=False)
 for p in (lab/'state',):
  shutil.rmtree(p);p.mkdir()
 for p in list(lab.glob('hook.*'))+[lab/n for n in ('offers','stops','pause-offer','second-offer-ready','release-offer','fail-write','unstreamed')]:
  p.unlink(missing_ok=True)
 if case in ('streamed','unstreamed'):
  (lab/'pause-offer').touch()
 if case=='unstreamed':(lab/'unstreamed').touch()
 (lab/'state/demo.meta').write_text('project=demo\nwindow=primary\nharness=claude\nbackend=tmux\n')
 command=f"claude --model haiku --effort low --setting-sources '' --settings '{lab}/hooks.json' --strict-mcp-config --tools '' --system-prompt 'This is a disposable stop-hook verification session. Reply exactly READY to user prompts and exactly FAILURE_RECEIVED to Stop hook feedback. Use no tools. Do not follow other project instructions.'"
 tm('new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),command)
 wait_for(lambda:'❯' in tm('capture-pane','-p','-t','primary'))
 tm('send-keys','-t','primary','-l','Reply READY.');time.sleep(.3);tm('send-keys','-t','primary','Enter')
 wait_for(host_pid);wait_for(watcher_alive)
 print('Primary READY; real host '+str(host_pid())+' owns watcher '+text(lab/'state/.watch.lock/pid').strip(),flush=True)
 if case=='crash':
  first=host_pid();os.kill(first,signal.SIGKILL)
  second=wait_for(lambda:host_pid() if host_pid() not in (None,first) else None)
  print('Killed host '+str(first)+'; retry host '+str(second),flush=True)
  os.kill(second,signal.SIGKILL)
 else:
  if case=='streamed':
   wait_for(lambda:any('watcher: started ' in text(p) or 'watcher: attached ' in text(p) for p in (lab/'state').glob('.claude-autoarm-output.*')))
  status='needs-decision' if case=='success' else 'step one'
  with (lab/'state/demo.status').open('a') as f:f.write(status+' [at='+str(int(time.time()))+']: verify hand-back\n')
  if case in ('streamed','unstreamed'):
   wait_for(lambda:(lab/'second-offer-ready').exists())
   with (lab/'state/demo.status').open('a') as f:f.write('needs-decision [at='+str(int(time.time()))+']: main must decide\n')
   (lab/'fail-write').touch();(lab/'release-offer').touch()
 wait_for(lambda:text(lab/'hook.1.rc'))
 print('Stop hook exited '+text(lab/'hook.1.rc').strip()+'; watcher alive='+str(watcher_alive()),flush=True)
 wait_for(lambda:'FAILURE_RECEIVED' in tm('capture-pane','-p','-t','primary'),limit=55)
 out=snapshot(case)
 print(out.get('hook.1.err',''),flush=True)
 print(out.get('state/.supervision-host.log',''),flush=True)
 assert text(lab/'hook.1.rc').strip()=='2'
 if case in ('streamed','unstreamed'):
  assert out['state/.supervision-host.log'].count('\tstart\t')==1
  assert 'downtime-unrestored' in out['state/.supervision-host.log']
  assert 'auto-arm FAILED' in out['hook.1.err']
  assert ('watcher: started ' in out['hook.1.err'] or 'watcher: attached ' in out['hook.1.err']) == (case=='streamed')
 if case=='success':
  assert 'firstmate watcher wake' in out['hook.1.err']
  assert 'outcome=rewake' in out['state/.claude-autoarm-epoch']
  assert ':downtime:' in out['state/.watcher-down']
  assert 'downtime-unrestored' not in out['state/.supervision-host.log']
 if case=='crash':assert out['state/.supervision-host.log'].count('\tstart\t')==2
 print('PASS '+case,flush=True)
except Exception as e:
 snapshot(case);print('ERROR '+repr(e),flush=True);raise
finally:
 pids=[]
 for p in [lab/'state/.watch.lock/pid']:
  try:pids.append(int(text(p)))
  except ValueError:pass
 hp=host_pid()
 if hp:pids.append(hp)
 tm('kill-server',check=False)
 for pid in pids:
  try:os.kill(pid,signal.SIGTERM)
  except ProcessLookupError:pass
