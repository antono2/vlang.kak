// Exercise release discovery and delivery using isolated Git and Kakoune fixtures.
import editorui { quote }
import os
import rand
import releasetest { capture }
import time

const listed_release = 'v99.0.10'
const installed_release = 'v1.0.0'
const release_commit = '0000000000000000000000000000000000000002'
const installed_commit = '0000000000000000000000000000000000000001'
const expected_operations = ['ls-remote tags', 'describe', 'rev-parse', 'ls-remote release']
const remote_lookup_prefix = ['-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=10', 'ls-remote']
const sigterm_exit_status = 143 // Shell status 128 + SIGTERM.
// Age the stamp past the seven-day background refresh interval.
const expired_stamp_age_days = 8
const fixture_timeout = 15 * time.second
const fixture_poll = 20 * time.millisecond
const notification_session = 'discovery-session'
const notification_client = "client's view"

fn fake_git(args []string) ! {
	operations_path := os.getenv('DISCOVERY_GIT_LOG')
	if operations_path == '' {
		return error('Missing discovery fixture log')
	}
	scenario := os.getenv('DISCOVERY_SCENARIO')
	mut operation := ''
	mut response := ''
	if args.len > remote_lookup_prefix.len && args[..remote_lookup_prefix.len] == remote_lookup_prefix {
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
	if scenario == 'interrupted' && operation == 'ls-remote tags' {
		barrier := os.getenv('DISCOVERY_BARRIER')
		os.write_file(barrier, '')!
		wait_for_file(barrier + '.continue')!
	}
	println(response)
}

fn fake_kak(args []string) ! {
	if args != ['-p', notification_session] {
		return error('Unexpected Kakoune socket arguments: ${args}')
	}
	command := os.get_lines().join('\n') + '\n'
	mut attempts := os.open_append(os.getenv('DISCOVERY_KAK_LOG'))!
	defer { attempts.close() }
	attempts.write_string(command)!
	if os.getenv('DISCOVERY_KAK_FAILURE') == '1' {
		return error('Simulated Kakoune delivery failure')
	}
}

fn wait_for_file(path string) ! {
	deadline := time.sys_mono_now() + u64(fixture_timeout)
	for time.sys_mono_now() < deadline {
		if os.is_file(path) {
			return
		}
		time.sleep(fixture_poll)
	}
	return error('Release discovery did not reach ${path}')
}

fn check_interruption(root string, original map[string]string) ! {
	program := os.join_path(root, 'native-discovery')
	source := os.join_path(@DIR, '..', 'scripts', 'check-updates.vsh')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', program, source], true)!
	state := os.join_path(root, 'interrupted state')
	barrier := os.join_path(root, 'git started')
	mut env := original.clone()
	env['DISCOVERY_SCENARIO'] = 'interrupted'
	env['DISCOVERY_BARRIER'] = barrier
	mut child := os.new_process(program)
	child.set_args([state])
	child.set_environment(env)
	child.use_pgroup = true
	child.set_redirect_stdio()
	child.run()
	defer {
		if child.is_alive() {
			child.signal_pgkill()
			child.wait()
		}
		child.close()
	}
	wait_for_file(barrier)!
	lock_path := os.join_path(state, 'check-lock')
	assert os.is_dir(lock_path)
	child.signal_term()
	os.write_file(barrier + '.continue', '')!
	child.wait()
	assert child.code == sigterm_exit_status
	assert !os.exists(lock_path)
	assert !os.exists(os.join_path(state, 'update-status'))
	assert !os.exists(os.join_path(state, 'update-checked'))
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

fn check_notification(root string, original map[string]string) ! {
	mut env := original.clone()
	state := os.join_path(env['VLANG_KAK_PREFIX'], 'opt', 'vlang-state')
	marker := os.join_path(state, 'update-notified')
	status := os.join_path(state, 'update-status')
	attempts := os.join_path(root, os.file_name(env['VLANG_KAK_PREFIX']) + '-notices')
	env['DISCOVERY_KAK_LOG'] = attempts
	operation_log := env['DISCOVERY_GIT_LOG']
	previous_operations := os.read_file(operation_log)!
	message := "Release available: ${listed_release} (installed: editor's %{ view })"
	os.write_file(status, message + '\n')!
	args := ['--notify', notification_session, notification_client]
	lock_path := os.join_path(state, 'check-lock')
	os.mkdir(lock_path)!
	assert discovery(env, args)! == ''
	assert !os.exists(attempts) && !os.exists(marker)
	os.rmdir(lock_path)!
	env['DISCOVERY_KAK_FAILURE'] = '1'
	if _ := discovery(env, args) {
		return error('Failed Kakoune delivery unexpectedly succeeded')
	}
	assert !os.exists(marker)
	env.delete('DISCOVERY_KAK_FAILURE')
	assert discovery(env, args)! == ''
	assert os.read_file(marker)! == message + '\n'
	expected := 'evaluate-commands -client ${quote(notification_client)} ${quote('echo ' +
		quote(message))}'
	assert os.read_lines(attempts)! == [expected, expected]
	assert discovery(env, args)! == ''
	assert os.read_lines(attempts)! == [expected, expected]
	os.write_file(status, 'Up to date: ${listed_release}\n')!
	assert discovery(env, args)! == ''
	assert os.read_lines(attempts)! == [expected, expected]
	assert os.read_file(operation_log)! == previous_operations
}

