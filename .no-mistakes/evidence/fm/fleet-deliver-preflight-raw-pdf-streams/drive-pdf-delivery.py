import email, email.policy, hashlib, json, os, pathlib, re, shutil, socketserver, ssl, subprocess, threading, zlib
ROOT = pathlib.Path.cwd()
WORK = ROOT / '.tmp-pdf-live'
EVIDENCE = pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M6VZP0K7G7CG8H82RP0EXCDC')
HOME = WORK / 'home'
for prior in (HOME, WORK/'baseline-bin'):
    if prior.exists(): shutil.rmtree(prior)
DATA = HOME / 'data' / 'report'
DATA.mkdir(parents=True, exist_ok=True)
for name in ('config', 'state'):
    (HOME / name).mkdir(exist_ok=True)
(WORK / 'order.txt').write_text('Send this disposable PDF to my test contact.\n')
messages = []
class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        self.wfile.write(b'220 localhost disposable SMTP\r\n')
        while True:
            line = self.rfile.readline()
            if not line: return
            command = line.split(None, 1)[0].upper()
            if command in (b'EHLO', b'HELO'):
                self.wfile.write(b'250-localhost\r\n250 AUTH PLAIN\r\n')
            elif command == b'AUTH': self.wfile.write(b'235 authenticated\r\n')
            elif command in (b'MAIL', b'RCPT', b'RSET', b'NOOP'):
                self.wfile.write(b'250 OK\r\n')
            elif command == b'DATA':
                self.wfile.write(b'354 send message\r\n')
                chunks = []
                while True:
                    chunk = self.rfile.readline()
                    if chunk == b'.\r\n': break
                    if not chunk: return
                    chunks.append(chunk[1:] if chunk.startswith(b'..') else chunk)
                messages.append(b''.join(chunks))
                self.wfile.write(b'250 accepted\r\n')
            elif command == b'QUIT':
                self.wfile.write(b'221 closing\r\n'); return
            else: self.wfile.write(b'500 unsupported\r\n')
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def get_request(self):
        sock, address = super().get_request()
        return tls.wrap_socket(sock, server_side=True), address
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(str(WORK/'cert.pem'), str(WORK/'key.pem'))
server = Server(('127.0.0.1', 0), SMTP)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI'))}
env['PATH'] = str(WORK/'python/bin') + os.pathsep + env['PATH']
env.update(FM_HOME=str(HOME), FM_MAIL_USER='sender@example.invalid', FM_MAIL_PASS='disposable-test-only', FM_IMAP_HOST='localhost', FM_SMTP_HOST='localhost', FM_SMTP_PORT=str(server.server_address[1]), SSL_CERT_FILE=str(WORK/'cert.pem'))
transcript = []
def run(args, expected):
    result = subprocess.run([str(a) for a in args], env=env, text=True, capture_output=True)
    transcript.append('$ ' + ' '.join(str(a).replace(str(ROOT)+'/', '') for a in args))
    transcript.append('exit: ' + str(result.returncode))
    transcript.append(result.stdout.strip())
    transcript.append(result.stderr.strip())
    assert result.returncode == expected, (args, result.returncode, result.stderr)
    return result

def pdf(streams):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>', b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> /Contents 4 0 R >>']
    for dictionary, payload in streams:
        objects.append(b'<< /Length %d ' % len(payload) + dictionary + b' >>\nstream\n' + payload + b'\nendstream')
    out = b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n'
    offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(out)); out += b'%d 0 obj\n' % i + obj + b'\nendobj\n'
    start = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % len(offsets)
    out += b''.join(b'%010d 00000 n \n' % off for off in offsets[1:])
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(offsets), start)
    return out
