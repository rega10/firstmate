import json
import fcntl
import os
from pathlib import Path
import shutil
import select
import signal
import subprocess
import struct
import termios
import time

ROOT = Path('/Users/rega1011/.no-mistakes/worktrees/422718388d14/01M4MEAE85KY2YG676VGCXTPCN')
WORK = ROOT / '.test-codex-live'
PRODUCT = WORK / 'product'
EVIDENCE = Path('/Users/rega1011/.no-mistakes/evidence/01M4MEAE85KY2YG676VGCXTPCN')
TMUX = str(WORK / 'toolchain/local/bin/tmux')

def call(args, env=None, cwd=ROOT, check=True):
    if args[0] == TMUX:
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 120, 0, 0))
        child = subprocess.Popen(args, cwd=cwd, env=env, stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        chunks = []
        while True:
            ready, _, _ = select.select([master], [], [], 0.1)
            if not ready:
                if child.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 65536)
                if not chunk:
                    break
                chunks.append(chunk)
            except OSError:
                break
        os.close(master)
        p = subprocess.CompletedProcess(args, child.wait(), b''.join(chunks).decode(errors='replace').replace('\r\n', '\n'))
    else:
        p = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and p.returncode:
        raise RuntimeError(str(args) + '\n' + p.stdout)
    return p

def catalog(path, levels):
    path.mkdir(parents=True, exist_ok=True)
    (path / 'models_cache.json').write_text(json.dumps({'models': [
        {'slug': model, 'supported_reasoning_levels': [{'effort': level} for level in values]}
        for model, values in levels.items()
    ]}))

def remove_case(case):
    for path in case.rglob('*'):
        if not path.is_symlink() and path.is_dir():
            path.chmod(path.stat().st_mode | 0o700)
    shutil.rmtree(case)

