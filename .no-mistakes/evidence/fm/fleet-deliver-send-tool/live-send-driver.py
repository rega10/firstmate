import base64
import email
import email.policy
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import socketserver
import ssl
import subprocess
import threading
import zipfile
import zlib

ROOT = Path.cwd()
WORK = ROOT / '.test-outbound' / 'live'
EVIDENCE = Path('/Users/rega1011/.no-mistakes/evidence/01M5NGH4HEX9Q5GZW2RAFHEGE2')
WORK.mkdir(parents=True, exist_ok=True)
HOME = WORK / 'home'
for folder in ('data/report', 'state', 'config', 'projects'):
    (HOME / folder).mkdir(parents=True, exist_ok=True)
TASK = HOME / 'data/report'
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(HOME), FM_MAIL_USER='sender@lab.invalid',
           FM_MAIL_PASS='disposable-local-smtp', FM_IMAP_HOST='127.0.0.1',
           FM_SMTP_HOST='127.0.0.1', FM_MAIL_TIMEOUT='5', PYTHONDONTWRITEBYTECODE='1')
config = WORK / 'tls.cnf'
config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
                  '[dn]\nCN=127.0.0.1\n[ext]\nsubjectAltName=IP:127.0.0.1\n'
                  'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n')
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-keyout', str(WORK / 'key.pem'), '-out', str(WORK / 'cert.pem'),
                '-config', str(config)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
env['SSL_CERT_FILE'] = str(WORK / 'cert.pem')
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(str(WORK / 'cert.pem'), str(WORK / 'key.pem'))
messages = []
sessions = []


class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        events = []
        sessions.append(events)
        self.wfile.write(b'220 isolated.lab ESMTP\r\n')
        recipients = []
        while True:
            line = self.rfile.readline()
            if not line:
                break
            command = line.split(None, 1)[0].upper()
            if command == b'EHLO':
                events.append('EHLO over ' + self.connection.version())
                self.wfile.write(b'250-isolated.lab\r\n250-AUTH PLAIN LOGIN\r\n250 SIZE 30000000\r\n')
            elif command == b'AUTH':
                # The sink is disposable and accepts only this run's synthetic credentials.
                data = line.strip().split()
                assert len(data) == 3 and data[1] == b'PLAIN'
                assert base64.b64decode(data[2]) == b'\0sender@lab.invalid\0disposable-local-smtp'
                events.append('AUTH PLAIN accepted disposable credentials')
                self.wfile.write(b'235 Authentication successful\r\n')
            elif command == b'MAIL':
                events.append(line.decode().strip())
                self.wfile.write(b'250 Sender accepted\r\n')
            elif command == b'RCPT':
                events.append(line.decode().strip())
                if b'reject@lab.invalid' in line:
                    self.wfile.write(b'550 Mailbox unavailable\r\n')
                else:
                    recipients.append(line.decode().strip().split(':', 1)[1].strip('<>\r\n'))
                    self.wfile.write(b'250 Recipient accepted\r\n')
            elif command == b'DATA':
                self.wfile.write(b'354 End with a dot\r\n')
                chunks = []
                while True:
                    part = self.rfile.readline()
                    if part == b'.\r\n':
                        break
                    if not part:
                        raise RuntimeError('SMTP DATA truncated')
                    chunks.append(part[1:] if part.startswith(b'..') else part)
                raw = b''.join(chunks)
                messages.append((list(recipients), raw))
                events.append('DATA accepted %d bytes' % len(raw))
                self.wfile.write(b'250 Queued in isolated sink\r\n')
            elif command == b'QUIT':
                self.wfile.write(b'221 Bye\r\n')
                break
            elif command == b'RSET':
                recipients = []
                self.wfile.write(b'250 Reset\r\n')
            else:
                raise RuntimeError('Unexpected SMTP command ' + repr(command))


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    def get_request(self):
        sock, address = super().get_request()
        return context.wrap_socket(sock, server_side=True), address


server = Server(('127.0.0.1', 0), SMTP)
env['FM_SMTP_PORT'] = str(server.server_address[1])
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
transcript = []
results = []
log = HOME / 'data/outbound/sends.jsonl'


