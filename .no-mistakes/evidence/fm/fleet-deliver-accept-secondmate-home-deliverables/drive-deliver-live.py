"""Disposable CLI-to-SMTP validation. No product code or mail command is replaced."""
import email.policy
import hashlib
import json
import os
from pathlib import Path
import shutil
import socketserver
import ssl
import subprocess
import tempfile
import threading
from email.parser import BytesParser

ROOT = Path.cwd()
EVIDENCE = Path('/Users/rega1011/.no-mistakes/evidence/01M5SQHXVYA7SER61GYZGDEJ9M')
BASE = 'f4a2ca99b948d05b6578dc5fe77de4afca15128b'
lab = Path(tempfile.mkdtemp(prefix='deliver-live-', dir=ROOT / '.validation-tmp'))
transcript = (EVIDENCE / 'deliver-live-transcript.log').open('w')
messages = []
checks = []
server = None

def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())
    return path

def report(text):
    print(text, flush=True)
    print(text, file=transcript, flush=True)

class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        def reply(line):
            self.wfile.write(line + b'\r\n')
            self.wfile.flush()
        reply(b'220 localhost disposable validation SMTP')
        while True:
            line = self.rfile.readline()
            if not line:
                return
            verb = line.split(None, 1)[0].upper()
            if verb in (b'EHLO', b'HELO'):
                reply(b'250-localhost')
                reply(b'250 AUTH PLAIN')
            elif verb == b'AUTH':
                reply(b'235 Authentication successful')
            elif verb in (b'MAIL', b'RCPT', b'RSET', b'NOOP'):
                reply(b'250 OK')
            elif verb == b'DATA':
                reply(b'354 End data with <CRLF>.<CRLF>')
                data = bytearray()
                while True:
                    line = self.rfile.readline()
                    if line in (b'.\r\n', b'.\n', b''):
                        break
                    data.extend(line[1:] if line.startswith(b'..') else line)
                messages.append(bytes(data))
                (EVIDENCE / ('received-%02d.eml' % len(messages))).write_bytes(data)
                reply(b'250 Message accepted')
            elif verb == b'QUIT':
                reply(b'221 Bye')
                return
            else:
                reply(b'502 Unsupported command')

