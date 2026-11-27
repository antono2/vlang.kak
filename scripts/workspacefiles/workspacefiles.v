// Remember only existing files within an explicitly opened directory.
module workspacefiles

import crypto.sha256
import os
import rand
import x.json2

struct Recent {
	root string
	file string
}

fn state_file(root string) string {
	base := os.getenv_opt('XDG_STATE_HOME') or { os.join_path(os.home_dir(), '.local', 'state') }
	return os.join_path(base, 'vlang.kak', 'workspaces', sha256.hexhash(root) + '.json')
}

pub fn within(root string, file string) bool {
	return file.starts_with(if root == '/' { root } else { root + '/' })
}

pub fn remember(root string, file string) ! {
	if !os.is_file(file) || !within(root, os.real_path(file)) {
		return
	}
	path := state_file(root)
	data := json2.encode(Recent{ root: root, file: os.real_path(file) })
	if os.read_file(path) or { '' } == data {
		return
	}
	os.mkdir_all(os.dir(path), mode: 0o700)!
	stage := path + '.' + rand.uuid_v4()
	defer { os.rm(stage) or {} }
	os.write_file(stage, data)!
	os.chmod(stage, 0o600)!
	os.rename_dir(stage, path)!
}

pub fn initial_file(root string, restore bool) string {
	if restore {
		if data := os.read_file(state_file(root)) {
			if recent := json2.decode[Recent](data) {
				if recent.root == root && os.is_file(recent.file)
					&& within(root, os.real_path(recent.file)) {
					return recent.file
				}
			}
		}
	}
	// Prefer the module at the directory root, then search breadth-first in
	// lexical order. Never follow directory links or enter hidden directories.
	mut pending := [root]
	for pending.len > 0 {
		directory := pending[0]
		pending.delete(0)
		manifest := os.join_path(directory, 'v.mod')
		if os.is_file(manifest) && within(root, os.real_path(manifest)) {
			return manifest
		}
		for name in (os.ls(directory) or { continue }).sorted() {
			path := os.join_path(directory, name)
			if !name.starts_with('.') && !os.is_link(path) && os.is_dir(path) {
				pending << path
			}
		}
	}
	return ''
}
