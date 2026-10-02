#!/usr/bin/env python3
"""Exercise activation recovery, rollback and repair against real cached tools."""
import os, subprocess, sys, tempfile, shutil, signal, time
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
    # Instrument a private source copy, keeping production scripts free of test hooks.
    interrupted_repo=root/'interrupted-source'
    shutil.copytree(repo,interrupted_repo,ignore=shutil.ignore_patterns('.git','__pycache__'))
    impl=interrupted_repo/'scripts/setup-impl.sh'
    original_impl=impl.read_text()
    # Model release selection from a revision with the older, shorter rollback
    # script. Recovery must keep running after checkout replaces its own source.
    new_rollback=(interrupted_repo/'scripts/rollback.sh').read_text()
    old_rollback=subprocess.check_output(['git','-C',str(repo),'show','v1.2.0:scripts/rollback.sh'],text=True)
    (interrupted_repo/'scripts/rollback.sh').write_text(old_rollback)
    def git(*args):
        return subprocess.check_output(['git','-C',str(interrupted_repo),'-c','user.name=Recovery Test',
                                       '-c','user.email=recovery@example.invalid','-c','commit.gpgsign=false',*args],text=True)
    git('init','-q');git('add','.');git('commit','-qm','previous release')
    old_revision=git('rev-parse','HEAD').strip()
    marker=root/'activation-barrier'
    barrier='\n    touch '+str(marker)+"\n    while :; do sleep 1; done\n"
    personal=root/'config/kak/vlang-user.kak'
    personal.parent.mkdir(parents=True,exist_ok=True)
    personal.write_text('# personal settings before interruption\n')
    kakrc_target=root/'personal-kakrc'
    kakrc_target.write_text('# original personal kakrc\n')
    kakrc=personal.parent/'kakrc'
    kakrc.symlink_to(kakrc_target)
    for phase in ['before','partial']:
        marker.unlink(missing_ok=True)
        anchor='# All builds succeeded. Switch the prepared versions and generate launchers.' if phase=='before' else '    mv -Tf "$root/current.next" "$root/current"'
        replacement=barrier+anchor if phase=='before' else anchor+'\n    if [ "$tool" = kakoune ]; then '+barrier+'    fi'
        assert original_impl.count(anchor)==1
        impl.write_text(original_impl.replace(anchor,replacement))
        (interrupted_repo/'scripts/rollback.sh').write_text(new_rollback)
        git('add','.');git('commit','-qm','candidate '+phase)
        command=[str(interrupted_repo/'scripts/update.sh'),*setup[1:],'--integrate']
        log=(root/('interrupted-'+phase+'.log')).open('w')
        process=subprocess.Popen(command,env={**env,'VLANG_KAK_PREVIOUS_PLUGIN_REVISION':old_revision},stdout=log,stderr=log,start_new_session=True)
        try:
            deadline=time.monotonic()+120
            while not marker.exists() and process.poll() is None and time.monotonic()<deadline:
                time.sleep(.05)
            assert marker.exists(),(root/('interrupted-'+phase+'.log')).read_text()
            os.killpg(process.pid,signal.SIGKILL)
            process.wait(timeout=10)
        finally:
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=10)
            log.close()
        changed={tool:os.readlink(prefix/'opt'/tool/'current') for tool in links}
        assert (changed==links)==(phase=='before'),(phase,changed,links)
        if phase=='partial':
            assert changed['vlang-kakoune']!=links['vlang-kakoune']
            assert changed['vlang-vls']==links['vlang-vls']
        pending=list((prefix/'opt/vlang-state').glob('pending.*'))
        assert len(pending)==1 and (pending[0]/'ready').exists()
        assert (pending[0]/'plugin-revision').read_text().strip()==old_revision
        owner=run([str(repo/'scripts/lock.sh'),'--prefix',str(prefix)],False)
        assert 'stale setup' in owner.stdout,owner.stdout+owner.stderr
        personal.write_text(personal.read_text()+'# edited after interruption\n')
        kakrc_target.write_text(kakrc_target.read_text()+'# kakrc edited after interruption\n')
        run([str(repo/'scripts/rollback.sh'),'--prefix',str(prefix),'--recover',str(pending[0])],False)
        run([str(repo/'scripts/lock.sh'),'--prefix',str(prefix),'--clear-stale'])
        invalid=root/'pending.foreign';invalid.mkdir(exist_ok=True)
        run([str(repo/'scripts/rollback.sh'),'--prefix',str(prefix),'--recover',str(invalid)],False)
        alias=prefix/'opt/vlang-state/pending.alias';alias.symlink_to(pending[0])
        run([str(repo/'scripts/rollback.sh'),'--prefix',str(prefix),'--recover',str(alias)],False)
        assert alias.is_symlink();alias.unlink()
        incomplete=prefix/'opt/vlang-state/pending.incomplete'
        shutil.copytree(pending[0],incomplete,symlinks=True);(incomplete/'ready').unlink()
        run([str(repo/'scripts/rollback.sh'),'--prefix',str(prefix),'--recover',str(incomplete)],False)
        assert incomplete.exists();shutil.rmtree(incomplete)
        run([str(interrupted_repo/'scripts/rollback.sh'),'--prefix',str(prefix),'--recover',str(pending[0])])
        assert git('rev-parse','HEAD').strip()==old_revision
        assert links=={tool:os.readlink(prefix/'opt'/tool/'current') for tool in links}
        assert launcher==(prefix/'bin/kak-v').read_bytes()
        assert '# edited after interruption' in personal.read_text()
        assert kakrc.is_symlink() and kakrc.resolve()==kakrc_target
        assert '# kakrc edited after interruption' in kakrc_target.read_text()
        assert not pending[0].exists()
    print('ok - SIGKILL before/within update activation, stale lock recovery and preservation of personal edits')
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
