// Exercise release discovery with an isolated, read-only Git fixture.
import os
import rand
import time

const listed_release = 'v99.0.10'
const installed_release = 'v1.0.0'
const release_commit = '0000000000000000000000000000000000000002'
const installed_commit = '0000000000000000000000000000000000000001'
const expected_operations = ['ls-remote tags', 'describe', 'rev-parse', 'ls-remote release']

fn fake_git(args []string) ! {
	operations_path := os.getenv('DISCOVERY_GIT_LOG')
	if operations_path == '' {
		return error('Missing discovery fixture log')
	}
	scenario := os.getenv('DISCOVERY_SCENARIO')
	mut operation := ''
	mut response := ''
	if args.len > 5
		&& args[..5] == ['-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=10', 'ls-remote'] {
		if args.last() == 'refs/tags/${listed_release}^{}' {
			operation = 'ls-remote release'
			if scenario != 'lightweight' {
				response = '${release_commit}\t${args.last()}'
			}
		} else if args.last() == 'v[0-9]*' && '--refs' in args && '--tags' in args {
			operation = 'ls-remote tags'
			// Deliberately unsorted, with a prerelease that should be ignored.
			response = '${release_commit}\trefs/tags/${listed_release}\n' +
				'${installed_commit}\trefs/tags/v100.0.0-rc.1\n' +
				'${installed_commit}\trefs/tags/v99.0.9'
		}
	} else if args.len >= 4 && args[0] == '-C' {
		match args[2..] {
			['describe', '--tags', '--always'] {
				operation = 'describe'
				response = if scenario == 'ahead' {
					'${listed_release}-3-gabc123'
				} else {
					installed_release
				}
			}
			['rev-parse', 'HEAD'] {
				operation = 'rev-parse'
				response = if scenario in ['annotated', 'lightweight'] {
					release_commit
				} else {
					installed_commit
				}
			}
			else {}
		}
	}
	mut file := os.open_append(operations_path)!
	defer { file.close() }
	if operation == '' {
		file.writeln('unexpected: ${args.join(' ')}')!
		return error('Unexpected Git arguments in release discovery')
	}
	file.writeln(operation)!
	if scenario == 'network_failure' && operation == 'ls-remote release' {
		return error('Simulated release lookup failure')
	}
	println(response)
}

fn discovery(env map[string]string, args []string) !string {
	program := os.join_path(@DIR, '..', 'scripts', 'check-updates.sh')
	mut child := os.new_process(program)
	child.set_args(args)
	child.set_environment(env)
	child.set_redirect_stdio()
	child.run()
	defer { child.close() }
	// Output is bounded by the local Git fixture and the one-line release status.
	child.wait()
	output := child.stdout_read()
	if child.code != 0 {
		return error('Release discovery failed (${child.code}): ${output}${child.stderr_read()}')
	}
	return output
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-discovery-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	bin := os.join_path(root, 'bin')
	os.mkdir(bin)!
	// The script runs as the checker or as Git, depending on the executable name.
	os.symlink(os.executable(), os.join_path(bin, 'git'))!
	operations_path := os.join_path(root, 'git-operations')
	mut env := os.environ()
	env['PATH'] = bin + ':' + env['PATH']
	env['VLANG_KAK_PREFIX'] = os.join_path(root, 'prefix with spaces')
	env['DISCOVERY_GIT_LOG'] = operations_path

	assert discovery(env, ['--background'])!.contains('Release available: ${listed_release}')
	assert os.read_lines(operations_path)! == expected_operations
	assert discovery(env, ['--background'])! == ''
	assert os.read_lines(operations_path)! == expected_operations
	state := os.join_path(env['VLANG_KAK_PREFIX'], 'opt', 'vlang-state')
	stamp := os.join_path(state, 'update-checked')
	status := os.join_path(state, 'update-status')
	lock_path := os.join_path(state, 'check-lock')
	os.mkdir(lock_path)!
	assert discovery(env, [])! == ''
	assert os.read_lines(operations_path)! == expected_operations
	os.rmdir(lock_path)!

	for scenario in ['annotated', 'lightweight'] {
		env['DISCOVERY_SCENARIO'] = scenario
		assert discovery(env, [])!.trim_space() == 'Up to date: ${listed_release}'
	}
	env['DISCOVERY_SCENARIO'] = 'ahead'
	old_time := time.utc().unix() - 8 * 24 * 60 * 60
	os.utime(stamp, old_time, old_time)!
	assert discovery(env, ['--background'])!.contains('Installed: ${listed_release}-3-gabc123.')
	previous_status := os.read_file(status)!
	previous_stamp := os.read_file(stamp)!
	env['DISCOVERY_SCENARIO'] = 'network_failure'
	mut failure := ''
	if output := discovery(env, []) {
		return error('The failed Git lookup unexpectedly succeeded: ${output}')
	} else {
		failure = err.msg()
	}
	assert failure.contains('Simulated release lookup failure')
	assert os.read_file(status)! == previous_status && os.read_file(stamp)! == previous_stamp
	assert !os.exists(lock_path)
	// Exercise the supported editor-only setup with no compiler on PATH.
	for tool in ['dirname', 'mkdir', 'rmdir', 'find', 'sed', 'sort', 'tail', 'cut', 'date', 'cat'] {
		os.symlink(os.find_abs_path_of_executable(tool)!, os.join_path(bin, tool))!
	}
	env['PATH'] = bin
	env['VLANG_KAK_PREFIX'] = os.join_path(root, 'fallback')
	env.delete('DISCOVERY_SCENARIO')
	assert discovery(env, ['--background'])!.contains('Release available: ${listed_release}')
	assert discovery(env, ['--background'])! == ''
	println('ok - optional release discovery is read-only, locked and limited to one weekly check')
}

if os.file_name(os.args[0]) == 'git' {
	fake_git(os.args[1..]) or {
		eprintln(err)
		exit(1)
	}
} else {
	check() or {
		eprintln(err)
		exit(1)
	}
}
