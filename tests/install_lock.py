#!/usr/bin/env python3
"""Installation recovery must preserve active, unknown and modified locks."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='vlang-lock-') as directory:
    prefix = Path(directory)
    lock = prefix / 'opt/vlang-state/lock'
    lock.mkdir(parents=True)
    owner = lock / 'owner'
    command = [str(repo / 'scripts/lock.sh'), '--prefix', str(prefix)]

    def run(expected, clear=False):
        result = subprocess.run(command + (['--clear-stale'] if clear else []), text=True, capture_output=True)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        return result.stdout + result.stderr

    assert 'unknown owner' in run(2)
    run(1, True)
    assert lock.exists()
    start = Path(f'/proc/{os.getpid()}/stat').read_text().rsplit(') ', 1)[1].split()[19]
    owner.write_text(f'{os.getpid()} {start} setup\n')
    assert 'active setup' in run(1)
    run(1, True)
    assert owner.exists()
    # A PID that now belongs to a different process is stale, even if alive.
    owner.write_text(f'{os.getpid()} 0 setup\n')
    unexpected = lock / 'personal'
    unexpected.write_text('keep')
    run(1, True)
    assert unexpected.read_text() == 'keep' and owner.exists()
    unexpected.unlink()
    assert 'Stale lock cleared' in run(0, True)
    assert not lock.exists()
    run(0)
    # The shared release function removes only the lock acquired by its caller.
    subprocess.run(['sh', '-eu', '-c', '. "$1/scripts/install-lock.inc"; prefix=$2; state=$prefix/opt/vlang-state; lock_acquire test; lock_release',
                    'test', str(repo), str(prefix)], check=True)
    assert not lock.exists()
    child = subprocess.Popen(['sh', '-eu', '-c', '. "$1/scripts/install-lock.inc"; prefix=$2; state=$prefix/opt/vlang-state; lock_acquire interrupted; exec sleep 30',
                              'test', str(repo), str(prefix)])
    try:
        deadline = time.monotonic() + 5
        while not owner.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        assert owner.exists(), 'child did not acquire its lock'
        child.kill()
        child.wait(timeout=5)
        assert 'stale interrupted' in run(3)
        run(0, True)
        assert not lock.exists()
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
print('ok - active, unknown, stale and modified installation locks; PID reuse and owner release')
