#!/usr/bin/env python3
"""Exercise activation recovery, rollback and repair against real cached tools."""
import os, subprocess, sys, tempfile, shutil
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
source=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='vlang-stack-') as directory:
    root=Path(directory); prefix=root/'prefix'
    for tool in ['vlang-kakoune','vlang-kak-lsp','vlang-vls']:
        current=(source/'opt'/tool/'current').resolve()
        target=prefix/'opt'/tool/'releases'/current.name
        shutil.copytree(current,target,symlinks=True)
    env={**os.environ,'XDG_CONFIG_HOME':str(root/'config'),'XDG_CACHE_HOME':str(root/'cache'),'VLANG_KAK_PREFIX':str(prefix),'VLANG_KAK_SKIP_PULL':'1'}
    env.pop('VLANG_KAK_CONFIG_HOME',None)
    versions={line.split('=',1)[0]:line.split('=',1)[1] for line in (repo/'tests/release.env').read_text().splitlines() if '=' in line and not line.startswith('#')}
    versions['KAKOUNE_VERSION']=env.get('VLANG_RELEASE_KAKOUNE_REF', versions['KAKOUNE_VERSION'])
    setup=[str(repo/'scripts/setup.sh'),'--prefix',str(prefix),'--kakoune-version',versions['KAKOUNE_VERSION'],'--lsp-version',versions['LSP_VERSION'],'--vls-ref',versions['VLS_REF']]
    def run(args,ok=True):
        result=subprocess.run(args,env=env,text=True,capture_output=True,timeout=180)
        assert (result.returncode==0)==ok,result.stdout+result.stderr
        return result
    run(setup)
    # Distinct activation paths make early per-tool activation observable.
    for tool in ['vlang-kakoune','vlang-kak-lsp','vlang-vls']:
        current=(prefix/'opt'/tool/'current').resolve()
        previous=prefix/'opt'/tool/'releases/cached-previous'
        shutil.copytree(current,previous,symlinks=True)
        link=prefix/'opt'/tool/'current';link.unlink();link.symlink_to(previous)
    links={tool:os.readlink(prefix/'opt'/tool/'current') for tool in ['vlang-kakoune','vlang-kak-lsp','vlang-vls']}
    launcher=(prefix/'bin/kak-v').read_bytes()
    run(setup+['--vls-ref','vlang-kak-test-invalid-ref'],False)
    assert links=={tool:os.readlink(prefix/'opt'/tool/'current') for tool in links}
    assert launcher==(prefix/'bin/kak-v').read_bytes()
    config=prefix/'opt/vlang-kakoune/ide-config/kak/kakrc'
    run(setup+['--pane-mode','off'])
    assert 'v_pane_mode off' in config.read_text()
    run([str(repo/'scripts/rollback.sh'),'--prefix',str(prefix)])
    assert 'v_pane_mode auto' in config.read_text()
    # A missing owned link is repaired; a replacement is preserved.
    plugin=prefix/'opt/vlang-kakoune/ide-config/kak/autoload/vlang.kak'
    plugin.unlink()
    run([str(repo/'scripts/health.sh'),'--repair'])
    assert plugin.resolve()==repo/'rc/vlang.kak'
    release=prefix/'opt/vlang-vls/releases'/versions['VLS_REF']
    added=release/'my-notes.txt';added.write_text('keep me')
    changed=release/'.vlang-commit';changed.write_text('edited')
    run(setup)
    manifest=(prefix/'opt/vlang-state/manifest.tsv').read_text()
    assert str(added) not in manifest
    run([str(repo/'scripts/uninstall.sh'),'--prefix',str(prefix),'--apply'])
    assert added.exists() and changed.exists()
print('ok - complete-stack failed update, rollback, missing-link repair and release ownership preservation')