try:
    cert = lab / 'smtp.crt'
    key = lab / 'smtp.key'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1',
                    '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), SMTP)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    home, mate, remote, stranger = [lab / x for x in ('primary', 'documents mate', 'remote', 'stranger')]
    for h in (home, mate, remote, stranger):
        for folder in ('data/task', 'data/outbound', 'config', 'state', 'projects'):
            (h / folder).mkdir(parents=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
    env['PATH'] = str(ROOT / '.validation-tmp/python/bin') + os.pathsep + env['PATH']
    env.update(FM_HOME=str(home), TMPDIR=str(lab), FM_MAIL_USER='sender@example.test',
               FM_MAIL_PASS='disposable-local-password', FM_IMAP_HOST='localhost',
               FM_SMTP_HOST='localhost', FM_SMTP_PORT=str(server.server_address[1]),
               SSL_CERT_FILE=str(cert), FM_MAIL_TIMEOUT='3')
    diagnostic = subprocess.run(['python3', '-I', '-c', 'import ssl,os; print(ssl.get_default_verify_paths()); print(ssl.create_default_context().cert_store_stats()); print(os.environ.get("SSL_CERT_FILE"))'], env=env, capture_output=True, text=True)
    report('TLS trust diagnostic: ' + diagnostic.stdout + diagnostic.stderr)
    contacts = ['bin/fm-contacts.sh', 'add', '--id', 'captain', '--name', 'Captain Test',
                '--role', 'Owner', '--trust', 'self', '--language', 'en',
                '--email', 'captain@example.test', '--added-by', 'Disposable validation setup']
    subprocess.run(contacts, env=env, check=True, capture_output=True)
    words = write(lab / 'order.txt', 'Send the second mate report to me.\n')
    registry = home / 'data/secondmates.md'
    def local_record(identifier='documents-mate', path=mate):
        return '- %s - Makes documents. (home: %s; scope: documents; projects: ; added 2026-10-24)\n' % (identifier, path)
    remote_record = '- remote-mate - Remote documents. (host: testbox; root: /srv/code; home: %s; scope: remote; projects: ; added 2026-10-24)\n' % remote
    valid_registry = local_record() + remote_record
    write(registry, valid_registry)
    pdf = b'%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n'
    report_pdf = write(mate / 'data/task/report.pdf', pdf)
    own_pdf = write(home / 'data/task/own.pdf', pdf + b'primary report\n')
    remote_pdf = write(remote / 'data/task/remote.pdf', pdf)
    stranger_pdf = write(stranger / 'data/task/stranger.pdf', pdf)
    note = write(mate / 'data/task/note.txt', 'The report from the second mate.\n')
    log_path = home / 'data/outbound/sends.jsonl'
    def logs():
        return [json.loads(line) for line in log_path.read_text().splitlines()] if log_path.exists() else []
    def drive(name, files, expected=0, flags=(), needle=None, executable='bin/fm-deliver.sh', settings=None, forbidden=False):
        before_messages, before_logs = len(messages), len(logs())
        command = [str(executable), 'captain', *map(str, files), '--order-file', str(words), *map(str, flags)]
        done = subprocess.run(command, env=dict(env, **(settings or {})), capture_output=True, text=True, timeout=12)
        report('\nCASE: ' + name)
        report('$ ' + ' '.join(command))
        report('exit=%s\nstdout: %sstderr: %s' % (done.returncode, done.stdout, done.stderr))
        assert done.returncode == expected, (name, done.returncode, expected)
        assert needle is None or needle in done.stdout + done.stderr, (name, needle)
        if expected or '--dry-run' in flags:
            assert len(messages) == before_messages, name + ': unexpected SMTP message'
        else:
            assert len(messages) == before_messages + 1, name + ': missing SMTP message'
        if '--dry-run' in flags:
            assert len(logs()) == before_logs, name + ': preview appended a log'
        else:
            assert len(logs()) == before_logs + 1
            record = logs()[-1]
            assert record['result'] == ('sent' if expected == 0 else 'refused'), record
            if forbidden:
                assert all(f['sha256'] is None and f['home'] is None for f in record['files']), record
            report('persisted send record: ' + json.dumps(record))
        checks.append({'name': name, 'exit': done.returncode, 'result': 'pass'})
        return done

    # Execute the previous product with the identical isolated inputs.
    basebin = lab / 'base-bin'
    basebin.mkdir()
    for path in (ROOT / 'bin').iterdir():
        (basebin / path.name).symlink_to(path)
    for name in ('fm-deliver.sh', 'fm-deliver.py'):
        path = basebin / name
        path.unlink()
        content = subprocess.run(['git', 'show', BASE + ':bin/' + name], check=True, capture_output=True).stdout
        path.write_bytes(content)
        path.chmod(0o755)
    drive('Base version accepts primary report', [own_pdf], flags=('--dry-run',), executable=basebin / 'fm-deliver.sh')
    drive('Base version reproduces refusal of registered second mate report', [report_pdf], expected=5,
          flags=('--dry-run',), needle='outside data/', executable=basebin / 'fm-deliver.sh')
    drive('Preview accepts registered second mate PDF and covering note', [report_pdf], flags=('--dry-run', '--note-file', note), needle='report.pdf')
    drive('Send registered second mate PDF directly to self', [report_pdf], flags=('--note-file', note))
    msg = BytesParser(policy=email.policy.default).parsebytes(messages[-1])
    attached = list(msg.iter_attachments())
    assert len(attached) == 1 and attached[0].get_payload(decode=True) == pdf
    assert msg.get_body(preferencelist=('plain',)).get_content().strip() == note.read_text().strip()
    assert msg['To'] == 'captain@example.test'
    record = logs()[-1]['files'][0]
    assert record['home'] == str(mate) and record['secondmate'] == 'documents-mate'
    assert record['sha256'] == hashlib.sha256(pdf).hexdigest()
    assert not (home / 'data/task/report.pdf').exists()
    assert not (mate / 'data/outbound/sends.jsonl').exists()
    report('SMTP recipient received the original PDF bytes and covering note; primary log records the registered source; no copy exists in primary data/task/.')
    drive('Mixed send preserves primary and second mate source homes', [own_pdf, report_pdf])
    msg = BytesParser(policy=email.policy.default).parsebytes(messages[-1])
    assert [part.get_payload(decode=True) for part in msg.iter_attachments()] == [own_pdf.read_bytes(), pdf]
    assert [(f['home'], f['secondmate']) for f in logs()[-1]['files']] == [(str(home), None), (str(mate), 'documents-mate')]
    safe_link = mate / 'data/task/safe-link.pdf'
    safe_link.symlink_to(report_pdf)
    drive('Safe symlink resolves to registered deliverable', [safe_link])

    for folder in ('config', 'state', 'projects'):
        direct = write(mate / folder / 'private.pdf', pdf)
        drive('Refuse second mate home ' + folder, [direct], expected=5, needle='never sent', forbidden=True)
        link = mate / 'data/task' / (folder + '-link.pdf')
        link.symlink_to(direct)
        drive('Refuse symlink to second mate ' + folder, [link], expected=5, needle='never sent', forbidden=True)
    env_file = write(mate / '.env', 'DISPOSABLE=fixture\n')
    env_link = mate / 'data/task/env-link.pdf'
    env_link.symlink_to(env_file)
    drive('Refuse second mate home .env', [env_file], expected=5, needle='never sent', forbidden=True)
    drive('Refuse symlink to second mate .env', [env_link], expected=5, needle='never sent', forbidden=True)
    for folder in ('.env', 'config', 'state', 'projects'):
        path = write(mate / 'data/task' / folder / 'private.pdf', pdf)
        drive('Refuse nested ' + folder + ' directory', [path], expected=5, needle='never sent', forbidden=True)
    for name, path, needle in (
        ('top-level data file', mate / 'data/top.pdf', 'bookkeeping'),
        ('outbound file', mate / 'data/outbound/old.pdf', 'send log folder'),
        ('.env-prefixed file', mate / 'data/task/.env.private.pdf', 'never sent')):
        drive('Refuse ' + name, [write(path, pdf)], expected=5, needle=needle, forbidden=True)
    fifo = mate / 'config/no-read.pdf'
    os.mkfifo(fifo)
    drive('Refuse forbidden FIFO without opening or blocking', [fifo], expected=5, needle='never sent', forbidden=True)
    primary_private = write(home / 'config/private.pdf', pdf)
    drive('Refuse primary config from second mate alias', [primary_private], expected=5, needle='never sent', forbidden=True)
    private_alias = mate / 'data/task/primary-config.pdf'
    private_alias.symlink_to(primary_private)
    drive('Refuse symlink to primary config', [private_alias], expected=5, needle='never sent', forbidden=True)
    md = write(mate / 'data/task/report.md', '# Report\n')
    drive('Refuse second mate Markdown with PDF instruction', [md], expected=5, needle='Markdown must be rendered to PDF first')
    hidden_md = mate / 'data/task/hidden-md.pdf'
    hidden_md.symlink_to(md)
    drive('Refuse Markdown disguised as PDF symlink', [hidden_md], expected=5, needle='Markdown must be rendered to PDF first')
    leak = write(mate / 'data/task/leak.pdf', pdf + b'password=NEVER_SEND_THIS\n')
    drive('Refuse secret in second mate PDF', [leak], expected=5, needle='matches the secret pattern password=')
    leak_note = write(mate / 'data/task/leak-note.txt', 'password=NEVER_SEND_THIS\n')
    drive('Refuse secret in second mate covering note', [report_pdf], expected=5, flags=('--note-file', leak_note), needle='matches the secret pattern password=')
    drive('Enforce total size cap on second mate report', [report_pdf], expected=5, settings={'FM_DELIVER_MAX_BYTES': '8'}, needle='above')
    directory = mate / 'data/task/directory.pdf'
    directory.mkdir()
    drive('Refuse nonregular second mate attachment', [directory], expected=5, needle='not a regular file')

    outside = 'is outside data/ of this home and of every registered local second mate home'
    for name, path in (('remote registration', remote_pdf), ('unregistered home', stranger_pdf)):
        drive('Refuse ' + name + ' attachment', [path], expected=5, needle=outside, forbidden=True)
        drive('Refuse ' + name + ' preview', [path], expected=5, flags=('--dry-run',), needle=outside)
        drive('Refuse ' + name + ' note', [own_pdf], expected=5, flags=('--note-file', path), needle=outside)
    remote_alias = mate / 'data/task/remote-alias.pdf'
    remote_alias.symlink_to(remote_pdf)
    drive('Refuse registered-home symlink to remote-only file', [remote_alias], expected=5, needle=outside, forbidden=True)
    for name, content in (
        ('malformed registry', valid_registry + '- broken - no route\n'),
        ('duplicate binding registry', valid_registry + local_record('other-id')),
        ('relative-home registry', local_record(path=Path('relative-home')))):
        write(registry, content)
        drive('Refuse mate file with ' + name, [report_pdf], expected=5, needle='registry cannot be used', forbidden=True)
        drive('Preserve primary delivery with ' + name, [own_pdf])
    registry.unlink()
    registry.symlink_to(write(lab / 'registry-copy.md', valid_registry))
    drive('Refuse mate file with symlinked registry', [report_pdf], expected=5, needle='registry cannot be used', forbidden=True)
    drive('Preserve primary delivery with symlinked registry', [own_pdf])
    registry.unlink()
    drive('Refuse mate file with missing registry', [report_pdf], expected=5, needle=outside, forbidden=True)
    drive('Preserve primary delivery with missing registry', [own_pdf])
    write(registry, remote_record)
    drive('Remote-only registry grants no local access', [remote_pdf], expected=5, needle=outside, forbidden=True)
    report('\nAll live CLI scenarios passed. SMTP messages received: %d.' % len(messages))
finally:
    if 'log_path' in globals() and log_path.exists():
        shutil.copyfile(log_path, EVIDENCE / 'primary-sends.jsonl')
    (EVIDENCE / 'live-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
    if server:
        server.shutdown()
        server.server_close()
    shutil.rmtree(lab)
    transcript.close()
