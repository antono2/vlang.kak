#!/usr/bin/env python3
"""Drive real tmux clients through tree, peek and shared-view workflows."""
import os
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


def wait_for(test, label, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = test()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError('Timed out: ' + label)


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    prefix = Path(sys.argv[1]).resolve()
    kak = str(prefix / 'bin/kak') if (prefix / 'bin/kak').exists() else 'kak'
    name = 'vlang-panes-' + uuid.uuid4().hex[:12]
    env = os.environ.copy()
    env['PATH'] = str(prefix / 'bin') + os.pathsep + env['PATH']
    with tempfile.TemporaryDirectory(prefix='vlang-pane-test-') as directory:
        root = Path(directory) / 'project with spaces'
        root.mkdir()
        source = root / 'main.v'
        source.write_text('module main\n\n// Add two numbers.\nfn add(a int, b int) int {\n    return a + b\n}\n\nfn main() {\n    println(add(1, 2))\n}\n')
        (root / 'v.mod').write_text("Module { name: 'pane_check' }\n")
        client_file = root / 'client'
        server = subprocess.Popen([str(prefix / 'bin/kak-v'), '-d', '-s', name, str(source)], env=env)

        def tmux(*args):
            return subprocess.check_output(['tmux', '-L', name, *args], text=True, env=env)

        def panes():
            return tmux('list-panes', '-F', '#{pane_id}').splitlines()

        def remote(command):
            subprocess.run([kak, '-p', name], input=f'evaluate-commands -client client0 %{{ {command} }}\n', text=True, check=True, env=env)

        def position():
            path = root / 'position'
            path.unlink(missing_ok=True)
            remote(f'echo -to-file {quote(path)} %val{{buffile}} %val{{cursor_line}} %val{{cursor_column}}')
            wait_for(path.exists, 'source position')
            return path.read_text().strip()

        try:
            wait_for(lambda: name in subprocess.check_output([kak, '-l'], text=True, env=env).splitlines(), 'server')
            command = shlex.join([kak, '-c', name, '-e', f'edit -existing {quote(source)}; echo -to-file {quote(client_file)} %val{{client}}'])
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', '140', '-y', '40', command)
            wait_for(client_file.exists, 'first client')
            original = panes()[0]
            for _ in range(2):
                remote('select 9.14,9.14')
                tmux('send-keys', '-t', original, 'Space', 'F')
                wait_for(lambda: len(panes()) == 2, 'tree pane')
                tree = next(p for p in panes() if p != original)
                wait_for(lambda: 'q close pane' in tmux('capture-pane', '-p', '-t', tree), 'tree close hint')
                tmux('send-keys', '-t', tree, *(['Space', 'q'] if _ == 0 else ['q']))
                wait_for(lambda: len(panes()) == 1, 'tree closes')
                if position() != f'{source} 9 14':
                    raise RuntimeError('Tree changed the source cursor')

                tmux('send-keys', '-t', original, 'Space', 'g')
                wait_for(lambda: len(panes()) == 2, 'definition pane')
                peek = next(p for p in panes() if p != original)
                wait_for(lambda: 'main.v 4:4' in tmux('display-message', '-p', '-t', peek, '#{pane_title}'), 'definition target')
                tmux('send-keys', '-t', peek, 'q')
                wait_for(lambda: len(panes()) == 1, 'peek closes')
                if position() != f'{source} 9 14':
                    raise RuntimeError('Peek changed the source cursor')

                tmux('send-keys', '-t', original, 'Space', 'w')
                wait_for(lambda: len(panes()) == 2, 'extra view')
                extra = next(p for p in panes() if p != original)
                wait_for(lambda: 'main.v 9:14' in tmux('display-message', '-p', '-t', extra, '#{pane_title}'), 'same file and cursor in extra view')
                tmux('send-keys', '-t', extra, 'g', 'g')
                wait_for(lambda: 'main.v 1:1' in tmux('display-message', '-p', '-t', extra, '#{pane_title}'), 'extra cursor moves independently')
                if position() != f'{source} 9 14':
                    raise RuntimeError('Moving the extra view changed the source cursor')
                remote('select 4.4,4.4')
                if position() != f'{source} 4 4':
                    raise RuntimeError('Source cursor did not move')
                if 'main.v 1:1' not in tmux('display-message', '-p', '-t', extra, '#{pane_title}'):
                    raise RuntimeError('Moving the source changed the extra view cursor')
                tmux('send-keys', '-t', extra, 'Space', 'q')
                wait_for(lambda: len(panes()) == 1, 'extra view closes')
            print('ok - real tmux tree, definition peek, same-file views and closing (repeated)')
        finally:
            subprocess.run(['tmux', '-L', name, 'kill-server'], capture_output=True, env=env)
            subprocess.run([kak, '-p', name], input='kill!\n', text=True, capture_output=True, env=env)
            server.terminate()
            server.wait(timeout=10)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print('not ok - pane interaction: ' + str(error), file=sys.stderr)
        sys.exit(1)