fn check_live_notification(root string, kak string, bin string) ! {
	os.rm(os.join_path(bin, 'kak'))!
	os.symlink(kak, os.join_path(bin, 'kak'))!
	prefix := os.join_path(root, 'live prefix')
	state := os.join_path(prefix, 'opt', 'vlang-state')
	os.mkdir_all(state)!
	message := "Release available: editor's %{ view }"
	os.write_file(os.join_path(state, 'update-status'), message + '\n')!
	os.write_file(os.join_path(state, 'update-checked'), '')!
	os.setenv('PATH', bin + ':' + os.getenv('PATH'), true)
	os.setenv('VLANG_KAK_PREFIX', prefix, true)
	file := os.join_path(root, 'demo.v')
	os.write_file(file, 'module main\n')!
	mut editor := editorui.open(kak, root, file)!
	defer { editor.close() }
	source := os.real_path(os.join_path(@DIR, '..', 'rc', 'vlang.kak'))
	editor.remote('source ${quote(source)}')!
	offset := editor.offset()
	editor.remote('set-option global v_update_check_enabled true\nv-update-check-background')!
	editor.wait_event(offset, 'draw_status', [message])!
	marker := os.join_path(state, 'update-notified')
	wait_for_file(marker)!
	assert os.read_file(marker)! == message + '\n'
	println('ok - Kakoune displays the release notice with literal quotes and braces')
}

fn check(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-discovery-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	bin := os.join_path(root, 'bin')
	os.mkdir(bin)!
	// These names dispatch this executable to the Git and Kakoune test peers.
	os.symlink(os.executable(), os.join_path(bin, 'git'))!
	os.symlink(os.executable(), os.join_path(bin, 'kak'))!
	operations_path := os.join_path(root, 'git-operations')
	mut env := os.environ()
	env['PATH'] = bin + ':' + env['PATH']
	env['VLANG_KAK_PREFIX'] = os.join_path(root, 'prefix with spaces')
	env['DISCOVERY_GIT_LOG'] = operations_path

	assert discovery(env, ['--background'])!.contains('Release available: ${listed_release}')
	assert os.read_lines(operations_path)! == expected_operations
	assert discovery(env, ['--background'])! == ''
	assert os.read_lines(operations_path)! == expected_operations
	check_notification(root, env)!
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
		actual := discovery(env, [])!.trim_space()
		assert actual == 'Up to date: ${listed_release}', '${scenario}: ${actual}\n${os.read_file(operations_path)!}'
	}
	env['DISCOVERY_SCENARIO'] = 'ahead'
	old_time := time.utc().add_days(-expired_stamp_age_days).unix()
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
	check_interruption(root, env)!
	// Exercise the supported editor-only setup with no compiler on PATH.
	for tool in ['dirname', 'mkdir', 'rmdir', 'find', 'sed', 'sort', 'tail', 'cut', 'date', 'cat',
		'grep', 'cmp', 'cp', 'mv', 'rm'] {
		os.symlink(os.find_abs_path_of_executable(tool)!, os.join_path(bin, tool))!
	}
	env['PATH'] = bin
	env['VLANG_KAK_PREFIX'] = os.join_path(root, 'fallback')
	env.delete('DISCOVERY_SCENARIO')
	fallback_lock := os.join_path(env['VLANG_KAK_PREFIX'], 'opt', 'vlang-state', 'check-lock')
	os.mkdir_all(fallback_lock)!
	previous_operations := os.read_file(operations_path)!
	assert discovery(env, [])! == ''
	assert os.read_file(operations_path)! == previous_operations
	os.rmdir(fallback_lock)!
	assert discovery(env, ['--background'])!.contains('Release available: ${listed_release}')
	assert discovery(env, ['--background'])! == ''
	check_notification(root, env)!
	if kak != '' {
		check_live_notification(root, kak, bin)!
	}
	println('ok - release discovery and notification share one lock in both paths')
}

fn run() ! {
	args := os.args[1..]
	match os.file_name(os.args[0]) {
		'git' { fake_git(args)! }
		'kak' { fake_kak(args)! }
		else { check(args[0] or { '' })! }
	}
}

run() or {
	eprintln(err)
	exit(1)
}
