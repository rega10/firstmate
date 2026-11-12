import os, json, time, socket, subprocess, pathlib, urllib.request, signal, shutil
ROOT=pathlib.Path.cwd()
E=pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M77BS44H6JR41SKP4XGGW42N')
D=ROOT/'.test-live'/'live'
D.mkdir(parents=True,exist_ok=True)
log=(E/'live-transcript.log').open('w',buffering=1)
def note(s):
    print(s,flush=True); print(s,file=log,flush=True)
sock=socket.socket(); sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]; sock.close()
base=f'http://127.0.0.1:{port}'
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('LAVISH_AXI_'))}
env.update(FM_HOME=str(D/'home'),FM_PROCEVENT_CLAIM_ROOT=str(D/'claims'),LAVISH_AXI_STATE_DIR=str(D/'lavish'),LAVISH_AXI_HOST='127.0.0.1',LAVISH_AXI_PORT=str(port),LAVISH_AXI_NO_OPEN='1',TMPDIR=str(ROOT/'.test-live'/'tmp'))
(D/'home'/'state').mkdir(parents=True,exist_ok=True)
A=str(ROOT/'bin/fm-procevent-lavish.sh'); P=str(ROOT/'bin/fm-procevent.sh')
children=[]
def cmd(args, e=None, check=True):
    r=subprocess.run(args,env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=35)
    note('$ '+' '.join(map(str,args))+f'\nexit={r.returncode}\n'+r.stdout+(('stderr: '+r.stderr) if r.stderr else ''))
    if check and r.returncode: raise RuntimeError('command failed')
    return r

def api(path,body=None):
    req=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers={'Content-Type':'application/json','Origin':base})
    with urllib.request.urlopen(req,timeout=2) as r: return json.load(r)

def health():
    try:return api('/health')
    except Exception:return {}

def wait(fn,desc,timeout=30):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        r=fn()
        if r:return r
        time.sleep(.1)
    raise RuntimeError('timeout: '+desc)

def spawn(args,name,e=None):
    out=(E/(name+'.stdout')).open('wb'); err=(E/(name+'.stderr')).open('wb')
    p=subprocess.Popen(args,env=e or env,stdout=out,stderr=err,start_new_session=True)
    children.append((p,out,err)); return p

def new_board(name):
    f=D/(name+'.html')
    f.write_text('<!doctype html><html><head><title>Isolated retry test</title></head><body style="background:white;color:black"><h1>Isolated retry test</h1><p>Disposable review.</p></body></html>')
    cmd(['lavish-axi',str(f),'--no-open'])
    state=json.loads((D/'lavish'/'state.json').read_text())
    s=next(s for s in state['sessions'].values() if s['file']==str(f))
    ident=cmd([A,'source-id',str(f)]).stdout.strip()
    return f,s['key'],ident

def results(ident):return list((D/'home'/'state'/'procevent-inbox').glob(ident+'.*.result'))
def wakes():
    q=D/'home'/'state'/'.wake-queue'
    return q.read_text() if q.exists() else ''
def submit(key,text,end=False):
    response=api('/api/'+key+'/prompts',{'prompts':[{'uid':'','prompt':text,'selector':'','tag':'message','text':'Freeform message'}],'endSession':end})
    note('POST prompts '+key+' '+json.dumps(response)); assert response['status']=='queued'

def wait_listeners(keys):
    return wait(lambda: (h if keys.issubset({l['key'] for l in h.get('listeners',[])}) else None) if (h:=health()) else None,'listeners '+str(keys))

