import datetime as dt
import email
import email.policy
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import socketserver
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path.cwd()
EVIDENCE = Path('/Users/rega1011/.no-mistakes/evidence/01M5NT0QTKZT9EZX3RGMR8DB01')
LAB = ROOT / '.tmp-deliver-live'
HOME = LAB / 'home'
for path in [HOME / 'data/one', HOME / 'data/two', HOME / 'config', HOME / 'state', LAB / 'bucket/private', LAB / 'tmp']:
    path.mkdir(parents=True, exist_ok=True)
cert, key = LAB / 'cert.pem', LAB / 'key.pem'
context = ssl.create_default_context(cafile=str(cert))
received = []
smtp_commands = []
transcript = []
checks = []
processes = []

class SMTP(socketserver.StreamRequestHandler):
    def handle(self):
        self.wfile.write(b'220 localhost disposable SMTP\r\n'); self.wfile.flush()
        while True:
            line = self.rfile.readline()
            if not line: return
            command = line.decode().strip()
            verb = command.split()[0].upper()
            smtp_commands.append(verb)
            if verb in ('EHLO', 'HELO'):
                self.wfile.write(b'250-localhost\r\n250 AUTH PLAIN\r\n')
            elif verb == 'AUTH': self.wfile.write(b'235 2.7.0 Authentication successful\r\n')
            elif verb in ('MAIL', 'RCPT', 'RSET', 'NOOP'): self.wfile.write(b'250 OK\r\n')
            elif verb == 'DATA':
                self.wfile.write(b'354 End with dot\r\n'); self.wfile.flush()
                lines = []
                while True:
                    part = self.rfile.readline()
                    if part == b'.\r\n': break
                    if part.startswith(b'..'): part = part[1:]
                    lines.append(part)
                raw = b''.join(lines)
                received.append(raw)
                self.wfile.write(b'250 2.0.0 Message accepted\r\n')
            elif verb == 'QUIT':
                self.wfile.write(b'221 Bye\r\n'); self.wfile.flush(); return
            else: self.wfile.write(b'500 Unsupported\r\n')
            self.wfile.flush()

class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

server = Server(('127.0.0.1', 0), SMTP)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(str(cert), str(key))
server.socket = tls.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
with socket.socket() as reserve:
    reserve.bind(('127.0.0.1', 0)); s3port = reserve.getsockname()[1]
config = LAB / 'rclone.conf'
config.write_text(f'''[lab]
type = s3
provider = Rclone
endpoint = https://127.0.0.1:{s3port}
access_key_id = disposable-access
secret_access_key = disposable-secret
region = us-east-1
force_path_style = true
''')
os.chmod(config, 0o600)
log = open(LAB / 's3.log', 'w')
s3 = subprocess.Popen(['rclone', '--config', str(config), '--cache-dir', str(LAB / 'cache'), 'serve', 's3', str(LAB / 'bucket'), '--addr', f'127.0.0.1:{s3port}', '--cert', str(cert), '--key', str(key), '--auth-key', 'disposable-access,disposable-secret'], stdout=log, stderr=log)
processes.append(s3)
base = os.environ.copy()
for name in list(base):
    if name.startswith(('FM_', 'RCLONE_', 'AWS_')): base.pop(name)
base.update(FM_HOME=str(HOME), FM_MAIL_USER='sender@example.test', FM_MAIL_PASS='disposable-mail-password', FM_IMAP_HOST='127.0.0.1', FM_SMTP_HOST='127.0.0.1', FM_SMTP_PORT=str(server.server_address[1]), SSL_CERT_FILE=str(cert), TMPDIR=str(LAB / 'tmp'))
wrapper = HOME / 'config/fm-share-b2.sh'
wrapper.write_text('''#!/usr/bin/env bash
set -euo pipefail
case "$1" in
copy)
  if [ -n "${LIVE_MUTATE:-}" ]; then
    printf '%%PDF-1.4 changed password=UNSCANNED\n' > "$FM_HOME/data/one/report.pdf"
    printf '%%PDF-1.4 later changed password=UNSCANNED\n' > "$FM_HOME/data/two/report.pdf"
  fi
  python3 -I -c 'import os,sys; p=sys.argv[1]; print(p, oct(os.stat(p).st_mode&511), oct(os.stat(os.path.dirname(p)).st_mode&511))' "$2" >> "$FM_HOME/snapshots"
  exec rclone --config "$LIVE_RCLONE_CONFIG" --ca-cert "$SSL_CERT_FILE" --cache-dir "$FM_HOME/cache" --retries 1 --low-level-retries 1 copy "$2" "lab:private/$3" ;;
link)
  if [ -n "${LIVE_LINK_FAILURE:-}" ]; then
    exec rclone --config "$LIVE_RCLONE_CONFIG" link "$FM_HOME/data/one/report.pdf" --expire 168h
  fi
  exec rclone --config "$LIVE_RCLONE_CONFIG" --ca-cert "$SSL_CERT_FILE" --cache-dir "$FM_HOME/cache" link "lab:private/$2" "${@:3}" ;;
esac
''')
wrapper.chmod(0o700)
base['LIVE_RCLONE_CONFIG'] = str(config)
base['PATH'] = str(ROOT / '.tmp-deliver-python/python/bin') + os.pathsep + base['PATH']
order = LAB / 'order'; order.write_text('send these disposable reports to the test contact\n')
confirm = LAB / 'confirm'; confirm.write_text('yes, send\n')
first = HOME / 'data/one/report.pdf'
second = HOME / 'data/two/report.pdf'
first.write_bytes(b'%PDF-1.4 safe report A\n')
second.write_bytes(b'%PDF-1.4 safe report A\n')

