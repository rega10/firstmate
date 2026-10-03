from pathlib import Path
# Reuse only the disposable setup and CLI driver helpers, without replaying scenarios.
source=Path('.test-summary-live/drive.py').read_text()
exec(source[:source.index('\nregistry(3)')])

# Reproduce the original unavailable-home failure with the base producer.
registry(4000)
old=command(MATE,BASE,['--secondmate-home-summary'])
(MATE/'state/home-summary.json').write_bytes(old)
raw=command(PARENT,ROOT/'bin/fm-fleet-snapshot.sh',['--json'])
m=next(x for x in json.loads(raw)['secondmate_current']['records'] if x['id']=='bytes-mate')
assert m['current']['state']=='unknown' and 'exceeded byte limit' in m['current']['reason'],m
(EVIDENCE/'baseline-overflow-parent.json').write_bytes(raw)
print(json.dumps({'case':'baseline-overflow','serialized_bytes':len(old),'parent_current':m['current']}),flush=True)
raw,d=publish('regression-fixed')
parent('regression-fixed',d)

# Force all captain/held rows to be dropped before the large diagnostics are cut.
for mode in ('captain-cut-to-zero','hold-cut-to-zero'):
    (MATE/'data/projects.md').write_text('')
    orphan=''.join(f'- [ ] orphan-{i:04d}-'+('0'*1000)+' - Orphan (repo: sample) (kind: ship)\n' for i in range(300))
    if mode=='captain-cut-to-zero':
        hold='- [ ] choose-option - Pick an option (repo: sample) (kind: captain) (hold: choose an option) (hold-kind: captain)\n'
        expected='captain_decision'
    else:
        hold='- [ ] await-release - Await release blocked-by: external-release - Vendor release (repo: sample) (kind: ship)\n'
        expected='externally_held'
    (MATE/'data/backlog.md').write_text('## In flight\n'+orphan+'\n## Queued\n'+hold+'\n## Done\n')
    raw,d=publish(mode)
    assert d['state']==expected and not d['valid'],d['state']
    assert d['queued']==[] and d['holds']==[]
    if mode=='captain-cut-to-zero':
        assert d['decisions_open']==[]
        assert any(x['surface']=='summary_bytes' and x['name']=='decisions_open' and x['kept']==0 and x['omitted']==1 for x in d['omitted'])
    parent(mode,d)
    results.append({'scenario':mode+' retains producer classification with zero retained evidence rows','result':'pass'})

# Landed byte omissions must not create a false row-cap disclosure.
for cap in (0,303):
    mode='landed-cap-'+str(cap)
    repo='large-repository-'+('0'*1000)
    (MATE/'data/projects.md').write_text(f'- {repo} [no-mistakes] - App (added 2026-07-01)\n')
    done=''.join(f'- [x] done-{i:04d} - Completed change (repo: {repo}) (kind: ship) (merged 2026-07-01)\n' for i in range(320))
    (MATE/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n'+done)
    raw,d=publish(mode,{'FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME':cap})
    assert any(x['surface']=='summary_bytes' and x['name']=='landed' for x in d['omitted'])
    m,b=parent(mode,d)
    canonical=json.loads((EVIDENCE/(mode+'-parent.json')).read_bytes())
    assert ('bytes-mate' in [x.split('/')[-1] for x in canonical['secondmate_landed']['truncated']]) == False
    assert bool(canonical['secondmate_landed']['truncated'])==(cap!=0),canonical['secondmate_landed']
    assert any(x['surface']=='secondmate home Done capped at the snapshot layer for 1 home(s)' for x in b['omitted'])==(cap!=0)
    print(json.dumps({'case':mode,'retained_landed':len(d['landed']),'total_landed':d['counts']['landed'],
                      'row_cap_disclosure':canonical['secondmate_landed']['truncated']}),flush=True)
    results.append({'scenario':mode+' distinguishes landed byte omissions from genuine row cap','result':'pass'})

# UTF-8 names must be budgeted in bytes while markers count rows.
mode='unicode-projects'
(MATE/'data/projects.md').write_text(''.join(f'- project-{i:04d}-'+('界'*160)+' [no-mistakes] - App (added 2026-07-01)\n' for i in range(400)))
(MATE/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
raw,d=publish(mode)
assert len(command(MATE,BASE,['--secondmate-home-summary']))>262144
marker=next(x for x in d['omitted'] if x['surface']=='summary_bytes' and x['name']=='projects')
assert marker['kept']==len(d['projects']) and marker['kept']+marker['omitted']==400
assert '界' in d['projects'][0]['name']
parent(mode,d)
results.append({'scenario':'UTF-8 project names remain within byte limit with correct row marker','result':'pass'})
(EVIDENCE/'adversarial-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Baseline failure reproduced and all adversarial live scenarios passed.',flush=True)
