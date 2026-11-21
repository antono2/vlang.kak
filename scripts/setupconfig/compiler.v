// Select and probe the compiler needed for the requested setup components.
module setupconfig

import os
import rand
import time

const compiler_probe_poll = 5 * time.millisecond

pub struct CompilerPlan {
pub:
	policy      string
	mode        string
	install     bool
	search_path string
}

fn saved_system_policy(path string) !bool {
	entry := os.stat(path) or { return false }
	if entry.get_filetype() != .regular {
		return false
	}
	settings := os.read_file(path)!
	return '# vlang.kak compiler-policy: system' in settings.split('\n')
}

fn compiler_works(upstream_vls bool) !bool {
	compiler := os.find_abs_path_of_executable('v') or { return false }
	directory := os.join_path(os.temp_dir(), 'vlang-kak-compiler-' + rand.uuid_v4())
	os.mkdir(directory, mode: 0o700)!
	defer { os.rmdir_all(directory) or {} }
	probe := os.join_path(directory, 'probe.v')
	json_import := if upstream_vls { 'json2' } else { 'x.json2' }
	os.write_file(probe, 'import ${json_import}\nfn main() { _ = json2.Any(0) }\n')!
	mut child := os.new_process(compiler)
	defer { child.close() }
	child.set_args(['-check', probe])
	child.set_redirect_stdio()
	child.run()
	for child.is_alive() {
		_ = child.stdout_read()
		_ = child.stderr_read()
		time.sleep(compiler_probe_poll)
	}
	child.wait()
	return child.code == 0
}

pub fn compiler_plan(prefix string, settings string, choice string, options ToolOptions) !CompilerPlan {
	upstream_vls := options.vls_mode in ['auto', 'upstream']
	required := upstream_vls || options.build || options.install_lsp || options.explorer
	root := os.join_path(prefix, 'opt', 'vlang-v')
	current := os.join_path(root, 'current')
	candidate := os.join_path(root, 'candidate')
	has_managed := os.is_executable(os.join_path(current, 'v'))
	mut mode := choice
	mut policy := match choice {
		'true' { 'managed' }
		'system' { 'system' }
		else { 'auto' }
	}

	if choice == 'auto' {
		if saved_system_policy(settings)! {
			mode = 'system'
			policy = 'system'
		} else if has_managed {
			mode = 'true'
		}
	}
	mut search_path := os.getenv('PATH')
	if mode == 'system' {
		search_path = search_path.split(':').filter(it != current && it != candidate).join(':')
	} else if has_managed {
		search_path = current + ':' + search_path
	}
	original_path := os.getenv('PATH')
	os.setenv('PATH', search_path, true)
	defer { os.setenv('PATH', original_path, true) }
	install := mode == 'true' || (required && !compiler_works(upstream_vls)!)
	if install && mode == 'system' {
		return error('Selected system V cannot compile the requested stack; use --managed-v or supply a compatible compiler on PATH.')
	}
	return CompilerPlan{policy, mode, install, search_path}
}
