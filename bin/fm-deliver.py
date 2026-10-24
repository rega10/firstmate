#!/usr/bin/env python3
# fm-deliver.py - the send engine behind bin/fm-deliver.sh.
#
# Checks one send to one listed contact, runs the preflight over the files,
# sends them through bin/fm-mail.sh, and appends one line to the send log.
# The wrapper owns usage and help and passes every path through the
# environment, never through arguments:
#   FM_DELIVER_HOME          the home whose .env, config/, state/, and
#                            projects/ are never sent
#   FM_DELIVER_DATA          the home's data directory (book, deliverables, log)
#   FM_DELIVER_AWAY          the away or quiet record path, or empty
#   FM_DELIVER_MAIL          bin/fm-mail.sh
#   FM_DELIVER_CONTACTS_PY   bin/fm-contacts.py, whose reader and masking this
#                            engine reuses so the book schema has one owner
# docs/configuration.md "Outbound send" owns the exit codes, the preflight
# rules, the log format, and away-mode enforcement. Standard library only, so it runs
# under the system Python 3.9 with `python3 -I`. It never reads FM_MAIL_PASS:
# the environment passes through to fm-mail.sh unchanged.
import argparse
import datetime
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import re
import stat
import subprocess
import sys
import unicodedata
import zipfile
import zlib

EXIT_ERROR = 1
EXIT_UNLISTED = 2
EXIT_CONFIRM = 3
EXIT_AWAY = 4
EXIT_PREFLIGHT = 5
EXIT_CHANNEL = 6
EXIT_SEND = 7

DEFAULT_MAX_BYTES = 20971520
ALLOWED_EXTENSIONS = ('.pdf', '.png', '.jpg', '.jpeg', '.docx', '.xlsx')
# Home folders whose contents never go out, also refused as any folder name
# inside data/.
NEVER_SENT = ('.env', 'config', 'state', 'projects')
SECRET_PATTERNS = (
    ('private-key header', re.compile(rb'-----BEGIN')),
    ('ghp_ token', re.compile(rb'ghp_')),
    ('github_pat_ token', re.compile(rb'github_pat_')),
    ('AKIA key id', re.compile(rb'AKIA')),
    ('password=', re.compile(rb'password=')),
    ('FM_MAIL_PASS', re.compile(rb'FM_MAIL_PASS')),
    ('Slack token', re.compile(rb'xox[bp]-')),
    ('sk- key', re.compile(rb'sk-\w{20,}')),
)
# Accepted confirmations, already normalized: "yes, send", "send it", and
# "sí, envía" (or "si, envia").
CONFIRMATIONS = (('yes', 'send'), ('send', 'it'), ('si', 'envia'))
DEFAULT_TEXT = {
    'es': ('Le comparto el archivo adjunto.', 'Le comparto los archivos adjuntos.', 'Documento'),
    'en': ('Please find the file attached.', 'Please find the files attached.', 'Document'),
}


class Refusal(Exception):
    """A refused or failed attempt: exit code, logged result, and reason."""

    def __init__(self, code, reason, result='refused'):
        Exception.__init__(self, reason)
        self.code = code
        self.reason = reason
        self.result = result


def die(msg):
    print('fm-deliver: ' + msg, file=sys.stderr)
    sys.exit(EXIT_ERROR)


def env_path(name):
    value = os.environ.get(name, '')
    if not value:
        die('%s is not set; run through bin/fm-deliver.sh' % name)
    return value


def byte_cap(name):
    raw = os.environ.get(name, '')
    if raw == '':
        return DEFAULT_MAX_BYTES
    if not re.fullmatch(r'[0-9]+', raw) or int(raw) <= 0:
        raise Refusal(EXIT_ERROR, '%s must be a positive integer, got: %s' % (name, raw), 'error')
    return int(raw)


def read_text(label, path):
    """The file's UTF-8 text without trailing newlines; empty is an error."""
    try:
        with open(path, 'rb') as fh:
            raw = fh.read()
    except OSError as err:
        raise Refusal(EXIT_ERROR, 'cannot read %s %s: %s' % (label, path, err.strerror or err), 'error')
    return decode_text(label, path, raw)


