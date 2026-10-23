#!/usr/bin/env python3
"""Drive the real fm-mail CLI over a loopback implicit-TLS SMTP endpoint.
The endpoint is a disposable service fixture, not a replacement for fm-mail.
No product imports, substitutions, external mailbox, or production secrets.
Run from the assigned worktree after creating .mail-validation/{key,cert}.pem.
"""
import base64
import email
import email.policy
import hashlib
import json
import os
from pathlib import Path
import socketserver
import ssl
import subprocess
import threading
import traceback

ROOT = Path.cwd()
LAB = ROOT / '.mail-validation'
OUT = Path(__file__).parent
FILES = LAB / 'files'
HOME = LAB / 'home'
FILES.mkdir(exist_ok=True)
HOME.mkdir(exist_ok=True)
(HOME / '.env').write_text('FM_MAIL_USER=sender@example.test\nFM_MAIL_PASS=disposable-app-password\nFM_IMAP_HOST=unused.invalid\nFM_SMTP_HOST=localhost\nFM_MAIL_FROM_NAME="Oficina Técnica Núñez"\n', encoding='utf-8')

# A small real PDF with a page and text, plus opaque binary attachment fixtures.
objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
           b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
           b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
stream = b'BT /F1 18 Tf 50 720 Td (Site questionnaire - local mail validation) Tj ET\n'
objects.append(b'<< /Length %d >>\nstream\n' % len(stream) + stream + b'endstream')
pdf = b'%PDF-1.4\n'
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf += b'%d 0 obj\n' % i + obj + b'\nendobj\n'
xref = len(pdf)
pdf += b'xref\n0 6\n0000000000 65535 f \n'
pdf += b''.join(b'%010d 00000 n \n' % x for x in offsets[1:])
pdf += b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % xref
pdf_path = FILES / 'cuestionario técnico.pdf'
pdf_path.write_bytes(pdf)
(FILES / 'plan.png').write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jG9sAAAAASUVORK5CYII='))
(FILES / 'notes.fmunknownext').write_bytes(bytes(range(256)))
(FILES / 'a.bin').write_bytes(b'a' * 600)
(FILES / 'b.bin').write_bytes(b'b' * 500)
(FILES / 'folder').mkdir(exist_ok=True)
if (FILES / 'locked.pdf').exists():
    os.chmod(FILES / 'locked.pdf', 0o600)
(FILES / 'locked.pdf').write_bytes(pdf)
os.chmod(FILES / 'locked.pdf', 0)
(FILES / 'pipe.pdf').unlink(missing_ok=True)
os.mkfifo(FILES / 'pipe.pdf')
with (FILES / 'big.bin').open('wb') as f:
    f.truncate(20971521)

class Endpoint(socketserver.TCPServer):
    allow_reuse_address = True
    def __init__(self, refused=()):
        self.events = []
        self.messages = []
        self.refused = set(refused)
        self.errors = []
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(LAB / 'cert.pem', LAB / 'key.pem')
        super().__init__(('127.0.0.1', 0), SMTP)
    def get_request(self):
        conn, addr = super().get_request()
        self.events.append({'event': 'connect'})
        conn.settimeout(20)
        return self.ctx.wrap_socket(conn, server_side=True), addr
    def handle_error(self, request, client_address):
        self.errors.append(traceback.format_exc())