def invoke(args, extra=None, expected=0):
    env = base.copy(); env.update(extra or {})
    before = dt.datetime.now(dt.timezone.utc)
    done = subprocess.run([str(ROOT / 'bin/fm-deliver.sh')] + [str(v) for v in args], env=env, capture_output=True, text=True, timeout=120)
    after = dt.datetime.now(dt.timezone.utc)
    transcript.append('$ bin/fm-deliver.sh ' + ' '.join(shlex.quote(str(a).replace(str(LAB), '<lab>')) for a in args))
    transcript.append(f'exit: {done.returncode}\n{done.stdout}{done.stderr}')
    assert done.returncode == expected, transcript[-1]
    return done, before, after

def last_entry():
    return json.loads((HOME / 'data/outbound/sends.jsonl').read_text().splitlines()[-1])

def message(label):
    raw = received[-1]
    (EVIDENCE / f'{label}.eml').write_bytes(raw)
    return email.message_from_bytes(raw, policy=email.policy.default)

def assert_links(msg, originals, before, after):
    assert not list(msg.iter_attachments())
    text = msg.get_content()
    urls = re.findall(r'https://\S+', text)
    assert len(urls) == len(originals), text
    entry = last_entry()
    assert entry['mode'] == 'link' and entry['result'] == 'sent'
    for url, data, record in zip(urls, originals, entry['files']):
        parsed = urllib.parse.urlparse(url)
        query = urllib.parse.parse_qs(parsed.query)
        assert query['X-Amz-Expires'] == ['604800'], query
        signing = dt.datetime.strptime(query['X-Amz-Date'][0], '%Y%m%dT%H%M%SZ').replace(tzinfo=dt.timezone.utc)
        assert before.replace(microsecond=0) <= signing <= after
        assert (before + dt.timedelta(days=7)).date().isoformat() <= record['link_expires'] <= (after + dt.timedelta(days=7)).date().isoformat()
        assert record['link_expires'] in text
        assert record['sha256'] == hashlib.sha256(data).hexdigest()
        assert record['bytes'] == len(data)
        with urllib.request.urlopen(url, context=context) as response:
            actual = response.read()
            assert actual == data, (len(actual), len(data))
        unsigned = urllib.parse.urlunparse(parsed._replace(query=''))
        try:
            urllib.request.urlopen(unsigned, context=context)
        except urllib.error.HTTPError as error:
            assert error.code in (400, 401, 403), error.read()
        else: raise AssertionError('unsigned access to private object succeeded')
        tampered = url.replace('X-Amz-Signature=', 'X-Amz-Signature=00')
        try:
            urllib.request.urlopen(tampered, context=context)
        except urllib.error.HTTPError as error:
            assert error.code in (400, 401, 403), error.read()
        else: raise AssertionError('tampered signature succeeded')
        transcript.append(f'Downloaded {record["name"]}: {len(data)} bytes, SHA256 {record["sha256"]}; signed lifetime 604800 seconds; unsigned and tampered requests rejected.')
    return urls

def check(name):
    checks.append(name); transcript.append('Verified: ' + name)

