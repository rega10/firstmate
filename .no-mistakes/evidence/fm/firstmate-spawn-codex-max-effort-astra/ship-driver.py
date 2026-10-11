import os, json, subprocess, pathlib, shlex, time, threading, http.server, shutil
ROOT=pathlib.Path.cwd(); W=ROOT/'.no-mistakes/test-live'; PRODUCT=W/'product'; E=pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M4MEAE85KY2YG676VGCXTPCN')
BASE=os.environ.copy()
for k in list(BASE):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ['TMUX','CODEX_HOME','CLAUDE_CONFIG_DIR','NO_MISTAKES_GATE']: BASE.pop(k,None)
BASE['PATH']=str(W/'tools/bin')+':'+BASE['PATH']; BASE['GIT_CONFIG_NOSYSTEM']='1'; BASE['GIT_CONFIG_GLOBAL']='/dev/null'
BASE['NO_MISTAKES_GATE']='1'
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_GET(self):
  self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"data":[]}')
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
  requests.append({'path':self.path,'model':data.get('model'),'reasoning':data.get('reasoning')})
  response={'id':'resp_lab','object':'response','created_at':1,'status':'completed','error':None,'incomplete_details':None,'output':[{'id':'msg_lab','type':'message','status':'completed','role':'assistant','content':[{'type':'output_text','text':'OK','annotations':[]}]}],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
  self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
  for event in [{'type':'response.created','response':dict(response,status='in_progress',output=[])},{'type':'response.completed','response':response}]:
   self.wfile.write(('event: '+event['type']+'\ndata: '+json.dumps(event)+'\n\n').encode())
  self.wfile.flush()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler); threading.Thread(target=server.serve_forever,daemon=True).start()
