// Update the managed tools and tell the original Kakoune client to restart.
import os

const usage = 'Usage: update-session.sh PREFIX SESSION CLIENT CLIENT_PID [update options]'

fn update(prefix string, options []string) int {
	mut child := os.new_process(os.join_path(@DIR, 'update.sh'))
	defer { child.close() }
	mut args := ['--prefix', prefix]
	args << options
	child.set_args(args)
	child.run()
	child.wait()
	return child.code
}

fn request_restart(kak string, session string, client string) bool {
	quoted := client.replace("'", "''")
	command := "evaluate-commands -client '${quoted}' %{ v-restart }\n"
	mut child := os.new_process(kak)
	defer { child.close() }
	child.set_args(['-p', session])
	child.set_redirect_stdio_merged()
	child.run()
	os.signal_ignore(.pipe)
	child.stdin_write(command)
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	diagnostics := child.stdout_slurp()
	child.wait()
	if diagnostics != '' {
		eprint(diagnostics)
	}
	return child.code == 0
}

fn run(args []string) !int {
	if (args[0] or { '' }) in ['--help', '-h'] {
		println(usage)
		return 0
	}
	if args.len < 4 {
		return error_with_code(usage, 2)
	}
	prefix, session, client, pid := args[0], args[1], args[2], args[3]
	options := args[4..]
	if '--prefix' in options {
		return error_with_code('The in-editor update keeps the current installation prefix.', 2)
	}
	if pid == '' || !pid.bytes().all(it >= `0` && it <= `9`) {
		return error_with_code('Invalid Kakoune client PID.', 2)
	}
	// Keep the path to the executable serving the current session before activation.
	kak := os.real_path('/proc/${pid}/exe')
	if !os.is_executable(kak) || !os.is_file(kak) {
		return error('Cannot locate the running Kakoune executable.')
	}
	status := update(prefix, options)
	if status != 0 {
		return status
	}
	println('Update installed. Requesting restart.')
	println('If Kakoune remains open, check *debug* for the restart error. Save edits, close additional clients or stop debugging, then run :v-restart.')
	println('For unsaved buffers and multiple views, use :v-restart-recover and confirm the recovery restart.')
	if !request_restart(kak, session, client) {
		eprintln('The update succeeded, but the original session could not receive the restart request.')
		eprintln("Run '${prefix}/bin/kak-v' to start the updated IDE; existing recovery checkpoints are kept.")
		return 1
	}
	return 0
}

code := run(os.args[1..]) or {
	eprintln(err.msg())
	exit(if err.code() == 2 { 2 } else { 1 })
}
exit(code)
