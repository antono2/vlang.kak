#!/usr/bin/env python3
"""Real GDB/Kakoune debugging: V locations, menus, panels, stepping and cleanup."""
import json
from contextlib import nullcontext
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
subprocess.run([str(repo / 'scripts/debug.sh'), '--prepare'], check=True)
artifacts = os.environ.get('VLANG_DEBUG_ARTIFACTS')
if artifacts:
    Path(artifacts).mkdir(parents=True, exist_ok=True)
    workspace = nullcontext(tempfile.mkdtemp(prefix='vlang debug-', dir=artifacts))
else:
    workspace = tempfile.TemporaryDirectory(prefix='vlang debug-')
with workspace as directory:
    root = Path(directory)
    config = root / 'config/kak'
    config.mkdir(parents=True)
    state_dir = root / 'debug'
    main = root / 'main.v'
    main.write_text('module main\nimport os\nfn add(a int, b int) int {\n    result := a + b\n    return result\n}\nfn main() {\n    answer := add(2, 3)\n    println(answer)\n    text := os.input("input: ")\n    println("received: " + text)\n    println(os.args.last())\n    println(os.getenv("MODE"))\n}\n')
    (config / 'kakrc').write_text(f'source {quote(repo / "rc/vlang.kak")}\nset-option global v_debug_directory {quote(state_dir)}\nset-option global idle_timeout 50\nset-option global v_debug_adapter_args -q -nx --interpreter=dap -iex {quote('set debug dap-log-file ' + str(root / 'dap.log'))}\n')
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'))
    env['PATH'] = str(Path(kak).parent) + ':' + env['PATH']
    session = 'vlang-debug-' + uuid.uuid4().hex[:12]
    ready = root / 'ready'
    output = root / 'ui'

    def state():
        try:
            return json.loads((state_dir / 'state.json').read_text())
        except (OSError, ValueError):
            return {}

    def wait_for(predicate, label, timeout=30):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            value = predicate()
            if value:
                return value
            time.sleep(.03)
        raise RuntimeError(f'Timed out: {label}\nState: {state()}\nUI: {output.read_text()[-6000:]}')

    with output.open('wb') as ui:
        process = subprocess.Popen([kak, '-ui', 'json', '-s', session, str(main), '-e',
                                    f'echo -to-file {quote(ready)} %val{{client}}'],
                                   stdin=subprocess.PIPE, stdout=ui, stderr=subprocess.PIPE, env=env)
        try:
            wait_for(ready.exists, 'editor startup')
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

            def menu(expected, submenu=True):
                keys('<esc>')
                phase = root / 'editor-phase'

                def synchronized():
                    remote(f'echo -to-file {quote(phase)} %opt{{v_debug_phase}}')
                    return phase.read_text().strip() == state().get('phase')

                wait_for(synchronized, 'editor debugger phase')
                offset = output.stat().st_size
                keys('<space>')
                if submenu:
                    keys('B')

                def find():
                    for line in output.read_bytes()[offset:].splitlines():
                        try:
                            event = json.loads(line)
                        except ValueError:
                            continue
                        if event.get('method') == 'info_show' and expected in json.dumps(event['params']):
                            return json.dumps(event['params'])
                    return None

                text = wait_for(find, 'menu: ' + expected)
                keys('<esc>')
                return text

            def stopped(line):
                return wait_for(lambda: state().get('phase') == 'stopped' and state().get('line') == line and state().get('variables_ready'), f'stop at V line {line}')

            remote("set-option global v_debug_args 'two words'; set-option global v_debug_env 'MODE=local test'")
            remote('select 4.1,4.1; v-debug-breakpoint-if "a == 2"')
            assert state()['breakpoints'][0]['line'] == 4
            launch_menu = menu('Build and debug')
            assert 'Toggle breakpoint' in launch_menu and 'Run to cursor' not in launch_menu
            keys('<space>BB')
            stopped(4)
            assert 'tbreak main__main' not in state()['output']
            root_menu = menu('Continue debugging', submenu=False)
            assert 'Step over' in root_menu and 'Run to cursor' in root_menu
            assert 'Add watch' in root_menu and 'Evaluate expression' in root_menu
            for command in ('v-restart', 'v-update --no-build --no-lsp'):
                rejection = root / 'restart-rejection'
                rejection.unlink(missing_ok=True)
                remote(f'try %{{ {command}; echo -to-file {quote(rejection)} allowed }} catch %{{ echo -to-file {quote(rejection)} %val{{error}} }}')
                assert 'Stop debugging' in rejection.read_text(), rejection.read_text()
                assert state()['phase'] == 'stopped'
            assert state()['file'] == str(main)
            assert state()['breakpoints'][0]['verified']
            assert {v['name']: v['value'] for v in state()['variables']}['a'] == '2'
            remote('set-register v sentinel; v-debug-variables')
            panel = root / 'panel'
            remote(f'echo -to-file {quote(panel)} %val{{bufname}} %reg{{v}}')
            assert panel.read_text().strip() == '*v-debug-variables* sentinel', panel.read_text()
            remote('v-debug-return; v-debug-stack; select 3.1,3.1; v-debug-select')
            wait_for(lambda: state().get('line') == 8, 'selected caller stack frame')
            remote('v-debug-stack; select 2.1,2.1; v-debug-select')
            stopped(4)
            remote('v-debug-call action watch "a + b"')
            wait_for(lambda: state().get('watches', {}).get('a + b') == '5', 'expression watch')
            remote('v-debug-next')
            stopped(5)
            assert {v['name']: v['value'] for v in state()['variables']}['result'] == '5'
            remote('set-option buffer readonly true')
            assert 'Run to cursor' not in menu('Step over', submenu=False)
            remote('set-option buffer readonly false')
            remote(f'v-debug-call action runToCursor {quote(main)} 99999')
            wait_for(lambda: 'No line' in state().get('message', ''), 'invalid run-to-cursor location')
            assert state()['phase'] == 'stopped' and state()['line'] == 5
            assert state()['variables_ready']
            remote('select 9.1,9.1')
            keys('<space>G')
            stopped(9)
            assert len(state()['breakpoints']) == 1 and state()['breakpoints'][0]['line'] == 4
            assert 'tbreak ' in state()['output'] and ':9' in state()['output']
            assert state()['watches']['a + b'].startswith('<unavailable:')
            remote('v-debug-continue')
            wait_for(lambda: state().get('phase') == 'running' and 'input:' in state().get('output', ''), 'program input prompt')
            text = menu('Pause debugging', submenu=False)
            assert 'Step over' not in text and 'Run to cursor' not in text
            remote('v-debug-pause')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('frames'), 'pause running program')
            remote('v-debug-continue')
            wait_for(lambda: state().get('phase') == 'running', 'resume input')
            remote('v-debug-output')
            assert 'Send program input' in menu('Pause debugging', submenu=False)
            offset = output.stat().st_size
            keys('<ret>')
            wait_for(lambda: b'Program input: ' in output.read_bytes()[offset:], 'Enter opens program input prompt')
            keys('discard this<esc>')
            remote('nop')
            assert state()['phase'] == 'running' and 'received:' not in state()['output']
            offset = output.stat().st_size
            keys('<ret>')
            wait_for(lambda: b'Program input: ' in output.read_bytes()[offset:], 'input prompt reopens after cancellation')
            keys('hello IDE<ret>')
            wait_for(lambda: state().get('phase') == 'exited' and 'received: hello IDE' in state().get('output', ''), 'program output and exit')
            assert 'two words' in state()['output'] and 'local test' in state()['output']
            remote('v-debug-return')
            idle_menu = menu('Debugging', submenu=False)
            assert 'Step over' not in idle_menu and 'Run to cursor' not in idle_menu
            wait_for(lambda: subprocess.run([str(repo / 'scripts/debug.sh'), 'active', str(state_dir)], env=env, capture_output=True).returncode != 0, 'debugger lock released')
            remote('v-debug-output; v-debug-output; v-debug-return')
            remote('select 4.1,4.1; v-debug-breakpoint')
            assert not state()['breakpoints']
            remote('v-debug')
            wait_for(lambda: state().get('phase') == 'running' and 'input:' in state().get('output', ''), 'no-breakpoint launch runs normally')
            assert 'tbreak main__main' not in state()['output']
            remote('v-debug-stop')
            wait_for(lambda: state().get('phase') == 'idle', 'no-breakpoint launch cleanup')
            remote('set-option global v_debug_entry main__main; v-debug')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('line') in (7, 8) and state().get('variables_ready'), 'opt-in entry stop')
            remote('v-debug-next')
            stopped(8)
            remote('v-debug-step-in')
            stopped(4)
            remote('v-debug-step-out')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('line') in (8, 9), 'step out')
            remote('v-debug-stop')
            wait_for(lambda: state().get('phase') == 'idle', 'explicit stop cleanup')
            assert state()['line'] == 0 and not state()['variables']
            remote("set-option global v_debug_build_command 'sleep 30 #'; v-debug")
            remote('v-debug-stop')
            wait_for(lambda: state().get('phase') == 'idle', 'cancelled build')
            remote('set-option global v_debug_build_command false; v-debug')
            wait_for(lambda: state().get('phase') == 'failed', 'failed build')
            assert 'Debug build failed' in state()['message']
            remote('set-option global v_debug_build false; v-debug')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('line') in (7, 8) and state().get('variables_ready'), 'entry stop')
            remote('v-debug-stop')
            wait_for(lambda: state().get('phase') == 'idle', 'prebuilt executable cleanup')
            test = root / 'math_test.v'
            test.write_text('module main\nfn test_math() {\n    result := 2 + 3\n    println(result)\n    assert result == 5\n}\n')
            remote(f'edit {quote(test)}; set-option global v_debug_build true; set-option global v_debug_build_command "v -g -cc gcc"; select 4.1,4.1; v-debug-breakpoint; v-debug')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('file') == str(test) and state().get('line') == 4 and state().get('variables_ready'), 'V test breakpoint')
            assert {v['name']: v['value'] for v in state()['variables']}['result'] == '5'
            remote('v-debug-stack; select 3.1,3.1; v-debug-select')
            wait_for(lambda: state().get('file', '').endswith('.c'), 'generated C caller frame')
            assert 'Step over' in menu('Continue debugging', submenu=False)
            remote('v-debug-unwatch "a + b"; v-debug-continue')
            wait_for(lambda: state().get('phase') == 'exited', 'V test exit')
            wait_for(lambda: subprocess.run([str(repo / 'scripts/debug.sh'), 'active', str(state_dir)], env=env, capture_output=True).returncode != 0, 'test debugger lock released')
            remote('v-debug-return')
            remote(f'edit {quote(test)}; select 4.1,4.1; v-debug-breakpoint; set-option global v_debug_entry ""')
            assert not state()['breakpoints']
            test.write_text('module main\nfn test_math() {\n    result := 2 + 3\n    println(result)\n    assert result == 6\n}\n')
            remote(f'edit! {quote(test)}; v-debug')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('file') == str(test) and state().get('variables_ready'), 'failed V test stops without breakpoints')
            assert state()['message'] == 'V assertion failed', state()
            assert {v['name']: v['value'] for v in state()['variables']}['result'] == '5'
            remote('v-debug-continue')
            wait_for(lambda: state().get('phase') == 'exited', 'failed V test exit')
            errors_dir = root / 'errors'
            errors_dir.mkdir()
            failure = errors_dir / 'main.v'
            failure.write_text('module main\nfn main() {\n    panic("debugger test panic")\n}\n')
            remote(f'edit {quote(failure)}; v-debug')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('file') == str(failure) and state().get('variables_ready'), 'panic stops at user source without breakpoints')
            assert state()['message'] == 'V panic', state()
            remote('v-debug-continue')
            wait_for(lambda: state().get('phase') == 'exited', 'panic exit')
            assert 'debugger test panic' in state()['output']
            failure.write_text('module main\nfn main() {\n    assert 2 == 3\n}\n')
            remote(f'edit! {quote(failure)}; v-debug')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('file') == str(failure) and state().get('variables_ready'), 'assertion stops at user source without breakpoints')
            assert state()['message'] == 'V assertion failed', state()
            remote('v-debug-stop')
            wait_for(lambda: state().get('phase') == 'idle', 'assertion stop cleanup')
            failure.write_text('module main\nfn main() {\n    unsafe { p := &int(0); println(*p) }\n}\n')
            remote(f'edit! {quote(failure)}; v-debug')
            wait_for(lambda: state().get('phase') == 'stopped' and state().get('file') == str(failure) and state().get('variables_ready'), 'native runtime fault stops without breakpoints')
            assert any(word in state()['message'].lower() for word in ('signal', 'exception')), state()
            remote('v-debug-stop')
            wait_for(lambda: state().get('phase') == 'idle', 'native fault cleanup')
            values_dir = root / 'values'
            values_dir.mkdir()
            values = values_dir / 'main.v'
            values.write_text('module main\nstruct Person {\n name string\n age int\n}\nfn main() {\n greeting := "hello V"\n numbers := [2, 3, 5]\n person := Person{"Ada", 36}\n empty := []int{}\n println(greeting)\n println(numbers)\n println(person)\n println(empty)\n}\n')
            remote(f'edit {quote(values)}; select 11.1,11.1; v-debug-breakpoint; set-option window modelinefmt CUSTOM-STATUS; v-debug')
            stopped(11)
            variables = {item['name']: item for item in state()['variables']}
            assert variables['greeting']['value'] == '"hello V"', variables
            assert variables['numbers']['value'] == '[]int (len=3)', variables
            assert variables['person']['value'] == 'main.Person', variables
            assert variables['empty']['value'] == '[]int (len=0)', variables
            remote(f'echo -to-file {quote(panel)} %opt{{modelinefmt}}')
            assert panel.read_text().strip().startswith('CUSTOM-STATUS') and '[debug:' in panel.read_text(), panel.read_text()
            remote('v-debug-variables')
            row = next(i + 2 for i, item in enumerate(state()['variables']) if item['name'] == 'numbers')
            remote(f'select {row}.1,{row}.1')
            keys('<ret>')
            wait_for(lambda: [item['name'] for item in state()['variables']] == ['[0]', '[1]', '[2]'], 'expand V array with Enter')
            assert [item['value'] for item in state()['variables']] == ['2', '3', '5']
            remote('v-debug-call action watch person')
            wait_for(lambda: state().get('watches', {}).get('person') == 'main.Person', 'pretty-printed struct watch')
            wait_for(lambda: state().get('watch_refs', {}).get('person', 0) > 0, 'expandable watch reference')
            watch_row = len(state()['variables']) + 2 + list(state()['watches']).index('person')
            remote(f'select {watch_row}.1,{watch_row}.1')
            keys('<ret>')
            wait_for(lambda: [item['name'] for item in state()['variables']] == ['name', 'age'], 'expand struct watch with Enter')
            assert [item['value'] for item in state()['variables']] == ['"Ada"', '36']
            assert 'Remove watch' in menu('Remove watch', submenu=False)
            keys('<space>-')
            keys('person<ret>')
            wait_for(lambda: 'person' not in state()['watches'], 'remove watch through prompt')
            assert 'Remove watch' not in menu('Step over', submenu=False)
            remote('v-debug-call action watch person')
            wait_for(lambda: 'person' in state()['watches'], 'watch restored for row removal')
            remote('v-debug-variables; select 4.1,4.1')
            keys('<del>')
            wait_for(lambda: 'person' not in state()['watches'], 'remove watch row with Delete')
            remote('v-debug-stop')
            wait_for(lambda: state()['phase'] == 'idle', 'value inspection cleanup')
            remote(f'v-debug-return; echo -to-file {quote(panel)} %opt{{modelinefmt}}')
            assert panel.read_text().strip() == 'CUSTOM-STATUS', panel.read_text()
            remote('set-option global v_debug_pretty_print false; set-option global v_debug_status false; v-debug')
            stopped(11)
            raw = {item['name']: item['value'] for item in state()['variables']}
            assert raw['greeting'] != '"hello V"' and raw['numbers'] != '[]int (len=3)', raw
            greeting_ref = next(item['variablesReference'] for item in state()['variables'] if item['name'] == 'greeting')
            remote(f'v-debug-call action expand {greeting_ref}')
            wait_for(lambda: [item['name'] for item in state()['variables']] == ['str', 'len', 'is_lit'], 'raw V string layout')
            assert state()['variables'][1]['value'] == '7'
            remote(f'echo -to-file {quote(panel)} %opt{{modelinefmt}}')
            assert panel.read_text().strip() == 'CUSTOM-STATUS', panel.read_text()
            remote('v-debug-stop')
            wait_for(lambda: state()['phase'] == 'idle', 'raw value inspection cleanup')
            remote('v-debug-breakpoints; select 2.1,2.1')
            keys('<ret>')
            remote(f'echo -to-file {quote(panel)} %val{{buffile}} %val{{cursor_line}}')
            def breakpoint_source_open():
                remote(f'echo -to-file {quote(panel)} %val{{buffile}} %val{{cursor_line}}')
                return panel.read_text().strip() == f'{values} 11'
            wait_for(breakpoint_source_open, 'open breakpoint source with Enter')
            remote('v-debug-breakpoints; select 2.1,2.1')
            keys('<del>')
            wait_for(lambda: not state()['breakpoints'], 'remove inactive breakpoint with Delete')
            errors = [line for line in output.read_text().splitlines() if 'error' in line.lower() and ('highlighter' in line.lower() or 'unknown command' in line.lower())]
            assert not errors, errors
            print('ok - real GDB: V values, modeline preservation, raw opt-out, breakpoint panels, V breakpoints, source jumps, stack selection, variables, watch, stepping, run to cursor, input/output, normal launch, panic/assertion/fault stops, relaunch, build failure and cleanup')
        finally:
            subprocess.run([kak, '-p', session], input='try %{ v-debug-stop }\n', text=True, env=env, capture_output=True)
            end = time.monotonic() + 5
            while state().get('phase') in ('building', 'starting', 'running', 'stopped') and time.monotonic() < end:
                time.sleep(.05)
            subprocess.run([kak, '-p', session], input='kill!\n', text=True, env=env, capture_output=True)
            time.sleep(.2)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
