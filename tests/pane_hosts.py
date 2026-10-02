#!/usr/bin/env python3
"""Real terminal host clients; isolated sessions/configuration only."""
import argparse
import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import time
import uuid
import re
import select
import shutil


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def wait_for(predicate, label, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(.1)
    raise RuntimeError('Timed out: ' + label)


class Host:
    def __init__(self, backend, root, name, env):
        self.backend, self.root, self.name, self.env = backend, root, name, env
        self.process = None
        self.display = None
        self.screen_sockets = None
        self.wayland_runtime = None
        self.log = (root / 'host.log').open('w')

    def run(self, *args):
        return subprocess.check_output(args, text=True, env=self.env, stderr=self.log, timeout=15)

    def cli(self, *args):
        if self.backend == 'screen':
            return self.run('screen', '-S', self.name, *args)
        if self.backend == 'zellij':
            return self.run('zellij', '--session', self.name, 'action', *args)
        if self.backend == 'wezterm':
            return self.run('wezterm', '--config-file', str(self.root / 'wezterm.lua'), 'cli', '--no-auto-start', *args)
        return self.run('kitten', '@', '--to', 'unix:' + str(self.root / 'kitty.sock'), *args)

    def prepare(self):
        if self.backend == 'screen':
            sockets = Path(tempfile.mkdtemp(prefix='vlang-screen-'))
            self.screen_sockets = sockets
            self.env['SCREENDIR'] = str(sockets)
        if self.backend == 'wayland':
            self.wayland_runtime = Path(tempfile.mkdtemp(prefix='vlang-wayland-'))
            self.env.update(XDG_RUNTIME_DIR=str(self.wayland_runtime), WLR_BACKENDS='headless',
                            WLR_LIBINPUT_NO_DEVICES='1', WLR_RENDERER='pixman')
            config = self.root / 'sway.conf'
            config.write_text('xwayland disable\noutput * resolution 1600x1200\nseat seat0 fallback true\ndefault_border none\n')
            self.display = subprocess.Popen(['sway', '--unsupported-gpu', '-c', str(config)], env=self.env,
                                            stdout=self.log, stderr=self.log)
            socket = wait_for(lambda: next(self.wayland_runtime.glob('sway-ipc*.sock'), None), 'Sway socket')
            self.env['SWAYSOCK'] = str(socket)
            wayland = wait_for(lambda: next((p for p in self.wayland_runtime.glob('wayland-*') if p.is_socket()), None), 'Wayland socket')
            self.env['WAYLAND_DISPLAY'] = wayland.name
            foot = shutil.which('foot', path=self.env['PATH'])
            assert foot, 'Foot must be installed for Wayland tests'
            terminal = self.root / 'terminal'
            terminal.write_text('#!/usr/bin/env python3\nimport os, shlex, sys\n' +
                                'os.execv(' + repr(foot) + ', ["foot", "--app-id", ' + repr(self.name) +
                                ', "--term=xterm-256color", "--window-size-chars", "140x40", ' +
                                '"script", "-q", "-f", "-c", shlex.join(sys.argv[1:]), ' +
                                repr(str(self.root / 'terminal-')) + ' + str(os.getpid()) + ".log"])\n')
            terminal.chmod(0o755)
            # Wrap the real Foot executable only in this fixture's PATH, so
            # the plugin's default Wayland terminal retains capturable output.
            shim = self.root / 'bin'
            shim.mkdir()
            (shim / 'foot').symlink_to(terminal)
            self.env['PATH'] = str(shim) + os.pathsep + self.env['PATH']
            return
        if self.backend != 'native':
            return
        read, write = os.pipe()
        self.display = subprocess.Popen(['Xvfb', '-displayfd', str(write), '-screen', '0', '1600x1200x24'],
                                        pass_fds=(write,), stdout=self.log, stderr=self.log)
        os.close(write)
        try:
            assert select.select([read], [], [], 10)[0], 'Xvfb did not start'
            self.env['DISPLAY'] = ':' + os.read(read, 32).decode().strip()
        finally:
            os.close(read)
        terminal = self.root / 'terminal'
        terminal.write_text('#!/bin/sh\nexec xterm -class ' + shlex.quote(self.name) +
                            ' -geometry 140x40 -l -lf ' + shlex.quote(str(self.root / 'terminal-')) +
                            '$$.log -e "$@"\n')
        terminal.chmod(0o755)

    def start(self, command):
        if self.backend == 'screen':
            config = self.root / 'screenrc'
            config.write_text('startup_message off\ndefscrollback 2000\n')
            attach = shlex.join(['env', '-u', 'TMUX', '-u', 'TMUX_PANE', 'screen', '-c', str(config),
                                 '-S', self.name, '-t', 'source', *command])
            self.run('tmux', '-L', self.name, '-f', '/dev/null', 'new-session', '-d', '-s', 'host',
                     '-x', '140', '-y', '40', attach)
        elif self.backend in ('native', 'wayland'):
            self.process = subprocess.Popen([str(self.root / 'terminal'), *command],
                                            env=self.env, stdout=self.log, stderr=self.log)
        elif self.backend == 'zellij':
            config = self.root / 'zellij.kdl'
            config.write_text('session_serialization false\nshow_release_notes false\nshow_startup_tips false\n')
            self.run('zellij', '--config', str(config), 'attach', '--create-background', self.name,
                     '--close-on-exit', '--', *command)
            # near-current-pane needs an attached terminal client, even when
            # commands run in a background session. Give it a private tmux PTY.
            attach = shlex.join(['env', '-u', 'TMUX', '-u', 'TMUX_PANE', 'zellij',
                                 '--config', str(config), 'attach', self.name])
            self.run('tmux', '-L', self.name, '-f', '/dev/null', 'new-session', '-d',
                     '-s', 'host', '-x', '140', '-y', '40', attach)
            wait_for(lambda: 'fn main()' in self.run('tmux', '-L', self.name,
                                                    'capture-pane', '-p', '-t', 'host:0.0'),
                     'Zellij attached terminal is ready')
        elif self.backend == 'wezterm':
            config = self.root / 'wezterm.lua'
            socket = self.root / 'wezterm.sock'
            config.write_text('return { unix_domains = {{ name = "test", socket_path = ' + json.dumps(str(socket)) +
                              ' }}, default_workspace = "test" }\n')
            self.env['WEZTERM_UNIX_SOCKET'] = str(socket)
            self.process = subprocess.Popen(['wezterm-mux-server', '--config-file', str(config), '--', *command],
                                            env=self.env, stdout=self.log, stderr=self.log)
            wait_for(socket.exists, 'WezTerm socket')
        else:
            self.process = subprocess.Popen(['xvfb-run', '-a', 'kitty', '--config', 'NONE',
                                             '-o', 'allow_remote_control=socket-only', '-o', 'enabled_layouts=splits',
                                             '-o', 'remember_window_size=no', '-o', 'initial_window_width=120c',
                                             '-o', 'initial_window_height=36c', '--listen-on',
                                             'unix:' + str(self.root / 'kitty.sock'), *command],
                                            env=self.env, stdout=self.log, stderr=self.log, start_new_session=True)
            wait_for((self.root / 'kitty.sock').exists, 'kitty socket')

    def panes(self):
        if self.backend == 'wayland':
            return [str(node['id']) for node in self.wayland_nodes()]
        if self.backend == 'native':
            result = subprocess.run(['xdotool', 'search', '--class', '^' + self.name + '$'],
                                    text=True, capture_output=True, env=self.env)
            return result.stdout.splitlines()
        if self.backend == 'screen':
            try:
                return re.findall(r'(?:^|\s)(\d+)[*$!@-]*\s', self.cli('-p', '0', '-Q', 'windows'))
            except subprocess.CalledProcessError:
                return []
        raw = (self.cli('list-panes', '--json') if self.backend == 'zellij' else
                          self.cli('list', '--format', 'json') if self.backend == 'wezterm' else self.cli('ls'))
        (self.root / 'panes.json').write_text(raw)
        if not raw.strip():
            return []
        data = json.loads(raw)
        if self.backend == 'zellij':
            return ['terminal_' + str(p['id']) for p in data if not p['is_plugin']]
        if self.backend == 'wezterm':
            return [str(p['pane_id']) for p in data]
        return [str(p['id']) for window in data for tab in window['tabs'] for p in tab['windows']]

    def wayland_nodes(self):
        tree = json.loads(self.run('swaymsg', '-r', '-t', 'get_tree'))
        def walk(node):
            yield node
            for child in node.get('nodes', []) + node.get('floating_nodes', []):
                yield from walk(child)
        return [n for n in walk(tree) if n.get('app_id') == self.name]

    def send(self, pane, text):
        if self.backend == 'wayland':
            self.run('swaymsg', '[con_id=' + pane + ']', 'focus')
            for i, part in enumerate(text.split('\r')):
                if i:
                    self.run('wtype', '-s', '150', '-k', 'Return')
                if part:
                    self.run('wtype', '-s', '150', '-d', '80', '--', part)
        elif self.backend == 'native':
            self.run('xdotool', 'windowfocus', '--sync', pane)
            for i, part in enumerate(text.split('\r')):
                if i:
                    self.run('xdotool', 'key', '--clearmodifiers', 'Return')
                if part:
                    self.run('xdotool', 'type', '--clearmodifiers', '--delay', '80', part)
        elif self.backend == 'screen':
            self.cli('-p', pane, '-X', 'stuff', text)
        elif self.backend == 'zellij':
            data = json.loads(self.cli('list-panes', '--json'))
            if not any('terminal_' + str(p['id']) == pane and p['is_focused'] for p in data):
                self.cli('focus-pane-id', pane)
            keys = ['Space' if c == ' ' else 'Enter' if c == '\r' else c for c in text]
            # Send separate keyboard events through the attached terminal.
            for key in keys:
                self.run('tmux', '-L', self.name, 'send-keys', '-t', 'host:0.0', key)
                time.sleep(.1)
        elif self.backend == 'wezterm':
            self.cli('send-text', '--no-paste', '--pane-id', pane, text)
        else:
            self.cli('send-text', '--match', 'id:' + pane, text.replace('\\', '\\\\').replace('\r', '\\r'))

    def capture(self, pane):
        if self.backend == 'wayland':
            pid = next(n['pid'] for n in self.wayland_nodes() if str(n['id']) == pane)
            path = self.root / ('terminal-' + str(pid) + '.log')
            wait_for(path.exists, 'Foot terminal stream')
            return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', path.read_text(errors='replace'))
        if self.backend == 'native':
            # Xterm logs its real terminal stream. The wrapper execs Xterm,
            # keeping its PID equal to the unique log file's identity.
            pid = self.run('xdotool', 'getwindowpid', pane).strip()
            path = self.root / ('terminal-' + pid + '.log')
            wait_for(path.exists, 'Xterm screen capture')
            return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', path.read_text(errors='replace'))
        if self.backend == 'screen':
            path = self.root / ('screen-' + pane + '.txt')
            path.unlink(missing_ok=True)
            self.cli('-p', pane, '-X', 'hardcopy', str(path))
            wait_for(path.exists, 'Screen capture')
            return path.read_text(errors='replace')
        if self.backend == 'zellij':
            return self.cli('dump-screen', '--pane-id', pane)
        if self.backend == 'wezterm':
            return self.cli('get-text', '--pane-id', pane)
        return self.cli('get-text', '--match', 'id:' + pane)

    def stop(self):
        if self.backend == 'screen':
            try:
                (self.root / 'screen-terminal.txt').write_text(self.run('tmux', '-L', self.name, 'capture-pane', '-p'))
            except subprocess.SubprocessError:
                pass
            subprocess.run(['screen', '-S', self.name, '-X', 'quit'], env=self.env, stdout=self.log, stderr=self.log)
            subprocess.run(['tmux', '-L', self.name, 'kill-server'], env=self.env, stdout=self.log, stderr=self.log)
        if self.screen_sockets:
            shutil.rmtree(self.screen_sockets)
        if self.backend == 'zellij':
            subprocess.run(['zellij', 'delete-session', '--force', self.name], env=self.env,
                           stdout=self.log, stderr=self.log)
            subprocess.run(['tmux', '-L', self.name, 'kill-server'], env=self.env,
                           stdout=self.log, stderr=self.log)
        if self.process and self.process.poll() is None:
            # kitty's isolated xvfb-run process group includes Xvfb and its GUI.
            if self.backend == 'kitty':
                import signal
                os.killpg(self.process.pid, signal.SIGTERM)
            else:
                self.process.terminate()
            self.process.wait(timeout=15)
        if self.display and self.display.poll() is None:
            self.display.terminate()
            self.display.wait(timeout=10)
        if self.wayland_runtime:
            shutil.rmtree(self.wayland_runtime)
        self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path)
    parser.add_argument('backend', choices=['zellij', 'wezterm', 'kitty', 'screen', 'native', 'wayland'])
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    name = 'vlang-host-' + uuid.uuid4().hex[:12]
    directory = args.artifacts or Path(tempfile.mkdtemp(prefix=name + '-'))
    directory.mkdir(parents=True, exist_ok=True)
    root = directory.resolve()
    root.chmod(0o700)
    prefix = args.prefix.resolve()
    kak = str(prefix / 'bin/kak')
    env = dict(os.environ)
    for key in ['TMUX', 'TMUX_PANE', 'ZELLIJ', 'ZELLIJ_SESSION_NAME', 'ZELLIJ_PANE_ID',
                'WEZTERM_PANE', 'WEZTERM_UNIX_SOCKET', 'KITTY_WINDOW_ID', 'KITTY_LISTEN_ON', 'STY',
                'WAYLAND_DISPLAY', 'DISPLAY', 'ITERM_SESSION_ID', 'SWAYSOCK']:
        env.pop(key, None)
    env['PATH'] = str(prefix / 'opt/vlang-kak-lsp/current/bin') + os.pathsep + str(prefix / 'bin') + os.pathsep + env['PATH']
    env['XDG_CONFIG_HOME'] = str(root / 'config')
    env['XDG_CACHE_HOME'] = str(root / 'cache')
    env['XDG_DATA_HOME'] = str(root / 'data')
    config = root / 'config/kak'
    config.mkdir(parents=True)
    repo = Path(__file__).resolve().parent.parent
    (config / 'kakrc').write_text(
        f'eval %sh{{kak-lsp}}\nset-option global lsp_cmd \'kak-lsp --session "$kak_session"\'\n' +
        f'source {quote(repo / "rc/vlang.kak")}\nset-option global v_window_backend auto\n')
    project = root / "project with spaces"
    project.mkdir()
    source = project / 'main.v'
    source.write_text('module main\n\n// Add two numbers.\nfn add(a int, b int) int {\n    return a + b\n}\n\nfn main() {\n    println(add(1, 2))\n}\n')
    (project / 'v.mod').write_text("Module { name: 'pane_test' }\n")
    target = project / "it's.v"
    target.write_text('module main\nfn other() {}\n')
    host = Host(args.backend, root, name, env)
    try:
        host.prepare()
    except Exception:
        host.stop()
        raise
    if args.backend == 'native':
        with (config / 'kakrc').open('a') as stream:
            stream.write('try %{ declare-option str termcmd }\nset-option global termcmd ' + quote(shlex.quote(str(root / 'terminal')) + ' sh -c') + '\n')
    server_env = dict(env)
    if args.backend in ('native', 'wayland'):
        server_env.pop('DISPLAY', None)
        server_env.pop('WAYLAND_DISPLAY', None)
    server = subprocess.Popen([kak, '-d', '-s', name, str(source)], env=server_env)
    ready = root / 'client'

    def value(client, expression):
        output = root / 'value'
        output.unlink(missing_ok=True)
        remote(client, f'echo -to-file {quote(output)} {expression}')
        wait_for(output.exists, 'editor response')
        return output.read_text().strip()

    def remote(client, command):
        done = root / ('done-' + uuid.uuid4().hex)
        subprocess.run([kak, '-p', name], input=f'evaluate-commands -client {client} %{{ {command}\necho -to-file {quote(done)} done }}\n',
                       text=True, check=True, env=env)
        wait_for(lambda: done.exists() and done.read_text().strip() == 'done', 'command: ' + command)
        done.unlink()

    def position(client):
        return value(client, '%val{buffile} %val{cursor_line} %val{cursor_column}')

    def other_client():
        return next((c for c in value('source', '%val{client_list}').split() if c != 'source'), None)

    try:
        wait_for(lambda: name in subprocess.check_output([kak, '-l'], text=True, env=env).splitlines(), 'Kakoune daemon')
        host.start([kak, '-c', name, '-e', f'edit -existing {quote(source)}; rename-client source; echo -to-file {quote(ready)} ready'])
        wait_for(ready.exists, 'first client')
        original = wait_for(lambda: host.panes()[0] if len(host.panes()) == 1 else None, 'initial pane')
        actual = value('source', f'%sh{{: "$kak_client_env_ZELLIJ" "$kak_client_env_ZELLIJ_SESSION_NAME" "$kak_client_env_WEZTERM_PANE" "$kak_client_env_KITTY_WINDOW_ID" "$kak_client_env_STY" "$kak_client_env_DISPLAY" "$kak_client_env_WAYLAND_DISPLAY"; source=$(readlink -f "$kak_opt_v_plugin_source"); "${{source%/rc/vlang.kak}}/scripts/windowing.sh" detect auto}}')
        expected = 'native' if args.backend == 'wayland' else args.backend
        if actual != expected:
            print('Plugin source:', value('source', '%opt{v_plugin_source}'))
            print('Client environment:', value('source', '%val{client_env_ZELLIJ} %val{client_env_ZELLIJ_SESSION_NAME}'))
            remote('source', f'evaluate-commands -draft -buffer *debug* %{{ write -force {quote(root / "kak-debug")} }}')
        assert actual == expected, (actual, args.backend)
        remote('source', "execute-keys 'gei // unsaved pane check<esc>'")
        for iteration in range(2):
            remote('source', 'select 9.14,9.14')
            host.send(original, ' F')
            wait_for(lambda: len(host.panes()) == 2, 'tree pane')
            tree = next(p for p in host.panes() if p != original)
            client = wait_for(other_client, 'tree client')
            wait_for(lambda: 'q close pane' in host.capture(tree), 'tree close hint')
            if iteration == 0:
                state = json.loads(Path(value(client, '%opt{v_tree_state}')).read_text())
                row = next(i + 1 for i, entry in enumerate(state['rows']) if entry and entry['path'] == str(target))
                remote(client, f'select {row}.1,{row}.1')
                host.send(tree, '\r')
                wait_for(lambda: position('source').startswith(str(target) + ' '), 'tree opens quoted path in source client')
            host.send(tree, ' q' if iteration == 0 else 'q')
            wait_for(lambda: len(host.panes()) == 1, 'tree closes')
            remote('source', f'edit -existing {quote(source)}; select 9.14,9.14')
            wait_for(lambda: 'unsaved pane check' in host.capture(original), 'source window redraw after closing tree')
            contents = root / 'buffer-contents'
            remote('source', f"evaluate-commands -draft %{{ execute-keys '%'; echo -to-file {quote(contents)} %val{{selection}} }}")
            assert 'unsaved pane check' in contents.read_text()
            assert 'unsaved pane check' not in source.read_text()
            host.send(original, ' g')
            wait_for(lambda: len(host.panes()) == 2, 'definition peek')
            peek = next(p for p in host.panes() if p != original)
            client = wait_for(other_client, 'peek client')
            wait_for(lambda: position(client) == f'{source} 4 4', 'definition target')
            host.send(peek, 'q')
            wait_for(lambda: len(host.panes()) == 1, 'peek closes')
            assert position('source') == f'{source} 9 14'
            host.send(original, ' w')
            wait_for(lambda: len(host.panes()) == 2, 'same-file view')
            extra = next(p for p in host.panes() if p != original)
            client = wait_for(other_client, 'extra client')
            wait_for(lambda: position(client) == f'{source} 9 14', 'same-file initial cursor')
            host.send(extra, 'gg')
            wait_for(lambda: position(client) == f'{source} 1 1', 'extra cursor moves')
            assert position('source') == f'{source} 9 14'
            remote('source', 'select 4.4,4.4')
            assert position(client) == f'{source} 1 1'
            host.send(extra, ' q')
            wait_for(lambda: len(host.panes()) == 1, 'extra view closes')
        print(f'ok - real {args.backend}: detection, tree/open/close, peek, independent views, unsaved edits and repeated use')
    finally:
        try:
            for pane in host.panes():
                (root / ('pane-' + pane + '.txt')).write_text(host.capture(pane))
        except (subprocess.SubprocessError, ValueError, RuntimeError):
            pass
        subprocess.run([kak, '-p', name], input=f'evaluate-commands -draft -buffer *debug* %{{ write -force {quote(root / "kak-debug")} }}\n', env=env, text=True, capture_output=True)
        time.sleep(.1)
        subprocess.run([kak, '-p', name], input='kill!\n', env=env, text=True, capture_output=True)
        host.stop()
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
        print('Pane test artifacts:', root)


if __name__ == '__main__':
    main()
