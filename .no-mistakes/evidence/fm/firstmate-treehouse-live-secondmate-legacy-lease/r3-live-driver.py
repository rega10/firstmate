import os, pathlib, subprocess, json, time, shlex, traceback, shutil
W=pathlib.Path.cwd(); V=W/'.v'; C=V/'code'; B=V/'base-code'; H=V/'lab'
E=pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M4SYPXEG1MRQH6WG24952C4W')
log=(E/'r3-live-leases.log').open('w',buffering=1); results=[]; processes=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('GIT_') or k.startswith('TASKS_AXI_') or k in ('NO_MISTAKES_GATE','TMUX','HERDR_SESSION','HERDR_ENV'):env.pop(k)
for d in ('user','tmp','codex'): (V/d).mkdir(exist_ok=True)
env.update(HOME=str(V/'user'),TMPDIR=str(V/'tmp'),TREEHOUSE_ROOT=str(V/'pool'),CODEX_HOME=str(V/'codex'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',SHELL='/bin/bash',TERM='xterm-256color',PATH=str(V/'tools/local/bin')+':'+env['PATH'])
T=str(V/'tools/local/bin/tmux'); sock=str(V/'s')
def run(args,cwd=C,expect=None,e=None,timeout=120):
    log.write('$ '+shlex.join(map(str,args))+'\n')
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=e or env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=timeout)
    log.write(p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    if expect is not None:assert p.returncode==expect,p.stdout+p.stderr
    return p

def tm(*args,expect=0):return run([T,'-S',sock,*args],cwd=W,expect=expect)
def status():return [{k:v for k,v in r.items() if k!='processes'} for r in json.loads(run(['treehouse','status','--json'],expect=0).stdout)]
def alloc(id):return json.loads(run(['treehouse','get','--lease','--json','--lease-holder',id,'--no-fetch'],expect=0).stdout)
def row(path):return next(x for x in status() if x['path']==str(path))
def alter(path,**fields):
    sf=path.parent.parent/'treehouse-state.json';obj=json.loads(sf.read_text());next(x for x in obj['worktrees'] if x['path']==str(path)).update(fields);sf.write_text(json.dumps(obj))
def write_meta(id,fields,home=H):(home/'state'/f'{id}.meta').write_text(''.join(k+'='+str(v)+'\n' for k,v in fields.items()))
def meta(id,home=H):return dict(line.split('=',1) for line in (home/'state'/f'{id}.meta').read_text().splitlines() if '=' in line)
def brief(id):
    d=H/'data'/id;d.mkdir(parents=True,exist_ok=True);(d/'brief.md').write_text("# Task\n## Captain's intent\nVerify isolated lease ownership.\n## Firstmate spec\nRun a disposable supervised process.\n")
def spawn(id,path,sm=False,base=False,extra=()):
    brief(id);p=run([C/'bin/fm-spawn.sh',id,'--relaunch'] if '--relaunch' in extra else [(B if base else C)/'bin/fm-spawn.sh',id,path,*(['--secondmate'] if sm else ['--scout']),'sleep 600',*extra])
    return p

def seed(id,holder=None):
    receipt=alloc(holder or id);path=pathlib.Path(receipt['path'])
    for d in ('state','data','config','projects'):(path/d).mkdir(exist_ok=True)
    (path/'.fm-secondmate-home').write_text(id+'\n');(path/'data/charter.md').write_text('Disposable charter.\n')
    with (H/'data/secondmates.md').open('a') as f:f.write(f'- {id} - disposable secondmate (home: {path}; scope: lease validation; projects: ; added 2026-10-13)\n')
    return path,receipt

def check(name,fn):
    log.write('\nSCENARIO: '+name+'\n')
    try:fn();log.write('RESULT: pass\n');results.append(dict(name=name,result='pass',live=True,evidence=str(E/'r3-live-leases.log'),reason=''))
    except Exception as ex:log.write(traceback.format_exc());results.append(dict(name=name,result='fail',live=True,evidence=str(E/'r3-live-leases.log'),reason=str(ex)))
    (E/'r3-live-results.json').write_text(json.dumps(results,indent=2))

def pending(id,path,lid,kind='secondmate',project=None,home=H):
    fields=dict(window='primary:fm-'+id,endpoint_task_id=id,backend='tmux',project=str(project or (path if kind=='secondmate' else C)),kind=kind,mode='local-only',spawn_gen='disposable-lease-proof',harness='codex',worktree='',treehouse_retiring_worktree=str(path),treehouse_lease_id=lid,treehouse_lease_holder=id)
    if kind=='secondmate':fields['home']=str(path)
    write_meta(id,fields,home)
    if kind=='scout':
        d=home/'data'/id;d.mkdir(parents=True,exist_ok=True);(d/'report.md').write_text('Disposable scout report. No unresolved captain decisions.\n')
        e=env.copy();e['FM_HOME']=str(home);run([C/'bin/fm-captain-hold.sh','complete',id,'--none'],e=e,expect=0)
    return fields

def td(id,force=False,home=H):
    e=env.copy();e['FM_HOME']=str(home)
    return run([C/'bin/fm-teardown.sh',id,*(['--force'] if force else [])],e=e)

def ordinary():
    shell=V/'ordinary-shell';shell.write_text('#!/bin/sh\nexec sleep 600\n');shell.chmod(0o755)
    e=env.copy();e['SHELL']=str(shell)
    proc=subprocess.Popen(['treehouse','get','--no-fetch'],cwd=C,env=e,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);processes.append(proc)
    for _ in range(100):
        rows=status();r=next((r for r in rows if r['status']=='in-use' and not r.get('lease_id')),None)
        if r:return pathlib.Path(r['path']),proc
        time.sleep(.2)
    raise RuntimeError('ordinary Treehouse allocation did not become in-use')

try:
    for path,commit in ((C,'68a2e681fd20e98b8e8a261d820f3edca0e7a32d'),(B,'e6fe72eeb38a665d78ca7ccd77fa71e9b5a5073f')):
        path.mkdir(exist_ok=True)
        archive=subprocess.run(['git','archive',commit],cwd=W,stdout=subprocess.PIPE,check=True)
        subprocess.run(['tar','-x','-C',str(path)],input=archive.stdout,check=True)
        run(['git','init','-q','-b','main'],cwd=path,expect=0);run(['git','add','.'],cwd=path,expect=0)
        run(['git','-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','Disposable product snapshot'],cwd=path,expect=0)
    run([C/'bin/fm-lab-home.sh','create',H],expect=0);env['FM_HOME']=str(H)
    (H/'config/backend').write_text('tmux\n');(H/'config/backlog-backend').write_text('manual\n');(H/'config/crew-harness').write_text('codex\n')
    tm('-f','/dev/null','new-session','-d','-s','primary','-x','120','-y','40','-c',C,'/bin/bash --noprofile --norc')
    env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},#{session_id}').stdout.strip()
    log.write('The tmux session is a disposable command terminal. Workers use fm-spawn raw-launch support. No agent, allocator, or backend is mocked.\n')
    id='catalog-sm-k2';path,receipt=seed(id)
    tm('new-window','-d','-t','primary','-n','fm-'+id,'-c',path,'sleep 600')
    fields=dict(window='primary:fm-'+id,endpoint_task_id=id,backend='tmux',project=str(path),kind='secondmate',home=str(path),worktree=str(path),spawn_gen='legacy-live-proof',harness='codex',mode='local-only')
    write_meta(id,fields);original=(H/'state'/f'{id}.meta').read_bytes();alter(path,lease_id='',lease_holder=id)
    def admission(qualified=False):
        alter(path,lease_id='',lease_holder=str(H)+':'+id if qualified else id)
        assert row(path)['status']=='leased' and not row(path).get('lease_id')
        if not qualified:
            p=spawn('baseline',C,base=True);assert p.returncode!=0 and 'legacy unleased record blocks this pool' in p.stderr
        worker='new-qualified' if qualified else 'new-bare';p=spawn(worker,C);assert p.returncode==0,p.stdout+p.stderr
        assert meta(worker)['treehouse_lease_id'] and meta(worker)['worktree']!=str(path)
        assert (H/'state'/f'{id}.meta').read_bytes()==original and row(path)['status']=='leased' and not row(path).get('lease_id')
        assert tm('has-session','-t','primary:fm-'+id).returncode==0
        log.write('OBSERVED: another slot launched with a durable receipt; legacy record, legacy lease, and running endpoint remain unchanged.\n')
    check('A live legacy secondmate with a matching bare holder allows another spawn; the base commit refuses',admission)
    check('A live legacy secondmate with a matching qualified holder allows another spawn',lambda:admission(True))
    def refuse(holder=None,release=False):
        if release:run(['treehouse','return','--force',path],expect=0)
        else:alter(path,lease_holder=holder)
        before=status();p=spawn('unsafe-'+('released' if release else ('foreign' if ':' in holder else 'other')),C)
        assert p.returncode!=0 and 'legacy unleased record blocks this pool' in p.stderr
        assert status()==before and (H/'state'/f'{id}.meta').read_bytes()==original
        log.write('OBSERVED: refusal precedes allocation; the legacy record and pool ownership remain unchanged.\n')
    check('A legacy slot leased to another task refuses a new spawn',lambda:refuse('different-task'))
    check('A legacy holder qualified with another home refuses a new spawn',lambda:refuse('/wrong/home:'+id))
    check('A recorded legacy slot released in Treehouse refuses a new spawn',lambda:refuse(release=True))
    (H/'state'/f'{id}.meta').unlink();(H/'data/secondmates.md').write_text('')
    seeded={}
    def fresh(qualified=False):
        sid='seeded-qualified' if qualified else 'seeded-bare';sp,sr=seed(sid,str(H)+':'+sid if qualified else sid)
        before=status();p=spawn(sid,sp,True);assert p.returncode==0,p.stdout+p.stderr
        rec=meta(sid);assert rec['treehouse_lease_id']==sr['lease_id'] and rec['treehouse_lease_holder']==sr['lease_holder'] and status()==before
        assert 'command not found' not in p.stderr;seeded[sid]=(sp,sr)
        log.write('OBSERVED: the secondmate record contains the allocator identity and exact holder; no new slot was allocated.\n')
    check('A fresh secondmate on a bare-holder durable lease records its exact receipt',fresh)
    check('A fresh secondmate on a qualified-holder durable lease starts without shell errors',lambda:fresh(True))
    def bad_seed(legacy=False):
        sid='seeded-legacy' if legacy else 'seeded-foreign';sp,sr=seed(sid,sid if legacy else 'wrong-task')
        if legacy:alter(sp,lease_id='')
        before=status();p=spawn(sid,sp,True);assert p.returncode!=0,p.stdout+p.stderr
        assert ('empty pool lease_id' if legacy else 'not leased to this task') in p.stderr and status()==before and not (H/'state'/f'{sid}.meta').exists()
        log.write('OBSERVED: seeded-home ownership refusal preserves the live pool lease and provides the applicable repair.\n')
    check('A fresh secondmate with an empty legacy identity refuses with coordinated repair guidance',lambda:bad_seed(True))
    check('A fresh secondmate leased to another task refuses without changing its home',bad_seed)
    def recover(legacy=False,relaunch=False):
        sid='seeded-bare';sp,sr=seeded[sid];old=meta(sid)
        if legacy:
            old.pop('treehouse_lease_id');old.pop('treehouse_lease_holder');write_meta(sid,old);alter(sp,lease_id='')
        tm('kill-window','-t',old['window']);before=status();p=spawn(sid,sp,True,extra=('--relaunch',) if relaunch else ())
        assert p.returncode==0,p.stdout+p.stderr
        rec=meta(sid);assert rec.get('treehouse_lease_id','')==old.get('treehouse_lease_id','') and rec.get('treehouse_lease_holder','')==old.get('treehouse_lease_holder','') and status()==before
        log.write('OBSERVED: the existing home and receipt state survive endpoint replacement without allocator changes.\n')
    check('Automatic recovery preserves a secondmate durable receipt and home',recover)
    check('Explicit relaunch preserves a secondmate durable receipt and home',lambda:recover(relaunch=True))
    check('Automatic recovery preserves a legacy secondmate record without adding lease fields',lambda:recover(legacy=True))
    def retry_released():
        for kind in ('ship','scout','secondmate'):
            sid='released-'+kind;r=alloc(sid);sp=pathlib.Path(r['path']);pending(sid,sp,r['lease_id'],kind)
            run(['treehouse','return','--force','--if-lease-id',r['lease_id'],sp],expect=0)
            sentinel=sp/'released-proof';sentinel.write_text('keep\n');before=status();p=td(sid)
            assert p.returncode==0,p.stdout+p.stderr
            assert not (H/'state'/f'{sid}.meta').exists() and status()==before and sentinel.read_text()=='keep\n'
            sentinel.unlink()
        log.write('OBSERVED: ship, scout, and secondmate retries remove only stale records after conditional return.\n')
    check('Teardown retries after conditional release finish stale-record cleanup for every task kind',retry_released)
    def retry_ordinary():
        sp,proc=ordinary();sentinel=sp/'occupant-proof';sentinel.write_text('keep successor\n')
        for kind in ('ship','scout','secondmate'):
            sid='ordinary-'+kind;pending(sid,sp,'old-released-identity',kind);before=status();p=td(sid)
            assert p.returncode==0,p.stdout+p.stderr
            assert not (H/'state'/f'{sid}.meta').exists() and status()==before and sentinel.read_text()=='keep successor\n' and proc.poll() is None
        log.write('OBSERVED: all retries preserve the real ordinary allocation, its process, and its file.\n')
    check('Teardown retries preserve another ordinary allocation without a durable identity',retry_ordinary)
    def mismatches():
        for kind in ('ship','scout','secondmate'):
            sid='mismatch-'+kind;r=alloc(sid);sp=pathlib.Path(r['path'])
            for phase in ('active','pending'):
                for identity in ('', 'another-identity'):
                    alter(sp,lease_id=identity);f=pending(sid,sp,r['lease_id'],kind)
                    if phase=='active':f['worktree']=str(sp);f.pop('treehouse_retiring_worktree');write_meta(sid,f)
                    before=status();bytes_before=(H/'state'/f'{sid}.meta').read_bytes();p=td(sid,True)
                    assert p.returncode!=0 and 'Treehouse lease identity mismatch' in p.stderr and 'Repair' in p.stderr,p.stdout+p.stderr
                    assert status()==before and (H/'state'/f'{sid}.meta').read_bytes()==bytes_before
            (H/'state'/f'{sid}.meta').unlink();alter(sp,lease_id=r['lease_id'])
        log.write('OBSERVED: active and pending mismatches refuse, including --force and empty live lease identities.\n')
    check('Active and pending teardown refuse mismatched or empty identities on still-leased slots',mismatches)
    def removed_retry():
        sid='seeded-qualified';sp,sr=seeded[sid];orig=meta(sid);p=td(sid,True);assert p.returncode==0,p.stdout+p.stderr
        run(['treehouse','destroy',sp,'--yes','--include-unlanded'],expect=0)
        assert not sp.exists() and not any(x['path']==str(sp) for x in status()) and not (H/'state'/f'{sid}.meta').exists()
        log.write('OBSERVED: real retirement returned the lease; real Treehouse destroy removed the home and slot. Restoring its pending receipt emulates interruption before record deletion.\n')
        f=orig.copy();f['worktree']='';f['treehouse_retiring_worktree']=str(sp);write_meta(sid,f);before=status();p=td(sid)
        assert p.returncode==0,p.stdout+p.stderr
        assert not (H/'state'/f'{sid}.meta').exists() and not sp.exists() and status()==before
        log.write('OBSERVED: retry succeeds after actual home removal, cleans the stale record, and preserves pool status.\n')
    check('Teardown retry after real secondmate home removal finishes stale-record cleanup',removed_retry)
    def recreated_missing():
        sid='missing-but-recreated';sp,sr=seed(sid);p=spawn(sid,sp,True);assert p.returncode==0,p.stdout+p.stderr
        orig=meta(sid);p=td(sid,True);assert p.returncode==0,p.stdout+p.stderr
        run(['treehouse','destroy',sp,'--yes','--include-unlanded'],expect=0)
        sp.mkdir(parents=True);(sp/'foreign-file').write_text('do not delete\n');f=orig.copy();f['worktree']='';f['treehouse_retiring_worktree']=str(sp);write_meta(sid,f)
        before=status();p=td(sid,True);assert p.returncode!=0 and 'cannot read Treehouse status' in p.stderr,p.stdout+p.stderr
        assert (H/'state'/f'{sid}.meta').exists() and (sp/'foreign-file').read_text()=='do not delete\n' and status()==before
        log.write('OBSERVED: an existing foreign directory cannot be certified as a removed slot; retry refuses without deleting it.\n')
    check('An absent pool slot with a recreated directory refuses cleanup and preserves that directory',recreated_missing)
finally:
    for p in processes:
        if p.poll() is None:p.terminate()
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:p.kill();p.wait()
    try:tm('kill-server',expect=None)
    except Exception:log.write(traceback.format_exc())
    for d in (C,B,H,V/'pool',V/'user',V/'codex'):
        for root,dirs,files in os.walk(d):
            os.chmod(root,0o700)
        shutil.rmtree(d,ignore_errors=True)
    log.write('CLEANUP: disposable terminal stopped; copied product, pool, homes, and user data removed.\n');log.close()
print(json.dumps(results,indent=2))
