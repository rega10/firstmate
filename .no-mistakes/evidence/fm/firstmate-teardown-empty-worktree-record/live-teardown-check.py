from pathlib import Path
import os, subprocess, tempfile, shutil, hashlib, json
root=Path.cwd()
evidence=Path('/Users/rega1011/.no-mistakes/evidence/01M4MVPSJMB4V9THXVW7RD8VME')
lab=Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.test-step-tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_')}
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.test-step-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Lab Tester',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab Tester',GIT_COMMITTER_EMAIL='lab@example.invalid')
transcript=[]
results=[]
def run(args,expected=None):
    r=subprocess.run([str(a) for a in args],cwd=root,env=env,capture_output=True,text=True,timeout=45)
    transcript.append('$ FM_HOME='+str(lab)+' '+ ' '.join(str(a) for a in args)+'\nexit='+str(r.returncode)+'\n'+r.stdout+r.stderr)
    if expected is not None: assert r.returncode==expected,transcript[-1]
    return r
def snapshot():
    files=[p for d in [lab/'state',lab/'data'] for p in d.rglob('*') if p.is_file()]
    files.append(lab/'wt'/'sentinel')
    return {str(p.relative_to(lab)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
def check_refusal(name,expected_text,flags=(),empty=False):
    before=snapshot()
    r=run([root/'bin/fm-teardown.sh','task-x1',*flags])
    assert r.returncode==1,transcript[-1]
    assert expected_text in r.stderr,transcript[-1]
    assert not r.stdout.strip(),transcript[-1]
    if empty:
        assert r.stderr.count('REFUSED:')==1,transcript[-1]
        assert str(meta) in r.stderr and 'retry teardown without --force' in r.stderr,transcript[-1]
    after=snapshot()
    # Existing advisory guard may add a home-local warning marker after path recovery.
    assert all(after.get(k)==v for k,v in before.items()),(before,after)
    assert not (lab/'state/task-x1.backlog-close').exists()
    results.append({'name':name,'result':'pass','exit':r.returncode,'preserved_sha256':before})
    transcript.append('OBSERVED: '+name+'; original task records, backlog row, check, and local sentinel remain byte-identical. No completion output or close marker.\n')
try:
    run([root/'bin/fm-lab-home.sh','create',lab],0)
    shutil.copyfile(root/'.tasks.toml',lab/'.tasks.toml')
    run([root/'bin/fm-tasks-axi.sh','add','task-x1','Empty local-copy cleanup lab'],0)
    run([root/'bin/fm-tasks-axi.sh','start','task-x1'],0)
    run(['git','init','-q','-b','main',lab/'project'],0)
    (lab/'project/base').write_text('base\n')
    run(['git','-C',lab/'project','add','base'],0)
    run(['git','-C',lab/'project','commit','-qm','Lab base'],0)
    run(['git','-C',lab/'project','worktree','add','-q','-b','fm/lab-task-x1',lab/'wt'],0)
    (lab/'wt/sentinel').write_text('uncommitted work must survive\n')
    meta=lab/'state/task-x1.meta'
    (lab/'state/task-x1.status').write_text('done: work ready\n')
    (lab/'state/task-x1.check.sh').write_text('# retained task check\n')
    modern='\n'.join(['endpoint_task_id=task-x1','worktree=','project='+str(lab/'project'),'harness=codex','kind=ship','mode=local-only','spawn_gen=s1.1.1','backend=tmux','window=fm-lab-empty:fm-task-x1'])+'\n'
    meta.write_text(modern)
    check_refusal('Normal cleanup refuses an empty local-copy entry','empty worktree= entry',empty=True)
    check_refusal('Forced cleanup refuses an empty local-copy entry','empty worktree= entry',('--force',),True)
    meta.write_text(modern.replace('kind=ship\n','kind=scout\n'))
    check_refusal('Forced scout cleanup cannot bypass the empty-path refusal','empty worktree= entry',('--force',),True)
    meta.write_text(modern.replace('kind=ship\n','').replace('spawn_gen=s1.1.1\n',''))
    check_refusal('Legacy cleanup cannot bypass the empty-path refusal','empty worktree= entry',('--legacy-record','--force'),True)
    meta.write_text(modern.replace('worktree=\n','worktree='+str(lab/'wt')+'\n'))
    check_refusal('Restoring the verified local-copy path exposes the dirty-work guard','uncommitted changes present')
    run(['git','-C',lab/'wt','add','sentinel'],0)
    run(['git','-C',lab/'wt','commit','-qm','Unlanded lab work'],0)
    check_refusal('Restoring the verified path and committing work retains the landed-work guard','commits not yet on main:')
    transcript.append('BACKLOG AFTER ALL REFUSALS:\n')
    run([root/'bin/fm-tasks-axi.sh','list'],0)
finally:
    shutil.rmtree(lab)
    transcript.append('CLEANUP: disposable lab home and Git repositories removed.\n')
    (evidence/'live-teardown-transcript.log').write_text('\n'.join(transcript))
    (evidence/'live-teardown-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
