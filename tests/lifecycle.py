#!/usr/bin/env python3
"""Ownership, removal, staging failure, settings and recovery use isolated paths."""
import os, subprocess, sys, tempfile, time
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
kak = Path(sys.argv[1]).resolve()

def run(command, env, ok=True):
    result = subprocess.run(command, env=env, input="", text=True, capture_output=True, timeout=60)
    if (result.returncode == 0) != ok:
        raise AssertionError(result.stdout + result.stderr)
    return result

with tempfile.TemporaryDirectory(prefix='vlang-lifecycle-') as directory:
    root = Path(directory)
    prefix = root / 'prefix with spaces'
    config = root / "personal config's"
    cache = root / 'cache'
    bindir = root / 'bin'; bindir.mkdir()
    (bindir / 'kak').symlink_to(kak)
    env = {**os.environ, 'PATH':str(bindir)+os.pathsep+os.environ['PATH'], 'XDG_CONFIG_HOME':str(config),
           'XDG_CACHE_HOME':str(cache), 'VLANG_KAK_PREFIX':str(prefix), 'VLANG_KAK_SKIP_PULL':'1'}
    env.pop('VLANG_KAK_CONFIG_HOME', None)
    setup = [str(repo/'scripts/setup.sh'), '--prefix',str(prefix),'--no-build','--no-lsp','--no-vls','--no-explorer']
    run(setup,env)
    assert (prefix/'opt/vlang-state/manifest.tsv').exists()
    user = config/'kak/vlang-user.kak'; user.write_text('# personal\n')
    run([str(repo/'scripts/settings.sh'),'v_pane_mode','off'],env)
    run([str(repo/'scripts/settings.sh'),'v_live_search_enabled','false'],env)
    run([str(repo/'scripts/settings.sh'),'v_pane_mode','auto'],env)
    assert user.read_text().startswith('# personal\n') and user.read_text().count('v_pane_mode')==1
    before = (prefix/'bin/kak-v').read_bytes()
    result=run(setup+['--vls',str(root/'missing')],env,False)
    assert 'Previous managed tool activation restored' in result.stderr
    assert (prefix/'bin/kak-v').read_bytes()==before
    # An unrelated autoload link is never claimed by an isolated installation.
    autoload=config/'kak/autoload';autoload.mkdir()
    other=root/'other.kak';other.write_text('# other\n')
    (autoload/'vlang.kak').symlink_to(other)
    run(setup,env)
    assert str(autoload/'vlang.kak') not in (prefix/'opt/vlang-state/manifest.tsv').read_text()
    # Unchanged owned files are removed; a changed launcher and personal files survive.
    launcher=prefix/'bin/kak-v';launcher.write_text(launcher.read_text()+'# my edit\n')
    preview=run([str(repo/'scripts/uninstall.sh'),'--prefix',str(prefix)],env)
    assert launcher.exists() and 'Keep changed:' in preview.stdout
    run([str(repo/'scripts/uninstall.sh'),'--prefix',str(prefix),'--apply'],env)
    assert launcher.exists() and user.exists() and (autoload/'vlang.kak').resolve()==other
    assert not (prefix/'opt/vlang-kakoune/ide-config/kak/kakrc').exists()
    # Project arguments stay data even when they contain shell syntax and quotes.
    project=root/"project's with spaces";project.mkdir(); (project/'v.mod').write_text('Module { name: "test" }')
    source=project/"it's.v";source.write_text('module main\nfn main() {}\n')
    marker=root/'must-not-exist'
    args=['one value',"it's literal",f'$(touch {marker})']
    prefs=run([str(repo/'scripts/preferences.sh'),'args',str(source),*args],env).stdout
    assert not marker.exists() and "it''s literal" in prefs
    assert args[0] in run([str(repo/'scripts/preferences.sh'),'show',str(source)],env).stdout
    # Capture and restore a modified source and scratch buffer in a fresh editor.
    session=root/'snapshot-path'; copy=root/'restored-source'; scratch=root/'restored-scratch'
    plugin=str(repo/'rc/vlang.kak').replace("'","''")
    editor_config=root/'editor-config/kak';editor_config.mkdir(parents=True)
    configk=editor_config/'kakrc';configk.write_text(f"source '{plugin}'\n")
    editor_env={**env, 'XDG_CONFIG_HOME':str(root/'editor-config'), 'VLANG_KAK_CONFIG_HOME':str(config)}
    commands=f"execute-keys iUnsaved<esc>; edit -scratch notes; execute-keys iScratch<esc>; edit -scratch recovered-report; execute-keys iReport<esc>; set-option buffer filetype v-doc; set-option buffer readonly true; buffer '{str(source).replace(chr(39),chr(39)*2)}'; select 1.2,1.3; v-session-save; echo -to-file '{session}' %opt{{v_session_checkpoint}}; quit!"
    commands=f"try %{{ {commands} }} catch %{{ echo -debug %val{{error}}; buffer *debug*; write '{root/'failure'}'; quit! }}"
    run([str(kak),'-ui','json', '-e',commands,str(source)],editor_env)
    if (root/'failure').exists(): raise AssertionError((root/'failure').read_text())
    checkpoint=session.read_text().strip()
    dispatch=root/'dispatch'
    source_quoted=str(source).replace("'","''")
    run_command = "'printf ''<%s>\\n'' .'"
    commands=f"define-command -override -params 1 v-make-command %{{ echo -to-file '{dispatch}' %arg{{1}} }}; set-option global v_run_command {run_command}; v-project-preference load; v-run-project; quit!"
    commands=f"try %{{ {commands} }} catch %{{ echo -debug %val{{error}}; buffer *debug*; write '{root/'failure'}'; quit! }}"
    run([str(kak),'-ui','json','-e',commands,str(source)],editor_env)
    if (root/'failure').exists(): raise AssertionError((root/'failure').read_text())
    command=dispatch.read_text().strip()
    result=run(['/bin/sh','-c',command],env)
    for arg in args: assert '<'+arg+'>' in result.stdout, result.stdout
    assert not marker.exists()
    commands=f"v-session-restore '{checkpoint}'; write '{copy}'; echo -to-file '{root/'selection'}' %val{{selections_desc}}; buffer notes; write '{scratch}'; buffer recovered-report; echo -to-file '{root/'recovery-type'}' %opt{{filetype}}; execute-keys -with-maps q; echo -to-file '{root/'after-close'}' %val{{buflist}}; quit!"
    commands=f"try %{{ {commands} }} catch %{{ echo -debug %val{{error}}; buffer *debug*; write '{root/'failure'}'; quit! }}"
    run([str(kak),'-ui','json','-e',commands],editor_env)
    if (root/'failure').exists(): raise AssertionError((root/'failure').read_text())
    assert copy.read_text().startswith('Unsaved') and source.read_text().startswith('module')
    assert scratch.read_text().startswith('Scratch')
    assert (root/'recovery-type').read_text().strip()=='v-recovery'
    assert 'recovered-report' not in (root/'after-close').read_text()
    assert (root/'selection').read_text().strip()=='1.2,1.3'
print('ok - owned removal, changed-file preservation, failed setup recovery, persistent settings, literal arguments and buffer checkpoint restoration')
