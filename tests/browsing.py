#!/usr/bin/env python3
"""Exercise tree and live search through the real Kakoune JSON UI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


repo = Path(__file__).resolve().parent.parent
kak = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='vlang-browsing-') as directory:
    root = Path(directory)
    project = root / 'project with spaces'
    project.mkdir()
    main = project / 'main.v'
    main.write_text('module main\nfn main() {}\n')
    (project / 'v.mod').write_text("Module { name: 'browsing' }\n")
    folder = project / 'nested'
    folder.mkdir()
    target = folder / "it's.v"
    target.write_text('module main\n// unique_browsing_marker\nfn helper() {}\n')
    config = root / 'config/kak'
    config.mkdir(parents=True)
    (config / 'kakrc').write_text(f'source {quote(repo / "rc/vlang.kak")}\nset-option global v_pane_mode off\n')
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'))
    session = 'vlang-browsing-' + uuid.uuid4().hex[:12]
    ready = root / 'ready'
    output = root / 'ui'

    def wait_for(predicate, label):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.05)
        raise RuntimeError(f'Timed out: {label}\n{output.read_text()[-4000:]}')

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
                subprocess.run([kak, '-p', session], input=f'evaluate-commands -client {client} %{{ {command}\necho -to-file {quote(done)} done }}',
                               text=True, check=True, env=env)
                wait_for(done.exists, command)

            def keys(value):
                process.stdin.write((json.dumps(dict(jsonrpc='2.0', method='keys', params=[value])) + '\n').encode())
                process.stdin.flush()

            def value(expression):
                path = root / 'value'
                remote(f'echo -to-file {quote(path)} {expression}')
                return path.read_text().strip()

            def info_after(offset, text):
                for line in output.read_bytes()[offset:].splitlines():
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if event.get('method') == 'info_show' and text in json.dumps(event['params']):
                        return True
                return False

            def tree_row(path):
                state_path = Path(value('%opt{v_tree_state}'))
                rows = json.loads(state_path.read_text())['rows']
                return next(i + 1 for i, row in enumerate(rows) if row and row['path'] == str(path))

            # Missing and failed helpers must fail before touching the source buffer.
            broken = root / 'broken/scripts'
            broken.mkdir(parents=True)
            helper = broken / 'explorer.sh'
            helper.write_text('#!/bin/sh\nexit 1\n')
            helper.chmod(0o755)
            (root / 'broken/rc').mkdir()
            remote(f'set-option global v_plugin_source {quote(root / "broken/rc/vlang.kak")}')
            remote("try %{ v-tree } catch %{ nop }")
            assert value('%val{buffile}') == str(main)
            assert value('%opt{readonly}') == 'false'
            saved = root / 'source-after-failed-helper'
            remote(f'write -force {quote(saved)}')
            assert saved.read_text() == main.read_text()
            remote(f'set-option global v_plugin_source {quote(root / "missing/rc/vlang.kak")}')
            remote("try %{ v-tree } catch %{ nop }")
            assert value('%val{buffile}') == str(main)
            assert value('%opt{readonly}') == 'false'
            saved = root / 'source-after-failed-tree'
            remote(f'write -force {quote(saved)}')
            assert saved.read_text() == main.read_text()
            remote(f'set-option global v_plugin_source {quote(repo / "rc/vlang.kak")}')
            keys('<space>F')
            wait_for(lambda: value('%val{bufname}').startswith('*v-tree-'), 'tree opens with Space F')
            offset = output.stat().st_size
            keys('<space>')
            wait_for(lambda: info_after(offset, 'Toggle hidden files'), 'tree Space context menu')
            assert info_after(offset, 'Return to source')
            keys('<esc>')
            line = tree_row(folder)
            remote(f'select {line}.1,{line}.1; execute-keys -with-hooks -with-maps l')
            line = tree_row(target)
            remote(f'select {line}.1,{line}.1')
            offset = output.stat().st_size
            keys('<space>p')
            wait_for(lambda: info_after(offset, 'unique_browsing_marker'), 'tree file preview')
            keys('<space><ret>')
            wait_for(lambda: value('%val{buffile}') == str(target), 'tree Enter opens quoted filename')
            remote(f'edit {quote(main)}')
            keys('<space>/')
            offset = output.stat().st_size
            keys('unique_browsing_marker')
            wait_for(lambda: info_after(offset, 'unique_browsing_marker'), 'live search preview')
            keys('<esc>')
            wait_for(lambda: value('%val{buffile}') == str(main), 'search cancellation preserves source')
            keys('<space>/unique_browsing_marker<ret>')
            wait_for(lambda: value('%val{bufname}') == '*grep*', 'search results open')
            results = root / 'results'
            wait_for(lambda: (remote(f'write -force {quote(results)}') or 'unique_browsing_marker' in results.read_text()), 'search result row')
            row = next(i + 1 for i, text in enumerate(results.read_text().splitlines()) if 'unique_browsing_marker' in text)
            remote(f'select {row}.1,{row}.1')
            keys('<ret>')
            wait_for(lambda: value('%val{buffile} %val{cursor_line}') == f'{target} 2', 'search Enter jumps to matching source line')
            remote(f'edit {quote(main)}')
            keys('<space>/')
            offset = output.stat().st_size
            keys('no_such_browsing_marker_9327')
            wait_for(lambda: info_after(offset, 'No matches yet'), 'empty live search feedback')
            keys('<esc>')
            remote('nop')
            assert value('%val{buffile}') == str(main)
            print('ok - real tree expand/preview/open, live search preview/results/jump, cancellation and no matches')
        finally:
            subprocess.run([kak, '-p', session], input='kill!\n', text=True, env=env, capture_output=True)
            process.wait(timeout=10)
