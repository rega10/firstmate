import json, os, pathlib, shutil, signal, subprocess, time

root = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M5H5XD0QWYRRFK7ZSKSQQY3Y')
fixture = root / '.remote-job-live-probe'
real_git = shutil.which('git')
real_mv = shutil.which('mv')
base = '3f6512ee8be1f5fc381ecd31f4bdde11e7a4ccf2'

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)

def run_case(name, version, expected):
    case = fixture / (name + '-' + version)
    code, account, home, state, shims = [case / n for n in ['code', 'account', 'home', 'state', 'shims']]
    for directory in [code / 'bin', account / '.local/bin', home, shims]:
        directory.mkdir(parents=True)
    for name_ in ['fm-remote-job-worker.sh', 'fm-remote-job-lib.sh']:
        content = (root / 'bin' / name_).read_text()
        if version == 'base' and name_ == 'fm-remote-job-worker.sh':
            content = subprocess.check_output(['git', 'show', base + ':bin/' + name_], text=True)
        write(code / 'bin' / name_, content)
    (code / 'AGENTS.md').write_text('fixture\n')
    command_sleep = '3' if name == 'shared-budget' else '0.1'
    write(code / 'bin/fm-probe.sh', '#!/bin/bash\nprintf "started\\n" > "$1/command-started"\n/bin/sleep ' + command_sleep + '\nprintf "completed\\n" > "$1/command-finished"\nprintf "probe-output\\n"\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'FM_', 'TASKS_AXI_'))}
    env.update(HOME=str(account), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_AUTHOR_NAME='Test', GIT_AUTHOR_EMAIL='test@example.com',
               GIT_COMMITTER_NAME='Test', GIT_COMMITTER_EMAIL='test@example.com',
               FM_ROOT_OVERRIDE=str(code), FM_REMOTE_JOB_STATE_ROOT=str(state),
               FM_REMOTE_JOB_QUEUE_TIMEOUT='60', FM_REMOTE_JOB_TIMEOUT='4' if name == 'shared-budget' else '2',
               FM_REMOTE_JOB_PLATFORM_OVERRIDE='Linux', PATH=str(shims) + ':' + os.environ['PATH'])
    for args in [['init', '-q', '-b', 'main'], ['add', 'AGENTS.md', 'bin'], ['commit', '-qm', 'fixture']]:
        subprocess.run([real_git, '-C', str(code)] + args, env=env, check=True)
    stage = '. "$1/bin/fm-remote-job-lib.sh"; fm_remote_job_stage "$2" "$1" "$3" fm-probe.sh "$4" </dev/null || exit 1; printf "%s\\n" "$FM_REMOTE_JOB_ID"'
    job_id = subprocess.check_output(['bash', '-c', stage, 'stage', str(code), str(account), str(home), str(case)], env=env, text=True).splitlines()[-1]
    job = state / 'jobs' / job_id
    if name in ['tracking-completion', 'shared-budget']:
        pause = '''printf '%s\\n' "$$" > '{case}/tracking-started'
for ((i=0;i<300;i++)); do
  [ ! -f '{case}/release-tracking' ] || break
  /bin/sleep 0.05
done
[ -f '{case}/release-tracking' ] || exit 1
'''.format(case=case) if name == 'tracking-completion' else '/bin/sleep 3\n'
        write(account / '.local/bin/git', '#!/bin/bash\ncase " $* " in *" ls-files "*)\n' + pause + ';; esac\nexec ' + real_git + ' "$@"\n')
    if name == 'tracking-completion':
        write(shims / 'sleep', '''#!/bin/bash
if [ "$1" = 0.25 ] && [ -s '{case}/tracking-started' ] && [ ! -f '{case}/delayed' ]; then
  : > '{case}/delayed'
  deadline=$(cat '{job}/deadline')
  for ((i=0;i<200;i++)); do
    [ "$(date +%s)" -le "$deadline" ] || break
    /bin/sleep 0.05
  done
  [ "$(date +%s)" -gt "$deadline" ] || exit 1
  : > '{case}/release-tracking'
  group=$(cat '{case}/tracking-started')
  for ((i=0;i<200;i++)); do
    kill -0 -- "-$group" 2>/dev/null || break
    /bin/sleep 0.05
  done
  ! kill -0 -- "-$group" 2>/dev/null || exit 1
  printf 'group disappeared before monitor resumed\\n' > '{case}/group-exited'
fi
exec /bin/sleep "$@"
'''.format(case=case, job=job))
    if name == 'release-delay':
        write(shims / 'mv', '''#!/bin/bash
'{mv}' "$@" || exit $?
case "${{@:$#}}" in */.claim/armed)
  count=0
  [ ! -f '{case}/armed-count' ] || read -r count < '{case}/armed-count'
  count=$((count+1))
  printf '%s\\n' "$count" > '{case}/armed-count'
  if [ "$count" -eq 2 ]; then
    : > '{case}/delayed'
    /bin/sleep 5
    group=$(cat '{job}/.claim/group')
    for ((i=0;i<200;i++)); do
      kill -0 -- "-$group" 2>/dev/null || break
      /bin/sleep 0.05
    done
    ! kill -0 -- "-$group" 2>/dev/null || exit 1
    printf 'group disappeared before release returned\\n' > '{case}/group-exited'
  fi
;; esac
'''.format(mv=real_mv, case=case, job=job))
    started = time.monotonic()
    process = subprocess.Popen([str(code / 'bin/fm-remote-job-worker.sh'), '--lane', job_id], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        out, err = process.communicate(timeout=35)
    finally:
        if process.poll() is None:
            group_file = job / '.claim/group'
            if group_file.exists():
                try: os.killpg(int(group_file.read_text()), signal.SIGKILL)
                except ProcessLookupError: pass
            process.kill()
            process.communicate()
    result = {'scenario': name, 'version': version, 'lane_exit': process.returncode,
              'state': (job / 'state').read_text().strip(), 'exit': int((job / 'exit').read_text()),
              'command_started': (case / 'command-started').exists(),
              'command_finished': (case / 'command-finished').exists(),
              'delay_exercised': (case / 'delayed').exists(),
              'group_disappearance': (case / 'group-exited').read_text().strip() if (case / 'group-exited').exists() else None,
              'stdout': (job / 'stdout').read_text(), 'elapsed_seconds': round(time.monotonic()-started, 2), 'lane_stderr': err}
    print(json.dumps(result), flush=True)
    (evidence / (name + '-' + version + '.json')).write_text(json.dumps(result, indent=2) + '\n')
    assert result['state'] == 'done' and result['lane_exit'] == 0
    assert result['exit'] == expected, result
    if name in ['tracking-completion', 'release-delay']:
        assert result['delay_exercised'] and result['group_disappearance'], result
    if version == 'target' and name in ['tracking-completion', 'shared-budget']:
        assert not result['command_finished'], result

try:
    for name in ['tracking-completion', 'release-delay', 'shared-budget']:
        run_case(name, 'target', 124)
    for name in ['release-delay']:
        run_case(name, 'base', 0)
finally:
    shutil.rmtree(fixture, ignore_errors=True)
