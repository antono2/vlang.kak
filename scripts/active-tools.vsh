// Report which running processes use a Kakoune installation prefix.
import managedfiles { process_ids }
import os

fn report(prefix string) ! {
	executable_prefix := prefix + '/opt/vlang-'
	prefix_setting := 'VLANG_KAK_PREFIX=' + prefix
	// Keep the order of the original /proc glob.
	for pid in process_ids()!.sorted() {
		directory := '/proc/${pid}'
		executable := os.readlink(directory + '/exe') or { '' }
		if executable.starts_with(executable_prefix) {
			println(executable)
		}
		// Linux procfs uses a NUL between entries. A multiline value must
		// never turn into a second environment entry.
		environment := os.read_file(directory + '/environ') or { continue }
		if prefix_setting in environment.split('\0') {
			println('managed-process:${pid}')
		}
	}
}

fn main() {
	if os.args.len != 2 {
		eprintln('Usage: active-tools.vsh PREFIX')
		exit(2)
	}
	report(os.args[1]) or {
		eprintln(err)
		exit(1)
	}
}
