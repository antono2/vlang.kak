// Resolve the runtime for a setup that uses an installed Kakoune executable.
import os
import setupconfig

fn main() {
	if os.args.len != 2 {
		eprintln('Usage: setup-runtime.vsh PREFIX')
		exit(2)
	}
	path := setupconfig.runtime(os.args[1]) or {
		eprintln(err)
		exit(1)
	}
	print(path + '.')
}
