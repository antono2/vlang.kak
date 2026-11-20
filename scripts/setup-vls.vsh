// Preserve a separately installed VLS or verify a user-supplied executable.
import os
import setupconfig

fn main() {
	if os.args.len == 3 && os.args[1] == 'select' {
		println(setupconfig.select_mode(os.args[2]))
	} else if os.args.len == 4 && os.args[1] == 'external' {
		path := setupconfig.external_path(os.args[2], os.args[3]) or {
			eprintln(err)
			exit(1)
		}
		println(path)
	} else {
		eprintln('Usage: setup-vls.vsh select PREFIX | external PREFIX EXECUTABLE')
		exit(2)
	}
}
