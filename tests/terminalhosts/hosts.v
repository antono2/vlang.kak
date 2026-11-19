// Isolated real terminal backends for the Kakoune pane acceptance driver.
module terminalhosts

import os
import rand
import releasetest { execute }
import time
import x.json2

#include <unistd.h>
#include <signal.h>

fn C.dup2(int, int) int
fn C.kill(int, int) int

pub const backends = ['zellij', 'wezterm', 'kitty', 'screen', 'native', 'wayland']
const startup_timeout = 30 * time.second
const command_timeout = 15 * time.second
const display_timeout = 10 * time.second
const poll = 100 * time.millisecond
// The fixtures display a full editor and its auxiliary panes simultaneously.
const columns = '140'
const rows = '40'
const display_size = '1600x1200'
const type_delay_ms = '80'
const focus_delay_ms = '150'
const attached_pane = 'host:0.0'
const terminal_root = 'VLANG_TEST_TERMINAL_ROOT'
const terminal_name = 'VLANG_TEST_TERMINAL_NAME'
const terminal_backend = 'VLANG_TEST_TERMINAL_BACKEND'
const real_foot = 'VLANG_TEST_REAL_FOOT'

pub struct Host {
pub:
	backend string
	root    string
	name    string
pub mut:
	env map[string]string
mut:
	display &os.Process = unsafe { nil }
	process &os.Process = unsafe { nil }
	runtime string
}

pub fn create(backend string, root string, name string, env map[string]string) !&Host {
	os.write_file(os.join_path(root, 'host.log'), '')!
	return &Host{ backend: backend, root: root, name: name, env: env }
}

pub fn shell_command(args []string) string {
	return args.map(os.quoted_path(it)).join(' ')
}

pub fn wait_for(label string, timeout time.Duration, ready fn () !bool) ! {
	deadline := time.sys_mono_now() + u64(timeout)
	for time.sys_mono_now() < deadline {
		if ready()! {
			return
		}
		time.sleep(poll)
	}
	return error('Timed out: ${label}')
}

fn wait_file(path string, label string) ! {
	wait_for(label, startup_timeout, fn [path] () !bool {
		return os.exists(path)
	})!
}

fn (host Host) run(program string, args []string) !string {
	result := execute(program, args, true, environment: host.env, timeout: command_timeout)!
	if result.stderr != '' {
		mut output_file := os.open_append(os.join_path(host.root, 'host.log'))!
		defer { output_file.close() }
		output_file.write_string(result.stderr)!
	}
	return result.stdout
}

fn (host Host) cli(args []string) !string {
	wezterm_config := os.join_path(host.root, 'wezterm.lua')
	kitty_socket := 'unix:' + os.join_path(host.root, 'kitty.sock')
	mut command := match host.backend {
		'screen' { ['screen', '-S', host.name] }
		'zellij' { ['zellij', '--session', host.name, 'action'] }
		'wezterm' { ['wezterm', '--config-file', wezterm_config, 'cli', '--no-auto-start'] }
		else { ['kitten', '@', '--to', kitty_socket] }
	}
	command << args
	return host.run(command[0], command[1..])
}

fn (host Host) background(program string, args []string, process_group bool, display_pipe bool) !&os.Process {
	target := if os.is_abs_path(program) && os.is_executable(program) {
		program
	} else {
		os.find_abs_path_of_executable(program)!
	}
	mut launcher_args := ['--host-child', os.join_path(host.root, 'host.log'),
		if display_pipe { 'display' } else { 'log' }, target]
	launcher_args << args
	mut child := os.new_process(os.executable())
	child.set_args(launcher_args)
	child.set_environment(host.env)
	child.use_pgroup = process_group
	if display_pipe {
		child.set_redirect_stdio()
	}
	child.run()
	return child
}

// Run in the child process so long-running display servers can log directly to disk.
pub fn launch_background(args []string) ! {
	mut log_file := os.open_append(args[0])!
	if C.dup2(log_file.fd, 2) != 2 || (args[1] == 'log' && C.dup2(log_file.fd, 1) != 1) {
		log_file.close()
		return error('Could not redirect the terminal host log')
	}
	log_file.close()
	os.execvp(args[2], args[3..])!
}

fn temporary_runtime(label string) !string {
	// Keep compositor/display socket paths short even under a long artifact path.
	path := os.join_path(os.temp_dir(), 'vlang-${label}-' + rand.uuid_v4()[..12])
	os.mkdir(path, mode: 0o700)!
	return path
}