flate = (b'/Filter /FlateDecode', zlib.compress(b'q 1 0 0 rg 10 10 50 50 re f Q'))
raw = (b'/Type /XObject /Subtype /Form /BBox [0 0 10 10]', b'q 0 0 1 rg 0 0 10 10 re f Q')
fixtures = {'raw-only': pdf([(b'', raw[1])]), 'flate-only': pdf([flate]), 'mixed-126': pdf([flate]*122 + [raw]*4)}
fixtures['secret-last-raw'] = pdf([flate]*122 + [raw]*3 + [(raw[0], b'% password=DISPOSABLE_MARKER\n')])
fixtures['secret-last-flate'] = pdf([flate]*121 + [(flate[0], zlib.compress(b'% password=DISPOSABLE_MARKER\n'))] + [raw]*4)
for name, field in {'unsupported': b'/Filter /ASCII85Decode', 'chain': b'/Filter [/FlateDecode /FlateDecode]', 'repeated': b'/Filter /FlateDecode /Filter /FlateDecode', 'empty': b'/Filter', 'unresolved': b'/Filter 999 0 R'}.items():
    fixtures[name] = pdf([(field, flate[1])])
fixtures['corrupt-flate'] = pdf([(flate[0], b'not compressed')])
fixtures['missing-dictionary'] = b'%PDF-1.4\n1 0 obj\nstream\nsafe\nendstream\nendobj\n%%EOF\n'
for name, content in fixtures.items(): (DATA/(name+'.pdf')).write_bytes(content)
run([ROOT/'bin/fm-contacts.sh', 'add', '--id', 'self-test', '--name', 'Disposable Owner', '--role', 'Test owner', '--trust', 'self', '--language', 'en', '--email', 'owner@example.invalid', '--added-by', 'Disposable live validation fixture'], 0)
baseline = WORK/'baseline-bin'
baseline.mkdir()
for path in (ROOT/'bin').iterdir():
    if path.name != 'fm-deliver.py': (baseline/path.name).symlink_to(path)
(baseline/'fm-deliver.py').write_bytes(subprocess.check_output(['git', 'show', '2059334cc7a85d63d68711c395807593c542b3f7:bin/fm-deliver.py']))
def delivery(name, expected, preview=False, base=False):
    count = len(messages)
    args = [(baseline if base else ROOT/'bin')/'fm-deliver.sh', 'self-test', DATA/(name+'.pdf'), '--order-file', WORK/'order.txt']
    if preview: args.append('--dry-run')
    result = run(args, expected)
    if expected or preview: assert len(messages) == count
    else:
        assert len(messages) == count+1
        message = email.message_from_bytes(messages[-1], policy=email.policy.default)
        attachments = list(message.iter_attachments())
        assert len(attachments) == 1
        received = attachments[0].get_payload(decode=True)
        assert received == fixtures[name]
        digest = hashlib.sha256(received).hexdigest()
        transcript.append('SMTP received one byte-identical PDF attachment; SHA-256: '+digest)
        (EVIDENCE/(name+'.eml')).write_bytes(messages[-1])
    return result
try:
    # The unchanged wrapper and base engine reproduce the reported refusal.
    assert 'Filter cannot be resolved' in delivery('mixed-126', 5, preview=True, base=True).stderr
    delivery('flate-only', 0, preview=True, base=True)
    for name in ('raw-only', 'mixed-126', 'flate-only'):
        delivery(name, 0)
        delivery(name, 0, preview=True)
    for name in ('secret-last-raw', 'secret-last-flate'):
        for preview in (False, True):
            result = delivery(name, 5, preview=preview)
            assert 'matches the secret pattern password=' in result.stderr
            assert 'DISPOSABLE_MARKER' not in result.stdout+result.stderr
    for name in ('unsupported', 'chain', 'repeated', 'empty', 'unresolved', 'corrupt-flate', 'missing-dictionary'):
        for preview in (False, True): delivery(name, 5, preview=preview)
    log = (HOME/'data/outbound/sends.jsonl').read_text()
    entries = [json.loads(line) for line in log.splitlines()]
    assert [entry['result'] for entry in entries].count('sent') == 3
    assert [entry['result'] for entry in entries].count('refused') == 9
    assert 'DISPOSABLE_MARKER' not in log
    (EVIDENCE/'delivery-log.jsonl').write_text(log)
    for name in ('mixed-126', 'raw-only'): (EVIDENCE/(name+'.pdf')).write_bytes(fixtures[name])
    transcript.append('All previews sent nothing and wrote no log entries. All rejected sends logged refusal. No secret value appeared in output or logs.')
finally:
    server.shutdown(); server.server_close(); thread.join()
    (EVIDENCE/'live-pdf-delivery.txt').write_text('\n'.join(transcript)+'\n')
print('\n'.join(transcript))
