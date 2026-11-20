// Select and probe the compiler needed for the requested setup components.
import os
import setupconfig

fn main() {
	if os.args.len != 8 || os.args[3] !in ['auto', 'true', 'system'] {
		eprintln('Usage: setup-compiler.vsh PREFIX SETTINGS_KAKRC CHOICE BUILD LSP EXPLORER VLS_MODE')
		exit(2)
	}
	chosen := setupconfig.compiler_plan(os.args[1], os.args[2], os.args[3], setupconfig.ToolOptions{
		build:       os.args[4] == 'true'
		install_lsp: os.args[5] == 'true'
		explorer:    os.args[6] == 'true'
		vls_mode:    os.args[7]
	}) or {
		eprintln(err)
		exit(1)
	}
	print('${chosen.policy}\n${chosen.mode}\n${chosen.install}\n${chosen.search_path}.')
}
