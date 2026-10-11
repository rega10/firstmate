import os, pathlib, subprocess, json, shlex, time, hashlib, shutil
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M4ME09EZQSXMS2XFEBXR2HBD')
LAB=ROOT/'.test-phase/live'
LAB.mkdir()
SESSION=(ROOT/'.test-phase/session').read_text().strip()
env=os.environ.copy()
env.update(FM_HERDR_LAB_STATE_DIR=str(ROOT/'.test-phase/herdr-helper'), GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
HELPER=ROOT/'bin/fm-herdr-lab.sh'
log=open(EV/'live-spawn-transcript.log','w', buffering=1)
results=[]
def run(args, check=True, cwd=ROOT, e=None):
    p=subprocess.run([str(x) for x in args], cwd=cwd, env=e or env, capture_output=True,text=True)
    if p.returncode and check:
        raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p

def lab(*args):
    return run(['bash', HELPER, 'run', SESSION, *args]).stdout

def tree(*args):
    return run(['treehouse','--root',LAB/'pool',*args],cwd=LAB/'project',e=isolated)

def assert_(v,s):
    if not v: raise AssertionError(s)

def snapshot(home, held, slot, claim):
    return {'record':(home/'state'/f'{held}.meta').read_text(), 'claim':claim.read_text() if claim.exists() else None,
      'head':run(['git','-C',slot,'rev-parse','HEAD']).stdout.strip(),
      'reflog':run(['git','-C',slot,'reflog']).stdout}

try:
    isolated=env.copy()
    userhome=LAB/'user-home'; userhome.mkdir()
    isolated.update(HOME=str(userhome),TREEHOUSE_ROOT=str(LAB/'pool'))
    client=LAB/'client'; client.mkdir()
    relay=client/'herdr'
    relay.write_text("#!/usr/bin/env bash\nset -eu\nargs=()\nwhile [ \"$#\" -gt 0 ]; do\n if [ \"$1\" = --session ]; then\n  [ \"$2\" = "+shlex.quote(SESSION)+" ] || exit 2\n  shift 2\n else args+=(\"$1\"); shift; fi\ndone\n"+
       "export HOME="+shlex.quote(env['HOME'])+"\nexport PATH="+shlex.quote(env['PATH'])+"\nexport FM_HERDR_LAB_STATE_DIR="+shlex.quote(env['FM_HERDR_LAB_STATE_DIR'])+"\n"+
       "exec bash "+shlex.quote(str(HELPER))+" run "+shlex.quote(SESSION)+" \"${args[@]}\"\n")
    relay.chmod(0o755)
    clientpath=str(client)+':'+env['PATH']
    log.write('Transparent Herdr relay routes real CLI calls through the named-lab helper while the spawn uses disposable HOME. No response stubs.\n')
    shell=LAB/'lab-shell'
    config=LAB/'herdr-config.toml'
    shell.write_text('#!/usr/bin/env bash\nexport HOME='+shlex.quote(str(userhome))+'\nexport TREEHOUSE_ROOT='+shlex.quote(str(LAB/'pool'))+'\nexport PATH='+shlex.quote(clientpath)+'\nexport HERDR_CONFIG_PATH='+shlex.quote(str(config))+'\nexec /bin/bash --noprofile --norc\n')
    shell.chmod(0o755)
    config.write_text('[terminal]\ndefault_shell = '+json.dumps(str(shell))+'\nshell_mode = "non_login"\n')
    env['HERDR_CONFIG_PATH']=str(config)
    relay.write_text(relay.read_text().replace('exec bash ', 'export HERDR_CONFIG_PATH='+shlex.quote(str(config))+'\nexec bash '))
    run(['bash',HELPER,'provision',SESSION])
    log.write('Named lab provisioned with a disposable shell configuration for every new pane.\n')
    homes={}
    for name in ['root','child','sibling','nested']:
        home=LAB/name
        run(['bash',ROOT/'bin/fm-lab-home.sh','create',home])
        (home/'config/herdr-presentation-spaces').write_text('off\n')
        homes[name]=home
    for name,parent in [('child','root'),('sibling','root'),('nested','child')]:
        (homes[name]/'.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={homes[parent]}\n')
    (homes['root']/'data/secondmates.md').write_text(''.join(f'- {n} - fixture (home: {homes[n]}; scope: test; projects: ; added 2026-10-10)\n' for n in ['child','sibling'])+'- remote - fixture (host: unavailable; root: /unavailable; home: /unavailable; scope: test; projects: ; added 2026-10-10)\n')
    (homes['child']/'data/secondmates.md').write_text(f'- nested - fixture (home: {homes["nested"]}; scope: test; projects: ; added 2026-10-10)\n')
    proj=LAB/'project'
    run(['git','init','--quiet','-b','main',proj])
    (proj/'README.md').write_text('disposable held slot project\n')
    run(['git','-C',proj,'add','README.md'])
    run(['git','-C',proj,'-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','initial'])
    p=tree('get','--lease')
    slot=pathlib.Path(p.stdout.strip())
    assert_(slot.is_relative_to(LAB),'pool escaped lab')
    log.write(f'Actual Treehouse allocation: {slot}\n{p.stderr}\n')
    log.write(tree('return',slot).stdout)
    claim=slot.parent/'.fm-slot-owner'
    alias=LAB/'slot-alias'; alias.symlink_to(slot,target_is_directory=True)
    workspace=json.loads(lab('workspace','create','--cwd',str(ROOT),'--label','held-slot-lab','--no-focus',
       '--env',f'HOME={userhome}','--env',f'ZDOTDIR={userhome}','--env',f'TREEHOUSE_ROOT={LAB/"pool"}','--env','GIT_CONFIG_GLOBAL=/dev/null','--env','GIT_CONFIG_NOSYSTEM=1','--env',f'PATH={clientpath}'))
    pane=workspace['result']['root_pane']['pane_id']
    log.write('Real launcher workspace: '+json.dumps(workspace)+'\n')
    precheck=json.loads(lab('tab','create','--workspace',workspace['result']['workspace']['workspace_id'],'--cwd',str(proj),'--label','isolation-check','--no-focus'))
    checkpane=precheck['result']['root_pane']['pane_id']
    proof=LAB/'pane-environment'
    lab('pane','run',checkpane,'printf "%s\\n%s\\n" "$HOME" "$TREEHOUSE_ROOT" > '+shlex.quote(str(proof)))
    for i in range(10):
        if proof.exists(): break
        time.sleep(1)
    assert_(proof.exists() and proof.read_text().splitlines()==[str(userhome),str(LAB/'pool')],'new-pane isolation precheck failed')
    log.write('Verified new task pane environment before spawn: '+proof.read_text()+'\n')
    lab('tab','close',precheck['result']['tab']['tab_id'])
    cases=[('same-home','root','root',False,False),('alias','root','root',True,False),
      ('parent','child','root',True,False),('child','root','child',True,False),
      ('sibling','child','sibling',True,False),('nested','root','nested',True,False),('same-id','root','child',True,True)]
    for variant,spawn,owner,usealias,sameid in cases:
        id=f'lab-held-{variant}'
        held=id if sameid else f'holder-{variant}'
        shome=homes[spawn]; ohome=homes[owner]
        brief=shome/'data'/id/'brief.md'; brief.parent.mkdir()
        brief.write_text("# Task\n## Captain's intent\nVerify a retained pool slot is refused.\n\n## Firstmate spec\nDisposable live verification.\n")
        record=ohome/'state'/f'{held}.meta'
        record.write_text(f'window={SESSION}:exited\nworktree={str(alias)+"/" if usealias else slot}\nproject={proj}\nharness=sh\nkind=ship\nmode=direct-PR\nyolo=off\nbackend=herdr\n')
        (ohome/'state'/f'{held}.status').write_text('done: awaiting review\n')
        if variant!='same-home': claim.write_text(f'task={held}\nhome={ohome}\n')
        old=snapshot(ohome,held,slot,claim)
        out=LAB/f'{id}.out'; rc=LAB/f'{id}.rc'; script=LAB/f'{id}.sh'
        witness=LAB/f'{id}.worker'
        raw='sh -c '+shlex.quote('printf worker-ran > '+shlex.quote(str(witness)))
        args=['env','-u','NO_MISTAKES_GATE','-u','FM_GATE_REFUSE_BYPASS','-u','FM_ROOT_OVERRIDE','-u','FM_STATE_OVERRIDE','-u','FM_DATA_OVERRIDE','-u','FM_CONFIG_OVERRIDE','-u','FM_PROJECTS_OVERRIDE','-u','TMUX',f'FM_HOME={shome}','FM_SPAWN_NO_GUARD=1',f'PATH={clientpath}',str(ROOT/'bin/fm-spawn.sh'),id,str(proj),raw,'--backend','herdr','--mode','direct-PR','--yolo','off']
        script.write_text('#!/usr/bin/env bash\n'+shlex.join(args)+' > '+shlex.quote(str(out))+' 2>&1\nprintf "%s\\n" "$?" > '+shlex.quote(str(rc))+'\n')
        lab('pane','run',pane,'bash '+shlex.quote(str(script)))
        for i in range(90):
            if rc.exists(): break
            time.sleep(1)
        assert_(rc.exists(),f'{variant}: spawn did not finish')
        status=int(rc.read_text()); stdout=out.read_text()
        log.write(f'\nSCENARIO {variant}\n$ {shlex.join(args)}\n{stdout}exit={status}\n')
        (EV/f'live-{variant}.log').write_text(stdout)
        assert_(status!=0,f'{variant}: held slot accepted')
        assert_('still recorded by task '+held in stdout,f'{variant}: not ownership refusal')
        assert_(snapshot(ohome,held,slot,claim)==old,f'{variant}: held copy changed')
        assert_(not (shome/'state'/f'{id}.meta').exists(),f'{variant}: metadata published')
        assert_(not witness.exists(),f'{variant}: worker launched')
        inventory=json.loads(lab('pane','list'))
        log.write('Pane inventory after refusal: '+json.dumps(inventory)+'\n')
        assert_(id not in json.dumps(inventory),f'{variant}: endpoint still present')
        log.write(f'Preserved held metadata, claim, HEAD={old["head"]}, and reflog. No new metadata or worker.\n')
        results.append({'name':variant,'result':'pass'})
        record.unlink()
        # Old owner claims alone must not prevent allocation once records retire.
    # After the final foreign-home record retires, prove the same slot launches.
    rc.unlink(); witness.unlink(missing_ok=True)
    lab('pane','run',pane,'bash '+shlex.quote(str(script)))
    for i in range(90):
        if rc.exists(): break
        time.sleep(1)
    assert_(rc.exists(),'reuse after retirement did not finish')
    stdout=out.read_text(); status=int(rc.read_text())
    log.write(f'\nSCENARIO retired-record-reuse\n{stdout}exit={status}\n')
    assert_(status==0,'reuse after retirement refused')
    for i in range(15):
        if witness.exists(): break
        time.sleep(1)
    assert_(witness.exists() and witness.read_text()=='worker-ran','supported raw shell task did not execute')
    metadata=(shome/'state'/f'{id}.meta').read_text()
    assert_('worktree='+str(slot) in metadata,'reused slot metadata incorrect')
    assert_('task='+id in claim.read_text(),'reused slot claim incorrect')
    log.write('Real shell task witness: '+witness.read_text()+'\nPublished metadata:\n'+metadata+'Slot claim:\n'+claim.read_text())
    results.append({'name':'retired-record-reuse','result':'pass'})
    (EV/'live-results.json').write_text(json.dumps(results,indent=2))
except Exception as ex:
    log.write('LIVE ERROR: '+repr(ex)+'\n')
    (EV/'live-results.json').write_text(json.dumps({'completed':results,'error':repr(ex)},indent=2))
    raise
finally:
    p=run(['bash',HELPER,'teardown',SESSION],check=False)
    log.write(f'\nGuarded teardown exit={p.returncode}\n{p.stdout}{p.stderr}\n')
    if p.returncode==0:
        log.write('Lab removed. Default-session tripwire verified by helper.\n')
        for root,dirs,files in os.walk(LAB,followlinks=False):
            os.chmod(root,0o700)
        shutil.rmtree(LAB)
    log.close()
