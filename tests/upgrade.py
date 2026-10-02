#!/usr/bin/env python3
"""Upgrade an actual published installation, then exercise rollback and removal."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
tools = Path(sys.argv[1]).resolve()
base_ref = sys.argv[2] if len(sys.argv) > 2 else 'v1.1.1'
revision = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='vlang-upgrade-') as directory:
    root = Path(directory)
    checkout = root / 'checkout'
    prefix = root / 'prefix'
    config = root / 'config/kak'
    config.mkdir(parents=True)
    external = root / 'external'
    external.mkdir()
    personal = external / 'personal.kak'
    personal.write_text('declare-option str upgrade_personal_setting preserved\n')
    (config / 'vlang-user.kak').symlink_to(personal)
    kakrc = external / 'kakrc'
    kakrc.write_text('# original personal configuration\n')
    (config / 'kakrc').symlink_to(kakrc)
    unrelated = config / 'autoload/personal.kak'
    unrelated.parent.mkdir()
    unrelated.symlink_to(personal)
    for tool in ['vlang-kakoune', 'vlang-kak-lsp']:
        installed = (tools / 'opt' / tool / 'current').resolve()
        target = prefix / 'opt' / tool / 'releases' / installed.name
        shutil.copytree(installed, target, symlinks=True)
        (target.parent.parent / 'current').symlink_to(target)
    vls = external / 'vls'
    shutil.copy2((tools / 'bin/vls').resolve(), vls)
    vls_before = vls.read_bytes()
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'), XDG_CACHE_HOME=str(root / 'cache'),
               VLANG_KAK_PREFIX=str(prefix), VLANG_KAK_SKIP_PULL='1')
    env.pop('VLANG_KAK_CONFIG_HOME', None)
    env['PATH'] = str(prefix / 'opt/vlang-kakoune/current/bin') + ':' + str(prefix / 'opt/vlang-kak-lsp/current/bin') + ':' + env['PATH']
    env['KAKOUNE_RUNTIME'] = str(prefix / 'opt/vlang-kakoune/current/share/kak')

    def run(args, ok=True):
        result = subprocess.run(args, env=env, input='', text=True, capture_output=True, timeout=180)
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result

    run(['git', 'clone', '--quiet', '--no-local', str(repo), str(checkout)])
    run(['git', '-C', str(checkout), 'checkout', '--quiet', '--detach', base_ref])
    setup = [str(checkout / 'scripts/setup.sh'), '--prefix', str(prefix), '--integrate', '--no-build', '--no-lsp']
    run(setup + ['--vls', str(vls)])
    assert (prefix / 'opt/vlang-state/manifest.tsv').exists() == (base_ref != 'v1.1.1')
    old_config = (prefix / 'opt/vlang-kakoune/ide-config/kak/kakrc').read_bytes()
    note = prefix / 'my-notes.txt'
    note.write_text('unrecorded personal file\n')
    inherited = (prefix / 'opt/vlang-kak-lsp/current').resolve() / 'my-notes.txt'
    inherited.write_text('personal file in an inherited tool release\n')
    isolated_note = prefix / 'opt/vlang-kakoune/ide-config/kak/autoload/custom.kak'
    isolated_note.write_text('# personal isolated autoload\n')
    run(['git', '-C', str(checkout), 'checkout', '--quiet', '--detach', revision])
    run(setup + ['--pane-mode', 'off'])
    generated = prefix / 'opt/vlang-kakoune/ide-config/kak/kakrc'
    assert 'v_pane_mode off' in generated.read_text()
    assert (prefix / 'bin/vls').resolve() == vls
    assert not (prefix / 'opt/vlang-v').exists()
    manifest = (prefix / 'opt/vlang-state/manifest.tsv').read_text()
    assert str(inherited.resolve()) not in manifest and str(isolated_note) not in manifest
    launcher = (prefix / 'bin/kak-v').read_bytes()
    run(setup + ['--vls', str(root / 'missing-vls')], ok=False)
    assert launcher == (prefix / 'bin/kak-v').read_bytes()
    run([str(checkout / 'scripts/rollback.sh'), '--prefix', str(prefix)])
    assert generated.read_bytes() == old_config
    assert (config / 'vlang-user.kak').is_symlink() and personal.read_text().endswith('preserved\n')
    run(setup)
    observed = root / 'observed'
    run([str(prefix / 'bin/kak-v'), '-ui', 'json', '-e',
         f"echo -to-file '{observed}' %opt{{upgrade_personal_setting}}; quit!"])
    assert observed.read_text().strip() == 'preserved'
    preview = run([str(checkout / 'scripts/uninstall.sh'), '--prefix', str(prefix)])
    assert 'Preview only' in preview.stdout and (prefix / 'bin/kak-v').exists()
    run([str(checkout / 'scripts/uninstall.sh'), '--prefix', str(prefix), '--apply'])
    assert not (prefix / 'bin/kak-v').exists()
    assert note.exists() and vls.read_bytes() == vls_before
    assert inherited.exists() and isolated_note.exists()
    assert (config / 'kakrc').is_symlink() and kakrc.read_text() == '# original personal configuration\n'
    assert unrelated.is_symlink() and (config / 'vlang-user.kak').is_symlink()
    assert personal.read_text() == 'declare-option str upgrade_personal_setting preserved\n'
print(f'ok - {base_ref} upgrade, external tools and symlinked settings, failed update, rollback and safe removal')
