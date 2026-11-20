// Resolve the runtime for a setup that uses an installed Kakoune executable.
import os

fn runtime(prefix string) !string {
	executable := os.find_abs_path_of_executable('kak') or {
		return error('Kakoune is not installed.')
	}
	managed := os.join_path(prefix, 'opt', 'vlang-kakoune', 'current', 'share', 'kak')
	if os.is_dir(managed) {
		return managed
	}
	override := os.getenv('KAKOUNE_RUNTIME')
	if override != '' {
		return override
	}
	installation := os.dir(os.dir(os.real_path(executable)))
	return os.join_path(installation, 'share', 'kak')
}

fn main() {
	if os.args.len != 2 {
		eprintln('Usage: setup-runtime.vsh PREFIX')
		exit(2)
	}
	path := runtime(os.args[1]) or {
		eprintln(err)
		exit(1)
	}
	print(path + '.')
}
