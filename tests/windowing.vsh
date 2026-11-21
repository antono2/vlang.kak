// Check terminal detection and pane launch arguments with isolated test executables.
import os
import rand
import releasetest { capture }
import time

const client_env = 'kak_client_env_'
const launch_session = 'test-session'
const quoted_command = 'edit "quoted path"'
const native_wait = 5 * time.second
const native_poll_interval = 100 * time.millisecond
const target_line = '14'
const target_column = '7'

fn record_arguments(log string) ! {
	os.write_file(log, os.args[1..].join('\n') + '\n')!
	os.write_file(log + '.socket', os.getenv('WEZTERM_UNIX_SOCKET') + '\n')!
	os.write_file(log + '.runtime', os.getenv('WAYLAND_DISPLAY') + '\n' +
		os.getenv('XDG_RUNTIME_DIR') + '\n')!
	os.write_file(log + '.session', os.getenv('VLANG_VIEW_SESSION') + '\n')!
}

struct Fixture {
	executable string
	env        map[string]string
	log        string
}

fn (fixture Fixture) invoke(args []string, client map[string]string) !string {
	mut environment := fixture.env.clone()
	for key, value in client {
		environment[client_env + key] = value
	}
	return capture(fixture.executable, args, true, environment: environment)!.trim_space()
}

fn (fixture Fixture) detect(requested string, expected string, client map[string]string) ! {
	actual := fixture.invoke(['detect', requested], client)!
	if actual != expected {
		return error('Expected ${expected} for ${requested} detection, got ${actual}')
	}
}

fn (fixture Fixture) launch(host string, side string, command string, client map[string]string) ! {
	fixture.invoke(['open', host, side, launch_session, command], client)!
}

fn (fixture Fixture) check_arguments(expected []string) ! {
	actual := os.read_lines(fixture.log)!
	for arg in expected {
		if arg !in actual {
			return error('Missing argument ${arg} in ${actual}')
		}
	}
}

fn check_views(fixture Fixture) ! {
	path := "/tmp/a 'quoted' source.v"
	quoted := "'/tmp/a ''quoted'' source.v'"
	assert fixture.invoke(['status', 'auto', 'off'], {})! == "echo 'Window backend: none; pane mode: off'"
	assert fixture.invoke(['view', 'tree', 'tmux', 'off', launch_session, path, 'client0'], {})! == 'v-tree'
	assert fixture.invoke(['view', 'tree', 'tmux', 'auto', launch_session, path, 'client0'], {})! == 'v-tree'
	assert fixture.invoke(['view', 'peek', 'tmux', 'auto', launch_session, path, target_line,
		target_column], {})! == 'v-doc'
	assert fixture.invoke(['view', 'peek', 'tmux', 'always', launch_session, '', target_line,
		target_column], {})! == "fail 'Peek definition needs a saved V file'"
	assert fixture.invoke(['view', 'buffer', 'tmux', 'off', launch_session, path, target_line,
		target_column], {})! == "fail 'No supported window backend is active; run v-window-status'"
	assert fixture.invoke(['checkpoint', 'tmux'], {})! == "v-window-finish-checkpoint 'none'"

	tmux := {
		'TMUX':      'socket,1,0'
		'TMUX_PANE': '%3'
	}
	fixture.invoke(['view', 'tree', 'auto', 'always', launch_session, path, "client 'one'"], tmux)!
	fixture.check_arguments(['-b', launch_session, "v-tree-pane-init ${quoted} 'client ''one'''"])!
	fixture.invoke(['view', 'peek', 'auto', 'always', launch_session, path, target_line, target_column], tmux)!
	fixture.check_arguments([launch_session,
		'v-peek-definition-init ${quoted} ${target_line} ${target_column}'])!
	fixture.invoke(['view', 'buffer', 'auto', 'off', launch_session, path, target_line, target_column], tmux)!
	fixture.check_arguments([launch_session,
		'buffer ${quoted}; select ${target_line}.${target_column},${target_line}.${target_column}'])!
	assert fixture.invoke(['checkpoint', 'auto'], tmux)! == "v-window-finish-checkpoint 'tmux'"
	fixture.invoke(['recover', 'tmux', launch_session, path], tmux)!
	fixture.check_arguments([launch_session, 'source ' + quoted])!

	refusal := {
		'TMUX':      'socket,1,0'
		'TMUX_PANE': '%refuse'
	}
	assert fixture.invoke(['view', 'tree', 'auto', 'auto', launch_session, path, 'client0'],
		refusal)! == 'v-tree'
	assert fixture.invoke(['view', 'tree', 'auto', 'always', launch_session, path, 'client0'],
		refusal)! == "fail 'Opening the project tree pane failed'"
	assert fixture.invoke(['recover', 'tmux', launch_session, path], refusal)! == "echo -debug 'A view could not reopen; its checkpoint remains available'"
}

