import os, pathlib, subprocess, json, shlex, time, shutil, sys
ROOT=pathlib.Path.cwd()
WORK=ROOT/'.test-vault-validation/live'
EVID=pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M54CYBBMG7N780Q4RY0TVMDH')
if WORK.exists():
    for parent,dirs,files in os.walk(WORK,followlinks=False): os.chmod(parent,0o700)
    shutil.rmtree(WORK)
WORK.mkdir(parents=True,exist_ok=True)
base=os.environ.copy()
for k in list(base):
    if k.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')) or k in ('TMUX','TMUX_PANE','NO_MISTAKES_GATE','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'):
        base.pop(k,None)
base.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',FM_HERDR_LAB_STATE_DIR=str(WORK/'lab-state'))
helper=str(ROOT/'bin/fm-herdr-lab.sh')
def cmd(args,env=None,cwd=None,check=True):
    p=subprocess.run(list(map(str,args)),env=env or base,cwd=cwd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}')
    return p.stdout.strip()
session=cmd([helper,'name','vault-live'])
lab=lambda *a: cmd([helper,'run',session,*a])
resume='--remaining' in sys.argv
log=open(EVID/'live-launch-transcript.log','a' if resume else 'w',buffering=1)
def report(s):
    print(s,flush=True); log.write(s+'\n')
