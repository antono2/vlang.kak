#!/usr/bin/env python3
"""Discovery only notifies, is rate-limited, and never updates the checkout."""
import os, subprocess, tempfile
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='vlang-discovery-') as directory:
    root=Path(directory);bin=root/'bin';bin.mkdir()
    git=bin/'git'
    git.write_text('''#!/bin/sh
case "$*" in
  *ls-remote*)
    echo request >> "$DISCOVERY_REQUESTS"
    case "$*" in *'refs/tags/v99.0.0^{}'*) printf '%040d\\trefs/tags/v99.0.0^{}\\n' 2 ;;
      *) printf '%040d\\trefs/tags/v99.0.0\\n' 2 ;; esac ;;
  *describe*) echo v1.0.0 ;;
  *rev-parse*) printf '%040d\\n' 1 ;;
  *) echo 'Unexpected mutating Git command' >&2; exit 1 ;;
esac
''');git.chmod(0o755)
    env={**os.environ,'PATH':str(bin)+os.pathsep+os.environ['PATH'],'VLANG_KAK_PREFIX':str(root/'prefix'),'DISCOVERY_REQUESTS':str(root/'requests')}
    command=[str(repo/'scripts/check-updates.sh'),'--background']
    result=subprocess.run(command,env=env,text=True,capture_output=True,check=True)
    assert 'Release available: v99.0.0' in result.stdout
    assert (root/'requests').read_text().count('request')==2
    subprocess.run(command,env=env,text=True,capture_output=True,check=True)
    assert (root/'requests').read_text().count('request')==2
print('ok - optional release discovery is read-only and limited to one check per week')