baseline=ROOT/'bin/.test-baseline-lavish.sh'
try:
    note('Lavish version: '+cmd(['lavish-axi','--version']).stdout.strip())
    server=spawn(['lavish-axi','server','--port',str(port),'--verbose'],'initial-server')
    wait(lambda:health().get('ok'),'isolated server')
    f,key,ident=new_board('baseline')
    baseline.write_bytes(subprocess.check_output(['git','show','a6e56cdfa1fccb6352f12ae086e286445ea55149:bin/fm-procevent-lavish.sh']))
    p=spawn(['bash',str(baseline),'poll',str(f)],'baseline')
    wait_listeners({key}); cmd(['lavish-axi','stop']); p.wait(timeout=15)
    output=(E/'baseline.stdout').read_bytes()
    assert p.returncode==1 and output==(ROOT/'tests/fixtures/lavish-poll-interrupted.txt').read_bytes()
    note('BASELINE REPRODUCED: pre-change public poll returned the three-line interruption immediately, exit 1.')
    baseline.unlink()
    # Opening restarts only this isolated server.
    boards=[new_board('board-'+str(i)) for i in range(9)]
    for f,key,ident in boards:cmd([A,'arm',str(f)])
    h=wait_listeners({key for f,key,ident in boards})
    note('Before stop: '+json.dumps(h))
    before=wakes(); cmd(['lavish-axi','stop'])
    h=wait_listeners({key for f,key,ident in boards})
    assert wakes()==before
    assert all(not results(ident) for f,key,ident in boards)
    note('QUIET RECOVERY: all 9 real listeners reconnected; zero new wake rows and zero captured results after stop.')
    note('After restart: '+json.dumps(h))
    for i,(f,key,ident) in enumerate(boards):
        submit(key,'live-feedback-'+str(i),end=(i==8))
        paths=wait(lambda:results(ident),'feedback '+ident)
        assert len(paths)==1
        text=paths[0].read_text(); assert 'live-feedback-'+str(i) in text and 'poll response was interrupted' not in text
        shutil.copyfile(paths[0],E/('feedback-'+str(i)+'.txt'))
        wait(lambda:('procevent lavish '+ident+' 1') in wakes(),'wake '+ident)
        classification=cmd([A,'classify',str(paths[0])]).stdout.strip()
        assert classification=='feedback'
        if i==8:
            assert 'session_ended: true' in text
            cmd([A,'terminal',str(paths[0])])
        cmd([P,'handled',ident,'1']);cmd([A,'retire',str(f)])
    note('FEEDBACK DELIVERY: all 9 review messages captured once and announced; final Send & End feedback retained its terminal marker.')
    # Real listener conflict is an unrelated error and must be surfaced immediately.
    f,key,ident=new_board('conflict')
    raw=spawn(['lavish-axi','poll',str(f)],'conflict-holder'); wait_listeners({key})
    t=time.monotonic();cmd([A,'arm',str(f)])
    paths=wait(lambda:results(ident),'conflict result')
    text=paths[0].read_text(); note('Unrelated error result:\n'+text)
    assert 'LISTENER_ACTIVE' in text
    wait(lambda:('procevent lavish '+ident+' 1') in wakes(),'conflict wake')
    assert time.monotonic()-t<5
    cmd([P,'handled',ident,'1']); cmd([A,'retire',str(f)])
    submit(key,'release conflict holder');raw.wait(timeout=15)
    note('UNRELATED ERROR: real LISTENER_ACTIVE conflict captured and announced without quiet retry.')
    # Stop the real server once per connected poll, 13 times, to exhaust 12 retries.
    f,key,ident=new_board('exhaustion')
    fast=env.copy();fast['FM_LAVISH_POLL_RETRY_DELAY']='1'
    cmd([A,'arm',str(f)],e=fast)
    start=time.monotonic();before=wakes()
    for n in range(13):
        wait_listeners({key})
        assert not results(ident), 'published before interruption '+str(n+1)
        cmd(['lavish-axi','stop'])
        if n<12:
            time.sleep(.1);assert wakes()==before
        note('Real server interruption '+str(n+1)+' completed')
    paths=wait(lambda:results(ident),'retry exhaustion')
    output=paths[0].read_bytes()
    assert output==(ROOT/'tests/fixtures/lavish-poll-interrupted.txt').read_bytes()
    wait(lambda:('procevent lavish '+ident+' 1') in wakes(),'exhaustion wake')
    shutil.copyfile(paths[0],E/'exhausted-result.txt')
    note('RETRY BOUND: interruption 13 published exact vendor bytes once after '+str(round(time.monotonic()-start,2))+' seconds; interruptions 1-12 stayed quiet.')
    cmd([P,'handled',ident,'1']);cmd([A,'retire',str(f)])
    queue=wakes()
    assert len({row.split('\t')[4] for row in queue.splitlines()})==11
    (E/'live-wake-queue.tsv').write_text(queue)
    note('ALL LIVE SCENARIOS PASSED')
finally:
    if baseline.exists():baseline.unlink()
    try:cmd([P,'sweep-home'],check=False)
    except Exception as ex:note('sweep cleanup: '+str(ex))
    try:cmd(['lavish-axi','stop'],check=False)
    except Exception as ex:note('server cleanup: '+str(ex))
    for p,out,err in children:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try:p.wait(timeout=8)
            except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
        out.close();err.close()
    shutil.rmtree(D)
    note('Isolated state and server cleaned up.')