def lines():
    return [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []


def call(name, args, expected=0, sent=0, extra=None, dry=False, logged=True):
    if '--order-file' in args and args[args.index('--order-file') + 1] == WORK / 'order.txt':
        files = []
        for arg in args[1:]:
            if str(arg).startswith('--'):
                break
            files.append(Path(arg).name)
        (WORK / 'order.txt').write_text('mándale ' + ', '.join(files) + ' a ' + str(args[0]) + '\n')
    before, before_mail, before_connections = len(lines()), len(messages), len(sessions)
    run_env = dict(env)
    run_env.update(extra or {})
    done = subprocess.run([str(ROOT / 'bin/fm-deliver.sh')] + list(map(str, args)),
                          env=run_env, capture_output=True, text=True, timeout=20)
    transcript.extend(['\nSCENARIO: ' + name, '$ FM_HOME=<disposable-home> bin/fm-deliver.sh ' +
                       shlex.join([str(a).replace(str(WORK), '<lab>') for a in args]),
                       'exit: ' + str(done.returncode), done.stdout.rstrip(), done.stderr.rstrip(),
                       'SMTP messages: %d -> %d; connections: %d -> %d' %
                       (before_mail, len(messages), before_connections, len(sessions))])
    assert done.returncode == expected, (name, done.returncode, done.stdout, done.stderr)
    assert len(messages) == before_mail + sent, (name, 'unexpected SMTP delivery')
    assert len(lines()) == before + (0 if dry or not logged else 1), (name, 'log count')
    if not sent and expected not in (7,):
        assert len(sessions) == before_connections, (name, 'unsafe attempt reached SMTP')
    if logged and not dry:
        entry = lines()[-1]
        assert entry['result'] == ('sent' if sent else 'error' if expected in (1, 7) else 'refused')
        transcript.append('persisted attempt: ' + json.dumps(entry, ensure_ascii=False))
    results.append({'name': name, 'exit': done.returncode, 'sent': sent, 'live': True})
    return done


def add(identifier, trust='internal', language='en', address=None, extra=()):
    argv = [str(ROOT / 'bin/fm-contacts.sh'), 'add', '--id', identifier, '--name', identifier,
            '--role', 'Lab reviewer', '--trust', trust, '--language', language,
            '--email', address or identifier + '@lab.invalid', '--added-by', 'isolated test'] + list(extra)
    done = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
    transcript.extend(['contact add: ' + identifier, 'exit: ' + str(done.returncode), done.stderr.rstrip()])
    return done


def pdf(text, filter_value=b'/FlateDecode', extra=b'', broken=False):
    payload = b'not-zlib' if broken else zlib.compress(text)
    content = b'BT /F1 12 Tf 40 80 Td (' + text + b') Tj ET'
    payload = b'not-zlib' if broken else zlib.compress(content)
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
               b'<< /Length %d /Filter ' % len(payload) + filter_value + b' >>\nstream\n' + payload + b'\nendstream',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    data = b'%PDF-1.4\n'
    offsets = [0]
    for n, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += str(n).encode() + b' 0 obj\n' + obj + b'\nendobj\n'
    data += extra
    offset = len(data)
    data += b'xref\n0 6\n0000000000 65535 f \n'
    for position in offsets[1:]:
        data += b'%010d 00000 n \n' % position
    return data + b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n' + str(offset).encode() + b'\n%%EOF\n'


try:
    for identifier, trust, language in [('external', 'external', 'es'), ('internal', 'internal', 'en'),
                                         ('self', 'self', 'en'), ('reject', 'internal', 'en')]:
        assert add(identifier, trust, language).returncode == 0
    assert add('fallback', extra=('--preferred', 'telegram', '--preferred', 'email')).returncode == 0
    assert add('unsupported', extra=('--telegram-chat-id', '12345', '--preferred', 'telegram', '--preferred', 'email')).returncode == 0
    report = TASK / 'report.pdf'
    report.write_bytes(pdf(b'Disposable report for isolated delivery.'))
    image = TASK / 'plan.png'
    image.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9X8AAAAASUVORK5CYII='))
    order = WORK / 'order.txt'
    words = 'mándale el reporte a external'
    order.write_text(words + '\n')
    confirm = WORK / 'confirm.txt'
    confirm.write_text('Sí, envía.\n')
    note = TASK / 'note.txt'
    note.write_text('Le comparto los documentos de prueba.\nSegunda línea confidencial de prueba.\n')
    base = [report, '--order-file', order]
    done = call('external preview shows required fields and sends nothing',
                ['external', report, image, '--order-file', order, '--note-file', note, '--dry-run'], dry=True)
    for value in ('recipient: external - Lab reviewer', 'channel: email', 'address: e***@lab.invalid',
                  'file: report.pdf', 'file: plan.png', 'delivery: attachment',
                  'subject: Documento: report.pdf', 'covering text: Le comparto los documentos de prueba.'):
        assert value in done.stdout
    assert 'confirmation:' not in done.stdout and 'Segunda' not in done.stdout
    call('external confirmed send reaches TLS SMTP with both attachments',
         ['external', report, image, '--order-file', order, '--confirm-file', confirm, '--note-file', note], sent=1)
    recipients, raw = messages[-1]
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    assert recipients == ['external@lab.invalid'] and msg['To'] == 'external@lab.invalid'
    assert msg['Subject'] == 'Documento: report.pdf'
    assert msg.get_body(preferencelist=('plain',)).get_content().replace('\r\n', '\n').rstrip('\n') == note.read_text().rstrip('\n')
    attachments = list(msg.iter_attachments())
    for item, path in zip(attachments, (report, image)):
        assert item.get_filename() == path.name and item.get_payload(decode=True) == path.read_bytes()
    assert len(attachments) == 2
    entry = lines()[-1]
    assert msg['Message-ID'] in entry['detail'] and entry['order'] == order.read_text().rstrip('\n') and entry['confirmation'] == 'Sí, envía.'
    for record, path in zip(entry['files'], (report, image)):
        assert record == {'name': path.name, 'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    assert (log.stat().st_mode & 0o777) == 0o600 and (log.parent.stat().st_mode & 0o777) == 0o700
    (EVIDENCE / 'received-external.eml').write_bytes(raw)
    done = call('new internal contact preview omits a trust-only confirmation verdict',
                ['internal'] + base + ['--dry-run'], dry=True)
    assert 'confirmation:' not in done.stdout and 'trust' not in done.stdout
    for identifier in ('internal', 'self', 'fallback'):
        call(identifier + ' sends on order alone using available preferred email', [identifier] + base, sent=1)
        m = email.message_from_bytes(messages[-1][1], policy=email.policy.default)
        assert m['Subject'] == 'Document: report.pdf'
        assert 'Please find the file attached.' in m.get_body().get_content()
    photo = TASK / 'photo.jpg'
    subprocess.run(['sips', '-s', 'format', 'jpeg', str(image), '--out', str(photo)],
                   check=True, capture_output=True)
    for extension in ('.jpg', '.jpeg'):
        path = TASK / ('photo' + extension)
        if path != photo:
            shutil.copy2(photo, path)
        call('JPEG attachment sends: ' + extension, ['internal', path, '--order-file', order], sent=1)
        m = email.message_from_bytes(messages[-1][1], policy=email.policy.default)
        item = list(m.iter_attachments())[0]
        assert item.get_content_type() == 'image/jpeg' and item.get_payload(decode=True) == path.read_bytes()
    call('unsupported preferred channel refuses instead of silently using email', ['unsupported'] + base, expected=6)
    for identifier in ('unknown', 'external@lab.invalid'):
        call('unlisted recipient refuses: ' + identifier, [identifier] + base, expected=2)
    call('external contact requires confirmation', ['external'] + base, expected=3)
    for answer in ('OK', 'sure', "no, don't send it", 'Should I say send it?', 'yes, send later', 'please send it'):
        confirm.write_text(answer)
        call('external rejects confirmation: ' + answer, ['external'] + base + ['--confirm-file', confirm], expected=3)
    for answer in ('YES, SEND!', 'Send it.', 'Sí, envía.'):
        confirm.write_text(answer)
        call('external accepts complete confirmation: ' + answer, ['external'] + base + ['--confirm-file', confirm], sent=1)
    confirm.write_text('Should I say send it?')
    call('internal also rejects an explicitly supplied invalid confirmation', ['internal'] + base + ['--confirm-file', confirm], expected=3)
    for flag, content in (('.afk', ''), ('.afk-contract', 'version: 2\nmode: quiet\nwords: |-\n  send report.pdf to internal\n')):
        marker = HOME / 'state' / flag
        marker.write_text(content)
        call('away or quiet blocks third-party send: ' + flag, ['internal'] + base, expected=4)
        call('specific-send override permits isolated send: ' + flag, ['internal'] + base + ['--allow-away'], sent=1)
        marker.unlink()
    # Validate new and hand-edited recipient records through the public tools.
    for address in ('ops@lab.invalid,postmaster', 'ops@lab.invalid;postmaster', 'ops @lab.invalid',
                    '<ops@lab.invalid>', 'ops@@lab.invalid', '@lab.invalid', 'ops@lab', 'ops@lab.invalid\npostmaster'):
        assert add('malformed', address=address).returncode == 1
    book_path = HOME / 'data/contacts.json'
    original = book_path.read_bytes()
    book = json.loads(original)
    book['contacts'][0]['email'] = 'ops@lab.invalid,postmaster'
    book_path.write_text(json.dumps(book))
    for dry in (False, True):
        call('stored multi-recipient address refuses ' + ('preview' if dry else 'send'),
             ['external'] + base + (['--dry-run'] if dry else []), expected=1, dry=dry)
    book_path.write_bytes(original)
    # Adversarial location checks include symlinks for attachment and note.
    for folder in ('config', 'state', 'projects'):
        path = HOME / folder / 'private.pdf'
        path.write_bytes(report.read_bytes())
        link = TASK / ('link-' + folder + '.pdf')
        link.symlink_to(path)
        for source in (path, link):
            call('forbidden attachment source ' + str(source.relative_to(HOME)), ['internal', source, '--order-file', order], expected=5)
            call('forbidden note source ' + str(source.relative_to(HOME)), ['internal'] + base + ['--note-file', source], expected=5)
    for relative in ('.env', 'data/report/.env.local', 'data/top.pdf', 'data/outbound/private.pdf', 'data/report/state/private.pdf'):
        path = HOME / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('Private fixture content')
        call('forbidden source ' + relative, ['internal', path, '--order-file', order], expected=5)
    for name in ('report.md', 'notes.txt'):
        path = TASK / name
        path.write_text('Public test text')
        call('unsupported attachment type ' + name, ['internal', path, '--order-file', order], expected=5)
    call('attachment outside data refuses', ['internal', order, '--order-file', order], expected=5)
    for setting in ('FM_DELIVER_MAX_BYTES', 'FM_MAIL_MAX_ATTACH_BYTES'):
        call('above cap refuses with manual-link guidance: ' + setting, ['internal'] + base,
             expected=5, extra={setting: str(report.stat().st_size - 1)})
        call('exact cap permits send: ' + setting, ['internal'] + base, sent=1,
             extra={setting: str(report.stat().st_size)})
    for token in ('-----BEGIN PRIVATE KEY-----', 'ghp_TESTLEAK', 'github_pat_TESTLEAK',
                  'AKIATESTLEAK', 'password=TESTLEAK', 'FM_MAIL_PASS=TESTLEAK',
                  'xoxb-TESTLEAK', 'sk-TESTLEAKabcdefghijklmn'):
        leak = TASK / 'raw-secret.png'
        leak.write_bytes(image.read_bytes() + token.encode())
        done = call('raw secret refuses: ' + token.split('TESTLEAK')[0], ['internal', leak, '--order-file', order], expected=5)
        assert 'TESTLEAK' not in done.stdout + done.stderr
    for extension in ('docx', 'xlsx'):
        for secret in (False, True):
            archive = TASK / (('leak' if secret else 'safe') + '.' + extension)
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
                z.writestr('[Content_Types].xml', '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
                z.writestr('document.xml', '<document>Public fixture</document>')
                z.writestr('extra/member.xml', 'password=TESTLEAK' if secret else 'Safe final member')
            call('compressed final archive member ' + ('refuses ' if secret else 'sends ') + extension,
                 ['internal', archive, '--order-file', order], expected=5 if secret else 0, sent=0 if secret else 1)
        archive.write_bytes(b'not a zip')
        call('broken archive refuses ' + extension, ['internal', archive, '--order-file', order], expected=5)
    for label, filter_value, extra in (
        ('direct', b'/FlateDecode', b''), ('array', b'[/FlateDecode]', b''),
        ('indirect-name', b'9 0 R', b'9 0 obj\n/FlateDecode\nendobj\n'),
        ('indirect-array', b'9 0 R', b'9 0 obj\n[/FlateDecode]\nendobj\n'),
        ('escaped', b'/Flate#44ecode', b'')):
        for secret in (False, True):
            path = TASK / ('filter-' + label + '.pdf')
            path.write_bytes(pdf(b'password=TESTLEAK' if secret else b'Safe test document', filter_value, extra))
            call('PDF filter ' + label + (' secret refuses' if secret else ' safe sends'),
                 ['internal', path, '--order-file', order], expected=5 if secret else 0, sent=0 if secret else 1)
    for label, value, extra, broken in (
        ('missing-reference', b'9 0 R', b'', False),
        ('indirect-chain', b'9 0 R', b'9 0 obj\n[/FlateDecode /FlateDecode]\nendobj\n', False),
        ('other-filter', b'/ASCII85Decode', b'', False),
        ('array-reference', b'[9 0 R]', b'9 0 obj\n/FlateDecode\nendobj\n', False),
        ('broken-stream', b'/FlateDecode', b'', True)):
        path = TASK / ('unsupported-' + label + '.pdf')
        path.write_bytes(pdf(b'Public test', value, extra, broken))
        call('unsupported PDF representation refuses: ' + label, ['internal', path, '--order-file', order], expected=5)
    call('compressed secret in PDF covering note refuses', ['internal'] + base +
         ['--note-file', TASK / 'filter-indirect-name.pdf'], expected=5)
    call('unsupported PDF filter also refuses preview', ['internal', TASK / 'unsupported-other-filter.pdf',
         '--order-file', order, '--dry-run'], expected=5, dry=True)
    for content in ('password=TESTLEAK', 'ghp_TESTLEAK', ''):
        note.write_text(content)
        call('unsafe or empty covering note refuses', ['internal'] + base + ['--note-file', note], expected=5)
    note.write_bytes(b'\xff')
    call('invalid UTF-8 covering note refuses', ['internal'] + base + ['--note-file', note], expected=5)
    for field in ('order', 'confirm', 'note'):
        args = ['internal'] + ([report, '--order-file', WORK / 'missing'] if field == 'order' else
                              base + ['--' + field + '-file', TASK / 'missing'])
        call('unreadable ' + field + ' logs the attempt', args, expected=5 if field == 'note' else 1)
    for setting in ('FM_DELIVER_MAX_BYTES', 'FM_MAIL_MAX_ATTACH_BYTES'):
        call('invalid cap logs attempt: ' + setting, ['internal'] + base, expected=1, extra={setting: 'invalid'})
    call('removed subject option refuses argument parsing', ['internal'] + base + ['--subject', 'Override'], expected=1, logged=False)
    call('SMTP rejection reports masked error and logs the failure', ['reject'] + base, expected=7)
    assert 'r***@lab.invalid' in lines()[-1]['detail'] and 'reject@lab.invalid' not in lines()[-1]['detail']
    call('unavailable SMTP reports connection failure and logs it', ['internal'] + base, expected=7,
         extra={'FM_SMTP_PORT': '1'})
    contents = log.read_text()
    for sensitive in ('TESTLEAK', 'disposable-local-smtp', 'Segunda línea'):
        assert sensitive not in contents, ('audit disclosure', sensitive)
    for entry in lines():
        if entry['contact_id'] == 'external':
            assert 'external@lab.invalid' not in json.dumps(entry, ensure_ascii=False)
    ids = [email.message_from_bytes(raw, policy=email.policy.default)['Message-ID'] for _, raw in messages]
    assert len(ids) == len(set(ids))
    shutil.copy2(log, EVIDENCE / 'live-sends.jsonl')
    (EVIDENCE / 'live-smtp-sessions.json').write_text(json.dumps(sessions, indent=2))
    transcript.append('\nAll live CLI and SMTP assertions passed. Messages received: %d' % len(messages))
finally:
    server.shutdown()
    server.server_close()
    (EVIDENCE / 'live-send-transcript.txt').write_text('\n'.join(transcript) + '\n')
    (EVIDENCE / 'live-send-cases.json').write_text(json.dumps(results, indent=2))

print('Live send validation passed: %d cases, %d actual TLS SMTP deliveries.' % (len(results), len(messages)))
