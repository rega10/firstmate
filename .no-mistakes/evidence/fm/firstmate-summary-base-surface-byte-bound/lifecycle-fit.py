from pathlib import Path
source=Path('.test-summary-live/drive.py').read_text()
exec(source[:source.index('\nregistry(3)')])
(MATE/'data/projects.md').write_text('- parked-app [direct-PR parked:2026-09-01] - App (added 2026-07-01)\n')
rows=''.join(f'- [ ] parked-{i:04d} - Deferred task {i} (repo: parked-app) (kind: ship)\n' for i in range(1500))
(MATE/'data/backlog.md').write_text('## In flight\n\n## Queued\n'+rows+'\n## Done\n')
raw,d=publish('lifecycle-fit')
old=command(MATE,BASE,['--secondmate-home-summary'])
assert raw==old,'Lifecycle-bounded fitting summary changed'
assert not any(x['surface']=='summary_bytes' for x in d['omitted'])
assert d['lifecycle_inventory']
assert any(x['surface']=='lifecycle_inventory' and x['count']>0 for x in d['omitted'])
parent('lifecycle-fit',d)
print(json.dumps({'case':'lifecycle-fit','baseline_byte_equal':raw==old,
                  'retained_lifecycle_inventory':len(d['lifecycle_inventory']),
                  'lifecycle_omissions':[x for x in d['omitted'] if x['surface']=='lifecycle_inventory']}),flush=True)
