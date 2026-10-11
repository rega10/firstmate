import http.server
import socketserver
import threading
import subprocess
import pathlib
import os
import shutil
import json
import time

repo = pathlib.Path.cwd()
evidence = pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M4MRJDMWFA7KGAY3Y8E6SKEJ')
scratch = repo / '.test-startup-notice'
transcript = []
requests = []
reject = False

def record(message):
    transcript.append(message)
    print(message, flush=True)

class Endpoint(http.server.BaseHTTPRequestHandler):
    def respond(self):
        requests.append({'method': self.command, 'path': self.path, 'status': 401 if reject else 200})
        self.send_response(401 if reject else 200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-OAuth-Scopes', 'repo, read:org')
        self.end_headers()
        payload = {'message': 'Bad credentials'} if reject else {'data': {'viewer': {'login': 'disposable-lab'}}}
        self.wfile.write(json.dumps(payload).encode())
    do_GET = respond
    do_POST = respond
    def log_message(self, *args):
        pass

server = socketserver.UnixStreamServer('.test-startup-notice/auth.sock', Endpoint)
threading.Thread(target=server.serve_forever, daemon=True).start()
(scratch / 'tools').mkdir(exist_ok=True)
if not (scratch / 'tools' / 'gh').exists():
    (scratch / 'tools' / 'gh').symlink_to(shutil.which('gh'))
config = scratch / 'isolated-gh'
config.mkdir(exist_ok=True)
(config / 'config.yml').write_text('http_unix_socket: .test-startup-notice/auth.sock\n')

def world(name, base=False, historical=False):
    location = scratch / name
    if location.exists(): shutil.rmtree(location)
    home, root = location / 'home', location / 'root'
    for part in ('state', 'config', 'data', 'projects'):
        (home / part).mkdir(parents=True)
    (root / 'bin').mkdir(parents=True)
    for source in (repo / 'bin').iterdir():
        (root / 'bin' / source.name).symlink_to(source)
    if base:
        bootstrap = root / 'bin' / 'fm-bootstrap.sh'
        bootstrap.unlink()
        bootstrap.write_bytes(subprocess.check_output(['git', 'show', '3f2d62a13ca048e1c77a8d09927d3501249bd798:bin/fm-bootstrap.sh']))
        bootstrap.chmod(0o755)
    if historical:
        backend = root / 'bin' / 'fm-backend.sh'
        backend.unlink()
        backend.write_bytes(subprocess.check_output(['git', 'show', '1b1b6e05^:bin/fm-backend.sh']))
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('FM_', 'HERDR_', 'CMUX_', 'GH_', 'GITHUB_', 'TASKS_AXI_')) or key in ('TMUX', 'TMUX_PANE', '__CFBundleIdentifier'):
            env.pop(key)
    env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root), FM_STATE_OVERRIDE=str(home/'state'), FM_DATA_OVERRIDE=str(home/'data'), FM_CONFIG_OVERRIDE=str(home/'config'), FM_PROJECTS_OVERRIDE=str(home/'projects'), FM_BACKEND_CMUX_BUNDLE_BIN=str(scratch/'absent-cmux'), TMPDIR=str(scratch/'tmp'), GIT_CEILING_DIRECTORIES=str(scratch), PATH=str(scratch/'tools')+':/usr/bin:/bin:/usr/sbin:/sbin', GH_CONFIG_DIR=str(config), GH_HOST='disposable.example', GH_ENTERPRISE_TOKEN='disposable-test-token', GH_NO_UPDATE_NOTIFIER='1', GH_NO_EXTENSION_UPDATE_NOTIFIER='1', GH_PROMPT_DISABLED='1', GH_TELEMETRY='false')
    return home, root, env

def command(args, env):
    result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=60)
    record('$ ' + ' '.join(str(a) for a in args))
    record('exit=' + str(result.returncode))
    if result.stdout: record(result.stdout.rstrip())
    if result.stderr: record('stderr:\n' + result.stderr.rstrip())
    assert result.returncode == 0, result.stderr
    return result.stdout + "\n" + result.stderr

def stage(home, root, env, label, actionable=False):
    record('\nSCENARIO: ' + label)
    command(['bash', str(root/'bin/fm-startup-network.sh'), 'run', '--locked', '0'], env)
    report = command(['bash', str(root/'bin/fm-startup-network.sh'), 'report'], env)
    raw = (home/'state/.startup-network.report').read_text()
    queue = home/'state/.wake-queue'
    wakes = queue.read_text() if queue.exists() else ''
    status = (home/'state/.startup-network.status').read_text()
    record('Persisted report: ' + repr(raw))
    record('Persisted wake queue: ' + repr(wakes))
    record('Persisted status:\n' + status.rstrip())
    if actionable:
        assert 'NEEDS_GH_AUTH' in raw and '\tcheck\tstartup-network\t' in wakes
    return raw, wakes, report