fn (mut host Host) install_shim() ! {
	terminal := os.join_path(host.root, 'terminal')
	os.symlink(os.executable(), terminal)!
	host.env[terminal_root] = host.root
	host.env[terminal_name] = host.name
	host.env[terminal_backend] = host.backend
	if host.backend == 'wayland' {
		host.env[real_foot] = os.find_abs_path_of_executable('foot')!
		bin := os.join_path(host.root, 'bin')
		os.mkdir(bin)!
		os.symlink(terminal, os.join_path(bin, 'foot'))!
		host.env['PATH'] = bin + ':' + host.env['PATH']
	}
}

pub fn is_shim() bool {
	return os.file_name(os.args[0]) in ['terminal', 'foot'] && os.getenv(terminal_backend) != ''
}

// Exec the actual terminal so its window PID identifies its captured stream.
pub fn launch_shim() ! {
	root := os.getenv(terminal_root)
	name := os.getenv(terminal_name)
	stream := os.join_path(root, 'terminal-${os.getpid()}.log')
	if os.getenv(terminal_backend) == 'wayland' {
		os.execvp(os.getenv(real_foot), ['--app-id', name, '--term=xterm-256color',
			'--window-size-chars', '${columns}x${rows}', 'script', '-q', '-f', '-c',
			shell_command(os.args[1..]), stream])!
	} else {
		mut args := ['-class', name, '-geometry', '${columns}x${rows}', '-l', '-lf', stream, '-e']
		args << os.args[1..]
		os.execvp(os.find_abs_path_of_executable('xterm')!, args)!
	}
}

fn find_socket(root string, prefix string) string {
	for name in os.ls(root) or { []string{} } {
		path := os.join_path(root, name)
		if !name.starts_with(prefix) {
			continue
		}
		info := os.stat(path) or { continue }
		if info.get_filetype() == .socket {
			return path
		}
	}
	return ''
}

fn (mut host Host) prepare_wayland() ! {
	host.runtime = temporary_runtime('wayland')!
	host.env['XDG_RUNTIME_DIR'] = host.runtime
	host.env['WLR_BACKENDS'] = 'headless'
	host.env['WLR_LIBINPUT_NO_DEVICES'] = '1'
	host.env['WLR_RENDERER'] = 'pixman'
	config := os.join_path(host.root, 'sway.conf')
	os.write_file(config, 'xwayland disable\noutput * resolution ${display_size}\nseat seat0 fallback true\ndefault_border none\n')!
	host.display = host.background('sway', ['--unsupported-gpu', '-c', config], false, false)!
	runtime := host.runtime
	wait_for('Sway and Wayland sockets', startup_timeout, fn [runtime] () !bool {
		return find_socket(runtime, 'sway-ipc') != '' && find_socket(runtime, 'wayland-') != ''
	})!
	host.env['SWAYSOCK'] = find_socket(runtime, 'sway-ipc')
	host.env['WAYLAND_DISPLAY'] = os.file_name(find_socket(runtime, 'wayland-'))
	host.install_shim()!
}

fn (mut host Host) prepare_x11() ! {
	host.display = host.background('Xvfb', ['-displayfd', '1', '-screen', '0', '${display_size}x24'],
		false, true)!
	deadline := time.sys_mono_now() + u64(display_timeout)
	mut reply := ''
	for time.sys_mono_now() < deadline && host.display.is_alive() {
		reply += host.display.stdout_read()
		if reply.contains('\n') {
			number := reply.all_before('\n').trim_space()
			if number != '' && number.bytes().all(it >= `0` && it <= `9`) {
				host.env['DISPLAY'] = ':' + number
				host.install_shim()!
				return
			}
			break
		}
		time.sleep(poll)
	}
	return error('Xvfb did not report a display number')
}

pub fn (mut host Host) prepare() ! {
	match host.backend {
		'screen' {
			host.runtime = temporary_runtime('screen')!
			host.env['SCREENDIR'] = host.runtime
		}
		'wayland' { host.prepare_wayland()! }
		'native' { host.prepare_x11()! }
		else {}
	}
}

fn (host Host) attach_tmux(command []string) ! {
	mut attach := ['env', '-u', 'TMUX', '-u', 'TMUX_PANE']
	attach << command
	host.run('tmux', ['-L', host.name, '-f', '/dev/null', 'new-session', '-d', '-s', 'host', '-x',
		columns, '-y', rows, shell_command(attach)])!
}

