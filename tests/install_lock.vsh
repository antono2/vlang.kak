// Verify that installation recovery clears only stale, owned locks.
import os
import rand
import time

// /proc/PID/stat fields following comm start at field 3. starttime is field 22.
const process_start_index = 22 - 3
const owner_timeout = 5 * time.second
const owner_poll = 10 * time.millisecond

const owner_setup = '. "$1/scripts/install-lock.inc"; prefix=$2; state=$prefix/opt/vlang-state; '

fn check_status(prefix string, expected int, clear bool) !string {
	command := os.quoted_path(os.join_path(@DIR, '..', 'scripts', 'lock.sh'))
	option := if clear { ' --clear-stale' } else { '' }
	result := os.execute('${command} --prefix ${os.quoted_path(prefix)}${option}')
	if result.exit_code != expected {
		return error('Expected installation lock status ${expected}, got ${result.exit_code}\n${result.output}')
	}
	return result.output
}

fn process_start(pid int) !string {
	record := os.read_file('/proc/${pid}/stat')!
	tail := record.last_index(') ') or { return error('Missing process name terminator') }
	return record[tail + ') '.len..].fields()[process_start_index] or {
		return error('Missing process start time')
	}
}

fn kill_owner(mut child os.Process) {
	if child.is_alive() {
		child.signal_kill()
		child.status = .running
		child.wait()
	}
}

fn wait_for_owner(owner string, mut child os.Process) ! {
	deadline := time.sys_mono_now() + u64(owner_timeout)
	for time.sys_mono_now() < deadline && child.is_alive() {
		record := os.read_file(owner) or { '' }
		if record.trim_space().ends_with(' interrupted') {
			return
		}
		time.sleep(owner_poll)
	}
	return error('Child did not record its lock owner')
}

fn exercise(prefix string) ! {
	lock_dir := os.join_path(prefix, 'opt', 'vlang-state', 'lock')
	os.mkdir_all(lock_dir)!
	owner := os.join_path(lock_dir, 'owner')
	assert check_status(prefix, 2, false)!.contains('unknown owner')
	check_status(prefix, 1, true)!
	assert os.is_dir(lock_dir)

	pid := os.getpid()
	os.write_file(owner, '${pid} ${process_start(pid)!} setup\n')!
	assert check_status(prefix, 1, false)!.contains('active setup')
	check_status(prefix, 1, true)!
	assert os.exists(owner)

	// An active PID with a different start time belongs to a different process.
	os.write_file(owner, '${pid} 0 setup\n')!
	assert check_status(prefix, 3, false)!.contains('stale setup')
	unexpected := os.join_path(lock_dir, 'personal')
	os.write_file(unexpected, 'keep')!
	check_status(prefix, 1, true)!
	assert os.read_file(unexpected)! == 'keep' && os.exists(owner)
	os.rm(unexpected)!
	assert check_status(prefix, 0, true)!.contains('Stale lock cleared')
	assert !os.exists(lock_dir)
	check_status(prefix, 0, false)!

	repo := os.dir(@DIR)
	command := owner_setup + 'lock_acquire test; lock_release'
	release :=
		os.execute('sh -eu -c ${os.quoted_path(command)} test ${os.quoted_path(repo)} ${os.quoted_path(prefix)}')
	assert release.exit_code == 0, release.output
	assert !os.exists(lock_dir)

	mut child := os.new_process(os.find_abs_path_of_executable('sh')!)
	child.set_args(['-eu', '-c', owner_setup + 'lock_acquire interrupted; exec sleep 30', 'test',
		repo, prefix])
	child.run()
	defer {
		kill_owner(mut child)
		child.close()
	}
	wait_for_owner(owner, mut child)!
	kill_owner(mut child)
	assert check_status(prefix, 3, false)!.contains('stale interrupted')
	check_status(prefix, 0, true)!
	assert !os.exists(lock_dir)
}

fn check() ! {
	prefix := os.join_path(os.temp_dir(), 'vlang-lock-' + rand.uuid_v4())
	os.mkdir(prefix, mode: 0o700)!
	defer { os.rmdir_all(prefix) or {} }
	exercise(prefix)!
	println('ok - active, unknown, stale and modified installation locks; PID reuse and owner release')
}

check() or {
	eprintln(err)
	exit(1)
}