class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        def reply(s):
            self.wfile.write(s.encode('ascii') + b'\r\n')
            self.wfile.flush()
        reply('220 localhost disposable SMTP endpoint')
        accepted = []
        while True:
            line = self.rfile.readline()
            if not line:
                return
            text = line.decode('ascii').rstrip('\r\n')
            verb, _, arg = text.partition(' ')
            verb = verb.upper()
            if verb in ('EHLO', 'HELO'):
                self.server.events.append({'event': verb, 'features': ['AUTH PLAIN'], '8BITMIME': False, 'SMTPUTF8': False})
                reply('250-localhost')
                reply('250 AUTH PLAIN')
            elif verb == 'AUTH':
                # Verify only disposable credentials. Never retain the token.
                method, token = arg.split(' ', 1)
                assert method.upper() == 'PLAIN'
                assert base64.b64decode(token) == b'\x00sender@example.test\x00disposable-app-password'
                self.server.events.append({'event': 'AUTH', 'credentials': 'verified disposable credentials; redacted'})
                reply('235 2.7.0 authenticated')
            elif verb == 'MAIL':
                accepted = []
                self.server.events.append({'event': 'MAIL', 'argument': arg})
                reply('250 2.1.0 sender accepted')
            elif verb == 'RCPT':
                addr = arg.split('<', 1)[1].split('>', 1)[0]
                refused = addr in self.server.refused
                self.server.events.append({'event': 'RCPT', 'recipient': addr, 'accepted': not refused})
                if not refused:
                    accepted.append(addr)
                reply('550 5.1.1 recipient refused' if refused else '250 2.1.5 recipient accepted')
            elif verb == 'DATA':
                assert accepted
                reply('354 end with dot')
                lines = []
                while True:
                    row = self.rfile.readline()
                    if row == b'.\r\n':
                        break
                    if row.startswith(b'..'):
                        row = row[1:]
                    lines.append(row)
                raw = b''.join(lines)
                self.server.messages.append({'raw': raw, 'delivered_to': accepted.copy()})
                self.server.events.append({'event': 'DATA', 'bytes': len(raw), 'delivered_to': accepted.copy()})
                reply('250 2.0.0 queued once')
            elif verb == 'RSET':
                self.server.events.append({'event': 'RSET'})
                accepted = []
                reply('250 reset')
            elif verb == 'QUIT':
                self.server.events.append({'event': 'QUIT'})
                reply('221 bye')
                return
            else:
                raise AssertionError('unexpected SMTP command ' + verb)

records = []

