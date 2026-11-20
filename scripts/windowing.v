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
		println("new '${initial.replace("'", "''")}'")
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

fn dispatch(args []string) ! {
	command := args[0] or { '' }
	match command {
		'--help', '-h' {
			println(usage)
		}
		'detect' {
			requested := args[1] or { '' }
			println(detect(if requested == '' { 'auto' } else { requested })!)
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
