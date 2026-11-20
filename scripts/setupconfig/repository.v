// Fast-forward a clean plugin clone before preparing tools for setup.
module setupconfig

import managedfiles { git_at }
import os

pub fn refresh(repo string) !int {
	if !os.is_dir(os.join_path(repo, '.git')) || git_at(repo, ['status', '--porcelain'])! != '' {
		println('Keeping local vlang.kak checkout: it has uncommitted changes or is not a Git clone.')
		return 0
	}

	// Preserve the terminal for credentials and Git diagnostics.
	mut child := os.new_process('git')
	defer { child.close() }
	child.set_args(['-C', repo, 'pull', '--ff-only'])
	child.run()
	child.wait()
	if child.code < 0 {
		return error('Could not fast-forward the plugin checkout.')
	}
	// The setup dispatcher reserves this status for an unavailable V bootstrap.
	return if child.code == 125 { 1 } else { child.code }
}