fn check(helper string, cache_writable bool) ! {
	root := os.join_path(os.temp_dir(), 'vlang-kak-windowing.' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	for name in ['tmux', 'zellij', 'wezterm', 'kitty', 'screen', 'foot'] {
		os.symlink(os.executable(), os.join_path(root, name))!
	}
	log := os.join_path(root, 'open.log')
	mut env := os.environ()
	for key in env.keys() {
		if key.starts_with(client_env) {
			env.delete(key)
		}
	}
	env['PATH'] = root + ':' + os.getenv('PATH')
	env['VLANG_WINDOWING_TEST_LOG'] = log
	env['kak_opt_termcmd'] = ''
	cache_home := os.join_path(root, 'cache')
	if !cache_writable {
		os.write_file(cache_home, '')!
	}
	env['XDG_CACHE_HOME'] = cache_home
	fixture := Fixture{
		executable: helper
		env:        env
		log:        log
	}
	zellij := {
		'ZELLIJ':              '1'
		'ZELLIJ_SESSION_NAME': 'test'
	}
	fixture.detect('auto', 'none', {})!
	if cache_writable {
		cache := os.join_path(cache_home, 'vlang.kak')
		binaries := os.ls(cache)!.filter(it.starts_with('windowing-'))
		assert binaries.len == 1 && os.is_executable(os.join_path(cache, binaries[0]))
	}
	fixture.detect('auto', 'tmux', {
		'TMUX':                'socket,1,0'
		'TMUX_PANE':           '%0'
		'ZELLIJ':              '1'
		'ZELLIJ_SESSION_NAME': 'test'
	})!
	fixture.detect('auto', 'zellij', zellij)!
	fixture.detect('auto', 'wezterm', {
		'WEZTERM_PANE': '7'
	})!
	fixture.detect('auto', 'kitty', {
		'KITTY_WINDOW_ID': '4'
	})!
	fixture.detect('auto', 'screen', {
		'STY': 'session'
	})!
	fixture.detect('kitty', 'none', zellij)!

	fixture.launch('tmux', 'left', quoted_command, {
		'TMUX':      'socket,1,0'
		'TMUX_PANE': '%3'
	})!
	fixture.check_arguments(['split-window', '-b', '%3', quoted_command])!

	fixture.launch('zellij', 'left', 'v-tree', {
		'ZELLIJ_SESSION_NAME': 'test'
		'ZELLIJ_PANE_ID':      'terminal_1'
	})!
	fixture.check_arguments(['new-pane', 'left', '--close-on-exit', 'v-tree'])!

	socket := '/tmp/socket with spaces'
	fixture.launch('wezterm', 'right', 'v-definition', {
		'WEZTERM_PANE':        '7'
		'WEZTERM_UNIX_SOCKET': socket
	})!
	fixture.check_arguments(['split-pane', '--no-auto-start', '--right', 'v-definition'])!
	assert os.read_lines(log + '.socket')! == [socket]

	fixture.launch('kitty', 'right', quoted_command, {
		'KITTY_WINDOW_ID': '4'
		'KITTY_LISTEN_ON': 'unix:/tmp/kitty socket'
	})!
	fixture.check_arguments(['--location=after', '--match=id:4', '--to=unix:/tmp/kitty socket',
		quoted_command])!

	screen_session := '123.session name'
	fixture.launch('screen', 'right', quoted_command, {
		'STY':    screen_session
		'WINDOW': '2'
	})!
	fixture.check_arguments([screen_session, '2', launch_session, quoted_command])!
	quoted := fixture.invoke(['open', 'native', 'left', launch_session, "echo 'quoted'"], {})!
	assert quoted == "new 'echo ''quoted'''"
	check_views(fixture)!

	os.rm(log)!
	marker := log + '.session'
	os.rm(marker)!
	display := 'wayland-test'
	runtime := '/tmp/runtime with spaces'
	fixture.launch('native', 'right', quoted_command, {
		'WAYLAND_DISPLAY': display
		'XDG_RUNTIME_DIR': runtime
	})!
	deadline := time.sys_mono_now() + u64(native_wait)
	for time.sys_mono_now() < deadline {
		receipt := os.read_file(marker) or { '' }
		if receipt.trim_space() == launch_session {
			assert os.read_lines(log + '.runtime')! == [display, runtime]
			fixture.check_arguments(['sh'])!
			return
		}
		time.sleep(native_poll_interval)
	}
	return error('The native terminal did not record its launch')
}

if log := os.getenv_opt('VLANG_WINDOWING_TEST_LOG') {
	if '%refuse' in os.args {
		exit(1)
	}
	record_arguments(log) or {
		eprintln(err)
		exit(1)
	}
} else if os.args.len != 2 {
	eprintln('Usage: v run tests/windowing.vsh PATH_TO_WINDOWING_HELPER')
	exit(2)
} else {
	check(os.args[1], true) or {
		eprintln(err)
		exit(1)
	}
	check(os.args[1], false) or {
		eprintln(err)
		exit(1)
	}
	println('ok - V pane adapter and POSIX fallback detect hosts and preserve client launch arguments')
}
