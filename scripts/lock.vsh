// Report or clear the installation lock without shell parsing.
import managedfiles { clear_stale_lock, inspect_lock }
import os

const usage = 'Usage: lock.sh [--prefix DIRECTORY] [--clear-stale]'

fn run(args []string) !int {
	setting := os.getenv('VLANG_KAK_PREFIX')
	mut prefix := if setting == '' { os.join_path(os.home_dir(), '.local') } else { setting }
	mut clear := false
	for i := 0; i < args.len; i++ {
		match args[i] {
			'--prefix' {
				i++
				prefix = args[i] or { return error_with_code('--prefix requires a directory.', 2) }
				if prefix == '' {
					return error_with_code('--prefix requires a directory.', 2)
				}
			}
			'--clear-stale' {
				clear = true
			}
			else {
				return error_with_code('Unknown option: ${args[i]}', 2)
			}
		}
	}
	prefix = os.real_path(os.abs_path(prefix))
	state := os.join_path(prefix, 'opt', 'vlang-state')
	path := os.join_path(state, 'lock')
	if clear {
		clear_stale_lock(prefix, path)!
		return 0
	}
	report := inspect_lock(prefix, path)
	println(report.message)
	return int(report.status)
}

if os.args[1..].any(it in ['--help', '-h']) {
	println(usage)
	exit(0)
}
exit(run(os.args[1..]) or {
	eprintln(err)
	if err.code() == 2 { 2 } else { 1 }
})