try:
    for _ in range(100):
        try:
            with socket.create_connection(('127.0.0.1', s3port), timeout=.1): break
        except OSError: time.sleep(.05)
    else: raise RuntimeError((LAB / 's3.log').read_text())
    for contact, language, trust in [('internal', 'en', 'internal'), ('external', 'es', 'external')]:
        subprocess.run([str(ROOT / 'bin/fm-contacts.sh'), 'add', '--id', contact, '--name', contact.title() + ' Tester', '--role', 'Disposable recipient', '--trust', trust, '--language', language, '--email', contact + '@example.test', '--added-by', 'isolated live validation'], env=base, check=True, capture_output=True)
    # Default caps and default wrapper: actual 25 MiB source, no override.
    large = HOME / 'data/one/large.pdf'
    with large.open('wb') as file:
        file.write(b'%PDF-1.4 disposable oversized report\n'); file.truncate(25 * 1048576)
    done, before, after = invoke(['internal', large, '--order-file', order])
    msg = message('large-default-link')
    assert_links(msg, [large.read_bytes()], before, after)
    assert 'large.pdf (25.0 MB)' in msg.get_content()
    assert 'Please find the file at this link.' in msg.get_content()
    check('A 25 MiB file uses the default executable wrapper, arrives by email without attachments, and downloads with a private seven-day signature.')
    # Equal names and equal contents get separate destinations.
    originals = [first.read_bytes(), second.read_bytes()]
    done, before, after = invoke(['external', first, second, '--order-file', order, '--confirm-file', confirm], {'FM_MAIL_MAX_ATTACH_BYTES': '30'})
    msg = message('same-name-spanish-links')
    old_urls = assert_links(msg, originals, before, after)
    assert urllib.parse.urlparse(old_urls[0]).path != urllib.parse.urlparse(old_urls[1]).path
    assert msg.get_content().count(f'report.pdf ({len(originals[0])} bytes)') == 2
    assert msg.get_content().count('El enlace vence el') == 2
    check('Two files with identical names and contents receive distinct links and Spanish expiry lines.')
    # Both sources change after scanning but before the real rclone upload.
    done, before, after = invoke(['external', first, second, '--order-file', order, '--confirm-file', confirm], {'FM_MAIL_MAX_ATTACH_BYTES': '30', 'LIVE_MUTATE': '1'})
    msg = message('snapshot-links')
    assert_links(msg, originals, before, after)
    assert b'password=UNSCANNED' in first.read_bytes() and b'password=UNSCANNED' in second.read_bytes()
    assert 'UNSCANNED' not in msg.get_content()
    for line in (HOME / 'snapshots').read_text().splitlines():
        path, filemode, dirmode = line.rsplit(' ', 2)
        assert filemode == '0o600' and dirmode == '0o700'
        assert not Path(path).exists() and not Path(path).parent.exists()
    check('Source mutation during upload cannot change scanned bytes, hashes, sizes, or earlier linked content; private snapshots are removed.')
    first.write_bytes(b'%PDF-1.4 safe replacement with different contents\n')
    done, before, after = invoke(['internal', first, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES': '30'})
    replacement = assert_links(message('replacement-link'), [first.read_bytes()], before, after)[0]
    assert urllib.parse.urlparse(replacement).path != urllib.parse.urlparse(old_urls[0]).path
    for url, data in zip(old_urls, originals):
        with urllib.request.urlopen(url, context=context) as response: assert response.read() == data
    check('A later same-day send of changed content leaves earlier links unchanged.')
    # Attachment boundary uses the real MIME send path, with cap exactly equal to bytes.
    first.write_bytes(originals[0]); second.write_bytes(originals[1])
    done, _, _ = invoke(['internal', first, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES': str(len(originals[0]))})
    msg = message('at-cap-attachment'); attachments = list(msg.iter_attachments())
    assert len(attachments) == 1 and attachments[0].get_payload(decode=True) == originals[0]
    assert last_entry()['mode'] == 'attachment' and 'link_expires' not in last_entry()['files'][0]
    check('A file exactly at the attachment cap remains an attachment with unchanged bytes.')
    # Settings from .env and environment precedence, plus note placement.
    alternate = HOME / 'config/alternate.sh'; shutil.copyfile(wrapper, alternate); alternate.chmod(0o700)
    (HOME / '.env').write_text('FM_DELIVER_SHARE_CMD=config/alternate.sh\nFM_MAIL_MAX_ATTACH_BYTES=20\n')
    note = HOME / 'data/one/note.txt'; note.write_text('Approved report.\n')
    wrapper.chmod(0o600)
    done, before, after = invoke(['internal', first, '--order-file', order, '--note-file', note])
    wrapper.chmod(0o700)
    msg = message('configured-link'); assert_links(msg, [originals[0]], before, after)
    assert msg.get_content().replace('\r\n', '\n').startswith('Approved report.\n\n')
    done, _, _ = invoke(['internal', first, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES': '30'})
    assert len(list(message('environment-cap-attachment').iter_attachments())) == 1
    check('Home settings support a relative override and custom note, while environment settings take priority.')
    (HOME / '.env').unlink()
    # Dry run has no object, SMTP, or audit-log writes.
    count = len(received); log_before = (HOME / 'data/outbound/sends.jsonl').read_bytes(); snapshots = (HOME / 'snapshots').read_bytes()
    done, before, after = invoke(['external', first, second, '--order-file', order, '--dry-run'], {'FM_MAIL_MAX_ATTACH_BYTES': '30'})
    assert 'delivery: link, expires ' in done.stdout and 'nothing sent' in done.stdout
    planned = re.search(r'delivery: link, expires (\d{4}-\d{2}-\d{2})', done.stdout)[1]
    assert (before + dt.timedelta(days=7)).date().isoformat() <= planned <= (after + dt.timedelta(days=7)).date().isoformat()
    assert len(received) == count and (HOME / 'data/outbound/sends.jsonl').read_bytes() == log_before
    assert (HOME / 'snapshots').read_bytes() == snapshots
    (EVIDENCE / 'dry-run-card.txt').write_text(done.stdout)
    check('An oversized dry run shows planned link delivery and expiry without uploading, emailing, or logging.')
    # Guards run before uploads or SMTP.
    for label, args, env, code in [
        ('unconfirmed external contact', ['external', first, second, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30'}, 3),
        ('over total cap', ['internal', first, second, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30', 'FM_DELIVER_MAX_BYTES':'40'}, 5),
        ('missing wrapper', ['internal', first, second, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30'}, 5),
    ]:
        if label == 'missing wrapper': wrapper.chmod(0o600)
        invoke(args, env, code)
        if label == 'missing wrapper': wrapper.chmod(0o700)
        assert len(received) == count and (HOME / 'snapshots').read_bytes() == snapshots
    secret = HOME / 'data/one/secret.pdf'; secret.write_bytes(b'%PDF-1.4 password=DISPOSABLE_SECRET_ONLY\n')
    invoke(['internal', secret, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30'}, 5)
    assert len(received) == count and (HOME / 'snapshots').read_bytes() == snapshots
    assert 'DISPOSABLE_SECRET_ONLY' not in (HOME / 'data/outbound/sends.jsonl').read_text()
    check('Missing confirmation, the total size cap, a missing wrapper, and secret scanning all prevent uploads and mail.')
    # Real command failure: local backend does not support rclone link.
    invoke(['internal', first, second, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30', 'LIVE_LINK_FAILURE':'1'}, 7)
    assert len(received) == count and last_entry()['result'] == 'error'
    check('A real rclone signing failure returns exit 7, records the error, and sends no email.')
    # Fallback when override is unusable.
    done, before, after = invoke(['internal', first, second, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30', 'FM_DELIVER_SHARE_CMD':'config/missing.sh'})
    assert_links(message('fallback-link'), originals, before, after)
    check('An unusable override falls back to the executable default wrapper.')
    # A closed local SMTP endpoint fails after signing, without leaking a URL to the log.
    count = len(received)
    with socket.socket() as unavailable:
        unavailable.bind(('127.0.0.1', 0))
        invoke(['internal', first, second, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30', 'FM_SMTP_PORT':str(unavailable.getsockname()[1])}, 7)
    assert len(received) == count and last_entry()['result'] == 'error'
    check('An SMTP connection failure returns exit 7 and records a masked error without signed URLs.')
    # The real upload endpoint is now stopped to exercise a copy failure.
    s3.terminate(); s3.wait(timeout=10)
    invoke(['internal', first, second, '--order-file', order], {'FM_MAIL_MAX_ATTACH_BYTES':'30'}, 7)
    assert len(received) == count and last_entry()['result'] == 'error'
    for line in (HOME / 'snapshots').read_text().splitlines():
        path, _, _ = line.rsplit(' ', 2)
        assert not Path(path).exists() and not Path(path).parent.exists()
    check('An unavailable upload endpoint returns exit 7, sends no email, and removes the private snapshot.')
    contents = (HOME / 'data/outbound/sends.jsonl').read_text()
    assert 'https://' not in contents and 'X-Amz-' not in contents and 'disposable-mail-password' not in contents
    assert (HOME / 'data/outbound').stat().st_mode & 0o777 == 0o700
    assert (HOME / 'data/outbound/sends.jsonl').stat().st_mode & 0o777 == 0o600
    (EVIDENCE / 'live-sends.jsonl').write_text(contents)
    check('The private audit log records attachment/link mode and per-file expiry without URLs, file contents, or passwords.')
    transcript.append(f'All {len(received)} messages traversed the real fm-mail.sh/fm-mail.py TLS SMTP path. Real rclone uploaded, signed, and served the linked objects.')
    (EVIDENCE / 'live-results.json').write_text(json.dumps({'checks':checks, 'message_count':len(received), 'smtp_commands':smtp_commands}, indent=2))
finally:
    (EVIDENCE / 'live-delivery-transcript.txt').write_text('\n'.join(transcript) + '\n')
    server.shutdown(); server.server_close()
    for process in processes:
        process.terminate()
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    log.close()
    (EVIDENCE / 'local-s3-service.log').write_bytes((LAB / 's3.log').read_bytes())
    shutil.rmtree(LAB)

print('\n'.join(checks))