report('Named isolated Herdr session: '+session)
results=json.loads((EVID/'live-results.json').read_text()) if resume else []
try:
    cmd([helper,'provision',session]); report('Lab provisioned. Default-session fleet tripwire recorded.')
    bindir=WORK/'bin'; bindir.mkdir()
    wrapper=bindir/'herdr'
    wrapper.write_text('#!/usr/bin/env bash\nset -eu\nargs=("$@")\nn=${#args[@]}\nif [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = '+shlex.quote(session)+' ]; then\n args=("${args[@]:0:$((n-2))}")\nelif [ "$*" = "status --json" ]; then\n :\nelse\n echo "refusing Herdr call without exact lab session" >&2; exit 98\nfi\nexec env HOME='+shlex.quote(os.environ['HOME'])+' PATH='+shlex.quote(base['PATH'])+' '+shlex.quote(helper)+' run '+shlex.quote(session)+' "${args[@]}"\n')
    wrapper.chmod(0o755)
    def make(name):
        d=WORK/name; d.mkdir()
        home=d/'home'; cmd([ROOT/'bin/fm-lab-home.sh','create',home])
        user=d/'user'; user.mkdir(); (home/'config/herdr-presentation-spaces').write_text('off\n')
        project=d/'project'; origin=d/'origin.git'; pub=d/'publisher'
        cmd(['git','init','-q','-b','main',project]); (project/'file.txt').write_text('base\n')
        (project/'.gitignore').write_text('.setup-base\n')
        cmd(['git','-C',project,'add','.']); cmd(['git','-C',project,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','initial'])
        cmd(['git','clone','-q','--bare',project,origin]); cmd(['git','-C',project,'remote','add','origin','file://'+str(origin)])
        cmd(['git','-C',project,'fetch','-q','origin']); cmd(['git','-C',project,'remote','set-head','origin','main'])
        cmd(['git','clone','-q','file://'+str(origin),pub])
        (pub/'file.txt').write_text('advanced\n'); cmd(['git','-C',pub,'add','.']); cmd(['git','-C',pub,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','advanced']);cmd(['git','-C',pub,'push','-q','origin','main'])
        env=base.copy(); env.update(FM_HOME=str(home),HOME=str(user),TREEHOUSE_ROOT=str(d/'treehouse'),HERDR_SESSION=session,FM_SPAWN_NO_GUARD='1',PATH=str(bindir)+':'+base['PATH'])
        return dict(d=d,home=home,project=project,origin=origin,pub=pub,env=env)
    def brief(c,id,branch=None):
        a=[ROOT/'bin/fm-brief.sh',id,'project','--scout','--herdr-lab']
        if branch: a+=['--base-branch',branch]
        cmd(a,env=c['env'])
        p=c['home']/'data'/id/'brief.md'
        t=p.read_text().replace('{TASK}','Read the current commit. Do not change any files.').replace('{FIRSTMATE_SPEC}','This is an isolated worker-launch verification. Report the current commit.')
        p.write_text(t)
    def allocate(c):
        receipt=subprocess.run(['treehouse','get','--lease','--json','--no-fetch'],env=c['env'],cwd=c['project'],text=True,capture_output=True,check=True)
        r=json.loads(receipt.stdout)
        cmd(['treehouse','return','--force','--if-lease-id',r['lease_id'],r['path']],env=c['env'],cwd=c['project'])
        return pathlib.Path(r['path'])
    def spawn(c,id,expected,success=True,branch=None,reason=None,expected_notices=None):
        brief(c,id,branch)
        transcript=EVID/(id+'.log')
        counter=c['d']/'upload-pack'
        counter.write_text('#!/bin/sh\nprintf "ORIGIN_CONTACT\\n" >> '+shlex.quote(str(transcript))+'\nexec /usr/bin/git upload-pack "$@"\n');counter.chmod(0o755)
        for p in c.get('contact_repos',[c['project']]):
            if 'origin' in cmd(['git','-C',p,'remote']).splitlines():
                cmd(['git','-C',p,'config','remote.origin.uploadpack',counter])
        raw="sh -c 'printf LIVE_WORKER_HEAD=; git rev-parse HEAD; sleep 120'"
        args=[str(ROOT/'bin/fm-spawn.sh'),id,str(c['project']),raw,'--scout','--backend','herdr']
        if branch: args+=['--base-branch',branch]
        report('$ FM_HOME=<disposable> '+shlex.join(args))
        with open(transcript,'w') as f: f.write('$ '+shlex.join(args)+'\n')
        with open(transcript,'a') as f: p=subprocess.run(args,env=c['env'],stdout=f,stderr=f,timeout=100)
        out=transcript.read_text(); report(out); report('exit='+str(p.returncode))
        contacts=out.count('\nORIGIN_CONTACT\n'); notices=sum(x.startswith('notice: contacting origin') for x in out.splitlines())
        assert contacts==expected,(id,contacts,expected)
        assert notices==(contacts if expected_notices is None else expected_notices),(id,notices,contacts)
        announced=False
        for line in out.splitlines():
            if line.startswith('notice: contacting origin'): announced=True
            if line=='ORIGIN_CONTACT':
                assert announced,'origin contacted without preceding announcement'; announced=False
        meta=c['home']/'state'/(id+'.meta')
        if success:
            assert p.returncode==0 and meta.exists(),id+' launch failed'
            m=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
            wt=pathlib.Path(m['worktree']); head=cmd(['git','-C',wt,'rev-parse','HEAD'])
            target=c.get('expected_commit') or cmd(['git','-C',c['pub'],'rev-parse',branch or 'HEAD'])
            assert head==target,(head,target)
            pane=m['herdr_pane_id']
            report('Persisted worker record:\n'+meta.read_text())
            screen=''
            for attempt in range(20):
                screen=lab('pane','read',pane,'--source','recent','--lines','60')
                if 'LIVE_WORKER_HEAD='+head in screen: break
                time.sleep(.3)
            assert 'LIVE_WORKER_HEAD='+head in screen, 'real worker did not print its commit'
            with open(transcript,'a') as f: f.write('\nReal worker terminal:\n'+screen+'\n')
            report('Worker terminal:\n'+screen)
            if c.get('setup'):
                assert (wt/'.setup-base').read_text().strip()==head,'setup ran on stale refs'
                report('Setup hook commit matches launched worker: '+head)
                with open(transcript,'a') as f: f.write('Setup hook commit: '+head+'\n')
            report(f'OBSERVED {id}: contacts={contacts}; notices={notices}; HEAD={head}')
            c['last_wt']=wt
        else:
            assert p.returncode!=0 and not meta.exists(),id+' refusal failed'
            if reason: assert reason in out,(reason,out)
            report(f'OBSERVED {id}: refused; contacts={contacts}; notices={notices}; no worker record')
        results.append({'name':id,'result':'pass','live':True,'contacts':contacts,'evidence':str(transcript)})
    def setup_hook(c):
        config=pathlib.Path(c['env']['HOME'])/'.config/treehouse'
        config.mkdir(parents=True,exist_ok=True)
        (config/'config.toml').write_text('[hooks]\npost_create = ["git rev-parse HEAD > .setup-base"]\n')
        c['setup']=True
    if not resume:
        c=make('common'); setup_hook(c); spawn(c,'live-common',1)
        c=make('reused'); allocate(c); setup_hook(c); spawn(c,'live-reused',1)
        for reflogs in ('on','off'):
            c=make('moved-'+reflogs)
            if reflogs=='off':
                cmd(['git','-C',c['project'],'config','core.logAllRefUpdates','false'])
                (c['project']/'.git/logs/refs/remotes/origin/HEAD').unlink()
            cmd(['git','-C',c['pub'],'checkout','-qb','trunk'])
            (c['pub']/'trunk-only.txt').write_text('trunk only\n')
            cmd(['git','-C',c['pub'],'add','.']);cmd(['git','-C',c['pub'],'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','trunk'])
            cmd(['git','-C',c['pub'],'push','-q','origin','trunk']);cmd(['git','--git-dir='+str(c['origin']),'symbolic-ref','HEAD','refs/heads/trunk'])
            spawn(c,'live-moved-'+reflogs,1 if reflogs=='on' else 2)
        c=make('named')
        cmd(['git','-C',c['pub'],'checkout','-qb','feature/hub']);cmd(['git','-C',c['pub'],'push','-q','origin','feature/hub'])
        spawn(c,'live-named',1,branch='feature/hub')
        c=make('narrow');cmd(['git','-C',c['project'],'config','--replace-all','remote.origin.fetch','+refs/heads/main:refs/remotes/origin/main'])
        spawn(c,'live-narrow',3)
        for variant in ('default','named','narrow'):
            c=make('shared-'+variant); old=c['project']; slot=allocate(c)
            branch=None
            if variant=='named':
                branch='feature/hub';cmd(['git','-C',c['pub'],'checkout','-qb',branch]);cmd(['git','-C',c['pub'],'push','-q','origin',branch])
            other=c['d']/'another/project';cmd(['git','clone','-q','file://'+str(c['origin']),other])
            c['project']=other;c['contact_repos']=[old,other]
            if variant=='narrow':
                for repo in (old,other): cmd(['git','-C',repo,'config','--replace-all','remote.origin.fetch','+refs/heads/main:refs/remotes/origin/main'])
            spawn(c,'live-shared-'+variant,6 if variant=='narrow' else 2,branch=branch)
            assert c['last_wt']==slot,'Treehouse did not reuse the other clone slot'
        for log_state in ('normal','empty'):
            c=make('unresolved-'+log_state)
            if log_state=='empty':
                cmd(['git','-C',c['project'],'reflog','expire','--expire=all','refs/remotes/origin/HEAD'])
                assert (c['project']/'.git/logs/refs/remotes/origin/HEAD').stat().st_size==0
            cmd(['git','--git-dir='+str(c['origin']),'symbolic-ref','HEAD','refs/heads/missing-default'])
            spawn(c,'live-unresolved-'+log_state,2,False,reason="could not resolve origin's current default branch")
            if log_state=='empty':
                assert (c['project']/'.git/logs/refs/remotes/origin/HEAD').stat().st_size==0
                report('Empty own HEAD log remained empty while origin/main advanced to '+cmd(['git','-C',c['project'],'rev-parse','origin/main']))
        c=make('missing');spawn(c,'live-missing',1,False,branch='feature/missing',reason="could not fetch 'origin/feature/missing'")
    if not resume:
        c=make('unreachable');cmd(['git','-C',c['project'],'remote','set-url','origin','file://'+str(c['d']/'missing.git')])
        spawn(c,'live-unreachable',1,False,reason='could not fetch origin')
        c=make('held');slot=allocate(c);before=cmd(['git','-C',slot,'rev-parse','HEAD'])
        (c['home']/'state/held.meta').write_text('worktree='+str(slot)+'\nkind=ship\n')
        spawn(c,'live-held',0,False,reason='still recorded by task held')
        assert cmd(['git','-C',slot,'rev-parse','HEAD'])==before
    if '--final' not in sys.argv:
        c=make('dirty-hook')
        config=pathlib.Path(c['env']['HOME'])/'.config/treehouse';config.mkdir(parents=True)
        (config/'config.toml').write_text('[hooks]\npost_create = ["printf keep-my-work > uncommitted.txt"]\n')
        spawn(c,'live-dirty-hook',1,False,reason='is not clean')
        slots=list((c['d']/'treehouse/.treehouse').glob('*/1/project'))
        assert len(slots)==1
        report('The real allocator returned the refused slot to its pool and removed disposable setup output.')
    c=make('originless');cmd(['git','-C',c['project'],'remote','remove','origin'])
    c['expected_commit']=cmd(['git','-C',c['project'],'rev-parse','HEAD'])
    spawn(c,'live-originless',0)

finally:
    try:
        report('Cleanup: '+cmd([helper,'teardown',session])); report('Lab removed. Default-session fleet tripwire unchanged.')
    except Exception as e:
        report('CLEANUP ERROR: '+str(e)); raise
    finally:
        (EVID/'live-results.json').write_text(json.dumps(results,indent=2)+'\n'); log.close()
