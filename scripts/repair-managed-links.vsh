// Restore missing symlinks from the installation's ownership record.
import managedfiles
import os

fn main() {
	if os.args.len != 2 || !os.is_abs_path(os.args[1]) {
		eprintln('Use an absolute prefix.')
		exit(2)
	}
	managedfiles.repair(os.norm_path(os.args[1])) or {
		eprintln(err)
		exit(1)
	}
}
