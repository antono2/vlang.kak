// Resolve setup's personal configuration without changing its logical path.
module setupconfig

import os

pub const legacy_error = 'Cannot locate personal configuration; rerun setup from a regular shell with XDG_CONFIG_HOME set.'
pub const path_error = 'Tabs/newlines in configuration paths are unsupported.'

const source_start = "source '"
const source_end = "/kak/vlang-user.kak'"

pub fn personal_config(isolated string) !string {
	kakrc := isolated + '/kak/kakrc'
	info := os.stat(kakrc)!
	if info.get_filetype() != .regular {
		return error('Expected an isolated kakrc file')
	}
	lines := os.read_file(kakrc)!.split('\n')
	for line in lines.reverse() {
		if !line.starts_with(source_start) || !line.ends_with(source_end) {
			continue
		}
		config_home := line[source_start.len..line.len - source_end.len].replace("''", "'")
		if config_home == '' {
			break
		}
		personal := os.stat(config_home + '/kak/vlang-user.kak')!
		if personal.get_filetype() == .regular {
			return config_home
		}
		break
	}
	return error('Personal config not found')
}

pub struct Paths {
pub:
	home     string
	settings string
	personal string
}

fn logical_path(path string) string {
	if os.is_abs_path(path) {
		return os.norm_path(path)
	}
	actual := os.getwd()
	pwd := os.getenv('PWD')
	base := if os.is_abs_path(pwd) && os.real_path(pwd) == actual { pwd } else { actual }
	return os.norm_path(base + '/' + path)
}

// On Linux backslashes are path characters. V's mkdir_all treats them as separators.
pub fn make_directory(path string) ! {
	if os.is_dir(path) {
		return
	}
	slash := path.last_index('/') or { 0 }
	if slash > 0 {
		make_directory(path[..slash])!
	}
	os.mkdir(path) or {
		if !os.is_dir(path) {
			return err
		}
	}
}

pub fn resolve(prefix string) !Paths {
	explicit := os.getenv('VLANG_KAK_CONFIG_HOME')
	xdg := os.getenv('XDG_CONFIG_HOME')
	isolated := prefix + '/opt/vlang-kakoune/ide-config'
	mut config := if explicit != '' {
		explicit
	} else if xdg != '' {
		xdg
	} else {
		os.home_dir() + '/.config'
	}
	if explicit == '' && config == isolated {
		config = personal_config(isolated) or { return error(legacy_error) }
	}
	home := logical_path(config)
	if config.contains_any('\t\n') || home.contains_any('\t\n') {
		return error_with_code(path_error, 2)
	}
	make_directory(config)!
	if !os.is_dir(home) || !os.is_executable(home) {
		return error('Cannot enter configuration directory ${home}.')
	}
	personal := home + '/kak/kakrc'
	managed := isolated + '/kak/kakrc'
	info := os.stat(managed) or { return Paths{home, personal, personal} }
	settings := if info.get_filetype() == .regular { managed } else { personal }
	return Paths{home, settings, personal}
}
