// Recover the personal config from launchers that exported only isolated XDG_CONFIG_HOME.
import os

const source_start = "source '"
const source_end = "/kak/vlang-user.kak'"

fn personal_config(isolated string) !string {
	kakrc := os.join_path(isolated, 'kak', 'kakrc')
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
		personal := os.stat(os.join_path(config_home, 'kak', 'vlang-user.kak'))!
		if personal.get_filetype() == .regular {
			return config_home
		}
		break
	}
	return error('Personal config not found')
}

fn main() {
	if os.args.len != 2 {
		eprintln('Usage: setup-legacy-config.vsh ISOLATED_CONFIG_HOME')
		exit(2)
	}
	println(personal_config(os.args[1]) or {
		eprintln('Cannot locate personal configuration; rerun setup from a regular shell with XDG_CONFIG_HOME set.')
		exit(1)
	})
}
