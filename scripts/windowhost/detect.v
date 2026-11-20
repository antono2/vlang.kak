// Detect pane hosts from the requesting editor client.
module windowhost

import os

const backends = ['tmux', 'zellij', 'wezterm', 'kitty', 'screen', 'native']

pub fn client(name string) string {
	return os.getenv('kak_client_env_' + name)
}

pub fn available(program string) bool {
	os.find_abs_path_of_executable(program) or { return false }
	return true
}

fn active(backend string) bool {
	return match backend {
		'tmux' {
			client('TMUX') != '' && available('tmux')
		}
		'zellij' {
			client('ZELLIJ') != '' && client('ZELLIJ_SESSION_NAME') != '' && available('zellij')
		}
		'wezterm' {
			client('WEZTERM_PANE') != '' && available('wezterm')
		}
		'kitty' {
			client('KITTY_WINDOW_ID') != '' && (available('kitten') || available('kitty'))
		}
		'screen' {
			client('STY') != '' && available('screen')
		}
		'native' {
			client('ITERM_SESSION_ID') != '' || client('WAYLAND_DISPLAY') != ''
				|| client('DISPLAY') != ''
		}
		else {
			false
		}
	}
}

pub fn detect(requested string) !string {
	if requested != 'auto' {
		if requested !in backends {
			return error_with_code('Unknown window backend: ${requested}', 2)
		}
		return if active(requested) { requested } else { 'none' }
	}
	for backend in backends {
		if active(backend) {
			return backend
		}
	}
	return 'none'
}
