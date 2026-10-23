#!/usr/bin/env python3
# fm-contacts.py - the contact-book engine behind bin/fm-contacts.sh.
#
# Subcommands (the wrapper owns usage and help):
#   add --id ... --name ... ...  Validate and store one contact; print it.
#   list                         One line per contact, addresses masked.
#   show <id>                    Print one full entry as JSON.
#   resolve <spoken words>...    Match spoken words against names and
#                                aliases; print scored matches as JSON.
#
# The book path arrives through FM_CONTACTS_FILE, never through arguments.
# docs/configuration.md "Contact book" owns the schema, the trust meanings, the
# resolve tiers and exit codes, and the masking rule. Standard library only, so
# it runs under the system Python 3.9 with `python3 -I`.
import argparse
import datetime
import fcntl
import json
import os
import re
import sys
import tempfile
import unicodedata

VERSION = 1
TRUST = ('self', 'internal', 'external')
LANGUAGES = ('es', 'en')
# Channel name -> the entry field that holds its address, in default
# preference order.
CHANNELS = (
    ('email', 'email'),
    ('telegram', 'telegram_chat_id'),
    ('imessage', 'imessage'),
    ('whatsapp', 'whatsapp'),
)
CHANNEL_NAMES = tuple(channel for channel, _ in CHANNELS)
ADDRESS_FIELDS = tuple(field for _, field in CHANNELS)
FIELDS = (
    'id', 'name', 'aliases', 'role', 'trust', 'language', 'preferred',
    'email', 'telegram_chat_id', 'imessage', 'whatsapp', 'added', 'added_by',
)
STOPWORDS = frozenset(('el', 'la', 'the'))
TIERS = ('exact', 'prefix', 'fuzzy')
FUZZY_MAX = 2

EXIT_ERROR = 1
EXIT_NO_MATCH = 2
EXIT_CONFIRM = 3

ID_RE = re.compile(r'^[a-z0-9]+(?:-[a-z0-9]+)*$')
DATE_RE = re.compile(r'^\d{4}-\d{2}-\d{2}$')
PHONE_RE = re.compile(r'^\+[0-9]{6,15}$')
TELEGRAM_RE = re.compile(r'^-?[0-9]+$')


class ContactError(Exception):
    """A refusal that is reported as one `fm-contacts:` line and exit 1."""


def die(msg):
    print('fm-contacts: ' + msg, file=sys.stderr)
    sys.exit(EXIT_ERROR)


# --- normalization and scoring ----------------------------------------------

def normalize(text):
    """Lowercase, strip accents (NFKD), turn punctuation into word breaks, and
    drop the articles el, la, and the. Returns the remaining words joined by
    single spaces."""
    decomposed = unicodedata.normalize('NFKD', text)
    bare = ''.join(c for c in decomposed if not unicodedata.combining(c))
    words = re.sub(r'[\W_]+', ' ', bare.casefold()).split()
    return ' '.join(w for w in words if w not in STOPWORDS)


def levenshtein(a, b):
    """Plain dynamic-programming edit distance over characters."""
    if len(a) < len(b):
        a, b = b, a
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (ca != cb),
            ))
        previous = current
    return previous[-1]


def words_prefix_in_order(query_words, candidate_words):
    """True when every query word is a prefix of a distinct candidate word and
    the matched candidate words appear in the same order as the query."""
    position = 0
    for qw in query_words:
        while position < len(candidate_words) and not candidate_words[position].startswith(qw):
            position += 1
        if position == len(candidate_words):
            return False
        position += 1
    return True


def score(query, candidate):
    """Best (tier index, distance) of a normalized query against one
    normalized candidate, or None when it does not match at any tier."""
    if not query or not candidate:
        return None
    if query == candidate:
        return (0, 0)
    distance = levenshtein(query, candidate)
    if words_prefix_in_order(query.split(), candidate.split()):
        return (1, distance)
    if distance <= FUZZY_MAX:
        return (2, distance)
    return None


def candidates(contact):
    return [contact['name']] + list(contact['aliases'])


def masked_address(contact):
    channel_fields = dict(CHANNELS)
    for channel in contact['preferred']:
        address = contact[channel_fields[channel]]
        if address is None:
            continue
        if channel == 'email':
            local, _, domain = address.partition('@')
            return local[:1] + '***@' + domain
        return '***' + address[max(1, len(address) - 3):]
    return None


def resolve(book, words):
    query = ' '.join(words)
    normalized = normalize(query)
    best = {}
    for contact in book['contacts']:
        for text in candidates(contact):
            result = score(normalized, normalize(text))
            if result is not None and (contact['id'] not in best or result < best[contact['id']][0]):
                best[contact['id']] = (result, contact)
    scored = sorted(best.values(), key=lambda item: (item[0], item[1]['id']))
    exact = [item for item in scored if item[0][0] == 0]
    # Resolution is a cascade: an exact name or alias decides on its own, and
    # prefix and fuzzy matches are offered only when nothing matched exactly.
    shown = exact if exact else scored
    matches = [{
        'id': contact['id'],
        'name': contact['name'],
        'role': contact['role'],
        'tier': TIERS[tier],
        'distance': distance,
        'masked_address': masked_address(contact),
    } for (tier, distance), contact in shown]
    print(json.dumps({'query': query, 'normalized': normalized, 'matches': matches}, ensure_ascii=False))
    if len(exact) == 1:
        return 0
    if not matches:
        return EXIT_NO_MATCH
    return EXIT_CONFIRM


