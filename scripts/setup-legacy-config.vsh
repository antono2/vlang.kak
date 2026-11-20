// Recover the personal config from launchers that exported only isolated XDG_CONFIG_HOME.
import os
import setupconfig

fn main() {
	if os.args.len != 2 {
		eprintln('Usage: setup-legacy-config.vsh ISOLATED_CONFIG_HOME')
		exit(2)
	}
	println(setupconfig.personal_config(os.args[1]) or {
		eprintln(setupconfig.legacy_error)
		exit(1)
	})
}
