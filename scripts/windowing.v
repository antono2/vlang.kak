// Detect the requesting client's pane host and open a Kakoune client there.
module main

import os
import windowhost { available, client, detect }

const stdout_fd = 1
const default_screen_window = '0'
const native_client = 'exec kak -c "$VLANG_VIEW_SESSION" -e "$VLANG_VIEW_COMMAND"'
const native_detach = 'setsid sh -c "$1" vlang-terminal "$2" < /dev/null > /dev/null 2>&1 &'
const usage = 'Usage: windowing.sh detect [auto|tmux|zellij|wezterm|kitty|screen|native]
       windowing.sh open BACKEND left|right SESSION KAKOUNE_COMMANDS'

fn forward(name string, value string) {
	if value == '' {
		os.unsetenv(name)
	} else {
		os.setenv(name, value, true)
	}
}

fn launch(program string, args []string, quiet bool) ! {
	executable := os.find_abs_path_of_executable(program) or {
		return error_with_code('${program}: not found', 127)
	}
	if quiet {
		mut null_output := os.open_file('/dev/null', 'w')!
		if null_output.fd != stdout_fd {
			redirected := os.fd_dup2(null_output.fd, stdout_fd)
			null_output.close()
			if redirected < 0 {
				return error('Cannot redirect output from ${program}')
			}
		}
	}
	os.execvp(executable, args)!
}

fn open_native(session string, initial string) ! {
	display := client('DISPLAY')
	wayland := client('WAYLAND_DISPLAY')
	mut terminal := os.getenv('kak_opt_termcmd')
	if terminal == '' && wayland != '' && available('foot') {
		terminal = 'foot sh -c'
	}
	if (display == '' && wayland == '') || terminal == '' {
		// Use Kakoune's windowing module when the requesting client supplies no desktop command.
		println('new ' + kak_quote(initial))
		return
	}

	forward('DISPLAY', display)
	forward('XAUTHORITY', client('XAUTHORITY'))
	forward('WAYLAND_DISPLAY', wayland)
	runtime := client('XDG_RUNTIME_DIR')
	if runtime != '' {
		forward('XDG_RUNTIME_DIR', runtime)
	}
	os.setenv('VLANG_VIEW_SESSION', session, true)
	// An empty command is valid, and the terminal's shell receives it as one argument.
	os.setenv('VLANG_VIEW_COMMAND', initial, true)
	// Only the configured terminal template is shell syntax. Client values stay in the environment.
	launch('sh', ['-c', native_detach, 'vlang-windowing', 'exec ${terminal} "$1"', native_client],
		false)!
}

fn open(backend string, side string, session string, initial string) ! {
	if side !in ['left', 'right'] {
		return error_with_code('', 2)
	}
	cwd := os.getenv_opt('PWD') or { os.getwd() }
	kak := ['kak', '-c', session, '-e', initial]
	match backend {
		'tmux' {
			pane := client('TMUX_PANE')
			if pane == '' {
				return error('Cannot identify the current tmux pane.')
			}
			os.setenv('TMUX', client('TMUX'), true)
			mut args := ['split-window', '-h']
			if side == 'left' {
				args << '-b'
			}
			args << ['-t', pane, '-c', cwd]
			args << kak
			launch('tmux', args, false)!
		}
		'zellij' {
			os.setenv('ZELLIJ_PANE_ID', client('ZELLIJ_PANE_ID'), true)
			mut args := ['--session', client('ZELLIJ_SESSION_NAME'), 'action', 'new-pane',
				'--direction', side, '--near-current-pane', '--close-on-exit', '--cwd', cwd, '--']
			args << kak
			launch('zellij', args, true)!
		}
		'wezterm' {
			mut socket := client('WEZTERM_UNIX_SOCKET')
			if socket == '' {
				socket = os.getenv('WEZTERM_UNIX_SOCKET')
			}
			os.setenv('WEZTERM_UNIX_SOCKET', socket, true)
			mut args := ['cli', '--no-auto-start', 'split-pane', '--${side}', '--pane-id',
				client('WEZTERM_PANE'), '--cwd', cwd, '--']
			args << kak
			launch('wezterm', args, true)!
		}
		'kitty' {
			program := if available('kitten') { 'kitten' } else { 'kitty' }
			location := if side == 'left' { 'before' } else { 'after' }
			socket := client('KITTY_LISTEN_ON')
			os.setenv('KITTY_LISTEN_ON', socket, true)
			mut args := ['@']
			if socket != '' {
				args << '--to=${socket}'
			}
			args << ['launch', '--type=window', '--location=${location}', '--cwd=${cwd}',
				'--match=id:${client('KITTY_WINDOW_ID')}']
			args << kak
			launch(program, args, true)!
		}
		'screen' {
			target := client('STY')
			if target == '' {
				return error('Cannot identify the current Screen session.')
			}
			forward('SCREENDIR', client('SCREENDIR'))
			window := client('WINDOW')
			mut args := ['-S', target, '-p', if window == '' {
				default_screen_window
			} else {
				window
			}, '-X', 'screen']
			args << kak
			launch('screen', args, false)!
		}
		'native' {
			open_native(session, initial)!
		}
		else {
			return error_with_code('Unknown window backend: ${backend}', 2)
		}
	}
}