pub fn (mut host Host) start(command []string) ! {
	match host.backend {
		'screen' {
			config := os.join_path(host.root, 'screenrc')
			os.write_file(config, 'startup_message off\ndefscrollback 2000\n')!
			mut args := ['screen', '-c', config, '-S', host.name, '-t', 'source']
			args << command
			host.attach_tmux(args)!
		}
		'native', 'wayland' {
			host.process = host.background(os.join_path(host.root, 'terminal'), command, false, false)!
		}
		'zellij' {
			config := os.join_path(host.root, 'zellij.kdl')
			os.write_file(config, 'session_serialization false\nshow_release_notes false\nshow_startup_tips false\n')!
			mut args := ['--config', config, 'attach', '--create-background', host.name,
				'--close-on-exit', '--']
			args << command
			host.run('zellij', args)!
			// near-current-pane needs a real attached terminal client.
			host.attach_tmux(['zellij', '--config', config, 'attach', host.name])!
			owner := host
			wait_for('Zellij attached terminal', startup_timeout, fn [owner] () !bool {
				return owner.run('tmux', ['-L', owner.name, 'capture-pane', '-p', '-t', attached_pane])!.contains('fn main()')
			})!
		}
		'wezterm' {
			config := os.join_path(host.root, 'wezterm.lua')
			socket := os.join_path(host.root, 'wezterm.sock')
			os.write_file(config, 'return { unix_domains = {{ name = "test", socket_path = ${json2.encode(socket)} }}, default_workspace = "test" }\n')!
			host.env['WEZTERM_UNIX_SOCKET'] = socket
			mut args := ['--config-file', config, '--']
			args << command
			host.process = host.background('wezterm-mux-server', args, false, false)!
			wait_file(socket, 'WezTerm socket')!
		}
		else {
			socket := os.join_path(host.root, 'kitty.sock')
			mut args := ['-a', 'kitty', '--config', 'NONE', '-o', 'allow_remote_control=socket-only',
				'-o', 'enabled_layouts=splits', '-o', 'remember_window_size=no', '-o',
				'initial_window_width=120c', '-o', 'initial_window_height=36c', '--listen-on',
				'unix:' + socket]
			args << command
			host.process = host.background('xvfb-run', args, true, false)!
			wait_file(socket, 'kitty socket')!
		}
	}
}

fn field(object map[string]json2.Any, key string) json2.Any {
	return object[key] or { json2.Any(json2.Null{}) }
}

fn wayland_panes(node map[string]json2.Any, name string, mut result []map[string]json2.Any) {
	if field(node, 'app_id').str() == name {
		result << node
	}
	for key in ['nodes', 'floating_nodes'] {
		for child in field(node, key).as_array() {
			wayland_panes(child.as_map(), name, mut result)
		}
	}
}

fn (host Host) wayland_nodes() ![]map[string]json2.Any {
	tree := json2.decode[json2.Any](host.run('swaymsg', ['-r', '-t', 'get_tree'])!)!
	mut nodes := []map[string]json2.Any{}
	wayland_panes(tree.as_map(), host.name, mut nodes)
	return nodes
}

fn screen_ids(text string) []string {
	mut result := []string{}
	for token in text.fields() {
		id := token.trim_right('*$!@-')
		if id != '' && id.bytes().all(it >= `0` && it <= `9`) {
			result << id
		}
	}
	return result
}

pub fn (host Host) panes() ![]string {
	match host.backend {
		'wayland' { return host.wayland_nodes()!.map(field(it, 'id').str()) }
		'native' {
			result := host.run('xdotool', ['search', '--class', '^${host.name}\$']) or { '' }
			return result.split_into_lines()
		}
		'screen' {
			raw := host.cli(['-p', '0', '-Q', 'windows']) or { '' }
			return screen_ids(raw)
		}
		else {}
	}
	args := match host.backend {
		'zellij' { ['list-panes', '--json'] }
		'wezterm' { ['list', '--format', 'json'] }
		else { ['ls'] }
	}
	raw := host.cli(args)!
	os.write_file(os.join_path(host.root, 'panes.json'), raw)!
	if raw.trim_space() == '' {
		return []
	}
	items := json2.decode[json2.Any](raw)!.as_array()
	mut ids := []string{}
	for item in items {
		node := item.as_map()
		match host.backend {
			'zellij' {
				if !field(node, 'is_plugin').bool() {
					ids << 'terminal_' + field(node, 'id').str()
				}
			}
			'wezterm' { ids << field(node, 'pane_id').str() }
			else {
				for tab in field(node, 'tabs').as_array() {
					for window in field(tab.as_map(), 'windows').as_array() {
						ids << field(window.as_map(), 'id').str()
					}
				}
			}
		}
	}
	return ids
}

fn (host Host) send_display(pane string, text string) ! {
	wayland := host.backend == 'wayland'
	if wayland {
		host.run('swaymsg', ['[con_id=${pane}]', 'focus'])!
	} else {
		host.run('xdotool', ['windowfocus', '--sync', pane])!
	}
	for index, segment in text.split('\r') {
		if index > 0 {
			if wayland {
				host.run('wtype', ['-s', focus_delay_ms, '-k', 'Return'])!
			} else {
				host.run('xdotool', ['key', '--clearmodifiers', 'Return'])!
			}
		}
		if segment != '' {
			if wayland {
				host.run('wtype', ['-s', focus_delay_ms, '-d', type_delay_ms, '--', segment])!
			} else {
				host.run('xdotool', ['type', '--clearmodifiers', '--delay', type_delay_ms, segment])!
			}
		}
	}
}

