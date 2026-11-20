// Preserve a separately installed VLS or verify a user-supplied executable.
import os

// Linux resolves at most 40 symbolic links in a pathname lookup.
const symlink_limit = 40

// Match readlink -f for managed links whose executable has yet to be rebuilt.
fn canonical_target(path string) string {
	mut target := path
	for _ in 0 .. symlink_limit {
		if os.exists(target) {
			return os.real_path(target)
		}
		directory := os.dir(target)
		if !os.is_dir(directory) {
			return ''
		}
		if !os.is_link(target) {
			return os.join_path(os.real_path(directory), os.file_name(target))
		}
		next := os.readlink(target) or { return '' }
		target = if os.is_abs_path(next) { next } else { os.join_path(directory, next) }
	}
	return ''
}

fn select_mode(prefix string) string {
	link := os.join_path(prefix, 'bin', 'vls')
	managed := os.join_path(prefix, 'opt', 'vlang-vls', 'current', 'bin', 'vls')
	if os.is_link(link) && canonical_target(link) != canonical_target(managed) {
		return 'skip'
	}
	return 'upstream'
}

fn external_path(prefix string, executable string) !string {
	info := os.stat(executable) or { return error('VLS is not executable: ${executable}') }
	if info.get_filetype() != .regular || !os.is_executable(executable) {
		return error('VLS is not executable: ${executable}')
	}
	bin := os.join_path(prefix, 'bin')
	os.mkdir_all(bin)!
	launcher := os.join_path(bin, 'vls')
	if os.exists(launcher) && !os.is_link(launcher) {
		return error('Existing unmanaged VLS at ${launcher}; choose another --prefix.')
	}
	path := os.real_path(executable)
	if path.contains_any('\t\r\n') {
		return error('Tabs and newlines are unsupported in VLS executable paths.')
	}
	return path
}

fn main() {
	if os.args.len == 3 && os.args[1] == 'select' {
		println(select_mode(os.args[2]))
	} else if os.args.len == 4 && os.args[1] == 'external' {
		path := external_path(os.args[2], os.args[3]) or {
			eprintln(err)
			exit(1)
		}
		println(path)
	} else {
		eprintln('Usage: setup-vls.vsh select PREFIX | external PREFIX EXECUTABLE')
		exit(2)
	}
}
