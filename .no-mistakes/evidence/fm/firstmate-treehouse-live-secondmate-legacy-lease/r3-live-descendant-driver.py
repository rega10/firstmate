import os, pathlib, subprocess, json, time, shlex, traceback, shutil
W=pathlib.Path.cwd(); V=W/'.a'; C=V/'code'; B=V/'base-code'; H=V/'lab'
E=pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M4SYPXEG1MRQH6WG24952C4W')
log=(E/'r3-live-descendants.log').open('w',buffering=1); results=[]; processes=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('GIT_') or k.startswith('TASKS_AXI_') or k in ('NO_MISTAKES_GATE','TMUX','HERDR_SESSION','HERDR_ENV'):env.pop(k)
for d in ('user','tmp','codex'): (V/d).mkdir(exist_ok=True)
env.update(HOME=str(V/'user'),TMPDIR=str(V/'tmp'),TREEHOUSE_ROOT=str(V/'pool'),CODEX_HOME=str(V/'codex'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',SHELL='/bin/bash',TERM='xterm-256color',PATH=str(W/'.v/tools/local/bin')+':'+env['PATH'])
T=str(W/'.v/tools/local/bin/tmux'); sock=str(V/'s')
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
    brief(id);p=run([(B if base else C)/'bin/fm-spawn.sh',id,path,*(['--secondmate'] if sm else ['--scout']),'sleep 600',*extra])
    return p

def seed(id,holder=None):
    receipt=alloc(holder or id);path=pathlib.Path(receipt['path'])
    for d in ('state','data','config','projects'):(path/d).mkdir(exist_ok=True)
    (path/'.fm-secondmate-home').write_text(id+'\n');(path/'data/charter.md').write_text('Disposable charter.\n')
    with (H/'data/secondmates.md').open('a') as f:f.write(f'- {id} - disposable secondmate (home: {path}; scope: lease validation; projects: ; added 2026-10-13)\n')
    return path,receipt

def check(name,fn):
    if os.environ.get('LIVE_SELECT') and os.environ['LIVE_SELECT'] not in name:return
    log.write('\nSCENARIO: '+name+'\n')
    try:fn();log.write('RESULT: pass\n');results.append(dict(name=name,result='pass',live=True,evidence=str(E/'r3-live-descendants.log'),reason=''))
    except Exception as ex:log.write(traceback.format_exc());results.append(dict(name=name,result='fail',live=True,evidence=str(E/'r3-live-descendants.log'),reason=str(ex)))
    (E/'r3-live-descendant-results.json').write_text(json.dumps(results,indent=2))

def pending(id,path,lid,kind='secondmate',project=None,home=H):
    fields=dict(window='primary:fm-'+id,endpoint_task_id=id,backend='tmux',project=str(project or (path if kind=='secondmate' else C)),kind=kind,mode='local-only',spawn_gen='disposable-lease-proof',harness='codex',worktree='',treehouse_retiring_worktree=str(path),treehouse_lease_id=lid,treehouse_lease_holder=id)
    if kind=='secondmate':fields['home']=str(path)
    write_meta(id,fields,home)
    if kind=='scout':
        d=home/'data'/id;d.mkdir(parents=True,exist_ok=True);(d/'report.md').write_text('Disposable scout report.\n')
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
    def descendant(successor=False):
        sp,proc=ordinary() if successor else (None,None)
        if not successor:
            r=alloc('child-old');sp=pathlib.Path(r['path']);run(['treehouse','return','--force','--if-lease-id',r['lease_id'],sp],expect=0)
        sentinel=sp/'child-successor-proof';sentinel.write_text('preserve child allocation\n')
        for kind in ('ship','scout','secondmate'):
            sid='parent-'+('ordinary-' if successor else 'released-')+kind;parent,pr=seed(sid)
            p=spawn(sid,parent,True);assert p.returncode==0,p.stdout+p.stderr
            child='child-'+kind;pending(child,sp,'released-child-id',kind,home=parent)
            before=row(sp);p=td(sid,True);assert p.returncode==0,p.stdout+p.stderr
            assert not (H/'state'/f'{sid}.meta').exists() and not (parent/'state'/f'{child}.meta').exists()
            assert row(sp)==before and sentinel.read_text()=='preserve child allocation\n'
            if proc:assert proc.poll() is None
        log.write('OBSERVED: forced parent retirement cleans pending descendant records for all kinds while preserving the released or ordinary child slot.\n')
    check('Forced secondmate retirement finishes released descendant receipts without changing their slots',descendant)
    check('Forced secondmate retirement preserves ordinary successor allocations of pending descendants',lambda:descendant(True))
    def descendant_mismatch():
        sid='parent-conflict';parent,pr=seed(sid);p=spawn(sid,parent,True);assert p.returncode==0,p.stdout+p.stderr
        r=alloc('child-owner');sp=pathlib.Path(r['path']);pending('child-conflict',sp,'different-old-id','secondmate',home=parent)
        before=status();original=(H/'state'/f'{sid}.meta').read_bytes();child=(parent/'state/child-conflict.meta').read_bytes()
        p=td(sid,True);assert p.returncode!=0 and 'Treehouse lease identity mismatch' in p.stderr,p.stdout+p.stderr
        assert status()==before and (H/'state'/f'{sid}.meta').read_bytes()==original and (parent/'state/child-conflict.meta').read_bytes()==child
        log.write('OBSERVED: conflicting descendant identity blocks forced retirement before either record or allocation changes.\n')
    check('A still-leased descendant with another identity blocks forced parent retirement',descendant_mismatch)
    def unreadable():
        sid='unreadable-removed';sp,r=seed(sid);p=spawn(sid,sp,True);assert p.returncode==0,p.stdout+p.stderr
        original=meta(sid);p=td(sid,True);assert p.returncode==0,p.stdout+p.stderr
        run(['treehouse','destroy',sp,'--yes','--include-unlanded'],expect=0)
        original['worktree']='';original['treehouse_retiring_worktree']=str(sp);write_meta(sid,original)
        sf=sp.parent.parent/'treehouse-state.json';data=sf.read_bytes();sf.write_text('{malformed')
        try:
            p=td(sid,True);assert p.returncode==0 and 'recovering from worktrees found on disk' in p.stderr,p.stdout+p.stderr
            assert not (H/'state'/f'{sid}.meta').exists() and not sp.exists()
            recovered=status();assert all(r['status']=='leased' for r in recovered)
        finally:sf.write_bytes(data)
        log.write('OBSERVED: Treehouse recovered a valid status snapshot from existing worktrees; retry removed only the absent home receipt. Remaining slots stay leased.\n')

    check('Removed-home retry uses Treehouse recovered status after pool-state corruption',unreadable)

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
