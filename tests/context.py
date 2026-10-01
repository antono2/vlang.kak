#!/usr/bin/env python3
"""Exercise actual Space menus and task/source transitions through Kakoune's JSON UI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


def wait_for(predicate, label):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.03)
    raise RuntimeError('Timed out: ' + label)


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


repo = Path(__file__).resolve().parent.parent
kak = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='vlang-context-') as directory:
    root = Path(directory)
    config = root / 'config/kak'
    config.mkdir(parents=True)
    (config / 'kakrc').write_text(f"source {quote(repo / 'rc/vlang.kak')}\nset-option global idle_timeout 50\n")
    main = root / 'main.v'
    test = root / 'main_test.v'
    main.write_text('module main\nfn main() {}\n')
    test.write_text('module main\nfn test_one() { assert true }\n')
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'))
    env.pop('VLANG_KAK_RESTART_ALLOWED', None)
    session = 'vlang-context-' + uuid.uuid4().hex[:12]
    ready = root / 'ready'
    output = root / 'ui'
    with output.open('wb') as ui:
        process = subprocess.Popen([kak, '-ui', 'json', '-s', session, str(main), '-e',
                                    f'echo -to-file {quote(ready)} %val{{client}}'],
                                   stdin=subprocess.PIPE, stdout=ui, stderr=subprocess.PIPE, env=env)
        try:
            wait_for(ready.exists, 'startup')
            client = ready.read_text().strip()

            def remote(command):
                done = root / 'done'
                done.unlink(missing_ok=True)
                subprocess.run([kak, '-p', session], env=env, text=True, check=True,
                               input=f'evaluate-commands -client {client} %{{ {command}\necho -to-file {quote(done)} done }}')
                wait_for(done.exists, command)

            def keys(value):
                process.stdin.write((json.dumps(dict(jsonrpc='2.0', method='keys', params=[value])) + '\n').encode())
                process.stdin.flush()

            def menu(expected, group=""):
                keys('<esc>')
                remote('nop')
                offset = output.stat().st_size
                keys('<space>' + group)

                def find_menu():
                    for line in output.read_bytes()[offset:].splitlines():
                        try:
                            event = json.loads(line)
                        except ValueError:
                            continue
                        if event.get('method') == 'info_show':
                            text = json.dumps(event['params'])
                            if expected in text:
                                return text
                    return None

                return wait_for(find_menu, 'Space menu containing ' + expected)

            text = menu('Testing')
            for unavailable in ('Test at cursor', 'Rerun last test', 'Go to definition', 'View file at Git revision…', 'Update and restart'):
                assert unavailable not in text, (unavailable, text)
            assert 'Format and save with V' in text
            assert 'Testing' in text and 'Maintenance' in text
            for grouped in ('Test V project', 'Check project with v vet', 'Check file for compile errors', 'Find callers'):
                assert grouped not in text, (grouped, text)
            remote('set-option global v_explorer_enabled false')
            assert 'Project explorer' not in menu('Open project path')
            keys('<esc>')
            remote('set-option global v_explorer_enabled true')
            assert 'Project explorer' in menu('Project explorer')
            keys('<esc>')
            tests_menu = menu('Test V project', 't')
            assert 'Test at cursor' not in tests_menu and 'Rerun last test' not in tests_menu
            assert 'Check project with v vet' in tests_menu and 'Check file for compile errors' in tests_menu
            maintenance = menu('Show pane backend', 'U')
            assert 'Update and restart' not in maintenance and 'Restart V IDE' not in maintenance
            remote("hook global User VKeysApplied %{ map window v-testing v ':echo custom<ret>' -docstring 'Personal vet' }; v-bind-keys")
            assert 'Personal vet' in menu('Personal vet', 't')
            keys('<esc>')
            remote('v-bind-keys')
            assert 'Personal vet' in menu('Personal vet', 't')
            keys('<esc>')
            remote('set-option buffer readonly true')
            assert 'Format and save with V' not in menu('Testing')
            keys('<esc>')
            remote('set-option buffer readonly false')
            remote(f'edit {quote(test)}')
            assert 'Test at cursor' in menu('Test at cursor')
            keys('<esc>')
            remote("execute-keys -with-hooks 'A <esc>'")
            assert 'Test at cursor' not in menu('Testing')
            keys('<esc>')
            remote('write')
            assert 'Test at cursor' in menu('Test at cursor')
            keys('<esc>')
            remote(f'edit {quote(main)}; select 2.4,2.4')
            runs = root / 'runs'
            remote(f'set-option buffer v_test_command {quote("printf x >> " + str(runs) + "; printf done")}; v-test')
            wait_for(runs.exists, 'test launched')
            text = menu('Rerun this task')
            assert 'Return to source' in text and 'Open location on this line' in text
            assert 'Test at cursor' not in text and 'Build V project' not in text
            keys('r')
            wait_for(lambda: runs.read_text() == 'xx', 'task rerun')
            menu('Return to source')
            keys('q')
            remote(f'echo -to-file {quote(root / "position")} %val{{buffile}} %val{{cursor_line}} %val{{cursor_column}}')
            assert (root / 'position').read_text().strip() == f'{main} 2 4'
            remote(f'echo -to-file {quote(root / "makecmd")} %opt{{makecmd}}')
            assert (root / 'makecmd').read_text().strip() == 'make'
            assert 'Rerun last test' in menu('Test V project', 't')
            keys('<esc>')
            # A personal override must win on subsequent refreshes too.
            remote("hook global User VKeysApplied %{ map window user b ':echo custom<ret>' -docstring 'Personal build' }; v-bind-keys")
            assert 'Personal build' in menu('Personal build')
            keys('<esc>')
            remote('set-option global v_context_keys false')
            text = menu('Personal build')
            assert 'Testing' in text and 'Go to definition' in text
            assert 'Test at cursor' in menu('Test at cursor', 't')
            keys('<esc>')
            remote('set-option global v_context_keys true')
            assert 'Test at cursor' not in menu('Personal build')
            keys('<esc>')
            remote("set-option window filetype text")
            # Generic make output is not a V task, even after a V task used *make*.
            remote("set-option window makecmd 'printf ordinary'; make; v-refresh-keys")
            remote('debug mappings')
            remote(f'evaluate-commands -buffer *debug* %{{ write -force {quote(root / "debug")} }}')
            debug = (root / 'debug').read_text()
            assert 'Rerun this task' not in debug, debug
            assert 'error while parsing kakrc' not in debug, debug
            print('ok - context-aware Space menus, saved-test gating, task rerun/return, and personal overrides')
        finally:
            process.terminate()
            process.wait(timeout=5)