pub fn (host Host) send(pane string, text string) ! {
	match host.backend {
		'wayland', 'native' { host.send_display(pane, text)! }
		'screen' { host.cli(['-p', pane, '-X', 'stuff', text])! }
		'zellij' {
			raw := host.cli(['list-panes', '--json'])!
			nodes := json2.decode[json2.Any](raw)!.as_array().map(it.as_map())
			if !nodes.any('terminal_' + field(it, 'id').str() == pane && field(it, 'is_focused').bool()) {
				host.cli(['focus-pane-id', pane])!
			}
			// Route separate keyboard events through the attached real terminal.
			for key in text.bytes() {
				label := match key {
					` ` { 'Space' }
					`\r` { 'Enter' }
					else { key.ascii_str() }
				}
				host.run('tmux', ['-L', host.name, 'send-keys', '-t', attached_pane, label])!
				time.sleep(poll)
			}
		}
		'wezterm' { host.cli(['send-text', '--no-paste', '--pane-id', pane, text])! }
		else {
			host.cli(['send-text', '--match', 'id:' + pane,
				text.replace('\\', '\\\\').replace('\r', '\\r')])!
		}
	}
}

fn strip_csi(text string) string {
	// Strip CSI parameters, intermediates, and a final byte from real terminal streams.
	bytes := text.bytes()
	mut result := []u8{cap: bytes.len}
	mut index := 0
	for index < bytes.len {
		if bytes[index] == 0x1b && index + 1 < bytes.len && bytes[index + 1] == `[` {
			mut end := index + 2
			for end < bytes.len && bytes[end] >= `0` && bytes[end] <= `?` {
				end++
			}
			for end < bytes.len && bytes[end] >= ` ` && bytes[end] <= `/` {
				end++
			}
			if end < bytes.len && bytes[end] >= `@` && bytes[end] <= `~` {
				index = end + 1
				continue
			}
		}
		result << bytes[index]
		index++
	}
	return result.bytestr()
}

fn (host Host) window_pid(pane string) !string {
	if host.backend == 'native' {
		return host.run('xdotool', ['getwindowpid', pane])!.trim_space()
	}
	for node in host.wayland_nodes()! {
		if field(node, 'id').str() == pane {
			return field(node, 'pid').str()
		}
	}
	return error('No Wayland surface for pane ${pane}')
}

pub fn (host Host) capture(pane string) !string {
	match host.backend {
		'wayland', 'native' {
			path := os.join_path(host.root, 'terminal-${host.window_pid(pane)!}.log')
			wait_file(path, 'terminal stream')!
			return strip_csi(os.read_file(path)!)
		}
		'screen' {
			path := os.join_path(host.root, 'screen-${pane}.txt')
			if os.exists(path) {
				os.rm(path)!
			}
			host.cli(['-p', pane, '-X', 'hardcopy', path])!
			wait_file(path, 'Screen capture')!
			return os.read_file(path)
		}
		'zellij' { return host.cli(['dump-screen', '--pane-id', pane]) }
		'wezterm' { return host.cli(['get-text', '--pane-id', pane]) }
		else { return host.cli(['get-text', '--match', 'id:' + pane]) }
	}
}

pub fn finish_process(mut child os.Process, group bool, timeout time.Duration) {
	if child.is_alive() {
		if group {
			C.kill(-child.pid, C.SIGTERM)
		} else {
			child.signal_term()
		}
		deadline := time.sys_mono_now() + u64(timeout)
		for child.is_alive() && time.sys_mono_now() < deadline {
			time.sleep(poll)
		}
		if child.is_alive() {
			if group {
				child.signal_pgkill()
			} else {
				child.signal_kill()
				child.status = .running
			}
			child.wait()
		}
	}
	child.close()
}

pub fn (mut host Host) stop() {
	if host.backend == 'screen' {
		if output := host.run('tmux', ['-L', host.name, 'capture-pane', '-p']) {
			os.write_file(os.join_path(host.root, 'screen-terminal.txt'), output) or {}
		}
		host.run('screen', ['-S', host.name, '-X', 'quit']) or {}
	}
	if host.backend == 'zellij' {
		host.run('zellij', ['delete-session', '--force', host.name]) or {}
	}
	if host.backend in ['screen', 'zellij'] {
		host.run('tmux', ['-L', host.name, 'kill-server']) or {}
	}
	if !isnil(host.process) {
		finish_process(mut host.process, host.backend == 'kitty', command_timeout)
	}
	if !isnil(host.display) {
		finish_process(mut host.display, false, display_timeout)
	}
	if host.runtime != '' {
		os.rmdir_all(host.runtime) or {}
	}
}
