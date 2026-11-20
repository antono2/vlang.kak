// Check that both process inspectors use complete, literal environment entries.
import os
import rand
import releasetest { capture_result }
import time

const process_wait = 5 * time.second
const poll_interval = 10 * time.millisecond

fn wait_for_exec(pid int, executable string) ! {
	deadline := time.sys_mono_now() + u64(process_wait)
	for time.sys_mono_now() < deadline {
		if (os.readlink('/proc/${pid}/exe') or { '' }) == executable {
			return
		}
		time.sleep(poll_interval)
	}
	return error('Process ${pid} did not execute ${executable}')
}

fn stop(mut child os.Process) {
	if child.is_alive() {
		child.signal_kill()
		child.status = .running
		child.wait()
	}
	child.close()
}

fn exercise(root string) ! {
	prefix := os.join_path(root, "user's managed prefix")
	managed_program := os.join_path(prefix, 'opt', 'vlang-test', 'sleep')
	sleep := os.real_path(os.find_abs_path_of_executable('sleep')!)
	os.mkdir_all(os.dir(managed_program))!
	os.cp(sleep, managed_program)!
	os.chmod(managed_program, 0o755)!
	mut managed := os.new_process(managed_program)
	managed.set_args(['30'])
	managed.set_environment({
		'VLANG_KAK_PREFIX': prefix
	})
	managed.run()
	defer { stop(mut managed) }
	wait_for_exec(managed.pid, managed_program)!

	mut unrelated := os.new_process(sleep)
	unrelated.set_args(['30'])
	unrelated.set_environment({
		'VLANG_KAK_PREFIX': prefix + '-other'
		'MULTILINE':        'line one\nVLANG_KAK_PREFIX=' + prefix
	})
	unrelated.run()
	defer { stop(mut unrelated) }
	wait_for_exec(unrelated.pid, sleep)!

	fallback_bin := os.join_path(root, 'bootstrap-bin')
	os.mkdir(fallback_bin)!
	for tool in ['awk', 'dirname', 'readlink'] {
		os.symlink(os.find_abs_path_of_executable(tool)!, os.join_path(fallback_bin, tool))!
	}
	script := os.join_path(os.dir(@DIR), 'scripts', 'active-tools.sh')
	for path in [os.getenv('PATH'), fallback_bin] {
		mut environment := os.environ()
		environment['PATH'] = path
		output := capture_result(script, [prefix], environment: environment)!
		lines := output.stdout.split_into_lines()
		if output.code != 0 || output.stderr.contains('Using shell inspection.')
			|| managed_program !in lines || 'managed-process:${managed.pid}' !in lines
			|| 'managed-process:${unrelated.pid}' in lines {
			return error('Unexpected process inspection result for PATH=${path}\n${output.stdout}${output.stderr}')
		}
	}
}

scratch := os.join_path(os.temp_dir(), 'vlang-active-tools.' + rand.uuid_v4())
os.mkdir(scratch) or { panic(err) }
defer { os.rmdir_all(scratch) or {} }
exercise(scratch) or { panic(err) }
println('ok - active tool inspector matches executable paths and exact environment entries with and without V')
