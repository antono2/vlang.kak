// Select preferences from explicit flags, the saved configuration and defaults.
module setupconfig

import os

pub struct Preferences {
pub:
	integrate      string
	explorer       string
	live_search    string
	pane_mode      string
	window_backend string
}

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

pub fn preferences(settings_path string, personal_path string, explicit Preferences) !Preferences {
	settings := read_kakrc(settings_path)!
	mut integrate := explicit.integrate
	if integrate == '' {
		integrate = last_value(settings, '# vlang.kak integrate: ')
	}
	if integrate == '' {
		personal := if settings_path == personal_path {
			settings
		} else {
			read_kakrc(personal_path)!
		}
		integrate = if '# >>> vlang.kak managed >>>' in personal.split('\n') {
			'true'
		} else {
			'false'
		}
	}
	explorer := choice(explicit.explorer, settings, 'v_explorer_enabled', 'true')
	live_search := choice(explicit.live_search, settings, 'v_live_search_enabled', 'true')
	pane_mode := choice(explicit.pane_mode, settings, 'v_pane_mode', 'auto')
	window_backend := choice(explicit.window_backend, settings, 'v_window_backend', 'auto')
	if explorer !in ['true', 'false'] || live_search !in ['true', 'false'] {
		return error_with_code('Explorer and live search choices must be true or false.', 2)
	}
	if pane_mode !in ['auto', 'always', 'off'] {
		return error_with_code('Unknown pane mode: ${pane_mode}', 2)
	}
	if window_backend !in ['auto', 'tmux', 'zellij', 'wezterm', 'kitty', 'screen', 'native'] {
		return error_with_code('Unknown window backend: ${window_backend}', 2)
	}
	return Preferences{integrate, explorer, live_search, pane_mode, window_backend}
}
