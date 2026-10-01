#!/usr/bin/env python3
"""Verify setup and migration never replace personal files or conflicting links."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='vlang-settings-') as directory:
    root = Path(directory)
    config = root / "personal config's"
    kak_config = config / 'kak'
    kak_config.mkdir(parents=True)
    prefix = root / 'prefix'
    target = root / 'real-kakrc'
    original = '# personal settings\nmap global user b ":echo mine<ret>"\n'
    target.write_text(original)
    (kak_config / 'kakrc').symlink_to(target)
    personal = kak_config / 'vlang-user.kak'
    personal.write_text('# keep my settings\n')
    autoload = kak_config / 'autoload'
    autoload.mkdir()
    unrelated = root / 'other-plugin.kak'
    unrelated.write_text('# another plugin\n')
    link = autoload / 'vlang.kak'
    link.symlink_to(unrelated)
    env = os.environ.copy()
    env['XDG_CONFIG_HOME'] = str(config)
    env['VLANG_KAK_SKIP_PULL'] = '1'
    env.pop('VLANG_KAK_CONFIG_HOME', None)
    bindir = root / 'bin'
    bindir.mkdir()
    (bindir / 'kak').symlink_to(Path(sys.argv[1]).resolve())
    env['PATH'] = str(bindir) + os.pathsep + env['PATH']
    args = [str(repo / 'scripts/setup.sh'), '--prefix', str(prefix), '--no-build', '--no-lsp', '--no-vls', '--no-explorer']

    def setup(extra=(), expected=0, environment=env):
        result = subprocess.run(args + list(extra), env=environment, capture_output=True, text=True, timeout=20)
        if (result.returncode == 0) != (expected == 0):
            raise RuntimeError(result.stdout + result.stderr)
        return result

    setup()
    setup(['--pane-mode', 'off', '--window-backend', 'tmux', '--no-live-search'])
    setup()
    generated = prefix / 'opt/vlang-kakoune/ide-config/kak/kakrc'
    for setting in ('v_pane_mode off', 'v_window_backend tmux', 'v_live_search_enabled false'):
        assert 'set-option global ' + setting in generated.read_text()
    setup(['--update'])
    assert 'set-option global v_pane_mode off' in generated.read_text()
    assert target.read_text() == original
    assert (kak_config / 'kakrc').is_symlink()
    assert link.resolve() == unrelated
    assert personal.read_text() == '# keep my settings\n'
    assert 'Conflicting plugin link' in setup(['--integrate'], expected=1).stderr
    assert link.resolve() == unrelated and target.read_text() == original

    managed_launcher = prefix / 'bin/kak-v'
    launcher_text = managed_launcher.read_text()
    managed_launcher.unlink()
    managed_launcher.symlink_to(unrelated)
    assert 'Existing unmanaged file' in setup(expected=1).stderr
    assert managed_launcher.is_symlink() and unrelated.read_text() == '# another plugin\n'
    managed_launcher.unlink()
    managed_launcher.write_text(launcher_text)
    managed_launcher.chmod(0o755)

    # An older launcher's environment must recover the original source path,
    # including apostrophes, without touching the regular configuration.
    old_env = env.copy()
    old_env['XDG_CONFIG_HOME'] = str(prefix / 'opt/vlang-kakoune/ide-config')
    setup(['--update'], environment=old_env)
    generated = prefix / 'opt/vlang-kakoune/ide-config/kak/kakrc'
    assert str(personal).replace("'", "''") in generated.read_text()
    assert target.read_text() == original
    subprocess.run(['sh', '-n', str(prefix / 'bin/kak-v')], check=True)

    link.unlink()
    malformed = original + '# >>> vlang.kak managed >>>\n# user content follows\n'
    target.write_text(malformed)
    assert 'Malformed managed block' in setup(['--integrate'], expected=1).stderr
    assert target.read_text() == malformed and not link.exists()
    target.write_text(original)
    setup(['--integrate'])
    assert target.read_text().startswith(original)
    assert (kak_config / 'kakrc').is_symlink()
    assert list(kak_config.glob('kakrc.vlang-backup*')) == []
    backups = list(root.glob('real-kakrc.vlang-backup.*'))
    assert any(p.read_text() == original for p in backups)
    setup(['--update'])
    assert target.read_text().startswith(original)
    assert personal.read_text() == '# keep my settings\n'
    assert link.resolve() == repo / 'rc/vlang.kak'

print('ok - setup preserves personal settings, symlinks, conflicts, and legacy update paths')
