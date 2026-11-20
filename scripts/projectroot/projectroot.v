// Locate the nearest V module or Git worktree for project commands.
module projectroot

import os

pub fn find(start string) string {
	mut directory := start
	for {
		git := os.join_path(directory, '.git')
		if os.is_file(os.join_path(directory, 'v.mod')) || os.is_dir(git) || os.is_file(git) {
			return directory
		}
		parent := os.dir(directory)
		if parent == directory {
			return start
		}
		directory = parent
	}
	return start
}
