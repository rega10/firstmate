import http.server
import json
import os
from pathlib import Path
import shutil
import socketserver
import subprocess
import threading

ROOT = Path.cwd()
EVIDENCE = Path('/Users/rega1011/.no-mistakes/evidence/01M4ME82BH54TSD9W4KA9F12MX')
SCRATCH = ROOT / '.startup-validation/live'
SCRATCH.mkdir(parents=True, exist_ok=False)
SOCKET = ROOT / '.startup-validation/s'
TRANSCRIPT = []
REQUESTS = []
AUTH_FAILED = False

class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        REQUESTS.append({'method': 'GET', 'path': self.path})
        self.send_response(401 if AUTH_FAILED else 200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-OAuth-Scopes', 'repo, read:org, gist')
        self.end_headers()
        self.wfile.write(json.dumps({'login': 'startup-lab', 'id': 100, 'name': 'Disposable validation user'}).encode())
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        REQUESTS.append({'method': 'POST', 'path': self.path})
        self.send_response(401 if AUTH_FAILED else 200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-OAuth-Scopes', 'repo, read:org, gist')
        self.end_headers()
        self.wfile.write(json.dumps({'data': {'viewer': {'login': 'startup-lab'}}}).encode())

server = Server(str(SOCKET), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()

def log(text):
    print(text, flush=True)
    TRANSCRIPT.append(text)

def execute(args, env):
    result = subprocess.run(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    log('$ ' + ' '.join(args))
    log('exit=' + str(result.returncode))
    if result.stdout:
        log(result.stdout.rstrip())
    return result

base_env = dict(os.environ)
base_env['PATH'] = str(ROOT / '.startup-validation/cli') + ':' + base_env['PATH']
for key in list(base_env):
    if key.startswith(('FM_', 'GH_', 'GITHUB_', 'HERDR_', 'CMUX_')) or key in ('TMUX', 'TMUX_PANE', '__CFBundleIdentifier', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY'):
        base_env.pop(key)
base_env.update({'TMPDIR': str(SCRATCH), 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CEILING_DIRECTORIES': str(SCRATCH), 'GH_TOKEN': 'disposable-token', 'GH_ENTERPRISE_TOKEN': 'disposable-token', 'GH_HOST': 'startup-lab.invalid', 'GH_PROMPT_DISABLED': '1', 'GH_NO_UPDATE_NOTIFIER': '1', 'GH_NO_EXTENSION_UPDATE_NOTIFIER': '1', 'GH_TELEMETRY': '0'})

config = SCRATCH / 'gh-config'
config.mkdir()
(config / 'config.yml').write_text('http_unix_socket: ' + str(SOCKET) + '\n')
(config / 'hosts.yml').write_text('startup-lab.invalid:\n    user: startup-lab\n    oauth_token: disposable-token\n    git_protocol: https\n')
base_env['GH_CONFIG_DIR'] = str(config)

try:
    log('The real gh CLI uses isolated configuration and a disposable local HTTP endpoint. No production credentials are loaded.')
    auth = execute(['gh', 'auth', 'status'], base_env)
    assert auth.returncode == 0, 'Disposable authenticated endpoint did not satisfy real gh'
    baseline = SCRATCH / 'baseline'
    (baseline / 'bin').mkdir(parents=True)
    for source in (ROOT / 'bin').glob('*.sh'):
        if source.name != 'fm-bootstrap.sh':
            (baseline / 'bin' / source.name).symlink_to(source)
    old = subprocess.check_output(['git', 'show', '81fa3fddbdefd27d5c507a427d4ec4baaa3d65df:bin/fm-bootstrap.sh'], cwd=ROOT)
    (baseline / 'bin/fm-bootstrap.sh').write_bytes(old)
    (baseline / 'bin/fm-bootstrap.sh').chmod(0o755)

    def scenario(name, backend, configured=False, failed_auth=False, before=False):
        global AUTH_FAILED
        AUTH_FAILED = failed_auth
        log('\nSCENARIO: ' + name)
        home = SCRATCH / name
        for child in ('config', 'state', 'data', 'projects'):
            (home / child).mkdir(parents=True)
        env = dict(base_env)
        env.update({'FM_HOME': str(home), 'FM_STATE_OVERRIDE': str(home/'state'), 'FM_CONFIG_OVERRIDE': str(home/'config'), 'FM_DATA_OVERRIDE': str(home/'data'), 'FM_PROJECTS_OVERRIDE': str(home/'projects')})
        env['HERDR_ENV' if backend == 'herdr' else 'CMUX_WORKSPACE_ID'] = '1' if backend == 'herdr' else 'disposable-workspace'
        if configured:
            (home / 'config/backend').write_text(backend + '\n')
        if failed_auth:
            empty_config = home / 'gh-empty'
            empty_config.mkdir()
            # A local 401 response exercises the real CLI authentication failure.
            auth = execute(['gh', 'auth', 'status'], env)
            assert auth.returncode != 0
        resolver = execute(['bash', '-c', '. "$1/bin/fm-backend.sh"; fm_backend_name', '_', str(ROOT)], env)
        if backend == 'cmux' and not configured:
            assert 'NOTICE: auto-detected cmux runtime' in resolver.stdout
        code = baseline if before else ROOT
        if before:
            env['FM_ROOT_OVERRIDE'] = str(code)
        run = execute(['bash', str(code/'bin/fm-startup-network.sh'), 'run', '--locked', '0'], env)
        assert run.returncode == 0
        report = execute(['bash', str(code/'bin/fm-startup-network.sh'), 'report'], env)
        wake_file = home / 'state/.wake-queue'
        wake = wake_file.read_text() if wake_file.exists() else ''
        raw_report = (home / 'state/.startup-network.report').read_text()
        log('Durable report bytes: ' + repr(raw_report))
        log('Durable wake queue: ' + (wake.rstrip() or '(empty)'))
        (EVIDENCE / (name + '.report.txt')).write_text(report.stdout + '\nDurable wake queue:\n' + (wake or '(empty)\n'))
        if before:
            assert 'NOTICE: auto-detected cmux runtime' in raw_report
            assert 'check\tstartup-network' in wake
            log('REPRODUCED: the base version creates a wake for an incidental NOTICE.')
        elif failed_auth:
            assert 'NEEDS_GH_AUTH' in raw_report
            assert 'check\tstartup-network' in wake
            assert 'NOTICE:' not in raw_report
            log('PASS: an authentication failure still creates an actionable report and a durable wake.')
        else:
            assert '(silent - no problems found)' in report.stdout
            assert not raw_report.strip()
            assert not wake
            log('PASS: a successful probe produces an empty report and no durable wake.')

    scenario('before-cmux-auto', 'cmux', before=True)
    for backend in ('herdr', 'cmux'):
        scenario('after-' + backend + '-configured', backend, configured=True)
        scenario('after-' + backend + '-auto', backend)
        scenario('after-' + backend + '-auth-failed', backend, failed_auth=True)
finally:
    server.shutdown()
    server.server_close()
    SOCKET.unlink(missing_ok=True)
    (EVIDENCE / 'live-startup-transcript.log').write_text('\n'.join(TRANSCRIPT) + '\n')
    (EVIDENCE / 'local-api-requests.json').write_text(json.dumps(REQUESTS, indent=2) + '\n')
    shutil.rmtree(SCRATCH)
