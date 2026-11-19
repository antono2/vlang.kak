// Exercise release discovery with an isolated, read-only Git fixture.
import os
import rand

const listed_release = 'v99.0.0'
const installed_release = 'v1.0.0'
const release_commit = '0000000000000000000000000000000000000002'
const installed_commit = '0000000000000000000000000000000000000001'
const expected_operations = ['ls-remote tags', 'describe', 'rev-parse', 'ls-remote release']

fn fake_git(args []string) ! {
	operations_path := os.getenv('DISCOVERY_GIT_LOG')
	if operations_path == '' {
		return error('Missing discovery fixture log')
	}
	mut operation := ''
	mut response := ''
	if args.len > 5
		&& args[..5] == ['-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=10', 'ls-remote'] {
		if args.last() == 'refs/tags/${listed_release}^{}' {
			operation = 'ls-remote release'
			response = '${release_commit}\t${args.last()}'
		} else if args.last() == 'v[0-9]*' && '--refs' in args && '--tags' in args {
			operation = 'ls-remote tags'
			response = '${release_commit}\trefs/tags/${listed_release}'
		}
	} else if args.len >= 4 && args[0] == '-C' {
		match args[2..] {
			['describe', '--tags', '--always'] {
				operation = 'describe'
				response = installed_release
			}
			['rev-parse', 'HEAD'] {
				operation = 'rev-parse'
				response = installed_commit
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
	println(response)
}

fn discovery(env map[string]string) !string {
	program := os.join_path(@DIR, '..', 'scripts', 'check-updates.sh')
	mut child := os.new_process(program)
	child.set_args(['--background'])
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
	env['VLANG_KAK_PREFIX'] = os.join_path(root, 'prefix')
	env['DISCOVERY_GIT_LOG'] = operations_path

	assert discovery(env)!.contains('Release available: ${listed_release}')
	assert os.read_lines(operations_path)! == expected_operations
	assert discovery(env)! == ''
	assert os.read_lines(operations_path)! == expected_operations
	println('ok - optional release discovery is read-only and limited to one check per week')
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
