// Compare VLS selection with the compiler-free setup path.
import os
import rand
import releasetest { capture, execute }

fn with_args(initial []string, extra []string) []string {
	mut arguments := initial.clone()
	arguments << extra
	return arguments
}

fn exercise(command []string, prefix string) ! {
	program := command[0]
	args := command[1..]
	bin := os.join_path(prefix, 'bin')
	link := os.join_path(bin, 'vls')
	managed := os.join_path(prefix, 'opt', 'vlang-vls', 'current', 'bin', 'vls')
	external := os.join_path(prefix, 'external VLS', 'vls')
	os.mkdir_all(bin)!
	os.mkdir_all(os.dir(managed))!
	os.mkdir_all(os.dir(external))!
	assert capture(program, with_args(args, ['select', prefix]), true)! == 'upstream\n'

	// The managed binary may be missing until setup finishes its build.
	os.symlink('../opt/vlang-vls/current/bin/vls', link)!
	assert capture(program, with_args(args, ['select', prefix]), true)! == 'upstream\n'
	os.rm(link)!
	os.symlink(external, link)!
	assert capture(program, with_args(args, ['select', prefix]), true)! == 'skip\n'

	os.write_file(external, '#!/bin/sh\nexit 0\n')!
	os.chmod(external, 0o755)!
	assert capture(program, with_args(args, ['select', prefix]), true)! == 'skip\n'
	assert capture(program, with_args(args, ['external', prefix, link]), true)! == external + '\n'

	bad := external + '\n'
	os.cp(external, bad)!
	os.chmod(bad, 0o755)!
	unsafe_path := execute(program, with_args(args, ['external', prefix, bad]), false)!
	assert unsafe_path.stderr.contains('Tabs and newlines are unsupported')
	assert os.real_path(link) == external

	directory := execute(program, with_args(args, ['external', prefix, os.dir(external)]), false)!
	assert directory.stderr.contains('VLS is not executable')
	os.rm(link)!
	os.write_file(link, 'user-installed file')!
	unmanaged := execute(program, with_args(args, ['external', prefix, external]), false)!
	assert unmanaged.stderr.contains('Existing unmanaged VLS')
	assert os.read_file(link)! == 'user-installed file'
}

fn run() ! {
	root := os.join_path(os.temp_dir(), 'vlang-vls-select-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	scripts := os.join_path(os.dir(@DIR), 'scripts')
	selector := os.join_path(root, 'selector')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', selector,
		os.join_path(scripts, 'setup-vls.vsh')], true)!
	exercise([selector], os.join_path(root, 'native prefix'))!
	exercise(['sh', '-eu', '-c', 'script=$1; shift; . "$script"', 'select-vls',
		os.join_path(scripts, 'setup-vls-posix')], os.join_path(root, 'shell prefix'))!
}

run() or { panic(err) }
println('ok - VLS selection preserves external links and checks executable paths with and without V')
