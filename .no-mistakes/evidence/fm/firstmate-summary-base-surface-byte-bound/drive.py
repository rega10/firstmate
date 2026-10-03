import os, json, subprocess, shutil
from pathlib import Path
ROOT = Path.cwd()
RUN = ROOT / '.test-summary-live'
EVIDENCE = Path('/Users/rega1011/.no-mistakes/evidence/01M409S7KC2Z9YRNGJQGFPK26V')
ISOLATED_ROOT = RUN / 'fixture-root'
ISOLATED_ROOT.mkdir(exist_ok=True)
PARENT = RUN / 'parent'
MATE = RUN / 'mate'
BASE = ROOT / 'bin/.summary-base-producer.sh'
for home in (PARENT, MATE):
    for name in ('data', 'state', 'config', 'projects', 'bin'):
        (home / name).mkdir(parents=True, exist_ok=True)
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
shutil.copyfile(ROOT / 'AGENTS.md', MATE / 'AGENTS.md')
(MATE / '.fm-secondmate-home').write_text('bytes-mate\n')
(PARENT / 'data/secondmates.md').write_text(f'- bytes-mate - disposable summary domain (home: {MATE}; scope: testing; projects: sample; added 2026-07-13)\n')
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_') or key == 'TMUX':
        env.pop(key)
env.update(FM_ROOT_OVERRIDE=str(ISOLATED_ROOT), TMPDIR=str(RUN/'tmp'),
           FM_SNAPSHOT_NOW='2026-08-01T18:00:00Z', FM_SNAPSHOT_NOW_EPOCH='1785607200',
           FM_BEARINGS_NOW='2026-08-01T18:00:00Z', FM_CREW_STATE_NO_FORGE='1')
results=[]
def command(home, script, args=(), extra=None):
    e=dict(env, FM_HOME=str(home))
    if extra: e.update({k:str(v) for k,v in extra.items()})
    argv=['bash',str(script),*args]
    print('$ FM_HOME='+str(home.relative_to(ROOT))+' '+str(script.relative_to(ROOT))+' '+' '.join(args),flush=True)
    p=subprocess.run(argv,env=e,capture_output=True,timeout=120)
    if p.returncode: raise RuntimeError(p.stderr.decode() or p.stdout.decode())
    return p.stdout

def publish(name, extra=None):
    command(MATE,ROOT/'bin/fm-home-summary-refresh.sh',extra=extra)
    raw=(MATE/'state/home-summary.json').read_bytes()
    d=json.loads(raw)
    assert len(raw)<=262144, (name,len(raw))
    markers=[x for x in d['omitted'] if x['surface']=='summary_bytes']
    for x in markers:
        assert set(x)=={'surface','name','kept','omitted'}, x
        assert x['omitted']>0 and x['kept']>=0, x
    (EVIDENCE/(name+'-summary.json')).write_bytes(raw)
    print(json.dumps({'case':name,'serialized_bytes':len(raw),'state':d['state'],'valid':d['valid'],
                      'counts':d['counts'],'byte_omissions':markers},ensure_ascii=False),flush=True)
    return raw,d

def parent(name, produced):
    raw=command(PARENT,ROOT/'bin/fm-fleet-snapshot.sh',['--json'])
    d=json.loads(raw)
    mate=next(x for x in d['secondmate_current']['records'] if x['id']=='bytes-mate')
    assert mate['provenance']['selected']=='structured-home',mate
    assert mate['current']['state']==produced['state'],(mate['current'],produced['state'])
    assert mate['provenance']['summary_valid']==produced['valid']
    assert mate['invalidity']==produced['invalidity']
    (EVIDENCE/(name+'-parent.json')).write_bytes(raw)
    print(json.dumps({'case':name,'parent_current':mate['current'],'provenance':mate['provenance'],
                      'invalidity':mate['invalidity'],'omitted':mate['omitted']},ensure_ascii=False),flush=True)
    raw=command(PARENT,ROOT/'bin/fm-bearings-snapshot.sh',['--json','--all-queued'])
    bearings=json.loads(raw)
    (EVIDENCE/(name+'-bearings.json')).write_bytes(raw)
    print(json.dumps({'case':name,'bearings_secondmates':bearings['secondmates'],
                      'bearings_omitted':bearings['omitted']},ensure_ascii=False),flush=True)
    toon=command(PARENT,ROOT/'bin/fm-bearings-snapshot.sh')
    (EVIDENCE/(name+'-bearings.txt')).write_bytes(toon)
    return mate,bearings

def registry(count,title='T'):
    (MATE/'data/projects.md').write_text(''.join(f'- active-{i:04d} [no-mistakes] - Active app (added 2026-07-01)\n' for i in range(1,count+1))+
        '- parked-app [direct-PR parked:2026-09-01] - Parked app (added 2026-07-01)\n'+
        '- archived-app [local-only archived] - Archived app (added 2026-07-01)\n')
    (MATE/'data/backlog.md').write_text(f'## In flight\n\n## Queued\n- [ ] q-active - {title} (repo: active-0001) (kind: ship)\n\n## Done\n')

