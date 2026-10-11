from pathlib import Path
import tempfile,subprocess,os,shutil,hashlib
root=Path.cwd()
log=[]
base_script=root/'bin/.test-step-base-teardown.sh'
lab=Path(tempfile.mkdtemp(prefix='fm-lab.baseline.',dir=root/'.test-step-tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_')}
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.test-step-tmp'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args):
 r=subprocess.run([str(a) for a in args],env=env,cwd=root,capture_output=True,text=True,timeout=30)
 log.append('$ '+' '.join(str(a) for a in args)+'\nexit='+str(r.returncode)+'\n'+r.stdout+r.stderr)
 return r
try:
 base_script.write_bytes(subprocess.check_output(['git','show','228f3f576470ac84055217e73a6b3b21fe654ba1:bin/fm-teardown.sh']))
 assert run([root/'bin/fm-lab-home.sh','create',lab]).returncode==0
 shutil.copyfile(root/'.tasks.toml',lab/'.tasks.toml')
 assert run([root/'bin/fm-tasks-axi.sh','add','task-x1','Counterfactual cleanup lab']).returncode==0
 assert run([root/'bin/fm-tasks-axi.sh','start','task-x1']).returncode==0
 (lab/'project').mkdir()
 (lab/'local-copy').mkdir()
 (lab/'local-copy/sentinel').write_text('retained local work\n')
 meta=lab/'state/task-x1.meta'
 meta.write_text('endpoint_task_id=task-x1\nworktree=\nproject='+str(lab/'project')+'\nharness=codex\nkind=ship\nmode=local-only\nspawn_gen=s1.1.1\nbackend=tmux\nwindow=fm-lab-empty:fm-task-x1\n')
 (lab/'state/task-x1.status').write_text('done: work ready\n')
 paths=[meta,lab/'state/task-x1.status',lab/'data/backlog.md',lab/'local-copy/sentinel']
 before={str(p):p.read_bytes() for p in paths}
 for flag in [[],['--force']]:
  old=run(['bash',base_script,'task-x1',*flag])
  new=run([root/'bin/fm-teardown.sh','task-x1',*flag])
  assert old.returncode==new.returncode==1
  assert 'missing, empty, or ambiguous worktree identity' in old.stderr
  assert 'Restore the verified original worktree path in '+str(meta) in new.stderr
  assert 'retry teardown without --force' not in old.stderr
  assert 'retry teardown without --force' in new.stderr
  assert {str(p):p.read_bytes() for p in paths}==before
 log.append('OBSERVED: base refuses normal and forced cleanup with a generic identity error. Target replaces it with the exact record path and safe recovery action. Both preserve task records and local work.\n')
finally:
 base_script.unlink(missing_ok=True)
 shutil.rmtree(lab)
 log.append('CLEANUP: baseline script and disposable lab removed.\n')
 Path('/Users/rega1011/.no-mistakes/evidence/01M4MVPSJMB4V9THXVW7RD8VME/base-counterfactual.log').write_text('\n'.join(log))
print(log[-2])
