// Fast-forward a clean plugin clone before preparing tools for setup.
import setupconfig
import os

fn main() {
	if os.args.len != 2 {
		eprintln('Usage: setup-repository.vsh PLUGIN_CHECKOUT')
		exit(2)
	}
	exit(setupconfig.refresh(os.args[1]) or {
		eprintln(err)
		1
	})
}
