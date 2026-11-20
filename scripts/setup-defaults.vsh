// Resolve setup choices from explicit flags, existing kakrc and defaults.
import os
import setupconfig

fn read_kakrc(path string) !string {
	info := os.stat(path) or { return '' }
	if info.get_filetype() != .regular {
		return ''
	}
	return os.read_file(path)
}

fn last_value(text string, prefix string) string {
	for line in text.split('\n').reverse() {
		if line.starts_with(prefix) {
			return line[prefix.len..]
		}
	}
	return ''
}

fn choice(explicit string, text string, setting string, default_value string) string {
	if explicit != '' {
		return explicit
	}
	stored := last_value(text, 'set-option global ${setting} ')
	return if stored == '' { default_value } else { stored }
}

fn invalid(message string) {
	eprintln(message)
	exit(2)
}

fn main() {
	if os.args.len != 8 {
		invalid('Usage: setup-defaults.vsh { --resolve-config PREFIX | SETTINGS_KAKRC PERSONAL_KAKRC } INTEGRATE EXPLORER LIVE_SEARCH PANE_MODE WINDOW_BACKEND')
	}
	mut settings_path := os.args[1]
	mut personal_path := os.args[2]
	mut output := []string{}
	if os.args[1] == '--resolve-config' {
		paths := setupconfig.resolve(os.args[2]) or {
			eprintln(err.msg())
			exit(if err.code() == 2 { 2 } else { 1 })
		}
		settings_path = paths.settings
		personal_path = paths.personal
		output << [paths.home, settings_path]
	}
	settings := read_kakrc(settings_path) or {
		eprintln(err)
		exit(1)
	}
	mut integrate := os.args[3]
	if integrate == '' {
		integrate = last_value(settings, '# vlang.kak integrate: ')
	}
	if integrate == '' {
		personal := if settings_path == personal_path {
			settings
		} else {
			read_kakrc(personal_path) or {
				eprintln(err)
				exit(1)
			}
		}
		integrate = if '# >>> vlang.kak managed >>>' in personal.split('\n') {
			'true'
		} else {
			'false'
		}
	}
	explorer := choice(os.args[4], settings, 'v_explorer_enabled', 'true')
	live_search := choice(os.args[5], settings, 'v_live_search_enabled', 'true')
	pane_mode := choice(os.args[6], settings, 'v_pane_mode', 'auto')
	window_backend := choice(os.args[7], settings, 'v_window_backend', 'auto')
	if explorer !in ['true', 'false'] || live_search !in ['true', 'false'] {
		invalid('Explorer and live search choices must be true or false.')
	}
	if pane_mode !in ['auto', 'always', 'off'] {
		invalid('Unknown pane mode: ${pane_mode}')
	}
	if window_backend !in ['auto', 'tmux', 'zellij', 'wezterm', 'kitty', 'screen', 'native'] {
		invalid('Unknown window backend: ${window_backend}')
	}
	output << [integrate, explorer, live_search, pane_mode, window_backend]
	println(output.join('\n'))
}
