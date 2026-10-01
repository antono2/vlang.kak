#!/usr/bin/env python3
"""Real Zellij, WezTerm and kitty clients; isolated sessions/configuration only."""
import argparse
import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import time
import uuid


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
        self.log = (root / 'host.log').open('w')

    def run(self, *args):
        return subprocess.check_output(args, text=True, env=self.env, stderr=self.log, timeout=15)

    def cli(self, *args):
        if self.backend == 'zellij':
            return self.run('zellij', '--session', self.name, 'action', *args)
        if self.backend == 'wezterm':
            return self.run('wezterm', '--config-file', str(self.root / 'wezterm.lua'), 'cli', '--no-auto-start', *args)
        return self.run('kitten', '@', '--to', 'unix:' + str(self.root / 'kitty.sock'), *args)

    def start(self, command):
        if self.backend == 'zellij':
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

    def send(self, pane, text):
        if self.backend == 'zellij':
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
        if self.backend == 'zellij':
            return self.cli('dump-screen', '--pane-id', pane)
        if self.backend == 'wezterm':
            return self.cli('get-text', '--pane-id', pane)
        return self.cli('get-text', '--match', 'id:' + pane)

    def stop(self):
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
        self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path)
    parser.add_argument('backend', choices=['zellij', 'wezterm', 'kitty'])
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
                'WEZTERM_PANE', 'WEZTERM_UNIX_SOCKET', 'KITTY_WINDOW_ID', 'KITTY_LISTEN_ON', 'STY']:
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
    server = subprocess.Popen([kak, '-d', '-s', name, str(source)], env=env)
    host = Host(args.backend, root, name, env)
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
        actual = value('source', f'%sh{{: "$kak_client_env_ZELLIJ" "$kak_client_env_ZELLIJ_SESSION_NAME" "$kak_client_env_WEZTERM_PANE" "$kak_client_env_KITTY_WINDOW_ID"; source=$(readlink -f "$kak_opt_v_plugin_source"); "${{source%/rc/vlang.kak}}/scripts/windowing.sh" detect auto}}')
        if actual != args.backend:
            print('Plugin source:', value('source', '%opt{v_plugin_source}'))
            print('Client environment:', value('source', '%val{client_env_ZELLIJ} %val{client_env_ZELLIJ_SESSION_NAME}'))
            remote('source', f'evaluate-commands -draft -buffer *debug* %{{ write -force {quote(root / "kak-debug")} }}')
        assert actual == args.backend, (actual, args.backend)
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
            assert 'unsaved pane check' in host.capture(original)
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
        except (subprocess.SubprocessError, ValueError):
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
