// Validate setup paths and prepare the checkout before downloading tools.
import os
import setupconfig

fn main() {
	args := os.args[1..]
	if args.len == 7 && args[0] == '--prepare' && args[5..].all(it in ['true', 'false']) {
		exit(setupconfig.prepare_paths(args[1], args[2], args[3], args[4] == 'true',
			args[5] == 'true', args[6] == 'true') or {
			eprintln(err)
			1
		})
	}
	if args.len != 5 || args[0] !in ['all', 'personal', 'managed'] {
		eprintln('Usage: setup-paths.vsh {all|personal|managed} PREFIX REPO CONFIG_HOME INTEGRATE')
		exit(2)
	}
	setupconfig.verify_paths(args[0], args[1], args[2], args[3], args[4] == 'true') or {
		eprintln(err)
		exit(1)
	}
}
