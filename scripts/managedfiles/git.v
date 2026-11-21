// Invoke Git without shell argument expansion.
module managedfiles

import os
import time

const git_output_poll_interval = 15 * time.millisecond

pub fn git_at(repo string, args []string) !string {
	mut child := os.new_process('git')
	defer { child.close() }
	mut command := ['-C', repo]
	command << args
	child.set_args(command)
	child.set_redirect_stdio()
	child.run()
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	mut output := ''
	mut diagnostics := ''
	for child.is_alive() {
		output += child.stdout_read()
		diagnostics += child.stderr_read()
		time.sleep(git_output_poll_interval)
	}
	output += child.stdout_slurp()
	diagnostics += child.stderr_slurp()
	child.wait()
	if child.code != 0 {
		return error('Git ${args.join(' ')} failed in ${repo}: ${diagnostics.trim_space()}')
	}
	return output.trim_right('\n')
}
