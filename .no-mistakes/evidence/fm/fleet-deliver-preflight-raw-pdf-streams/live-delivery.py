"""Drive real delivery scripts against a disposable loopback SMTP TLS endpoint."""
import email, email.policy, hashlib, json, os, pathlib, shutil, socketserver, ssl, subprocess, threading, zlib

ROOT = pathlib.Path.cwd()
LAB = ROOT / '.validation-pdf'
EVIDENCE = pathlib.Path('/Users/rega1011/.no-mistakes/evidence/01M6W21ZMSSFS38BN0F6DP1G21')
HOME = LAB / 'home'
FILES = HOME / 'data' / 'report'
FILES.mkdir(parents=True, exist_ok=True)
(HOME / 'state').mkdir(exist_ok=True)
(HOME / 'config').mkdir(exist_ok=True)
(HOME / 'order.txt').write_text('send to me\n')
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'SSL_CERT'))}
env.update(FM_HOME=str(HOME), TMPDIR=str(LAB / 'tmp'), PYTHONDONTWRITEBYTECODE='1')

# Build complete PDFs with page trees, content streams, Form XObjects and xref tables.
# The main fixture matches the reported 122 FlateDecode streams plus 4 raw Forms.
def pdf(name, mode='mixed', raw_secret=False, compressed_secret=False, filter_field=None, corrupt=False):
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'', b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    pages = []
    for i in range(122 if mode == 'mixed' else 1):
        page_id = len(objects) + 1
        content_id = page_id + 1
        form_id = page_id + 2 if mode == 'mixed' and i < 4 else None
        pages.append(page_id)
        resource = b'/Font << /F1 3 0 R >>'
        if form_id:
            resource += b' /XObject << /Figure %d 0 R >>' % form_id
        objects.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << ' + resource + b' >> /Contents %d 0 R >>' % content_id)
        text = b'password=SENTINELVALUE' if compressed_secret and i == 0 else b'PDF delivery validation'
        payload = b'BT /F1 18 Tf 40 740 Td (' + text + b') Tj ET\n'
        if form_id:
            payload += b'q 1 0 0 1 40 600 cm /Figure Do Q\n'
        field = b'/Filter /FlateDecode' if mode != 'raw' else b''
        if filter_field is not None:
            field = filter_field
        data = zlib.compress(payload) if mode != 'raw' else payload
        if mode == 'raw' and raw_secret:
            data += b'% password=SENTINELVALUE\n'
        if corrupt:
            data = b'not a zlib stream'
        objects.append(b'<< /Length %d ' % len(data) + field + b' >>\nstream\n' + data + b'\nendstream')
        if form_id:
            data = b'0.2 0.4 0.8 rg 0 0 100 60 re f\n'
            if raw_secret and i == 0:
                data += b'% password=SENTINELVALUE\n'
            objects.append(b'<< /Type /XObject /Subtype /Form /BBox [0 0 100 60] /Length %d >>\nstream\n' % len(data) + data + b'\nendstream')
    objects[1] = b'<< /Type /Pages /Count %d /Kids [' % len(pages) + b' '.join(b'%d 0 R' % p for p in pages) + b'] >>'
    content = b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n'
    offsets = [0]
    for n, obj in enumerate(objects, 1):
        offsets.append(len(content))
        content += b'%d 0 obj\n' % n + obj + b'\nendobj\n'
    xref = len(content)
    content += b'xref\n0 %d\n0000000000 65535 f \n' % len(offsets)
    content += b''.join(b'%010d 00000 n \n' % p for p in offsets[1:])
    content += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(offsets), xref)
    path = FILES / (name + '.pdf')
    path.write_bytes(content)
    return path

mixed = pdf('mixed-126-streams')
raw = pdf('raw-only', mode='raw')
flate = pdf('compressed-only', mode='compressed')
raw_leak = pdf('raw-secret', mode='raw', raw_secret=True)
mixed_raw_leak = pdf('mixed-raw-secret', raw_secret=True)
mixed_flate_leak = pdf('mixed-compressed-secret', compressed_secret=True)
assert b'password=' not in mixed_flate_leak.read_bytes()
shutil.copyfile(mixed, EVIDENCE / mixed.name)

# Keep the before-fix executable isolated. All unchanged dependencies are real scripts.
baseline = LAB / 'baseline-bin'
baseline.mkdir(exist_ok=True)
for path in (ROOT / 'bin').iterdir():
    if path.name != 'fm-deliver.py':
        (baseline / path.name).symlink_to(path)
old = subprocess.check_output(['git', 'show', '2059334cc7a85d63d68711c395807593c542b3f7:bin/fm-deliver.py'])
(baseline / 'fm-deliver.py').write_bytes(old)

subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-keyout', str(LAB / 'key.pem'), '-out', str(LAB / 'cert.pem'), '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], check=True, capture_output=True)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(LAB / 'cert.pem', LAB / 'key.pem')
messages, connections, server_errors = [], [], []
class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        connections.append(True)
        self.request.settimeout(5)
        try:
            with context.wrap_socket(self.request, server_side=True) as conn:
                stream = conn.makefile('rwb')
                def reply(text):
                    stream.write(text + b'\r\n')
                    stream.flush()
                reply(b'220 localhost validation SMTP')
                while True:
                    line = stream.readline()
                    if not line:
                        break
                    verb = line.split()[0].upper()
                    if verb in (b'EHLO', b'HELO'):
                        reply(b'250-localhost\r\n250-AUTH PLAIN\r\n250 SIZE 10000000')
                    elif verb == b'AUTH':
                        reply(b'235 Authentication successful')
                    elif verb in (b'MAIL', b'RCPT', b'RSET'):
                        reply(b'250 OK')
                    elif verb == b'DATA':
                        reply(b'354 End with dot')
                        lines = []
                        while True:
                            part = stream.readline()
                            if not part or part == b'.\r\n':
                                break
                            lines.append(part[1:] if part.startswith(b'..') else part)
                        messages.append(b''.join(lines))
                        reply(b'250 Accepted for isolated validation')
                    elif verb == b'QUIT':
                        reply(b'221 Bye')
                        break
                    else:
                        reply(b'502 Unsupported command')
        except Exception as err:
            server_errors.append(str(err))

server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), SMTP)
threading.Thread(target=server.serve_forever, daemon=True).start()
env.update(FM_MAIL_USER='owner@example.test', FM_MAIL_PASS='disposable-password', FM_IMAP_HOST='127.0.0.1', FM_SMTP_HOST='127.0.0.1', FM_SMTP_PORT=str(server.server_address[1]), SSL_CERT_FILE=str(LAB / 'cert.pem'))
subprocess.run([str(ROOT / 'bin/fm-contacts.sh'), 'add', '--id', 'owner', '--name', 'Test Owner', '--role', 'Owner', '--trust', 'self', '--language', 'en', '--email', 'owner@example.test', '--added-by', 'isolated validation fixture'], env=env, check=True, capture_output=True)
records = []
def run(label, path, expected, expected_error=None, before=False, preview=False):
    executable = baseline / 'fm-deliver.sh' if before else ROOT / 'bin/fm-deliver.sh'
    command = [str(executable), 'owner', str(path), '--order-file', str(HOME / 'order.txt')]
    if preview:
        command.append('--dry-run')
    prior = len(messages), len(connections)
    done = subprocess.run(command, env=env, capture_output=True, text=True, timeout=20)
    assert done.returncode == expected, (label, done.returncode, done.stdout, done.stderr)
    if expected_error:
        assert expected_error in done.stderr, (label, done.stderr)
    if expected or preview:
        assert prior == (len(messages), len(connections)), label + ' unexpectedly contacted SMTP'
    else:
        assert len(messages) == prior[0] + 1, label + ' did not deliver'
        message = email.message_from_bytes(messages[-1], policy=email.policy.default)
        attachments = list(message.iter_attachments())
        assert len(attachments) == 1
        assert attachments[0].get_payload(decode=True) == path.read_bytes()
        assert message['To'] == 'owner@example.test'
        (EVIDENCE / (path.stem + '.eml')).write_bytes(messages[-1])
    record = dict(scenario=label, command=' '.join(command), exit_code=done.returncode, stdout=done.stdout.strip(), stderr=done.stderr.strip(), smtp_connections=len(connections)-prior[1], messages_received=len(messages)-prior[0])
    records.append(record)
    print(json.dumps(record), flush=True)

try:
    run('Before fix: mixed 126-stream PDF refuses', mixed, 5, 'PDF stream Filter cannot be resolved', before=True, preview=True)
    run('After fix: mixed 126-stream PDF preview succeeds', mixed, 0, preview=True)
    run('After fix: mixed 126-stream PDF delivers unchanged', mixed, 0)
    run('Raw-only PDF delivers unchanged', raw, 0)
    run('FlateDecode-only PDF still delivers unchanged', flate, 0)
    for label, path in [('Raw stream secret refuses', raw_leak), ('Mixed raw stream secret refuses', mixed_raw_leak), ('Mixed decoded compressed stream secret refuses', mixed_flate_leak)]:
        run(label, path, 5, 'matches the secret pattern password=')
    for name, field in [('unsupported-filter', b'/Filter /ASCII85Decode'), ('filter-chain', b'/Filter [/FlateDecode /FlateDecode]'), ('repeated-filter', b'/Filter /FlateDecode /Filter /FlateDecode'), ('empty-filter', b'/Filter'), ('unresolved-filter', b'/Filter 9999 0 R')]:
        run(name + ' refuses', pdf(name, mode='compressed', filter_field=field), 5, 'PDF stream')
    missing_dictionary = FILES / 'missing-dictionary.pdf'
    missing_dictionary.write_bytes(b'%PDF-1.7\n1 0 obj\nstream\nSafe content\nendstream\nendobj\n%%EOF\n')
    run('Missing stream dictionary refuses', missing_dictionary, 5, 'PDF stream Filter dictionary cannot be resolved')
    run('Corrupt FlateDecode refuses', pdf('corrupt', mode='compressed', corrupt=True), 5, 'cannot decode document content')
    log = (HOME / 'data/outbound/sends.jsonl').read_text()
    assert 'SENTINELVALUE' not in log
    for record in records:
        assert 'SENTINELVALUE' not in record['stderr']
    assert not server_errors, server_errors
    shutil.copyfile(HOME / 'data/outbound/sends.jsonl', EVIDENCE / 'sends.jsonl')
    (EVIDENCE / 'live-results.json').write_text(json.dumps(dict(pdf_streams={'FlateDecode':122,'raw_Form':4}, scenarios=records, received_messages=len(messages), secret_value_omitted_from_output_and_log=True), indent=2) + '\n')
finally:
    server.shutdown()
    server.server_close()