# --- validation ---------------------------------------------------------------

def check_text(label, value, required=True):
    if value is None:
        if required:
            raise ContactError('%s is required' % label)
        return
    if not isinstance(value, str):
        raise ContactError('%s must be a string' % label)
    if required and not value.strip():
        raise ContactError('%s must not be empty' % label)
    if any(unicodedata.category(c) == 'Cc' for c in value):
        raise ContactError('%s must not contain control characters' % label)


def valid_email(value):
    if not isinstance(value, str) or any(c.isspace() for c in value) or value.count('@') != 1:
        return False
    local, domain = value.split('@')
    return bool(local) and '.' in domain and not domain.startswith('.') and not domain.endswith('.')


def validate_contact(contact, where):
    """Raise ContactError naming `where` unless `contact` is a schema-valid
    entry. Used for every entry on load and for a new entry before it is
    stored, so a hand edit that breaks the book is refused, never guessed."""
    try:
        if not isinstance(contact, dict):
            raise ContactError('must be an object')
        unknown = sorted(set(contact) - set(FIELDS))
        missing = [f for f in FIELDS if f not in contact]
        if unknown:
            raise ContactError('unknown field(s): %s' % ', '.join(unknown))
        if missing:
            raise ContactError('missing field(s): %s' % ', '.join(missing))
        if not isinstance(contact['id'], str) or not ID_RE.match(contact['id']):
            raise ContactError('id must be a lowercase slug such as site-it-lead, got %r' % (contact['id'],))
        check_text('name', contact['name'])
        if not normalize(contact['name']):
            raise ContactError('name %r has no matchable words' % contact['name'])
        if not isinstance(contact['aliases'], list):
            raise ContactError('aliases must be a list')
        for alias in contact['aliases']:
            check_text('alias', alias)
            if not normalize(alias):
                raise ContactError('alias %r has no matchable words' % alias)
        check_text('role', contact['role'])
        if contact['trust'] not in TRUST:
            raise ContactError('trust must be one of %s, got %r' % ('|'.join(TRUST), contact['trust']))
        if contact['language'] not in LANGUAGES:
            raise ContactError('language must be one of %s, got %r' % ('|'.join(LANGUAGES), contact['language']))
        if contact['email'] is not None and not valid_email(contact['email']):
            raise ContactError('email must look like name@domain.tld with exactly one @, got %r' % (contact['email'],))
        tg = contact['telegram_chat_id']
        if tg is not None and (not isinstance(tg, str) or not TELEGRAM_RE.match(tg)):
            raise ContactError('telegram_chat_id must be a numeric chat id string, got %r' % (tg,))
        im = contact['imessage']
        if im is not None and not (valid_email(im) or (isinstance(im, str) and PHONE_RE.match(im))):
            raise ContactError('imessage must be an email or a +<digits> phone number, got %r' % (im,))
        wa = contact['whatsapp']
        if wa is not None and (not isinstance(wa, str) or not PHONE_RE.match(wa)):
            raise ContactError('whatsapp must be a +<digits> phone number, got %r' % (wa,))
        if not any(contact[f] is not None for f in ADDRESS_FIELDS):
            raise ContactError('needs at least one address (email, telegram_chat_id, imessage, or whatsapp)')
        preferred = contact['preferred']
        if not isinstance(preferred, list):
            raise ContactError('preferred must be a list')
        if len(set(map(str, preferred))) != len(preferred):
            raise ContactError('preferred must not repeat a channel')
        for channel in preferred:
            if channel not in CHANNEL_NAMES:
                raise ContactError('preferred channel must be one of %s, got %r' % ('|'.join(CHANNEL_NAMES), channel))
        if not isinstance(contact['added'], str) or not DATE_RE.match(contact['added']):
            raise ContactError('added must be a YYYY-MM-DD date, got %r' % (contact['added'],))
        try:
            datetime.date.fromisoformat(contact['added'])
        except ValueError:
            raise ContactError('added is not a real date: %r' % contact['added'])
        check_text('added_by', contact['added_by'])
    except ContactError as err:
        raise ContactError('%s: %s' % (where, err))


def check_unique(contacts):
    seen_ids = set()
    for contact in contacts:
        if contact['id'] in seen_ids:
            raise ContactError('duplicate id %r' % contact['id'])
        seen_ids.add(contact['id'])


# --- storage ------------------------------------------------------------------

def book_path():
    path = os.environ.get('FM_CONTACTS_FILE', '')
    if not path:
        die('FM_CONTACTS_FILE is not set; run through bin/fm-contacts.sh')
    return path


