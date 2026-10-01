#!/usr/bin/env python3
"""Record actual IDE screens to a short GIF (optional Pillow dependency)."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import uuid

from pane_hosts import quote, wait_for


def render(screen, title):
    from PIL import Image, ImageDraw, ImageFont
    font = ImageFont.truetype('DejaVuSansMono.ttf', 15)
    image = Image.new('RGB', (960, 665), '#171b24')
    draw = ImageDraw.Draw(image)
    draw.text((18, 14), title, font=font, fill='#f1c75b')
    colors = ['#171b24', '#e56c73', '#91c788', '#f1c75b', '#78a9e3', '#c49bdf', '#75c4c7', '#dce1e8']
    pattern = re.compile(r'\x1b\[([0-9;]*)m')
    for row, line in enumerate(screen.splitlines()[:33]):
        fg, bg, column, start = colors[7], colors[0], 0, 0
        for match in list(pattern.finditer(line)) + [None]:
            end = match.start() if match else len(line)
            for char in line[start:end]:
                x, y = 18 + column * 9, 48 + row * 18
                if bg != colors[0]:
                    draw.rectangle((x, y, x + 9, y + 18), fill=bg)
                draw.text((x, y), char, font=font, fill=fg)
                column += 1
            if match:
                codes = [int(c or 0) for c in match.group(1).split(';')]
                i = 0
                while i < len(codes):
                    c = codes[i]
                    if c == 0:
                        fg, bg = colors[7], colors[0]
                    elif 30 <= c <= 37 or 90 <= c <= 97:
                        fg = colors[c % 10]
                    elif 40 <= c <= 47 or 100 <= c <= 107:
                        bg = colors[c % 10]
                    elif c == 39:
                        fg = colors[7]
                    elif c == 49:
                        bg = colors[0]
                    elif c in [38, 48] and i + 2 < len(codes):
                        if codes[i + 1] == 2 and i + 4 < len(codes):
                            color = tuple(codes[i + 2:i + 5])
                            i += 4
                        else:
                            n = codes[i + 2]
                            levels = [0, 95, 135, 175, 215, 255]
                            color = colors[n % 8] if n < 16 else tuple([8 + (n - 232) * 10] * 3) if n >= 232 else (
                                levels[(n - 16) // 36], levels[((n - 16) // 6) % 6], levels[(n - 16) % 6])
                            i += 2
                        if c == 38:
                            fg = color
                        else:
                            bg = color
                    i += 1
                start = match.end()
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--frames', type=Path, help='Also save individual PNG frames in this directory')
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    repo = Path(__file__).resolve().parent.parent
    name = 'vlang-demo-' + uuid.uuid4().hex[:10]
    env = dict(os.environ)
    env['PATH'] = str(prefix / 'opt/vlang-kak-lsp/current/bin') + ':' + str(prefix / 'bin') + ':' + env['PATH']
    kak = str(prefix / 'bin/kak')
    frames = []
    with tempfile.TemporaryDirectory(prefix='vlang-demo-', delete=False) as directory:
        root = Path(directory)
        print('Recording artifacts:', root, flush=True)
        project = root / 'demo'
        project.mkdir()
        source = project / 'main.v'
        source.write_text('module main\n\n// Add two numbers.\nfn add(a int, b int) int {\n    return a + b\n}\n\nfn main() {\n    println(add(1, 2))\n}\n')
        (project / 'main_test.v').write_text('module main\n\nfn test_add() {\n    assert add(1, 2) == 3\n}\n')
        (project / 'v.mod').write_text("Module { name: 'demo' }\n")
        config = root / 'config/kak'
        config.mkdir(parents=True)
        (config / 'kakrc').write_text('eval %sh{kak-lsp}\nset-option global lsp_cmd \'kak-lsp --session "$kak_session"\'\n' +
                                   f'source {quote(repo / "rc/vlang.kak")}\nset-option global v_pane_mode off\n')
        env['XDG_CONFIG_HOME'] = str(root / 'config')
        env['XDG_CACHE_HOME'] = str(root / 'cache')
        server = subprocess.Popen([kak, '-d', '-s', name, str(source)], env=env)

        def tmux(*command):
            return subprocess.check_output(['tmux', '-L', name, *command], env=env, text=True)

        def remote(command):
            done = root / 'done'
            done.unlink(missing_ok=True)
            subprocess.run([kak, '-p', name], input=f'evaluate-commands -client demo %{{ {command}\necho -to-file {quote(done)} done }}\n',
                           text=True, check=True, env=env)
            wait_for(lambda: done.exists() and done.read_text().strip() == 'done', command)

        def value(expression):
            path = root / 'value'
            remote(f'echo -to-file {quote(path)} {expression}')
            return path.read_text().strip()

        def capture(title):
            time.sleep(.3)
            screen = tmux('capture-pane', '-p', '-e', '-t', 'test:0.0')
            # Temporary directories and random session names do not help viewers.
            screen = screen.replace(str(project), '~/demo').replace(name, 'vlang-demo')
            frames.append(render(screen, title))

        try:
            wait_for(lambda: name in subprocess.check_output([kak, '-l'], env=env, text=True).splitlines(), 'daemon')
            ready = root / 'ready'
            command = shlex.join([kak, '-c', name, '-e', f'edit -existing {quote(source)}; rename-client demo; echo -to-file {quote(ready)} ready'])
            tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', '102', '-y', '33', command)
            wait_for(ready.exists, 'demo client')
            tmux('set-option', 'status', 'off')
            remote('select 9.14,9.14')
            time.sleep(1)
            tmux('send-keys', 'Space')
            capture('1 / 6   Space: commands for the current context')
            tmux('send-keys', 'Escape')
            time.sleep(.3)
            tmux('send-keys', 'Space', 'd')
            wait_for(lambda: value('%val{cursor_line}') == '4', 'definition')
            capture('2 / 6   Space d: jump to a definition')
            remote('select 9.14,9.14')
            tmux('send-keys', 'Space', 'H')
            wait_for(lambda: value('%val{bufname}').startswith('*hover*'), 'documentation')
            capture('3 / 6   Space H: function documentation; q returns')
            tmux('send-keys', 'q')
            remote(f'edit -existing {quote(source)}')
            tmux('send-keys', 'Space', 'F')
            wait_for(lambda: value('%val{bufname}').startswith('*v-tree-'), 'explorer')
            capture('4 / 6   Space F: project explorer; Enter opens, q returns')
            tmux('send-keys', 'q')
            remote(f'edit {quote(project / "main_test.v")}; select 4.5,4.5')
            tmux('send-keys', 'Space', 'T')
            wait_for(lambda: 'Summary' in tmux('capture-pane', '-p'), 'test result', timeout=60)
            capture('5 / 6   Space T in a test file: run the test at the cursor')
            remote(f'edit -existing {quote(source)}; select 5.5,5.5; v-debug-breakpoint; v-debug')
            wait_for(lambda: value('%opt{v_debug_phase}') == 'stopped', 'debug breakpoint', timeout=90)
            state = Path(value('%opt{v_debug_directory}')) / 'state.json'
            wait_for(lambda: json.loads(state.read_text()).get('variables_ready'), 'debug values', timeout=30)
            remote('v-debug-variables')
            wait_for(lambda: 'a = 1' in tmux('capture-pane', '-p'), 'variables')
            tmux('send-keys', 'Space')
            capture('6 / 6   Space while debugging: values, continue and stepping')
            remote('v-debug-stop')
        finally:
            subprocess.run(['tmux', '-L', name, 'kill-server'], env=env, capture_output=True)
            subprocess.run([kak, '-p', name], input='kill!\n', env=env, text=True, capture_output=True)
            server.terminate()
            server.wait(timeout=10)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(args.output, save_all=True, append_images=frames[1:], duration=3000, loop=0, optimize=True)
    if args.frames:
        args.frames.mkdir(parents=True, exist_ok=True)
        for i, frame in enumerate(frames):
            frame.save(args.frames / f'demo-{i + 1}.png')
    shutil.rmtree(root)
    print('Recorded six real IDE screens:', args.output)


if __name__ == '__main__':
    main()