def run(name='astra-max', model='gpt-6-astra', effort='max', setting='absent', support=True, special=None, kind='secondmate'):
    task = 'clab' + str(os.getpid()) + '-' + name
    case = WORK / name
    case.mkdir()
    primary = case / 'primary'
    mate = case / 'mate'
    user = case / 'worker-user'
    invoker = case / 'invoker-user'
    worker_codex = case / 'worker-codex'
    invoker_codex = case / 'invoker-codex'
    user.mkdir()
    invoker.mkdir()
    (case / 'tmp').mkdir()
    socket = None
    result = {'name': name}
    descendants = set()
    env = {'PATH': str(WORK / 'toolchain/local/bin') + ':' + os.environ['PATH'],
           'HOME': str(user), 'USER': os.environ.get('USER', 'rega1011'),
           'LOGNAME': os.environ.get('LOGNAME', 'rega1011'), 'SHELL': '/bin/bash',
           'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8', 'TMPDIR': str(case / 'tmp'),
           'NO_MISTAKES_GATE': 'test', 'CODEX_HOME': str(worker_codex)}
    env['GIT_CONFIG_NOSYSTEM'] = '1'
    env['GIT_CONFIG_GLOBAL'] = '/dev/null'
    try:
        for home in [primary, mate]:
            call([str(PRODUCT / 'bin/fm-lab-home.sh'), 'create', str(home)], env=env)
        socket_dir = call([str(PRODUCT / 'bin/fm-lab-home.sh'), 'tmux-dir', str(primary)], env=env).stdout.strip()
        env['TMUX_TMPDIR'] = socket_dir
        socket = str(Path(socket_dir) / 'fm-lab')
        socket_args = [TMUX, '-S', socket]
        (primary / 'config/crew-harness').write_text('codex\n')
        (primary / 'state/.last-watcher-beat').touch()
        if setting.startswith('filtered'):
            (primary / 'config/launch-env-allowlist').write_text('')
        elif setting.startswith('allowed'):
            (primary / 'config/launch-env-allowlist').write_text('CODEX_HOME\n')
        levels = {m: ['high', 'max', 'ultra'] for m in ['gpt-6-astra', 'gpt-5.6-luna', 'future-model']}
        if not support:
            levels['gpt-6-astra'] = ['high']
        catalog(worker_codex, levels)
        catalog(user / '.codex', levels)
        catalog(invoker_codex, {'gpt-6-astra': ['high'] if support else ['high', 'max']})
        if special == 'missing':
            (worker_codex / 'models_cache.json').unlink()
        elif special == 'malformed':
            (worker_codex / 'models_cache.json').write_text('not json')
        elif special == 'empty-levels':
            catalog(worker_codex, {'gpt-6-astra': []})
        if setting == 'fallback':
            env.pop('CODEX_HOME')
        elif setting == 'relative':
            env['CODEX_HOME'] = '../worker-codex'
        (mate / '.fm-secondmate-home').write_text(task + '\n')
        (mate / 'bin').mkdir()
        shutil.copyfile(PRODUCT / 'AGENTS.md', mate / 'AGENTS.md')
        (mate / 'data/charter.md').write_text('Remain idle. Do not execute any command or change any file.\n')
        (mate / '.gitignore').write_text('state/\ndata/\nconfig/\nprojects/\n')
        call(['git', 'init', '-q', '-b', 'main', str(mate)], env=env)
        if kind == 'scout':
            project = case / 'project'
            project.mkdir()
            (project / 'README.md').write_text('Disposable Codex launch verification.\n')
            call(['git', 'init', '-q', '-b', 'main', str(project)], env=env)
            call(['git', '-C', str(project), 'add', 'README.md'], env=env)
            call(['git', '-C', str(project), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Disposable fixture'], env=env)
            origin = case / 'origin.git'
            call(['git', 'clone', '--bare', '-q', str(project), str(origin)], env=env)
            call(['git', '-C', str(project), 'remote', 'add', 'origin', str(origin)], env=env)
            env['TREEHOUSE_ROOT'] = str(case / 'pool')
            task_data = primary / 'data' / task
            task_data.mkdir()
            (task_data / 'brief.md').write_text('# Task\n## Captain\'s intent\nRemain idle without changing any file.\n\n## Firstmate spec\nDo not execute any command.\n')
        call(socket_args + ['-f', '/dev/null', 'new-session', '-d', '-s', 'fm-lab-codex', '-x', '120', '-y', '36', '-c', str(mate), '/bin/bash --noprofile --norc'], env=env)
        call(socket_args + ['set-option', '-g', 'default-command', '/bin/bash --noprofile --norc'], env=env)
        call(socket_args + ['set-option', '-g', 'default-shell', '/bin/bash'], env=env)
        if setting.endswith('-local'):
            rc = case / 'worker-bashrc'
            rc.write_text('export -n HOME CODEX_HOME\nHOME=' + str(user) + '\nCODEX_HOME=' + str(worker_codex) + '\n')
            call(socket_args + ['set-option', '-t', 'fm-lab-codex', 'default-command', '/bin/bash --noprofile --rcfile ' + str(rc) + ' -i'], env=env)
        if setting == 'missing-context':
            call(socket_args + ['set-option', '-t', 'fm-lab-codex', 'default-command', '/bin/sleep 60'], env=env)
        tmux_identity = call(socket_args + ['display-message', '-p', '-t', 'fm-lab-codex', '#{socket_path},#{pid},0'], env=env).stdout.strip()
        invoke_env = dict(env, FM_HOME=str(primary), HOME=str(invoker), CODEX_HOME=str(invoker_codex), TMUX=tmux_identity)
        cmd = [str(PRODUCT / 'bin/fm-spawn.sh'), task, str(project if kind == 'scout' else mate), '--scout' if kind == 'scout' else '--secondmate']
        if setting == 'configured':
            (primary / 'config/secondmate-harness').write_text('codex ' + model + ' ' + effort + '\n')
        else:
            cmd += ['--harness', 'codex']
            if model is not None:
                cmd += ['--model', model]
            if effort is not None:
                cmd += ['--effort', effort]
        p = call(cmd, env=invoke_env, check=False)
        result.update(command=cmd, exit=p.returncode, output=p.stdout)
        result['metadata_published'] = (primary / 'state' / (task + '.meta')).exists()
        result['metadata'] = (primary / 'state' / (task + '.meta')).read_text() if result['metadata_published'] else None
        time.sleep(1)
        target = 'fm-lab-codex:fm-' + task
        pane = call(socket_args + ['capture-pane', '-p', '-t', target, '-S', '-80'], env=env, check=False)
        result['pane'] = pane.stdout
        pid = call(socket_args + ['display-message', '-p', '-t', target, '#{pane_pid}'], env=env, check=False).stdout.strip()
        records = call(['ps', '-axo', 'pid=,ppid='], env=env).stdout.splitlines()
        descendants = {int(pid)} if pid.isdigit() else set()
        for _ in range(5):
            for line in records:
                parts = line.strip().split(None, 2)
                if len(parts) == 2 and int(parts[1]) in descendants:
                    descendants.add(int(parts[0]))
        result['worker_processes'] = call(['ps', '-ww', '-p', ','.join(str(p) for p in descendants), '-o', 'pid=,ppid=,args='], env=env, check=False).stdout.splitlines() if descendants else []
        result['codex_environment'] = {}
        for process in result['worker_processes']:
            fields = process.split(None, 2)
            if len(fields) == 3 and fields[2].startswith('codex '):
                info = call(['ps', 'eww', '-p', fields[0], '-o', 'command='], env=env).stdout
                import re
                result['codex_environment'] = {key: (re.search(r'(?:^|\s)' + key + r'=([^\s]*)', info).group(1) if re.search(r'(?:^|\s)' + key + r'=([^\s]*)', info) else None) for key in ['HOME', 'CODEX_HOME']}
        return result
    finally:
        if socket:
            call([TMUX, '-S', socket, 'kill-server'], env=env, check=False)
            for pid in descendants:
                try:
                    os.kill(pid, signal.SIGCONT)
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            time.sleep(0.5)
            call([str(PRODUCT / 'bin/fm-lab-home.sh'), 'teardown', str(primary)], env=env, check=False)
        remove_case(case)
        task_tmp = Path('/tmp') / ('fm-' + task)
        if task_tmp.exists():
            remove_case(task_tmp)

if __name__ == '__main__':
    scenarios = [
        dict(name='scout-astra-max', kind='scout'),
        dict(name='astra-max'), dict(name='luna-max', model='gpt-5.6-luna'),
        dict(name='catalog-only-model', model='future-model'),
        dict(name='removed-max', support=False),
        dict(name='unsupported-high', model='future-model', effort='low'),
        dict(name='unknown-model', model='unknown-model'),
        dict(name='missing-catalog', special='missing'), dict(name='malformed-catalog', special='malformed'),
        dict(name='empty-levels', special='empty-levels'), dict(name='no-model', model=None),
        dict(name='default-model', model='default'), dict(name='ultra-refused', effort='ultra'),
        dict(name='defaults-without-catalog', model=None, effort=None, special='missing'),
        dict(name='home-fallback', setting='fallback'), dict(name='relative-codex-home', setting='relative'),
        dict(name='filtered-support', setting='filtered'), dict(name='filtered-refusal', setting='filtered', support=False),
        dict(name='allowed-support', setting='allowed'), dict(name='allowed-refusal', setting='allowed', support=False),
        dict(name='configured-secondmate', setting='configured'),
        dict(name='filtered-local-support', setting='filtered-local'),
        dict(name='allowed-local-support', setting='allowed-local'),
        dict(name='missing-context', setting='missing-context'),
    ]
    results = []
    for scenario in scenarios:
        result = run(**scenario)
        (EVIDENCE / ('live-' + scenario['name'] + '.json')).write_text(json.dumps(result, indent=2))
        processes = result['worker_processes']
        launched = any('codex --' in p or 'codex --dangerously-' in p for p in processes)
        expected_refusal = scenario['name'] in ['removed-max', 'unsupported-high', 'unknown-model', 'missing-catalog', 'malformed-catalog', 'empty-levels', 'no-model', 'default-model', 'ultra-refused', 'filtered-refusal', 'allowed-refusal', 'missing-context']
        if expected_refusal:
            passed = result['exit'] != 0 and not result['metadata_published'] and not launched and 'error:' in result['output']
        else:
            passed = result['exit'] == 0 and result['metadata_published'] and launched
            if scenario.get('effort', 'max'):
                passed = passed and any('model_reasoning_effort="' + scenario.get('effort', 'max') + '"' in p for p in processes)
            else:
                passed = passed and all('model_reasoning_effort=' not in p for p in processes)
            actual_home = result['codex_environment'].get('CODEX_HOME')
            if scenario.get('setting') in ['fallback', 'filtered', 'filtered-local']:
                passed = passed and actual_home is None
            else:
                passed = passed and actual_home == ('../worker-codex' if scenario.get('setting') == 'relative' else str(WORK / scenario['name'] / 'worker-codex'))
        result['result'] = 'pass' if passed else 'fail'
        results.append(result)
        print(scenario['name'], result['result'], 'exit=' + str(result['exit']), 'codex=' + str(launched), flush=True)
    (EVIDENCE / 'live-scenarios.json').write_text(json.dumps(results, indent=2))
    raise SystemExit(0 if all(r['result'] == 'pass' for r in results) else 1)