def run(args,env=None,check=True):
 r=subprocess.run([str(x) for x in args],env=env or BASE,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
 if check and r.returncode: raise RuntimeError(str(args)+': '+r.stdout)
 return r

def catalog(directory,model,levels):
 directory.mkdir(parents=True,exist_ok=True)
 (directory/'models_cache.json').write_text(json.dumps({'client_version':'0.159.2','models':[{'slug':model,'supported_reasoning_levels':[{'effort':x,'description':x} for x in levels]}]}))

def config(directory):
 directory.mkdir(parents=True,exist_ok=True)
 (directory/'config.toml').write_text('model = "gpt-6-astra"\nmodel_reasoning_effort = "medium"\nmodel_provider = "lab"\n[features]\ndaemon_auto_start = false\n[model_providers.lab]\nname = "Disposable local endpoint"\nbase_url = "http://127.0.0.1:'+str(server.server_port)+'/v1"\nwire_api = "responses"\nrequires_openai_auth = false\nsupports_websockets = false\nrequest_max_retries = 0\n')

results=[]
def case(name, model='gpt-6-astra',effort='max',kind='supported',policy=None,worker_levels=None,home_levels=None,local=False,relative=False,pin=False,blocked=False):
 C=W/name; C.mkdir(); lab=C/'lab'; user=C/'worker-user'; parent=C/'parent-user'; dest=C/'secondmate'; worker=C/'worker-codex'; caller=C/'caller-codex'
 run([ROOT/'bin/fm-lab-home.sh','create',lab]); user.mkdir(); parent.mkdir(); dest.mkdir(); (dest/'bin').mkdir(); (dest/'data').mkdir(); (dest/'state').mkdir()
 (dest/'.fm-secondmate-home').write_text(name+'\n'); (dest/'AGENTS.md').write_text('Reply OK. Do not use tools or modify files.\n'); (dest/'data/charter.md').write_text('Reply OK. Do not use tools or modify files.\n')
 (dest/'.gitignore').write_text('state/\ndata/\nconfig/\nprojects/\n'); run(['git','-C',dest,'init','-q','-b','main'])
 run(['git','-C',dest,'add','AGENTS.md','.gitignore'])
 run(['git','-C',dest,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','Isolated project'])
 (lab/'data'/name).mkdir()
 (lab/'data'/name/'brief.md').write_text("# Task\n## Captain's intent\nReply OK without using tools or changing files.\n\n## Firstmate spec\nReply OK without using tools or changing files.\n")
 (lab/'config/crew-harness').write_text('codex\n'); (lab/'state/.last-watcher-beat').touch()
 if pin: (lab/'config/secondmate-harness').write_text('codex '+model+' '+effort+'\n')
 if policy is not None: (lab/'config/launch-env-allowlist').write_text(policy)
 for d in [worker,user/'.codex',caller]: config(d)
 catalog(caller,model,['max'] if worker_levels==['high'] or home_levels==['high'] else ['high'])
 catalog(worker,model,worker_levels or ['medium','high','max','ultra'])
 catalog(user/'.codex',model,home_levels or ['medium','high','max','ultra'])
 effective=user/'.codex' if policy=='' or kind=='fallback' else worker
 if kind=='missing': (effective/'models_cache.json').unlink()
 if kind=='malformed': (effective/'models_cache.json').write_text('not json')
 if kind=='unknown': catalog(effective,'other-model',['max'])
 if kind=='empty': catalog(effective,model,[])
 worker_value='' if kind=='fallback' else ('../worker-codex' if relative else str(worker))
 rc=C/'shell.rc'; rc.write_text('export HOME='+shlex.quote(str(user))+'\nexport CODEX_HOME='+shlex.quote(worker_value)+'\nexport HISTFILE=/dev/null\nPS1="LAB> "\n'+('export -n HOME CODEX_HOME\n' if local else ''))
 shell='exec /bin/bash --noprofile --rcfile '+shlex.quote(str(rc))+' -i'
 socketdir=run([ROOT/'bin/fm-lab-home.sh','tmux-dir',lab]).stdout.strip()
 env=BASE.copy(); env.update(HOME=str(user),CODEX_HOME=worker_value,TMUX_TMPDIR=socketdir,FM_HOME=str(lab),TREEHOUSE_ROOT=str(C/'pool'),SHELL='/bin/bash')
 tmux=lambda *a,check=True:run(['tmux','-L','fm-lab',*a],env,check)
 observed=[]; output=''; captured=''; meta=False; launch=''; result='fail'; error=''
 try:
  tmux('-f','/dev/null','new-session','-d','-s','primary','-x','140','-y','40','-c',str(ROOT),shell)
  tmux('set-option','-g','default-command',shell)
  tmux('set-option','-g','remain-on-exit','on')
  if blocked: tmux('set-option','-g','default-command','exec /bin/sleep 30')
  pane_tmux=tmux('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
  invoke=BASE.copy(); invoke.update(HOME=str(parent),CODEX_HOME=str(caller),TMUX_TMPDIR=socketdir,TMUX=pane_tmux,FM_HOME=str(lab),FM_SPAWN_NO_GUARD='1',TREEHOUSE_ROOT=str(C/'pool'),SHELL='/bin/bash')
  args=[PRODUCT/'bin/fm-spawn.sh',name,dest,'--mode','direct-PR','--yolo','off','--backend','tmux']
  if not pin:
   args+=['--harness','codex']
   if model: args+=['--model',model]
   if effort: args+=['--effort',effort]
  start=len(requests); resp=run(args,invoke,False); output=resp.stdout; meta=(lab/'state'/f'{name}.meta').exists()
  if resp.returncode==0:
   for i in range(150):
    if len(requests)>start: break
    pane=tmux('capture-pane','-p','-t','primary:fm-'+name,check=False).stdout
    if 'Trust and continue' in pane: tmux('send-keys','-t','primary:fm-'+name,'Enter')
    if 'Use existing model' in pane: tmux('send-keys','-t','primary:fm-'+name,'Down','Enter')
    time.sleep(.1)
   observed=requests[start:]
   captured=tmux('capture-pane','-p','-t','primary:fm-'+name,'-S','-200',check=False).stdout
   expected_effort=effort or 'medium'
   result='pass' if observed and observed[0]['model']==(model or 'gpt-6-astra') and observed[0]['reasoning'].get('effort')==expected_effort and meta else 'fail'
  else:
   expected=kind not in ['supported','fallback'] or blocked or (effort=='ultra') or not model or (worker_levels==['high'] and policy!='') or (home_levels==['high'] and policy=='')
   result='pass' if expected and not meta and len(requests)==start and 'error:' in output else 'fail'
   captured=tmux('capture-pane','-p','-t','primary:fm-'+name,'-S','-150',check=False).stdout
  # Persist public launch shell bytes emitted by the product, not source text.
  for p in pathlib.Path('/tmp').glob('fm-'+name+'+*/launch.*.sh'): launch=p.read_text()
  record={'name':name,'result':result,'live':True,'exit_code':resp.returncode,'task_metadata_published':meta,'received_requests':observed,'output':output,'launch':launch,'pane':captured,'effective_catalog':str(effective/'models_cache.json')}
 except Exception as ex:
  record={'name':name,'result':'fail','live':True,'error':str(ex),'output':output}
 finally:
  tmux('kill-server',check=False)
  processes=run(['ps','-axo','pid,args']).stdout
  for line in processes.splitlines():
   if str(C)+'/' in line and '--managed-daemon' in line:
    os.kill(int(line.split()[0]),15)
  time.sleep(1)
  run([ROOT/'bin/fm-lab-home.sh','teardown',lab],check=False)
  # Launch files are toolchain side effects in /tmp; remove only exact case files created in this run.
  for p in pathlib.Path('/tmp').glob('fm-'+name+'+*'): shutil.rmtree(p)
  for attempt in range(10):
   for path in C.rglob('*'):
    if path.is_dir(): path.chmod(0o700)
   try:
    shutil.rmtree(C); break
   except OSError:
    time.sleep(.5)
 results.append(record); (E/(name+'.json')).write_text(json.dumps(record,indent=2)); print(name,record['result'],record.get('exit_code'),record.get('received_requests'),record.get('error',''),flush=True)
 (E/'ship-results.json').write_text(json.dumps(results,indent=2))

case('live-ship-astra-max')
server.shutdown()