def load(path):
    """Read and fully validate the book. A missing file is an empty book."""
    try:
        with open(path, encoding='utf-8') as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {'version': VERSION, 'contacts': []}
    except (OSError, ValueError) as err:
        raise ContactError('cannot read %s: %s' % (path, err))
    if not isinstance(data, dict):
        raise ContactError('%s: top level must be an object' % path)
    version = data.get('version')
    if type(version) is not int or version != VERSION:
        raise ContactError('%s: unsupported version %r; this tool reads version %d only' % (path, version, VERSION))
    unknown = sorted(set(data) - {'version', 'contacts'})
    if unknown:
        raise ContactError('%s: unknown top-level field(s): %s' % (path, ', '.join(unknown)))
    contacts = data.get('contacts')
    if not isinstance(contacts, list):
        raise ContactError('%s: contacts must be a list' % path)
    for index, contact in enumerate(contacts):
        label = contact.get('id') if isinstance(contact, dict) else None
        validate_contact(contact, '%s: contact %d (%s)' % (path, index, label or 'no id'))
    try:
        check_unique(contacts)
    except ContactError as err:
        raise ContactError('%s: %s' % (path, err))
    return data


def save(path, book):
    """Atomic write: a 0600 temp file in the same directory, fsync, rename."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.contacts.', suffix='.tmp', dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(book, fh, ensure_ascii=False, indent=2)
            fh.write('\n')
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def locked(path):
    """Hold an exclusive lock beside the book so concurrent adds serialize."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fh = open(os.path.join(directory, '.contacts.lock'), 'a')
    os.fchmod(fh.fileno(), 0o600)
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    return fh


# --- subcommands --------------------------------------------------------------

class Parser(argparse.ArgumentParser):
    """argparse exits 2 on a usage error, which `resolve` reserves for "no
    match"; every usage error here exits 1 instead."""

    def error(self, message):
        self.print_usage(sys.stderr)
        die(message)


def cmd_add(path, argv):
    parser = Parser(prog='fm-contacts.sh add', allow_abbrev=False)
    parser.add_argument('--id', required=True)
    parser.add_argument('--name', required=True)
    parser.add_argument('--alias', action='append', default=[])
    parser.add_argument('--role', required=True)
    parser.add_argument('--trust', required=True)
    parser.add_argument('--language', required=True)
    parser.add_argument('--email')
    parser.add_argument('--telegram-chat-id')
    parser.add_argument('--imessage')
    parser.add_argument('--whatsapp')
    parser.add_argument('--preferred', action='append')
    parser.add_argument('--added-by', required=True)
    args = parser.parse_args(argv)
    aliases = []
    for alias in args.alias:
        if alias not in aliases:
            aliases.append(alias)
    contact = {
        'id': args.id,
        'name': args.name,
        'aliases': aliases,
        'role': args.role,
        'trust': args.trust,
        'language': args.language,
        'preferred': [],
        'email': args.email,
        'telegram_chat_id': args.telegram_chat_id,
        'imessage': args.imessage,
        'whatsapp': args.whatsapp,
        'added': datetime.date.today().isoformat(),
        'added_by': args.added_by,
    }
    if args.preferred is None:
        contact['preferred'] = [ch for ch, field in CHANNELS if contact[field] is not None]
    else:
        contact['preferred'] = args.preferred
    validate_contact(contact, 'refusing contact %r' % args.id)
    with locked(path):
        book = load(path)
        try:
            check_unique(book['contacts'] + [contact])
        except ContactError as err:
            raise ContactError('refusing contact %r: %s' % (args.id, err))
        book['contacts'].append(contact)
        save(path, book)
    print(json.dumps(contact, ensure_ascii=False, indent=2))
    return 0


def cmd_list(path, argv):
    if argv:
        die('list takes no arguments')
    book = load(path)
    if not book['contacts']:
        print('fm-contacts: the contact book is empty', file=sys.stderr)
    for contact in book['contacts']:
        print('\t'.join((
            contact['id'], contact['name'], contact['role'], contact['trust'],
            masked_address(contact) or '-',
        )))
    return 0


def cmd_show(path, argv):
    if len(argv) != 1:
        die('usage: fm-contacts.sh show <id>')
    book = load(path)
    for contact in book['contacts']:
        if contact['id'] == argv[0]:
            print(json.dumps(contact, ensure_ascii=False, indent=2))
            return 0
    die('no contact with id %r' % argv[0])


def cmd_resolve(path, argv):
    if not argv or not ' '.join(argv).strip():
        die('usage: fm-contacts.sh resolve <spoken words>...')
    return resolve(load(path), argv)


COMMANDS = {
    'add': cmd_add,
    'list': cmd_list,
    'show': cmd_show,
    'resolve': cmd_resolve,
}


def main(argv):
    # The book and every printed entry are UTF-8 whatever the caller's locale.
    sys.stdout.reconfigure(encoding='utf-8')
    if not argv or argv[0] not in COMMANDS:
        die('unknown subcommand %r' % (argv[0] if argv else ''))
    path = book_path()
    try:
        return COMMANDS[argv[0]](path, argv[1:])
    except ContactError as err:
        die(str(err))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