def run(name, args, *, env_extra=None, stdin=None, refused=(), expected_rc=0,
        expected_error=None, expected_messages=1, expected_connections=1,
        inspect=None, save=True):
    with Endpoint(refused) as endpoint:
        thread = threading.Thread(target=endpoint.serve_forever, kwargs={'poll_interval': .02})
        thread.start()
        env = {k: v for k, v in os.environ.items() if not k.startswith('FM_MAIL_') and not k.startswith('FM_SMTP_') and not k.startswith('FM_IMAP_')}
        env.update({'FM_HOME': str(HOME), 'FM_SMTP_PORT': str(endpoint.server_address[1]),
                    'SSL_CERT_FILE': str(LAB / 'cert.pem'), 'PYTHONDONTWRITEBYTECODE': '1',
                    'FM_MAIL_TIMEOUT': '5'})
        env.update(env_extra or {})
        try:
            result = subprocess.run(['bash', 'bin/fm-mail.sh', 'send'] + [str(x) for x in args],
                                    cwd=ROOT, env=env, input=stdin, capture_output=True, timeout=30)
        finally:
            endpoint.shutdown()
            thread.join(5)
        rec = {'name': name, 'command': ['bash', 'bin/fm-mail.sh', 'send'] + [str(x).replace(str(ROOT) + '/', '') for x in args],
               'exit_code': result.returncode, 'stdout': result.stdout.decode('utf-8', 'replace'),
               'stderr': result.stderr.decode('utf-8', 'replace'), 'smtp_events': endpoint.events,
               'endpoint_errors': endpoint.errors, 'messages': []}
        records.append(rec)
        try:
            assert result.returncode == expected_rc, rec
            assert not endpoint.errors, endpoint.errors
            assert len(endpoint.messages) == expected_messages, rec
            assert sum(x['event'] == 'connect' for x in endpoint.events) == expected_connections, rec
            if expected_error:
                assert expected_error in rec['stderr'], rec
            assert 'disposable-app-password' not in rec['stdout'] + rec['stderr']
            for i, item in enumerate(endpoint.messages):
                raw = item['raw']
                msg = email.message_from_bytes(raw, policy=email.policy.default)
                raw.decode('ascii')  # No 8BITMIME, so the complete wire message must be 7-bit safe.
                metadata = {'delivered_to': item['delivered_to'], 'bytes': len(raw),
                            'from': str(msg['From']), 'to': str(msg['To']),
                            'cc': str(msg['Cc']) if msg['Cc'] else None,
                            'subject': str(msg['Subject']), 'content_type': msg.get_content_type(),
                            'body': msg.get_body(preferencelist=('plain',)).get_content().replace('\r\n', '\n'),
                            'attachments': [], 'wire_7bit': True}
                for part in msg.iter_attachments():
                    data = part.get_payload(decode=True)
                    original = FILES / part.get_filename()
                    assert data == original.read_bytes(), part.get_filename()
                    metadata['attachments'].append({'filename': part.get_filename(), 'content_type': part.get_content_type(),
                                                    'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                                                    'matches_original_bytes': True})
                rec['messages'].append(metadata)
                if save:
                    file = OUT / (name + '.eml')
                    file.write_bytes(raw)
                    metadata['raw_message'] = file.name
                if inspect:
                    inspect(msg, metadata)
            if expected_rc:
                assert not rec['stdout'], rec
            rec['result'] = 'pass'
        except Exception as e:
            rec['result'] = 'fail'
            rec['failure'] = str(e)
            raise
        finally:
            (OUT / 'live-mail-results.json').write_text(json.dumps(records, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        print(name + ': ' + rec['result'] + '; exit=' + str(result.returncode) + '; SMTP connections=' + str(expected_connections) + '; messages=' + str(expected_messages), flush=True)
        return rec

TO = 'contact@example.test'
CC1 = 'copy-one@example.test'
CC2 = 'copy-two@example.test'
BODY = 'Señora Muñoz:\nLe envío el cuestionario técnico. ¿Podría revisarlo?'
SUBJECT = 'Cuestionario de instalación: añada sus datos'

def rich_check(msg, data):
    assert data['subject'] == SUBJECT
    assert data['body'].rstrip('\n') == BODY
    assert data['from'] == 'Oficina Técnica Núñez <sender@example.test>'
    assert data['delivered_to'] == [TO, CC1, CC2]
    assert data['cc'] == CC1 + ', ' + CC2
    assert data['content_type'] == 'multipart/mixed'
    assert next(msg.iter_parts()).get_content_type() == 'text/plain'
    assert [a['content_type'] for a in data['attachments']] == ['application/pdf', 'image/png', 'application/octet-stream']
    assert [a['filename'] for a in data['attachments']] == [pdf_path.name, 'plan.png', 'notes.fmunknownext']
    assert not any(p.get_content_type() == 'text/html' for p in msg.walk())

run('attachments-cc-spanish', ['--attach', pdf_path, '--attach', FILES / 'plan.png', '--attach', FILES / 'notes.fmunknownext',
                             '--cc', CC1, '--cc', CC2, TO, SUBJECT, BODY], inspect=rich_check)

def stdin_check(msg, data):
    assert data['subject'] == SUBJECT
    assert data['body'].rstrip('\n') == BODY
    assert data['from'] == 'Nombre del entorno <sender@example.test>'

run('stdin-spanish-c-locale', ['--attach', pdf_path, TO, SUBJECT, '-'],
    env_extra={'LC_ALL': 'C', 'PYTHONUTF8': '0', 'PYTHONCOERCECLOCALE': '0', 'FM_MAIL_FROM_NAME': 'Nombre del entorno'},
    stdin=(BODY + '\n').encode('utf-8'), inspect=stdin_check)

# Existing positional usage remains single-part plain text, even with an irrelevant invalid cap.
(HOME / '.env').write_text((HOME / '.env').read_text().replace('FM_MAIL_FROM_NAME="Oficina Técnica Núñez"\n', ''))
def plain_check(msg, data):
    assert data['from'] == 'sender@example.test'
    assert data['content_type'] == 'text/plain' and not data['attachments'] and data['cc'] is None
    assert data['subject'] == '-dash subject'
    assert data['body'].rstrip('\n') == 'plain body'
run('plain-positional-compatibility', ['--', TO, '-dash subject', 'plain body'], env_extra={'FM_MAIL_MAX_ATTACH_BYTES': '20MB'}, inspect=plain_check)

# Aggregate cap and exact boundary. All refusals must happen before TCP connect.
run('cap-total-above', ['--attach', FILES / 'a.bin', '--attach', FILES / 'b.bin', TO, 'Cap', 'Body'],
    env_extra={'FM_MAIL_MAX_ATTACH_BYTES': '1000'}, expected_rc=1,
    expected_error='attachments total 1100 bytes', expected_messages=0, expected_connections=0)
run('cap-total-exact', ['--attach', FILES / 'a.bin', '--attach', FILES / 'b.bin', TO, 'Cap', 'Body'],
    env_extra={'FM_MAIL_MAX_ATTACH_BYTES': '1100'})
run('cap-default-above', ['--attach', FILES / 'big.bin', TO, 'Default cap', 'Body'], expected_rc=1,
    expected_error='cap of 20971520 bytes', expected_messages=0, expected_connections=0)
for cap in ['0', '-1', '20MB']:
    run('cap-invalid-' + cap.replace('-', 'minus'), ['--attach', pdf_path, TO, 'Bad cap', 'Body'],
        env_extra={'FM_MAIL_MAX_ATTACH_BYTES': cap}, expected_rc=1, expected_error='must be a positive integer',
        expected_messages=0, expected_connections=0)

for name, path, error in [('missing', FILES / 'absent.pdf', 'attachment not found'),
                          ('directory', FILES / 'folder', 'not a regular file'),
                          ('fifo', FILES / 'pipe.pdf', 'not a regular file'),
                          ('unreadable', FILES / 'locked.pdf', 'attachment unreadable')]:
    run('attachment-' + name, ['--attach', pdf_path, '--attach', path, TO, 'Bad file', 'Body'],
        expected_rc=1, expected_error=error, expected_messages=0, expected_connections=0)
for name, args, error in [('attach-missing-value', ['--attach'], '--attach needs a value'),
                          ('cc-missing-value', ['--cc'], '--cc needs a value'),
                          ('unknown-option', ['--bcc', CC1, TO, 'Bad option', 'Body'], 'unknown send option')]:
    run(name, args, expected_rc=1, expected_error=error, expected_messages=0, expected_connections=0)
run('invalid-utf8-stdin', [TO, 'Body encoding', '-'], stdin=b'not utf8 \xff', expected_rc=1,
    expected_error='body is not valid UTF-8', expected_messages=0, expected_connections=0)

# Adversarial RCPT failures both directions, multiple Ccs, and complete rejection.
for name, rejected in [('reject-to', [TO]), ('reject-cc', [CC1]), ('reject-both-copies', [CC1, CC2]), ('reject-all', [TO, CC1, CC2])]:
    accepted = [a for a in [TO, CC1, CC2] if a not in rejected]
    rec = run(name, ['--attach', pdf_path, '--cc', CC1, '--cc', CC2, TO, 'Refusal', 'Body'],
              refused=rejected, expected_rc=1, expected_error='fm-mail send refused recipients:',
              expected_messages=int(bool(accepted)))
    assert all(a in rec['stderr'] for a in rejected)
    assert all(a not in rec['stderr'] for a in accepted)
    assert len([x for x in rec['smtp_events'] if x['event'] == 'MAIL']) == 1
    if accepted:
        assert rec['messages'][0]['delivered_to'] == accepted
run('reject-sole-recipient', [TO, 'Refusal', 'Body'], refused=[TO], expected_rc=1,
    expected_error=TO, expected_messages=0)
print('All public CLI sends completed against the real TLS transport. No product code was substituted.', flush=True)
