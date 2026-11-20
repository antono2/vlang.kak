// Restore missing symlinks from the installation's ownership record.
module managedfiles

import os

fn managed_link(path string, prefix string, config string) bool {
	bin := os.join_path(prefix, 'bin')
	if os.dir(path) == bin && os.file_name(path) in ['kak', 'kak-v', 'vls', 'v'] {
		return true
	}
	if os.is_abs_path(config) && os.dir(path) == os.join_path(config, 'kak', 'autoload')
		&& os.file_name(path) in ['vlang.kak', 'vlang-site-runtime'] {
		return true
	}
	return ['kakoune', 'kak-lsp', 'vls', 'v'].any(path.starts_with(
		os.join_path(prefix, 'opt', 'vlang-' + it) + '/'))
}

fn redirected(path string) bool {
	if os.norm_path(path) != path {
		return true
	}
	// Resolve the closest existing ancestor even if the link's parent is missing.
	mut parent := os.dir(path)
	for !os.exists(parent) && !os.is_link(parent) {
		parent = os.dir(parent)
	}
	return os.is_link(parent) || os.real_path(parent) != parent
}

pub fn repair(prefix string) ! {
	state := os.join_path(prefix, 'opt', 'vlang-state')
	manifest := os.join_path(state, 'manifest.tsv')
	if !os.exists(manifest) && !os.is_link(manifest) {
		return
	}
	entries := read_manifest(manifest)!
	config_file := os.join_path(state, 'config-home')
	config := if os.is_file(config_file) {
		(os.read_file(config_file)!).trim_right('\n')
	} else {
		''
	}
	for path in entries.keys().sorted() {
		entry := entries[path]
		if entry.kind != 'link' || !managed_link(path, prefix, config) {
			continue
		}
		if redirected(path) {
			println('Keep redirected path: ${path}')
			continue
		}
		if os.is_link(path) {
			if os.readlink(path)! != entry.identity {
				println('Keep changed link: ${path}')
			}
		} else if os.exists(path) {
			println('Keep replacement file: ${path}')
		} else {
			os.mkdir_all(os.dir(path))!
			os.symlink(entry.identity, path)!
			println('Repaired link: ${path}')
		}
	}
}
