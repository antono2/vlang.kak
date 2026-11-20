// Verify candidate activation and restoration using local release fixtures.
import os
import rand
import releasetest { capture, execute }

const activation_tools = ['kakoune', 'kak-lsp', 'vls', 'v']

fn path(prefix string, tool string, entry string) string {
	return os.join_path(prefix, 'opt', 'vlang-' + tool, entry)
}

fn compile(source string, binary string) ! {
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', binary, source], true)!
}

fn fixture(prefix string) ! {
	for tool in activation_tools {
		for revision in ['old', 'new'] {
			os.mkdir_all(path(prefix, tool, 'releases/' + revision))!
		}
		os.symlink('releases/old', path(prefix, tool, 'current'))!
		os.symlink('releases/new', path(prefix, tool, 'candidate'))!
	}
	vls := path(prefix, 'vls', 'releases/new/bin/vls')
	os.mkdir_all(os.dir(vls))!
	os.write_file(vls, '#!/bin/sh\nexit 0\n')!
	os.chmod(vls, 0o755)!
	os.mkdir_all(os.join_path(prefix, 'bin'))!
}

fn assert_active(prefix string, revision string) ! {
	for tool in activation_tools {
		assert os.readlink(path(prefix, tool, 'current'))! == 'releases/' + revision
	}
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-activation-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	prefix := os.join_path(root, 'prefix with spaces')
	fixture(prefix)!
	scripts := os.join_path(os.dir(@DIR), 'scripts')
	source := os.join_path(scripts, 'setup-activation.vsh')
	binary := os.join_path(root, 'activation')
	compile(source, binary)!

	vls := os.join_path(prefix, 'bin', 'vls')
	os.write_file(vls, 'user-owned executable')!
	conflict := execute(binary, [prefix, 'upstream', ''], false)!
	assert conflict.stderr.contains('Existing unmanaged path:')
	assert_active(prefix, 'old')!
	assert os.read_file(vls)! == 'user-owned executable'
	os.rm(vls)!

	last := path(prefix, 'v', 'candidate')
	os.rm(last)!
	os.symlink('releases/missing', last)!
	invalid := execute(binary, [prefix, 'upstream', ''], false)!
	assert invalid.stderr.contains('Prepared release is unavailable')
	assert_active(prefix, 'old')!
	assert !os.is_link(vls)
	os.rm(last)!
	os.symlink('releases/new', last)!

	// Kill the native activator after the Kakoune link is switched, then restore its setup snapshot.
	snapshot := os.join_path(root, 'snapshot')
	managed := os.join_path(scripts, 'managed-state.sh')
	capture(managed, ['snapshot', prefix, snapshot], true)!
	probe := os.join_path(root, 'probe.vsh')
	marker := os.join_path(root, "Kakoune's link switched")
	os.cp(source, probe)!
	os.mkdir(os.join_path(root, 'setupconfig'))!
	activation_source := os.read_file(os.join_path(scripts, 'setupconfig', 'activation.v'))!
	os.write_file(os.join_path(root, 'setupconfig', 'activation.v'), releasetest.instrument_tool_activation(activation_source,
		marker)!)!
	interrupted := os.join_path(root, 'interrupted')
	compile(probe, interrupted)!
	releasetest.interrupt_at_marker(interrupted, [prefix, 'upstream', ''], marker)!
	assert os.readlink(path(prefix, 'kakoune', 'current'))! == 'releases/new'
	assert os.readlink(path(prefix, 'vls', 'current'))! == 'releases/old'
	assert !os.is_link(vls)
	capture(managed, ['restore', prefix, snapshot], true)!
	assert_active(prefix, 'old')!

	capture(binary, [prefix, 'upstream', ''], true)!
	assert_active(prefix, 'new')!
	assert os.readlink(vls)! == path(prefix, 'vls', 'current/bin/vls')
	for tool in activation_tools {
		assert !os.is_link(path(prefix, tool, 'candidate'))
	}
	external := path(prefix, 'vls', 'releases/new/bin/vls')
	capture(binary, [prefix, 'external', external], true)!
	assert os.readlink(vls)! == external

	fallback := os.join_path(root, 'shell prefix')
	fixture(fallback)!
	mut env := os.environ()
	env['prefix'] = fallback
	env['vls_mode'] = 'upstream'
	entry := os.join_path(scripts, 'setup-activation-posix')
	fallback_args := ['-eu', '-c', '. "$1"', 'activation', entry]
	fallback_vls := os.join_path(fallback, 'bin', 'vls')
	os.write_file(fallback_vls, 'user-owned executable')!
	capture('sh', fallback_args, false, environment: env)!
	assert_active(fallback, 'old')!
	assert os.read_file(fallback_vls)! == 'user-owned executable'
	os.rm(fallback_vls)!
	capture('sh', fallback_args, true, environment: env)!
	assert_active(fallback, 'new')!
	assert os.readlink(fallback_vls)! == path(fallback, 'vls', 'current/bin/vls')
	println('ok - activation validates all candidates before switching and recovers from a partial switch')
}

check() or {
	eprintln(err)
	exit(1)
}
