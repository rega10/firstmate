import os
from pathlib import Path
import shutil
import subprocess

root=Path.cwd()
evidence=Path('/Users/rega1011/.no-mistakes/evidence/01M4ME82BH54TSD9W4KA9F12MX')
scratch=root/'.startup-validation/local'
scratch.mkdir()
transcript=[]
try:
    for backend in ('herdr','cmux','invalid'):
        home=scratch/backend
        for subdir in ('config','state','data','projects'):
            (home/subdir).mkdir(parents=True)
        env=dict(os.environ)
        for key in list(env):
            if key.startswith(('FM_','HERDR_','CMUX_','GH_','GITHUB_')) or key in ('TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','__CFBundleIdentifier'):
                env.pop(key)
        env.update({'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','FM_HOME':str(home), 'FM_BOOTSTRAP_NETWORK':'skip','FM_BOOTSTRAP_DETECT_ONLY':'1','FM_BACKEND_CMUX_BUNDLE_BIN':str(home/'no-bundle'), 'TMPDIR':str(scratch), 'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','GIT_CEILING_DIRECTORIES':str(scratch)})
        if backend=='herdr':
            env['HERDR_ENV']='1'
        elif backend=='cmux':
            env['CMUX_WORKSPACE_ID']='disposable-workspace'
        else:
            (home/'config/backend').write_text('unknown-validation-backend\n')
        result=subprocess.run(['bash','bin/fm-bootstrap.sh'],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
        transcript.append(f'CASE: {backend}, real bootstrap local-only detect-only, backend CLI deliberately absent from PATH\n$ FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bash bin/fm-bootstrap.sh\nexit={result.returncode}\n{result.stdout}')
        assert result.returncode==0
        if backend=='invalid':
            assert 'BACKEND_INVALID: unknown-validation-backend' in result.stdout
        else:
            assert ('MISSING_MANUAL: herdr' if backend=='herdr' else 'MISSING: cmux') in result.stdout
            assert 'MISSING: tmux' not in result.stdout
        if backend=='cmux':
            assert 'NOTICE: auto-detected cmux runtime' in result.stdout
        transcript.append('PASS: local startup still detects the selected tool requirements and reports actionable configuration problems.\n')
finally:
    (evidence/'live-local-detection.log').write_text('\n'.join(transcript))
    shutil.rmtree(scratch)
print('\n'.join(transcript))
