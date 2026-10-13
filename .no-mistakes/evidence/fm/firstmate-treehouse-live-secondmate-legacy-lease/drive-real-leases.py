import os, pathlib, subprocess, json, time, shlex, traceback
W=pathlib.Path.cwd(); V=W/'.live-lease-validation'; C=V/'code'; B=V/'base-code'
E=pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M4SYPXEG1MRQH6WG24952C4W')
log=(E/'real-product-leases.log').open('w', buffering=1)
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_ENV','HERDR_SESSION','NO_MISTAKES_GATE'): env.pop(k)
env.update(HOME=str(V/'user-home'), TMPDIR=str(V/'tmp'), TREEHOUSE_ROOT=str(V/'pool'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', SHELL='/bin/bash', PATH=str(V/'tools/local/bin')+':'+env['PATH'], CODEX_HOME=str(V/'codex-home'))
for p in ('user-home','tmp','codex-home'): (V/p).mkdir(exist_ok=True)
T=str(V/'tools/local/bin/tmux'); sock='.live-lease-validation/fm-lab.sock'
results=[]
def run(args,cwd=W,expect=None,e=None):
    log.write('$ '+shlex.join(map(str,args))+'\n')
    p=subprocess.run(list(map(str,args)),cwd=cwd,env=e or env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=90)
    log.write(p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
    if expect is not None: assert p.returncode==expect, p.stdout+p.stderr
    return p

def tm(*args,expect=0): return run([T,'-S',sock,*args],expect=expect)
def brief(home,id):
    p=home/'data'/id;p.mkdir(parents=True,exist_ok=True)
    (p/'brief.md').write_text('# Task\n## Captain\'s intent\nObserve allocation and preserve existing leases.\n\n## Firstmate spec\nRun the supervised disposable process.\n')
def meta(home,id):
    p=home/'state'/f'{id}.meta'
    return dict(line.split('=',1) for line in p.read_text().splitlines() if '=' in line)
def write_meta(home,id,fields):
    (home/'state'/f'{id}.meta').write_text(''.join(k+'='+str(v)+'\n' for k,v in fields.items()))
def pool_status(): return json.loads(run(['treehouse','status','--json'],cwd=C,expect=0).stdout)
def alloc(id): return json.loads(run(['treehouse','get','--lease','--json','--lease-holder',id],cwd=C,expect=0).stdout)
def change_pool(path,**fields):
    sf=path.parent.parent/'treehouse-state.json'; obj=json.loads(sf.read_text())
    row=next(x for x in obj['worktrees'] if x['path']==str(path)); row.update(fields)
    sf.write_text(json.dumps(obj))
def check(name,fn):
    log.write('\nSCENARIO: '+name+'\n')
    try: fn(); results.append({'name':name,'result':'pass','live':True,'evidence':str(E/'real-product-leases.log'),'reason':''})
    except Exception as ex:
        log.write(traceback.format_exc()); results.append({'name':name,'result':'fail','live':True,'evidence':str(E/'real-product-leases.log'),'reason':str(ex)}); raise

try:
    tm('set-option','-g','default-shell','/bin/bash'); tm('set-option','-g','default-command','/bin/bash --noprofile --norc')
    for k in ('HOME','PATH','TMPDIR','TREEHOUSE_ROOT','CODEX_HOME'): tm('set-environment','-g',k,env[k])
    home=V/'home';run([C/'bin/fm-lab-home.sh','create',home],expect=0)
    env['FM_HOME']=str(home); env['TMUX']=tm('display-message','-p','-t','primary','#{socket_path},#{pid},#{session_id}').stdout.strip()
    (home/'config/backlog-backend').write_text('manual\n'); (home/'config/backend').write_text('tmux\n')
    tm('set-environment','-g','FM_HOME',str(home))
    legacy_id='nm-live-catalog-sm'; held_receipt=alloc(legacy_id); held=pathlib.Path(held_receipt['path'])
    for d in ('state','data','config','projects'): (held/d).mkdir(exist_ok=True)
    (held/'.fm-secondmate-home').write_text(legacy_id+'\n')
    (held/'data/charter.md').write_text('Disposable persistent secondmate.\n')
    (home/'data/secondmates.md').write_text(f'- {legacy_id} - disposable persistent secondmate (home: {held}; scope: lease validation; projects: ; added 2026-10-13)\n')
    tm('new-window','-d','-t','primary','-n','fm-'+legacy_id,'-c',held,'/bin/bash --noprofile --norc')
    fields={'window':'primary:fm-'+legacy_id,'endpoint_task_id':legacy_id,'backend':'tmux','project':str(held),'kind':'secondmate','home':str(held),'worktree':str(held),'spawn_gen':'legacy-live-validation','harness':'codex','mode':'local-only'}
    write_meta(home,legacy_id,fields); original=(home/'state'/f'{legacy_id}.meta').read_bytes()
    head=run(['git','-C',held,'rev-parse','HEAD'],expect=0).stdout
    change_pool(held,lease_id='',lease_holder=legacy_id)
    def legacy(qualified=False):
        change_pool(held,lease_id='',lease_holder=(str(home)+':'+legacy_id if qualified else legacy_id))
        rows=pool_status(); row=next(x for x in rows if x['path']==str(held)); assert row['status']=='leased' and not row.get('lease_id')
        id='nm-live-qualified' if qualified else 'nm-live-bare';brief(home,id)
        if not qualified:
            p=run([B/'bin/fm-spawn.sh',id,C,'--scout','printf baseline-worker'])
            assert p.returncode!=0 and 'legacy unleased record blocks this pool' in (p.stdout+p.stderr)
        p=run([C/'bin/fm-spawn.sh',id,C,'--scout','printf live-worker'],expect=0)
        rec=meta(home,id);assert rec['treehouse_lease_id'] and rec['worktree']!=str(held)
        assert (home/'state'/f'{legacy_id}.meta').read_bytes()==original
        assert run(['git','-C',held,'rev-parse','HEAD'],expect=0).stdout==head
        row=next(x for x in pool_status() if x['path']==str(held)); assert row['status']=='leased' and not row.get('lease_id')
        log.write('OBSERVED: fresh worker owns a different durable lease; legacy record and held checkout remain unchanged.\n')
    check('A matching bare legacy holder permits a new spawn; the baseline refuses it',legacy)
    check('A matching qualified legacy holder permits a new spawn without modifying the legacy record',lambda:legacy(True))
    def unsafe(kind):
        if kind=='other': change_pool(held,lease_id='',lease_holder='some-other-task')
        else: change_pool(held,leased=False,lease_id='',lease_holder='')
        before=pool_status();id='nm-live-refuse-'+kind;brief(home,id)
        p=run([C/'bin/fm-spawn.sh',id,C,'--scout','printf forbidden-worker'])
        assert p.returncode!=0 and 'legacy unleased record blocks this pool' in (p.stdout+p.stderr)
        assert not (home/'state'/f'{id}.meta').exists() and pool_status()==before
        assert (home/'state'/f'{legacy_id}.meta').read_bytes()==original
        log.write('OBSERVED: unsafe ownership refuses before allocation or publication.\n')
    check('A conflicting legacy holder refuses a spawn without allocating',lambda:unsafe('other'))
    check('An unleased recorded slot refuses a spawn without allocating',lambda:unsafe('unleased'))
    change_pool(held,leased=True,lease_id='',lease_holder=legacy_id)
    # Stop recording the old legacy mate before the independently seeded-home cases.
    (home/'data/secondmates.md').write_text('');(home/'state'/f'{legacy_id}.meta').unlink()
    sm_id='nm-live-seeded';sr=alloc(sm_id);sm=pathlib.Path(sr['path']);sm_fields={}
    for d in ('state','data','config','projects'): (sm/d).mkdir(exist_ok=True)
    (sm/'.fm-secondmate-home').write_text(sm_id+'\n');(sm/'data/charter.md').write_text('Disposable charter.\n');brief(home,sm_id)
    def seeded():
        p=run([C/'bin/fm-spawn.sh',sm_id,sm,'--secondmate','printf seeded-worker'],expect=0)
        rec=meta(home,sm_id); assert rec['treehouse_lease_id']==sr['lease_id'] and rec['treehouse_lease_holder']==sm_id
        assert rec['worktree']==str(sm);log.write('OBSERVED: seeded secondmate publishes the exact allocator receipt.\n')
    check('Starting a seeded secondmate records its existing lease without allocating another home',seeded)
    def recovery():
        rec=meta(home,sm_id);old_id=rec['treehouse_lease_id'];old_holder=rec['treehouse_lease_holder'];
        tm('kill-window','-t',rec['window'])
        before=pool_status()
        run([C/'bin/fm-spawn.sh',sm_id,sm,'--secondmate','printf recovered-worker'],expect=0)
        new=meta(home,sm_id);assert new['treehouse_lease_id']==old_id and new['treehouse_lease_holder']==old_holder and pool_status()==before
        log.write('OBSERVED: automatic recovery preserves the receipt and all pool allocations.\n')
    check('Recovering a stopped secondmate preserves its receipt and existing home',recovery)
    # Cleanly released ship/scout receipt, then ordinary allocation to a running process.
    def retry(kind,successor=False):
        id='nm-live-retry-'+kind+('-successor' if successor else '-released');r=alloc(id);path=pathlib.Path(r['path'])
        rec={'window':'primary:fm-'+id,'endpoint_task_id':id,'backend':'tmux','project':str(C),'kind':kind,'mode':'local-only','spawn_gen':'lease-retry-validation','worktree':'','treehouse_retiring_worktree':str(path),'treehouse_lease_id':r['lease_id'],'treehouse_lease_holder':id}
        if kind=='secondmate':
            rec['home']=str(path)
            for d in ('state','data','config','projects'): (path/d).mkdir(exist_ok=True)
            (path/'.fm-secondmate-home').write_text(id+'\n')
        write_meta(home,id,rec)
        run(['treehouse','return','--force','--if-lease-id',r['lease_id'],path],cwd=C,expect=0)
        if successor:
            # A real ordinary get blocks in its subprocess while owning an allocation without a durable identity.
            # get uses its shell selection from SHELL; the custom shell simply keeps that process alive.
            shell=V/'ordinary-allocation-shell';shell.write_text('#!/bin/sh\necho "ordinary allocation active"\nexec sleep 60\n');shell.chmod(0o755)
            e=env.copy();e['SHELL']=str(shell)
            proc=subprocess.Popen(['treehouse','get','--no-fetch'],cwd=C,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            processes.append(proc)
            time.sleep(1)
        sentinel=path/'current-allocation.txt';sentinel.write_text('preserve successor checkout\n')
        before=pool_status(); record_before=(home/'state'/f'{id}.meta').read_text()
        p=run([C/'bin/fm-teardown.sh',id,'--force'],expect=0)
        assert not (home/'state'/f'{id}.meta').exists() and sentinel.read_text()=='preserve successor checkout\n'
        assert pool_status()==before
        log.write('OBSERVED: stale receipt is removed; current checkout and allocator state are unchanged.\n')
    processes=[]
    for kind in ('ship','scout','secondmate'):check('Retrying released '+kind+' cleanup removes only the stale receipt',lambda kind=kind:retry(kind))
    # The real allocator may select any free slot; validate the chosen pending receipt against its running ordinary holder.
    def successor_retry():
        shell=V/'ordinary-allocation-shell';shell.write_text('#!/bin/sh\necho "ordinary allocation active"\nexec sleep 60\n');shell.chmod(0o755)
        e=env.copy();e['SHELL']=str(shell)
        proc=subprocess.Popen(['treehouse','get','--no-fetch'],cwd=C,env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);processes.append(proc)
        time.sleep(1);rows=pool_status();row=next(x for x in rows if x['status']=='in-use' and not x.get('lease_id'))
        path=pathlib.Path(row['path']);(path/'successor-proof.txt').write_text('ordinary successor remains\n')
        for kind in ('ship','scout','secondmate'):
            id='nm-live-ordinary-'+kind
            rec={'window':'primary:fm-'+id,'endpoint_task_id':id,'backend':'tmux','project':str(C),'kind':kind,'mode':'local-only','spawn_gen':'ordinary-successor-validation','worktree':'','treehouse_retiring_worktree':str(path),'treehouse_lease_id':'released-old-identity','treehouse_lease_holder':id}
            if kind=='secondmate':rec['home']=str(path)
            write_meta(home,id,rec);before=pool_status()
            run([C/'bin/fm-teardown.sh',id,'--force'],expect=0)
            assert not (home/'state'/f'{id}.meta').exists() and (path/'successor-proof.txt').read_text()=='ordinary successor remains\n'
            assert proc.poll() is None and pool_status()==before
        log.write('OBSERVED: ship, scout, and secondmate retries preserve the real ordinary successor process and allocation.\n')
    check('Retries finish stale-record cleanup while an ordinary allocation holds the slot without a durable identity',successor_retry)
    def mismatch():
        for kind in ('ship','scout','secondmate'):
            id='nm-live-mismatch-'+kind;r=alloc(id);path=pathlib.Path(r['path'])
            for phase in ('active','pending'):
                for pool_id in ('', 'different-identity'):
                    change_pool(path,lease_id=pool_id,lease_holder=id)
                    rec={'window':'primary:fm-'+id,'endpoint_task_id':id,'backend':'tmux','project':str(C),'kind':kind,'mode':'local-only','spawn_gen':'mismatch-validation','worktree':str(path) if phase=='active' else '', 'treehouse_lease_id':r['lease_id'],'treehouse_lease_holder':id}
                    if phase=='pending':rec['treehouse_retiring_worktree']=str(path)
                    if kind=='secondmate':rec['home']=str(path)
                    write_meta(home,id,rec);before=(home/'state'/f'{id}.meta').read_bytes();status=pool_status()
                    p=run([C/'bin/fm-teardown.sh',id,'--force']);assert p.returncode!=0 and 'Treehouse lease identity mismatch' in (p.stdout+p.stderr) and 'Repair' in (p.stdout+p.stderr)
                    assert (home/'state'/f'{id}.meta').read_bytes()==before and pool_status()==status
            change_pool(path,lease_id=r['lease_id'])
        log.write('OBSERVED: all active and pending mismatches preserve their records and pool ownership.\n')
    check('Active and pending cleanup refuse mismatched or empty identities on still-leased slots',mismatch)
finally:
    for p in globals().get('processes',[]):
        if p.poll() is None:p.terminate()
        try:p.wait(timeout=3)
        except subprocess.TimeoutExpired:p.kill();p.wait()
    run([T,'-S',sock,'kill-server'])
    (E/'real-scenario-results.json').write_text(json.dumps(results,indent=2))
    log.close()
