// Test installer diagnostics and package command arguments without package changes.
import os
import rand
import releasetest { capture, execute }

const minimal_options = ['--no-build', '--no-lsp', '--no-vls', '--no-explorer']
const package_commands = ['update',
	'install --yes build-essential git curl tar unzip ripgrep tmux gdb']

fn fixture_executable(path string, script string) ! {
	os.write_file(path, script)!
	os.chmod(path, 0o755)!
}

fn add_shell_tools(bin string, tools []string) ! {
	for tool in tools {
		os.symlink(os.find_abs_path_of_executable(tool)!, os.join_path(bin, tool))!
	}
}

fn check_preflight(program string, root string) ! {
	bin := os.join_path(root, 'preflight bin')
	os.mkdir(bin)!
	add_shell_tools(bin, ['git', 'sed', 'awk', 'sort', 'mktemp', 'sha256sum', 'readlink'])!
	mut env := os.environ()
	env['PATH'] = bin
	mut args := ['preflight']
	args << minimal_options
	capture(program, args, true, environment: env)!
	args << '--managed-v'
	missing := execute(program, args, false, environment: env)!
	for tool in ['gcc', 'make', 'ar'] {
		assert missing.stderr.contains('Missing: ${tool}'), missing.stderr
	}

	fixture_executable(os.join_path(bin, 'make'), '#!/bin/sh\nexit 0\n')!
	compiler := os.join_path(bin, 'C++ test compiler')
	env['CXX'] = compiler
	args = ['preflight', '--no-lsp', '--no-vls', '--no-explorer']
	missing_compiler := execute(program, args, false, environment: env)!
	assert missing_compiler.stderr.contains('Missing: ${compiler} (build Kakoune)'), missing_compiler.stderr
	fixture_executable(compiler, r'#!/bin/sh
[ "$*" = "-std=c++2b -x c++ -fsyntax-only -" ] || exit 2
if IFS= read -r unexpected; then exit 3; fi
exit "${TEST_CPP_STATUS:-0}"
')!
	capture(program, args, true, environment: env)!
	env['TEST_CPP_STATUS'] = '1'
	cpp_failure := execute(program, args, false, environment: env)!
	assert cpp_failure.stderr.contains('C++ compiler must support -std=c++2b.')
	add_shell_tools(bin, ['dirname', 'sh'])!
	env['VLANG_KAK_PREFIX'] = os.join_path(root, 'without a compiler')
	entry := os.join_path(os.dir(@DIR), 'scripts', 'preflight.sh')
	assert execute(entry, args[1..], false, environment: env)!.stderr == cpp_failure.stderr
}

fn check_dependencies(program string, root string) ! {
	bin := os.join_path(root, 'package bin')
	os.mkdir(bin)!
	// The child receives only these two executables. Neither can reach the host apt-get.
	fixture_executable(os.join_path(bin, 'sudo'), r'#!/bin/sh
[ "$1" = apt-get ] || exit 2
exec "$@"
')!
	fixture_executable(os.join_path(bin, 'apt-get'), r'#!/bin/sh
printf "%s\n" "$*" >> "$PACKAGE_LOG"
exit "${TEST_APT_STATUS:-0}"
')!
	setup_log := os.join_path(root, 'package.log')
	mut env := os.environ()
	env['PATH'] = bin
	env['PACKAGE_LOG'] = setup_log
	// Other distributions deliberately have a dependency message instead of an apt recipe.
	legacy :=
		os.execute(os.quoted_path(os.join_path(os.dir(@DIR), 'scripts', 'dependencies-posix')))
	if legacy.exit_code != 0 {
		unavailable := execute(program, ['dependencies'], false, environment: env)!
		assert unavailable.stderr.contains('automatic package recipe')
			|| unavailable.stderr.contains('Unknown distribution')
		return
	}
	preview := capture(program, ['dependencies'], true, environment: env)!
	assert preview == legacy.output && !os.exists(setup_log)
	capture(program, ['dependencies', '--apply'], true, environment: env)!
	assert os.read_lines(setup_log)! == package_commands
	os.rm(setup_log)!
	env['TEST_APT_STATUS'] = '1'
	capture(program, ['dependencies', '--apply'], false, environment: env)!
	assert os.read_lines(setup_log)! == [package_commands[0]]
	os.rm(setup_log)!
	add_shell_tools(bin, ['dirname', 'sh', 'id'])!
	env['VLANG_KAK_PREFIX'] = os.join_path(root, 'without a compiler')
	env.delete('TEST_APT_STATUS')
	entry := os.join_path(os.dir(@DIR), 'scripts', 'dependencies.sh')
	assert capture(entry, [], true, environment: env)! == preview
	assert !os.exists(setup_log)
	capture(entry, ['--apply'], true, environment: env)!
	assert os.read_lines(setup_log)! == package_commands
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-setup-checks-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	program := os.join_path(root, 'setup-checks')
	source := os.join_path(os.dir(@DIR), 'scripts', 'setup-checks.vsh')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', program, source], true)!
	check_preflight(program, root)!
	check_dependencies(program, root)!
	println('ok - setup checks respect selected components and package preparation requires explicit apply')
}

check() or {
	eprintln(err)
	exit(1)
}