def decode_text(label, path, raw):
    try:
        text = raw.decode('utf-8').rstrip('\r\n')
    except UnicodeDecodeError:
        raise Refusal(EXIT_ERROR, '%s %s is not valid UTF-8' % (label, path), 'error')
    if not text.strip():
        raise Refusal(EXIT_ERROR, '%s %s is empty' % (label, path), 'error')
    return text


def normalized_words(text):
    """Lowercase, accents stripped (NFKD), punctuation turned into breaks."""
    decomposed = unicodedata.normalize('NFKD', text)
    bare = ''.join(c for c in decomposed if not unicodedata.combining(c))
    return re.sub(r'[\W_]+', ' ', bare.casefold()).split()


def accepted_confirmation(text):
    return tuple(normalized_words(text)) in CONFIRMATIONS


def load_contacts_module(path):
    spec = importlib.util.spec_from_file_location('fm_contacts', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def human_size(n):
    for unit, size in (('MB', 1048576), ('KB', 1024)):
        if n >= size:
            return '%.1f %s (%d bytes)' % (n / size, unit, n)
    return '%d bytes' % n


def within(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


# --- preflight ----------------------------------------------------------------

def pdf_tokens(value):
    tokens = re.findall(
        rb'%[^\r\n]*|\((?:\\.|[^\\()])*\)|<[^<>]*>|<<|>>|'
        rb'/[^\x00\s()<>\[\]{}/%]+|[^\x00\s()<>\[\]{}/%]+|[^\x00\s]', value)
    return [re.sub(rb'#([0-9a-fA-F]{2})', lambda m: bytes([int(m[1], 16)]), token)
            if token.startswith(b'/') else token
            for token in tokens if not token.startswith(b'%')]


def check_pdf_filter(dictionary, content):
    tokens = pdf_tokens(dictionary)
    depth = 0
    positions = []
    for index, token in enumerate(tokens):
        if token in (b'<<', b'['):
            depth += 1
        elif token in (b'>>', b']'):
            depth -= 1
        elif depth == 0 and token == b'/Filter':
            positions.append(index + 1)
        elif token in (b'(', b')'):
            raise Refusal(EXIT_PREFLIGHT, 'PDF stream Filter cannot be resolved')
    if len(positions) != 1 or positions[0] == len(tokens):
        raise Refusal(EXIT_PREFLIGHT, 'PDF stream Filter cannot be resolved')
    value = tokens[positions[0]:]
    if (len(value) >= 3 and value[0].isdigit()
            and value[1].isdigit() and value[2] == b'R'):
        if value[1] != b'0':
            raise Refusal(EXIT_PREFLIGHT, 'PDF stream Filter reference must have generation 0')
        objects = re.findall(rb'(?<!\S)' + value[0] + rb'\s+0\s+obj\b(.*?)\bendobj\b',
                             content, re.DOTALL)
        if len(objects) != 1:
            raise Refusal(EXIT_PREFLIGHT, 'PDF stream Filter reference cannot be resolved')
        value = pdf_tokens(objects[0])
    elif value[0] == b'[':
        try:
            value = value[:value.index(b']') + 1]
        except ValueError:
            raise Refusal(EXIT_PREFLIGHT, 'PDF stream Filter array cannot be resolved')
    else:
        value = value[:1]
    if value not in ([b'/FlateDecode'], [b'[', b'/FlateDecode', b']']):
        raise Refusal(EXIT_PREFLIGHT, 'PDF stream uses an unsupported Filter or filter chain')


def decoded_contents(real, content):
    yield content
    extension = os.path.splitext(real)[1].lower()
    if extension in ('.docx', '.xlsx'):
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            for member in archive.infolist():
                yield archive.read(member)
    elif extension == '.pdf':
        for stream in re.finditer(
                rb'(?:<<((?:(?!\bendobj\b).)*?)>>\s*)?\bstream(?:\r\n|\n|\r)(.*?)endstream',
                content, re.DOTALL):
            if stream[1] is None:
                raise Refusal(EXIT_PREFLIGHT, 'PDF stream Filter dictionary cannot be resolved')
            check_pdf_filter(stream[1], content)
            yield zlib.decompress(stream[2])


def secret_problems(given, real, content):
    matches = set()
    try:
        for decoded in decoded_contents(real, content):
            for name, pattern in SECRET_PATTERNS:
                if pattern.search(decoded):
                    matches.add(name)
    except Refusal as refusal:
        return ['%s: %s' % (given, refusal.reason)]
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, EOFError, zlib.error):
        return ['%s: cannot decode document content for the secret scan' % given]
    return ['%s: matches the secret pattern %s' % (given, name)
            for name, _ in SECRET_PATTERNS if name in matches]


def check_file(given, home, data, read_limit, is_note=False):
    real = os.path.realpath(given)
    record = {'name': os.path.basename(real), 'sha256': None, 'bytes': None}
    if not os.path.lexists(given) or not os.path.exists(real):
        return record, ['%s: not found' % given]
    for folder in NEVER_SENT:
        if within(real, os.path.realpath(os.path.join(home, folder))):
            return record, ['%s: is under the home %s, which is never sent' % (given, folder)]
    data_real = os.path.realpath(data)
    if not within(real, data_real):
        return record, ['%s: is outside data/; only data/<task>/ deliverables are sent' % given]
    parts = os.path.relpath(real, data_real).split(os.sep)
    if len(parts) < 2:
        return record, ['%s: is a data/ bookkeeping file, not a data/<task>/ deliverable' % given]
    if parts[0] == 'outbound':
        return record, ['%s: is in the send log folder data/outbound/' % given]
    if any(part.casefold() == '.env' or part.casefold().startswith('.env.') for part in parts):
        return record, ['%s: is an .env source, which is never sent' % given]
    for part in parts[:-1]:
        if part.casefold() in NEVER_SENT:
            return record, ['%s: is under a %s folder, which is never sent' % (given, part)]
    problems = []
    if not is_note:
        shown = os.path.basename(given) or given
        extensions = {os.path.splitext(shown)[1].lower(), os.path.splitext(real)[1].lower()}
        if '.md' in extensions:
            problems.append('%s: Markdown must be rendered to PDF first' % given)
        elif not extensions.issubset(ALLOWED_EXTENSIONS):
            problems.append('%s: file type not allowed; send only %s' % (given, ' '.join(ALLOWED_EXTENSIONS)))
    try:
        st = os.stat(real)
    except OSError as err:
        return record, problems + ['%s: unreadable (%s)' % (given, err.strerror or err)]
    if not stat.S_ISREG(st.st_mode):
        return record, problems + ['%s: not a regular file' % given]
    if st.st_size > read_limit:
        record['bytes'] = st.st_size
        if is_note:
            problems.append('%s: covering note is above the size cap of %d bytes' % (given, read_limit))
        return record, problems
    try:
        with open(real, 'rb') as fh:
            content = fh.read()
    except OSError as err:
        return record, problems + ['%s: unreadable (%s)' % (given, err.strerror or err)]
    record['sha256'] = hashlib.sha256(content).hexdigest()
    record['bytes'] = len(content)
    record['path'] = real
    problems.extend(secret_problems(given, real, content))
    if is_note and not problems:
        try:
            record['text'] = decode_text('note file', given, content)
        except Refusal as refusal:
            problems.append(refusal.reason)
    return record, problems


def preflight(files, home, data, max_bytes, attach_cap):
    records, problems = [], []
    for given in files:
        record, found = check_file(given, home, data, min(max_bytes, attach_cap))
        records.append(record)
        problems.extend(found)
    total = sum(r['bytes'] or 0 for r in records)
    if total > max_bytes:
        problems.append('the files total %d bytes, above the FM_DELIVER_MAX_BYTES cap of %d bytes'
                        % (total, max_bytes))
    if total > attach_cap:
        problems.append('the files total %d bytes, above the mail attachment cap of %d bytes'
                        ' (FM_MAIL_MAX_ATTACH_BYTES); send them as a link instead, a manual step today'
                        % (total, attach_cap))
    return records, problems, total


# --- the send -----------------------------------------------------------------

def covering_text(contact, names, note):
    if note is not None:
        return note
    one, many, _ = DEFAULT_TEXT[contact['language']]
    return '%s\n%s' % (one if len(names) == 1 else many, ', '.join(names))


def first_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ''


def mask_in(text, address, masked):
    return re.sub(re.escape(address), lambda _: masked, text, flags=re.IGNORECASE)


def print_card(contact, channel, masked, records, subject, body):
    print('confirmation card (dry run, nothing sent)')
    print('recipient: %s - %s' % (contact['name'], contact['role']))
    print('channel: %s' % channel)
    print('address: %s' % masked)
    for record in records:
        print('file: %s - %s' % (record['name'], human_size(record['bytes'])))
    print('delivery: attachment')
    print('subject: %s' % subject)
    print('covering text: %s' % first_line(body))


def send_email(mail, address, masked, subject, body, records):
    argv = [mail, 'send']
    for record in records:
        argv += ['--attach', record['path']]
    argv += ['--', address, subject, '-']
    try:
        done = subprocess.run(argv, input=body.encode('utf-8'), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE)
    except OSError as err:
        raise Refusal(EXIT_SEND, 'cannot run the mail plane: %s' % (err.strerror or err), 'error')
    out = mask_in(done.stdout.decode('utf-8', 'replace'), address, masked)
    err = mask_in(done.stderr.decode('utf-8', 'replace'), address, masked)
    lines = [line.strip() for line in (out + '\n' + err).splitlines() if line.strip()]
    if done.returncode != 0:
        if err.strip():
            sys.stderr.write(err if err.endswith('\n') else err + '\n')
        detail = lines[-1] if lines else 'fm-mail.sh exited %d' % done.returncode
        raise Refusal(EXIT_SEND, 'the mail plane failed: %s' % detail, 'error')
    sent = [line for line in lines if line.startswith('sent to ')]
    return sent[-1] if sent else (lines[-1] if lines else 'sent')


# --- the log ------------------------------------------------------------------

def open_log(data):
    directory = os.path.join(data, 'outbound')
    if not os.path.isdir(directory):
        os.makedirs(directory, exist_ok=True)
        os.chmod(directory, 0o700)
    fd = os.open(os.path.join(directory, 'sends.jsonl'), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    os.fchmod(fd, 0o600)
    return fd


def append_log(fd, entry):
    line = (json.dumps(entry, ensure_ascii=False) + '\n').encode('utf-8')
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        os.write(fd, line)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)


# --- main ---------------------------------------------------------------------

class Parser(argparse.ArgumentParser):
    """Every usage error exits 1; exit 2 means an unlisted contact."""

    def error(self, message):
        self.print_usage(sys.stderr)
        die(message)


def parse(argv):
    parser = Parser(prog='fm-deliver.sh', allow_abbrev=False)
    parser.add_argument('contact_id')
    parser.add_argument('files', nargs='+')
    parser.add_argument('--order-file', required=True)
    parser.add_argument('--confirm-file')
    parser.add_argument('--note-file')
    parser.add_argument('--allow-away', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    return parser.parse_intermixed_args(argv)


def attempt(args, config, confirmation, entry):
    """Run the checks and the send, filling `entry` as facts become known.
    Returns the receipt line (None for a dry run), or raises Refusal."""
    home, data, mail, contacts, max_bytes, attach_cap = config
    # After input and cap validation, collect file metadata before recipient
    # checks so later refusals retain it. Report preflight problems only after
    # the contact, channel, confirmation, and away checks.
    records, problems, total = preflight(args.files, home, data, max_bytes, attach_cap)
    entry['files'] = [{k: r[k] for k in ('name', 'sha256', 'bytes')} for r in records]
    note = None
    if args.note_file:
        note_record, found = check_file(args.note_file, home, data, min(max_bytes, attach_cap), is_note=True)
        problems.extend(found)
        note = note_record.get('text')
    try:
        book = contacts.load(os.path.join(data, 'contacts.json'))
    except contacts.ContactError as err:
        raise Refusal(EXIT_ERROR, 'cannot use the contact book: %s' % err, 'error')
    contact = next((c for c in book['contacts'] if c['id'] == args.contact_id), None)
    if contact is None:
        what = 'an address' if '@' in args.contact_id else 'contact id %r' % args.contact_id
        raise Refusal(EXIT_UNLISTED, '%s is not in the contact book; the contact must be added first'
                      ' with bin/fm-contacts.sh add' % what)
    fields = dict(contacts.CHANNELS)
    channel = next((ch for ch in contact['preferred'] if contact[fields[ch]] is not None), None)
    if channel is None:
        raise Refusal(EXIT_CHANNEL, 'contact %s has no preferred channel with an address' % contact['id'])
    entry['channel'] = channel
    entry['masked_address'] = contacts.masked_address(contact)
    if channel != 'email':
        raise Refusal(EXIT_CHANNEL, 'channel %s not implemented; only email sends today' % channel)
    needs_confirmation = contact['trust'] == 'external'
    if not args.dry_run:
        if confirmation is not None and not accepted_confirmation(confirmation):
            raise Refusal(EXIT_CONFIRM, 'the confirmation is missing: the confirm file holds no accepted'
                          ' confirmation ("yes, send", "send it", or "sí, envía")')
        if needs_confirmation and confirmation is None:
            raise Refusal(EXIT_CONFIRM, 'the confirmation is missing: contact %s is external, so --confirm-file'
                          ' with the owner\'s "yes, send", "send it", or "sí, envía" is required' % contact['id'])
    away = os.environ.get('FM_DELIVER_AWAY', '')
    if away and not args.allow_away:
        raise Refusal(EXIT_AWAY, 'away or quiet mode is active (%s); send only when the owner\'s away words'
                      ' name this send, with --allow-away' % away)
    if problems:
        raise Refusal(EXIT_PREFLIGHT, 'preflight refused the send: ' + '; '.join(problems))
    names = [r['name'] for r in records]
    body = covering_text(contact, names, note)
    subject = '%s: %s' % (DEFAULT_TEXT[contact['language']][2], names[0])
    if args.dry_run:
        print_card(contact, channel, entry['masked_address'], records, subject, body)
        return None
    entry['detail'] = send_email(mail, contact['email'], entry['masked_address'],
                                 subject, body, records)
    entry['result'] = 'sent'
    return 'sent: %s %s %s %d file(s) %d bytes' % (contact['name'], channel, entry['masked_address'],
                                                  len(records), total)


def main(argv):
    # The book, the owner's words, and every printed name are UTF-8 whatever
    # the caller's locale.
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    args = parse(argv)
    data = env_path('FM_DELIVER_DATA')
    log_fd = None
    if not args.dry_run:
        try:
            log_fd = open_log(data)
        except OSError as err:
            die('cannot open the send log: %s' % (err.strerror or err))
    entry = {
        'at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'contact_id': args.contact_id,
        'channel': None,
        'masked_address': None,
        'files': [{'name': os.path.basename(os.path.realpath(f)), 'sha256': None, 'bytes': None}
                  for f in args.files],
        'mode': 'attachment',
        'order': None,
        'confirmation': None,
        'result': None,
        'detail': None,
    }
    code = 0
    try:
        entry['order'] = read_text('order file', args.order_file)
        if args.confirm_file:
            entry['confirmation'] = read_text('confirm file', args.confirm_file)
        config = (
            env_path('FM_DELIVER_HOME'),
            data,
            env_path('FM_DELIVER_MAIL'),
            load_contacts_module(env_path('FM_DELIVER_CONTACTS_PY')),
            byte_cap('FM_DELIVER_MAX_BYTES'),
            byte_cap('FM_MAIL_MAX_ATTACH_BYTES'),
        )
        receipt = attempt(args, config, entry['confirmation'], entry)
    except Refusal as refusal:
        entry['result'] = refusal.result
        entry['detail'] = refusal.reason
        print('fm-deliver: ' + refusal.reason, file=sys.stderr)
        code = refusal.code
        receipt = None
    if log_fd is not None:
        append_log(log_fd, entry)
        os.close(log_fd)
    if receipt:
        print(receipt)
    return code


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