try:
    home, root, env = world('before-historical-herdr', base=True, historical=True)
    env['HERDR_ENV'] = '1'
    record('Authentication setup uses the real gh executable and an isolated disposable GitHub endpoint.')
    command(['gh', 'auth', 'status'], env)
    raw, wakes, _ = stage(home, root, env, 'Historical Herdr notice with pre-fix bootstrap reproduces a false wake')
    assert 'NOTICE: auto-detected herdr runtime' in raw and '\tcheck\tstartup-network\t' in wakes

    home, root, env = world('after-historical-herdr', historical=True)
    env['HERDR_ENV'] = '1'
    raw, wakes, report = stage(home, root, env, 'Fixed bootstrap ignores historical Herdr notice during network checks')
    assert raw == '' and wakes == '' and '(silent - no problems found)' in report

    home, root, env = world('before-current-cmux', base=True)
    env['CMUX_WORKSPACE_ID'] = 'disposable-workspace'
    raw, wakes, _ = stage(home, root, env, 'Current cmux resolver with pre-fix bootstrap reproduces a false wake')
    assert 'NOTICE: auto-detected cmux runtime' in raw and '\tcheck\tstartup-network\t' in wakes

    for backend in ('herdr', 'cmux'):
        home, root, env = world('after-'+backend)
        env['HERDR_ENV' if backend == 'herdr' else 'CMUX_WORKSPACE_ID'] = '1' if backend == 'herdr' else 'disposable-workspace'
        record('\nResolver check for ' + backend)
        resolved = command(['bash', '-c', '. "$1/bin/fm-backend.sh"; fm_backend_name', '_', str(root)], env)
        assert resolved.splitlines()[0] == backend
        if backend == 'cmux': assert 'NOTICE: auto-detected cmux runtime' in resolved
        (home/'config/backend').write_text(backend+'\n')
        raw, wakes, report = stage(home, root, env, 'Configured '+backend+' has a clean report and no wake')
        assert raw == '' and wakes == ''
        (home/'config/backend').unlink()
        raw, wakes, report = stage(home, root, env, 'Auto-detected '+backend+' without config/backend has a clean report and no wake')
        assert raw == '' and wakes == '' and '(silent - no problems found)' in report
        reject = True
        stage(home, root, env, 'Rejected authentication under '+backend+' still reports NEEDS_GH_AUTH and queues a durable wake', actionable=True)
        reject = False
        env.update(FM_BOOTSTRAP_NETWORK='skip', FM_BOOTSTRAP_DETECT_ONLY='1')
        record('\nSCENARIO: Local dependency detection remains active for '+backend)
        output = command(['bash', str(root/'bin/fm-bootstrap.sh')], env)
        assert ('MISSING: '+backend+' ' in output or 'MISSING_MANUAL: '+backend+' ' in output) and 'MISSING: tmux' not in output
        if backend == 'cmux': assert 'NOTICE: auto-detected cmux runtime' in output
        (home/'config/backend').write_text('bogus\n')
        output = command(['bash', str(root/'bin/fm-bootstrap.sh')], env)
        assert 'BACKEND_INVALID: bogus' in output
    home, root, env = world('detached-cmux')
    env['CMUX_WORKSPACE_ID'] = 'disposable-workspace'
    record('\nSCENARIO: Detached startup with no config/backend completes silently')
    command(['bash', str(root/'bin/fm-startup-network.sh'), 'start', '--locked', '0', '--harvest-pid', '99999999'], env)
    command(['bash', str(root/'bin/fm-startup-network.sh'), 'wait', '20'], env)
    time.sleep(1)
    report = command(['bash', str(root/'bin/fm-startup-network.sh'), 'report'], env)
    raw = (home/'state/.startup-network.report').read_text()
    queue = home/'state/.wake-queue'
    wakes = queue.read_text() if queue.exists() else ''
    record('Persisted report: ' + repr(raw))
    record('Persisted wake queue: ' + repr(wakes))
    record('Persisted status:\n' + (home/'state/.startup-network.status').read_text())
    assert raw == '' and wakes == '' and '(silent - no problems found)' in report
    record('\nAll live script scenarios met their expected observable results.')
finally:
    server.shutdown()
    server.server_close()
    (scratch/'auth.sock').unlink(missing_ok=True)
    (evidence/'live-startup-notice.txt').write_text('\n'.join(transcript)+'\n')
    (evidence/'disposable-auth-requests.json').write_text(json.dumps(requests, indent=2)+'\n')
