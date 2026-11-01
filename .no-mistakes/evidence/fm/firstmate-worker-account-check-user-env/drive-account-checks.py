import os, pathlib, subprocess, json, shutil
repo = pathlib.Path.cwd()
scratch = repo / '.test-phase-tmp' / 'real-account-checks'
scratch.mkdir(parents=True, exist_ok=True)
real = {name: shutil.which(name) for name in ('claude', 'pi')}
identity = subprocess.check_output(['id', '-un'], text=True).strip()
base_path = os.environ['PATH']
failures = 0
for harness in ('claude', 'pi'):
    area = scratch / harness
    user_home, root, cfg, bindir = [area / n for n in ('home', 'root', 'config', 'bin')]
    for p in (user_home, root, cfg, bindir): p.mkdir(parents=True, exist_ok=True)
    if harness == 'claude':
        (root / 'settings.json').write_text(json.dumps({'apiKeyHelper':'echo sk-ant-fm-live-synthetic'}))
        pin = str(root) + '\n'
    else:
        (root / 'auth.json').write_text(json.dumps({'openai':{'type':'api_key','key':'sk-fm-live-synthetic'}}))
        (root / 'auth.json').chmod(0o600)
        pin = str(root) + '\nopenai\n'
    (cfg / (harness + '-account')).write_text(pin)
    wrapper = bindir / harness
    observed, answer = area / 'observed.json', area / 'answer.txt'
    wrapper.write_text('#!' + shutil.which('python3') + '\n' +
        'import os, subprocess, pathlib, json, sys\n' +
        'pathlib.Path(' + repr(str(observed)) + ').write_text(json.dumps({k:os.environ.get(k) for k in ("HOME","USER","LOGNAME","TMPDIR","CLAUDE_CONFIG_DIR","PI_CODING_AGENT_DIR","ANTHROPIC_API_KEY","CLAUDE_CODE_OAUTH_TOKEN","OPENAI_API_KEY")}))\n' +
        'p=subprocess.run([' + repr(real[harness]) + ']+sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)\n' +
        'pathlib.Path(' + repr(str(answer)) + ').write_bytes(p.stdout)\n' +
        'sys.stdout.buffer.write(p.stdout)\nsys.exit(p.returncode)\n')
    wrapper.chmod(0o755)
    for name, extra, failed_id, empty_root in [
        ('scrubbed caller', {}, False, False),
        ('incorrect caller names', {'USER':'caller-user','LOGNAME':'caller-logname'}, False, False),
        ('empty root with ambient credentials', {'ANTHROPIC_API_KEY':'sk-ant-fm-live-synthetic','CLAUDE_CODE_OAUTH_TOKEN':'synthetic','OPENAI_API_KEY':'sk-fm-live-synthetic'}, False, True),
        ('failed identity lookup with caller names', {'USER':'caller-user','LOGNAME':'caller-logname'}, True, False),
    ]:
        id_path = bindir / 'id'
        if failed_id:
            id_path.write_text('#!/bin/sh\nprintf "invalid-login\\n"\nexit 1\n')
            id_path.chmod(0o755)
        elif id_path.exists(): id_path.unlink()
        selected_root = root
        if empty_root:
            selected_root = area / 'empty'
            selected_root.mkdir(exist_ok=True)
            (cfg / (harness + '-account')).write_text(str(selected_root) + ('\nopenai\n' if harness == 'pi' else '\n'))
        else: (cfg / (harness + '-account')).write_text(pin)
        env = {'HOME':str(user_home), 'PATH':str(bindir)+':'+base_path, **extra}
        command = ['bash','-c', '. "$1"; fm_worker_account_select "$2" "$3" "$4" "$5"', '_', str(repo/'bin/fm-worker-account-lib.sh'), harness, str(cfg), 'openai/gpt-5' if harness == 'pi' else '', str(wrapper)]
        result = subprocess.run(command, env=env, capture_output=True, text=True)
        seen = json.loads(observed.read_text())
        print('\nSCENARIO:', harness, '-', name, flush=True)
        print('Real runner:', real[harness], flush=True)
        print('Observed probe environment:', json.dumps(seen, sort_keys=True), flush=True)
        print('Real runner response:', answer.read_text().strip(), flush=True)
        print('Firstmate exit:', result.returncode, flush=True)
        print('Firstmate output:', (result.stdout+result.stderr).strip(), flush=True)
        if failed_id:
            assert seen['USER'] == seen['LOGNAME'] == ''
            failures += int(result.returncode == 0)
            print('Required refusal:', 'PASS' if result.returncode != 0 else 'FAIL - Firstmate accepted the pin after id -un failed', flush=True)
        elif empty_root:
            assert result.returncode == 1
            assert all(seen[k] is None for k in ('ANTHROPIC_API_KEY','CLAUDE_CODE_OAUTH_TOKEN','OPENAI_API_KEY'))
        else:
            assert result.returncode == 0
            assert seen['USER'] == seen['LOGNAME'] == identity
            assert seen['HOME'] == str(user_home)
shutil.rmtree(scratch)
raise SystemExit(1 if failures else 0)
