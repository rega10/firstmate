import concurrent.futures
import datetime
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys

root = Path.cwd()
evidence = Path('/Users/rega1011/.no-mistakes/evidence/01M5MW599VEDQTQQE4YHAHQ8E2')
work = root / '.contact-test-tmp' / 'manual'
work.mkdir(parents=True, exist_ok=False)
cli = root / 'bin/fm-contacts.sh'
base_env = os.environ.copy()
for key in ('FM_HOME', 'FM_DATA_OVERRIDE', 'FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
    base_env.pop(key, None)
logs = {}

def record(group, text):
    logs.setdefault(group, []).append(text)

def run(group, home, args, expected=0, override=None):
    env = dict(base_env, FM_HOME=str(home))
    if override is not None:
        env['FM_DATA_OVERRIDE'] = str(override)
    result = subprocess.run([str(cli)] + args, env=env, input='', text=True, capture_output=True, timeout=20)
    transcript = '$ FM_HOME=<disposable-home> '
    if override is not None:
        transcript += 'FM_DATA_OVERRIDE=<disposable-data> '
    transcript += 'bin/fm-contacts.sh ' + shlex.join(args)
    transcript += '\nexit: %s\nstdout:\n%sstderr:\n%s' % (result.returncode, result.stdout, result.stderr)
    record(group, transcript)
    assert result.returncode == expected, transcript
    return result

def add(group, home, identifier, name, role='Operations', extra=(), trust='internal', language='es'):
    args = ['add', '--id', identifier, '--name', name, '--role', role,
            '--trust', trust, '--language', language, '--added-by', 'Sí, agrega este contacto para el equipo.'] + list(extra)
    return json.loads(run(group, home, args).stdout)

def resolve(group, home, words, code, ids, tier=None):
    result = json.loads(run(group, home, ['resolve'] + words, code).stdout)
    assert [m['id'] for m in result['matches']] == ids, result
    if tier:
        assert all(m['tier'] == tier for m in result['matches']), result
    return result

try:
    home = work / 'book'
    home.mkdir()
    group = 'storage'
    help_text = run(group, home, ['--help']).stdout
    # The emitted help is the public caller protocol, not proof of model behavior.
    assert 'The add command saves immediately' in help_text
    run(group, home, ['list'])
    assert not (home / 'data').exists()
    contact = add(group, home, 'site-it-lead', 'José Pérez', 'Site IT',
                  ['--alias', 'el de sistemas', '--alias', 'José', '--alias', 'the IT lead', '--email', 'jose.perez@example.com'], trust='external')
    book = home / 'data/contacts.json'
    saved = json.loads(book.read_text())
    assert saved == {'version': 1, 'contacts': [contact]}
    assert contact['added'] == datetime.date.today().isoformat()
    assert contact['added_by'] == 'Sí, agrega este contacto para el equipo.'
    assert contact['preferred'] == ['email'] and contact['telegram_chat_id'] is None
    assert stat.S_IMODE(book.stat().st_mode) == 0o600
    assert stat.S_IMODE((home / 'data/.contacts.lock').stat().st_mode) == 0o600
    record(group, 'Persisted contacts.json mode: 0600; lock mode: 0600.\n' + book.read_text())
    shown = json.loads(run(group, home, ['show', 'site-it-lead']).stdout)
    assert shown == contact
    jq = subprocess.run(['jq', '-e', '.version == 1 and (.contacts[0].name == "José Pérez")', str(book)], capture_output=True, text=True, check=True)
    record(group, '$ jq -e <version-and-unicode-check> <disposable-home>/data/contacts.json\n' + jq.stdout)
    ignored = subprocess.run(['git', 'check-ignore', '--no-index', 'data/contacts.json'], capture_output=True, text=True, check=True)
    record(group, '$ git check-ignore --no-index data/contacts.json\n' + ignored.stdout)
    shutil.copyfile(book, evidence / 'sample-contacts.json')

    group = 'resolution'
    add(group, home, 'me', 'Alex Owner', 'Owner', ['--alias', 'me', '--alias', 'mi', '--email', 'alex@example.net'], trust='self', language='en')
    for words in [['EL', 'DE', 'SISTEMAS'], ['Jose'], ['JOSE PEREZ.'], ['the', 'IT', 'lead'], ['la', 'José'], ['me'], ['mi']]:
        identifier = 'me' if words[0] in ('me', 'mi') else 'site-it-lead'
        resolve(group, home, words, 0, [identifier], 'exact')
    resolve(group, home, ['site-it-lead'], 2, [])
    resolve(group, home, ['unlisted.person@example.org'], 2, [])
    # Namesakes whose identifier equals the spoken first name remain ambiguous.
    add(group, home, 'maria', 'María López', 'Finance', ['--email', 'maria.lopez@example.com'])
    add(group, home, 'maria-ruiz', 'María Ruiz', 'Legal', ['--telegram-chat-id', '123456789'])
    ambiguous = resolve(group, home, ['maria'], 3, ['maria-ruiz', 'maria'], 'prefix')
    assert {m['role']: m['masked_address'] for m in ambiguous['matches']} == {'Legal': '***789', 'Finance': 'm***@example.com'}
    resolve(group, home, ['jose', 'per'], 3, ['site-it-lead'], 'prefix')
    result = resolve(group, home, ['Jsoe', 'Perez'], 3, ['site-it-lead'], 'fuzzy')
    assert result['matches'][0]['distance'] == 2
    resolve(group, home, ['Roberto', 'Sanchez'], 2, [])
    add(group, home, 'jose-duplicate', 'José Pérez', 'Vendor', ['--whatsapp', '+19876543210'], trust='external')
    result = resolve(group, home, ['JOSE PEREZ'], 3, ['jose-duplicate', 'site-it-lead'], 'exact')
    assert [(m['role'], m['masked_address']) for m in result['matches']] == [('Vendor', '***210'), ('Site IT', 'j***@example.com')]
    assert all('email' not in m for m in result['matches'])

    group = 'masking'
    channel_home = work / 'channels'
    fixtures = [
        ('email', ['--email', 'person@example.com'], ['telegram', 'email'], 'p***@example.com'),
        ('telegram', ['--telegram-chat-id=-123456789'], ['email', 'telegram'], '***789'),
        ('imessage', ['--imessage', 'team@example.com'], ['telegram', 'imessage'], '***com'),
        ('whatsapp', ['--whatsapp', '+12345678901'], ['imessage', 'whatsapp'], '***901'),
        ('order', ['--email', 'person@example.com', '--whatsapp', '+12345678901'], ['whatsapp', 'email'], '***901'),
        ('unavailable', ['--email', 'person@example.com'], ['telegram'], None),
    ]
    for identifier, addresses, preferences, mask in fixtures:
        extra = list(addresses)
        for pref in preferences:
            extra += ['--preferred', pref]
        add(group, channel_home, identifier, 'Recipient ' + identifier, 'Role ' + identifier, extra)
        result = resolve(group, channel_home, ['Recipient ' + identifier], 0, [identifier], 'exact')
        assert result['matches'][0]['masked_address'] == mask
    add(group, channel_home, 'shared', 'Shared mailbox', 'Support', ['--email', 'person@example.com'])
    listing = run(group, channel_home, ['list']).stdout
    rows = {line.split('\t')[0]: line.split('\t') for line in listing.splitlines()}
    for identifier, _, _, mask in fixtures:
        assert rows[identifier][-1] == (mask or '-')
    assert 'person@example.com' not in listing and '+12345678901' not in listing and '-123456789' not in listing
    assert rows['shared'][-1] == 'p***@example.com'

    group = 'refusals'
    before = book.read_bytes()
    base = ['add', '--id', 'unsafe', '--name', 'Unsafe', '--role', 'Ops', '--trust', 'internal', '--language', 'en', '--email', 'unsafe@example.com', '--added-by', 'Confirmed']
    for flag, bad in [('--trust', 'friend'), ('--language', 'fr'), ('--email', 'bad@@example.com'), ('--id', 'Invalid ID'), ('--name', 'Unsafe\nRecipient')]:
        args = base[:]
        args[args.index(flag) + 1] = bad
        run(group, home, args, 1)
        assert book.read_bytes() == before
    args = base[:]
    args[args.index('--id') + 1] = 'me'
    run(group, home, args, 1)
    assert book.read_bytes() == before
    run(group, home, ['show', 'nonexistent'], 1)
    run(group, home, ['resolve'], 1)
    assert book.read_bytes() == before
    corrupt_home = work / 'corrupt'
    (corrupt_home / 'data').mkdir(parents=True)
    corrupt = corrupt_home / 'data/contacts.json'
    for content in ['{broken', '{"version":2,"contacts":[]}', json.dumps({'version': 1, 'contacts': [contact, contact]})]:
        corrupt.write_text(content)
        run(group, corrupt_home, ['list'], 1)
        run(group, corrupt_home, ['resolve', 'José'], 1)
        run(group, corrupt_home, base, 1)
        assert corrupt.read_text() == content

    group = 'isolation-concurrency'
    isolated = work / 'isolated'
    run(group, isolated, ['list'])
    resolve(group, isolated, ['José'], 2, [])
    assert not isolated.exists()
    override = work / 'override-data'
    override_args = ['add', '--id', 'override', '--name', 'Override Person', '--role', 'Ops', '--trust', 'internal', '--language', 'en', '--email', 'override@example.com', '--added-by', 'Confirmed']
    run(group, isolated, override_args, override=override)
    assert (override / 'contacts.json').exists() and not isolated.exists()
    run(group, isolated, ['show', 'override'], override=override)
    concurrent_home = work / 'concurrent'
    def concurrent_add(i):
        env = dict(base_env, FM_HOME=str(concurrent_home))
        args = ['add', '--id', 'person-' + str(i), '--name', 'Person ' + str(i), '--role', 'Ops', '--trust', 'internal', '--language', 'en', '--email', 'shared@example.com', '--added-by', 'Confirmed concurrently']
        result = subprocess.run([str(cli)] + args, env=env, capture_output=True, text=True, timeout=20)
        return args, result
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(concurrent_add, range(16)))
    for args, result in results:
        record(group, '$ bin/fm-contacts.sh ' + shlex.join(args) + '\nexit: ' + str(result.returncode) + '\n' + result.stdout + result.stderr)
        assert result.returncode == 0
    persisted = json.loads((concurrent_home / 'data/contacts.json').read_text())
    assert len(persisted['contacts']) == 16
    assert {c['id'] for c in persisted['contacts']} == {'person-' + str(i) for i in range(16)}
    assert stat.S_IMODE((concurrent_home / 'data/contacts.json').stat().st_mode) == 0o600
    assert sorted(p.name for p in (concurrent_home / 'data').iterdir()) == ['.contacts.lock', 'contacts.json']
    run(group, concurrent_home, ['list'])
    record(group, 'Persisted book after simultaneous add calls:\n' + json.dumps(persisted, ensure_ascii=False, indent=2))
    print('All six live CLI scenario groups passed. Fixtures will be removed.')
finally:
    for group, entries in logs.items():
        (evidence / ('contact-' + group + '.log')).write_text('\n\n'.join(entries) + '\n', encoding='utf-8')
    shutil.rmtree(work)