registry(3)
raw,small=publish('small')
old=command(MATE,BASE,['--secondmate-home-summary'])
assert raw==old,'A fitting summary changed from baseline'
assert not any(x['surface']=='summary_bytes' for x in small['omitted'])
print('The small summary matches the baseline byte-for-byte.',flush=True)
results.append({'scenario':'small unchanged summary','result':'pass'})
registry(2000)
raw,d=publish('boundary-calibration')
row_bytes=len(json.dumps(d['projects'][0],ensure_ascii=False,separators=(',',':')).encode())+1
gap=262144-len(raw)
assert gap>0
count=2000+gap//row_bytes
pad=gap%row_bytes
title='T'+'0'*pad
registry(count,title)
raw,d=publish('exact-limit')
assert len(raw)==262144,len(raw)
assert not any(x['surface']=='summary_bytes' for x in d['omitted'])
assert raw==command(MATE,BASE,['--secondmate-home-summary'])
parent('exact-limit',d)
registry(count,title+'0')
raw,d=publish('one-byte-over')
assert len(command(MATE,BASE,['--secondmate-home-summary']))==262145
assert [x['name'] for x in d['omitted'] if x['surface']=='summary_bytes']==['projects']
parent('one-byte-over',d)
results.append({'scenario':'exact limit and one-byte overflow','result':'pass'})
registry(4000)
raw,d=publish('large-registry')
assert {'parked-app','archived-app'}<=set(x['name'] for x in d['projects'])
marker=next(x for x in d['omitted'] if x['surface']=='summary_bytes')
assert marker['kept']==len(d['projects']) and marker['kept']+marker['omitted']==4002
_,b=parent('large-registry',d)
assert any(x['id']=='q-active' and x['owner']=='bytes-mate' for x in b['gates'])
results.append({'scenario':'large registry stays readable and retains lifecycle priority','result':'pass'})

for mode in ('archived','parked','invalid'):
    projects=[]; records=[]
    for i in range(1,301):
        name=f'{mode}-{i:04d}-'+('0'*1000)
        if mode=='archived':
            projects.append(f'- {name} [local-only archived] - App (added 2026-07-01)\n')
            records.append(f'- [x] done-{i:04d} - Done (repo: {name}) (kind: ship) (done 2026-07-01)\n')
        elif mode=='parked':
            projects.append(f'- {name} [direct-PR parked:2026-09-01] - App (added 2026-07-01)\n')
            records.append(f'- [ ] queued-{i:04d} - Next (repo: {name}) (kind: ship)\n')
        else:
            records.append(f'- [ ] {name} - Orphan (repo: sample) (kind: ship)\n')
    (MATE/'data/projects.md').write_text(''.join(projects))
    lines=''.join(records)
    backlog=('## In flight\n'+(lines if mode=='invalid' else '')+'\n## Queued\n'+
             (lines if mode=='parked' else '')+'\n## Done\n'+(lines if mode=='archived' else ''))
    (MATE/'data/backlog.md').write_text(backlog)
    raw,d=publish(mode)
    old=command(MATE,BASE,['--secondmate-home-summary'])
    assert len(old)>262144,(mode,len(old))
    print(json.dumps({'case':mode,'baseline_serialized_bytes':len(old),'baseline_state':json.loads(old)['state']}),flush=True)
    if mode=='invalid':
        assert not d['valid'] and d['invalidity']['kind']=='orphan_in_flight'
        assert {'reason','invalidity.ids'}<=set(x['name'] for x in d['omitted'] if x['surface']=='summary_bytes')
    else:
        assert d['valid']
        assert any(x['surface']=='summary_bytes' and x['name'].endswith('.'+mode+'_projects') for x in d['omitted'])
    parent(mode,d)
    results.append({'scenario':mode+' nested disclosure or diagnostic remains readable','result':'pass'})

for extra_rows in (0,3):
    name='hold-accounting-'+str(extra_rows)
    repo='sample-'+('0'*1000)
    (MATE/'data/projects.md').write_text(f'- {repo} [no-mistakes] - App (added 2026-07-01)\n')
    lines=''.join(f'- [ ] hold-{i:04d} - Captain decision {i} (repo: {repo}) (kind: captain) (hold: choose an option) (hold-kind: captain)\n'
                  for i in range(1,1002+extra_rows))
    (MATE/'data/backlog.md').write_text('## In flight\n\n## Queued\n'+lines+'\n## Done\n')
    tuning={'FM_SNAPSHOT_SECONDMATE_QUEUED':1001,'FM_SNAPSHOT_SECONDMATE_DECISIONS':1001}
    raw,d=publish(name,tuning)
    assert d['state']=='captain_decision' and d['valid']
    assert any(x['surface']=='summary_bytes' and x['name']=='decisions_open' for x in d['omitted'])
    m,b=parent(name,d)
    for surface in ('queued','holds','decisions_open'):
        original=d['counts'][surface]-len(d[surface])
        byte_cut=sum(x['omitted'] for x in d['omitted'] if x['surface']=='summary_bytes' and x['name']==surface)
        expected=max(0,original-byte_cut)
        actual=sum(x.get('count',0) for x in m['omitted'] if x['surface']==surface)
        assert actual==expected,(surface,expected,actual)
        label={'queued':'queued rows','holds':'held rows','decisions_open':'open decisions'}[surface]
        print(json.dumps({'case':name,'surface':surface,'byte_omitted':byte_cut,'row_omitted':actual}),flush=True)
    assert not any('snapshot bound: 1001' in x['surface'] for x in b['omitted'])
    if extra_rows==0:
        assert not any('omitted by snapshot bound:' in x['surface'] and x['surface'].startswith('secondmate bytes-mate ') for x in b['omitted'])
    else:
        assert any(x['surface'].endswith('snapshot bound: 3') for x in b['omitted'])
    results.append({'scenario':name+' preserves captain decision and distinct omission accounting','result':'pass'})
(EVIDENCE/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
print('All live summary producer, parent reader, and Bearings checks passed.',flush=True)