fn kak_quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn detect_requested(requested string) !string {
	return detect(if requested == '' { 'auto' } else { requested })
}

// The existing open command execs the terminal client. Wait for that command
// in a child so the editor can still receive a fallback command on failure.
fn try_open(backend string, side string, session string, initial string) bool {
	mut child := os.new_process(os.executable())
	defer { child.close() }
	child.set_args(['open', backend, side, session, initial])
	child.run()
	child.wait()
	return child.code == 0
}

fn open_view(args []string) ! {
	if args.len < 5 {
		return error_with_code('Incomplete Kakoune view request', 2)
	}
	kind, requested, mode, session, target := args[0], args[1], args[2], args[3], args[4]
	if (kind == 'tree' && args.len != 6)
		|| (kind in ['peek', 'buffer'] && args.len != 7)
		|| kind !in ['tree', 'peek', 'buffer'] {
		return error_with_code('Invalid Kakoune view request', 2)
	}
	fallback := if kind == 'tree' { 'v-tree' } else { 'v-doc' }
	can_fallback := kind != 'buffer'
	if can_fallback {
		if mode !in ['off', 'auto', 'always'] {
			println("fail 'v_pane_mode must be auto, always, or off'")
			return
		}
		if mode == 'off' || (kind == 'tree' && target == '') {
			println(fallback)
			return
		}
		if kind == 'peek' && target == '' {
			println("fail 'Peek definition needs a saved V file'")
			return
		}
	}
	backend := detect_requested(requested)!
	if backend == 'none' {
		if can_fallback && mode == 'auto' {
			println(fallback)
		} else {
			println("fail 'No supported window backend is active; run v-window-status'")
		}
		return
	}
	quoted := kak_quote(target)
	side := if kind == 'tree' { 'left' } else { 'right' }
	initial, failure := match kind {
		'tree' {
			'v-tree-pane-init ${quoted} ${kak_quote(args[5])}', 'Opening the project tree pane failed'
		}
		'peek' {
			'v-peek-definition-init ${quoted} ${args[5]} ${args[6]}', 'Opening the definition pane failed'
		}
		else {
			position := '${args[5]}.${args[6]}'
			'buffer ${quoted}; select ${position},${position}', 'Opening a Kakoune client failed'
		}
	}

	if !try_open(backend, side, session, initial) {
		if can_fallback && mode == 'auto' {
			println(fallback)
		} else {
			println('fail ' + kak_quote(failure))
		}
	}
}

fn dispatch(args []string) ! {
	command := args[0] or { '' }
	match command {
		'--help', '-h' {
			println(usage)
		}
		'detect' {
			requested := args[1] or { '' }
			println(detect_requested(requested)!)
		}
		'status' {
			if args.len != 3 {
				return error_with_code('Expected a window backend and pane mode', 2)
			}
			backend := detect_requested(args[1])!
			println('echo ' + kak_quote('Window backend: ${backend}; pane mode: ${args[2]}'))
		}
		'view' {
			open_view(args[1..])!
		}
		'checkpoint' {
			if args.len != 2 {
				return error_with_code('Expected a checkpoint pane host', 2)
			}
			backend := detect_requested(args[1]) or {
				eprintln(err.msg())
				println("fail 'Could not detect a checkpoint pane host'")
				return
			}
			println('v-window-finish-checkpoint ' + kak_quote(backend))
		}
		'recover' {
			if args.len != 4 {
				return error_with_code('Expected a pane host, session and checkpoint file', 2)
			}
			if !try_open(args[1], 'right', args[2], 'source ' + kak_quote(args[3])) {
				println("echo -debug 'A view could not reopen; its checkpoint remains available'")
			}
		}
		'open' {
			if args.len != 5 {
				return error_with_code(usage, 2)
			}
			open(args[1], args[2], args[3], args[4])!
		}
		else {
			return error_with_code(usage, 2)
		}
	}
}

fn main() {
	dispatch(os.args[1..]) or {
		if err.msg() != '' {
			eprintln(err.msg())
		}
		exit(match err.code() {
			2, 127 { err.code() }
			else { 1 }
		})
	}
}
