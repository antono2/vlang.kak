// Prepare tool releases and validate them before the setup transaction activates them.
module setupconfig

import os

// The shell dispatcher reserves this status for a failed native bootstrap.
const bootstrap_fallback_status = 125

pub fn runtime(prefix string) !string {
	executable := os.find_abs_path_of_executable('kak') or {
		return error('Kakoune is not installed.')
	}
	managed := os.join_path(prefix, 'opt', 'vlang-kakoune', 'current', 'share', 'kak')
	if os.is_dir(managed) {
		return managed
	}
	override := os.getenv('KAKOUNE_RUNTIME')
	if override != '' {
		return override
	}
	installation := os.dir(os.dir(os.real_path(executable)))
	return os.join_path(installation, 'share', 'kak')
}

pub struct ToolOptions {
pub:
	build           bool
	install_lsp     bool
	explorer        bool
	kakoune_version string
	lsp_version     string
	vls_mode        string
	vls_path        string
	vls_ref         string
}

pub struct PreparedTools {
pub:
	runtime  string
	lsp      string
	vls_path string
}

pub fn run_tool(program string, args []string) ! {
	mut child := os.new_process(program)
	defer { child.close() }
	child.set_args(args)
	child.run()
	child.wait()
	if child.code != 0 {
		status := if child.code > 0 && child.code != bootstrap_fallback_status {
			child.code
		} else {
			1
		}
		return error_with_code('${program} exited with status ${child.code}', status)
	}
}

fn run_script(scripts string, script string, args []string) ! {
	compiler := os.find_abs_path_of_executable('v') or { return error('V is not on PATH.') }
	mut invocation := ['run', os.join_path(scripts, script)]
	invocation << args
	run_tool(compiler, invocation)!
}

pub fn prepare_tools(prefix string, repo string, options ToolOptions) !PreparedTools {
	scripts := os.join_path(repo, 'scripts')
	kak := os.join_path(prefix, 'opt', 'vlang-kakoune', 'candidate')
	kak_runtime := if options.build {
		run_script(scripts, 'build-kakoune.vsh', ['--version', options.kakoune_version, '--prefix',
			prefix])!
		os.join_path(kak, 'share', 'kak')
	} else {
		runtime(prefix)!
	}
	if !os.is_dir(os.join_path(kak_runtime, 'rc')) {
		return error('Kakoune runtime not found at ${kak_runtime}')
	}

	mut lsp_release := 'current'
	if options.install_lsp {
		run_script(scripts, 'install-kak-lsp.vsh', ['--version', options.lsp_version, '--prefix',
			prefix])!
		lsp_release = 'candidate'
	}
	mut lsp := os.join_path(prefix, 'opt', 'vlang-kak-lsp', lsp_release, 'bin', 'kak-lsp')
	if !os.is_executable(lsp) {
		lsp = os.find_abs_path_of_executable('kak-lsp') or { '' }
	}

	mut vls_path := options.vls_path
	match options.vls_mode {
		'upstream' {
			run_script(scripts, 'install-vls.vsh', ['--ref', options.vls_ref, '--prefix', prefix])!
		}
		'external' {
			vls_path = external_path(prefix, vls_path)!
		}
		else {
			local_vls := os.join_path(prefix, 'bin', 'vls')
			if !executable_file(local_vls) && !os.exists_in_system_path('vls') {
				eprintln('VLS is not on PATH. Pass --vls /path/to/vls after building it.')
			}
		}
	}

	if options.build { run_tool(os.join_path(kak, 'bin', 'kak'), ['-version'])! }
	if options.install_lsp {
		if lsp == '' {
			return error('kak-lsp is not executable.')
		}
		run_tool(lsp, ['--version'])!
	}
	if options.vls_mode == 'upstream' {
		run_script(scripts, 'probe-vls.vsh', [
			os.join_path(prefix, 'opt', 'vlang-vls', 'candidate', 'bin', 'vls'),
		])!
	}
	if options.explorer { run_tool(os.join_path(scripts, 'explorer.sh'), ['--prepare'])! }
	if os.exists_in_system_path('v') {
		if os.exists_in_system_path('gdb') {
			run_tool(os.join_path(scripts, 'debug.sh'), ['--prepare'])!
		}
		run_tool(os.join_path(scripts, 'preferences.sh'), ['--prepare'])!
	}
	return PreparedTools{kak_runtime, lsp, vls_path}
}
