// Capture and restore the managed files shared by setup and rollback.
import managedfiles { settings_block }
import os
import rand

#include <errno.h>

const tool_paths = ['bin/kak', 'bin/kak-v', 'bin/vls', 'bin/v', 'opt/vlang-kakoune/current',
	'opt/vlang-kak-lsp/current', 'opt/vlang-vls/current', 'opt/vlang-v/current',
	'opt/vlang-kakoune/ide-config/kak/kakrc', 'opt/vlang-kakoune/ide-config/kak/autoload/vlang.kak',
	'opt/vlang-kakoune/ide-config/kak/autoload/vlang-site-runtime']
const personal_paths = ['kak/kakrc', 'kak/autoload/vlang.kak', 'kak/autoload/vlang-site-runtime']

fn present(path string) !bool {
	info := os.lstat(path) or {
		if err.code() == C.ENOENT {
			return false
		}
		return err
	}
	if info.get_filetype() !in [.regular, .symbolic_link] {
		return error('Expected a file or symbolic link at ${path}.')
	}
	return true
}

fn check_parent(path string) ! {
	mut parent := os.dir(path)
	for {
		info := os.lstat(parent) or {
			if err.code() != C.ENOENT {
				return err
			}
			parent = os.dir(parent)
			continue
		}
		if info.get_filetype() != .directory || os.real_path(parent) != parent {
			return error('Refusing a redirected or non-directory parent for ${path}.')
		}
		return
	}
}

fn copy_entry(source string, target string) ! {
	// The platform copy preserves ownership, ACLs and full timestamp precision.
	// Pass each argument directly and keep symlink targets relative when saved.
	mut child := os.new_process('/bin/cp')
	child.set_args(['-Pp', '--', source, target])
	child.run()
	child.wait()
	status := child.code
	child.close()
	if status != 0 {
		return error('Could not copy ${source} to ${target} (exit ${status}).')
	}
}

fn save_group(root string, destination string, paths []string, personal bool) ! {
	marker := if personal { 'personal-paths' } else { 'paths' }
	marker_path := os.join_path(destination, marker)
	check_parent(marker_path)!
	if present(marker_path)! {
		return error('Snapshot already recorded at ${destination}.')
	}
	os.mkdir_all(destination)!
	stage := os.join_path(destination, '.capture-' + rand.uuid_v4())
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	for relative in paths {
		source := os.join_path(root, relative)
		target := if personal {
			os.join_path(stage, 'personal', relative)
		} else {
			os.join_path(stage, relative)
		}
		if !personal {
			check_parent(source)!
		}
		os.mkdir_all(os.dir(target))!
		if present(source)! {
			copy_entry(source, target)!
		}
	}
	if personal {
		os.write_file(os.join_path(stage, 'config-home'), root + '\n')!
		kakrc := os.join_path(root, 'kak', 'kakrc')
		if os.is_file(kakrc) {
			copy_entry(os.real_path(kakrc), os.join_path(stage, 'kakrc-content'))!
		}
	}
	mut names := os.ls(stage)!.sorted()
	pending := os.join_path(stage, marker)
	os.write_file(pending, paths.join('\n') + '\n')!
	names << marker // Publish the completion marker only after the payload.
	for name in names {
		target := os.join_path(destination, name)
		if os.exists(target) || os.is_link(target) {
			return error('Snapshot output already exists at ${target}.')
		}
	}
	for index, name in names {
		os.rename_dir(os.join_path(stage, name), os.join_path(destination, name)) or {
			for earlier in names[..index] {
				os.rename_dir(os.join_path(destination, earlier), os.join_path(stage, earlier)) or {
					eprintln(err)
				}
			}
			return err
		}
	}
}

fn snapshot_paths(marker string, allowed []string) ![]string {
	check_parent(marker)!
	if !os.is_file(marker) || os.is_link(marker) {
		return error('No valid tool snapshot at ${marker}.')
	}
	mut paths := []string{}
	for relative in os.read_lines(marker)! {
		if relative !in allowed {
			return error('Unexpected snapshot path: ${relative}')
		}
		if relative !in paths {
			paths << relative
		}
	}
	return paths
}

struct Replacement {
	target   string
	source   string
	contents ?string
	original string
}

fn restoration(root string, snapshot string, paths []string, personal bool, saved_kakrc string) ![]Replacement {
	mut replacements := []Replacement{}
	for relative in paths {
		path := os.join_path(root, relative)
		// The config directory can intentionally use symlinked parent directories.
		target := if personal {
			os.join_path(os.real_path(os.dir(path)), os.file_name(path))
		} else {
			path
		}
		source := os.join_path(snapshot, relative)
		check_parent(target)!
		check_parent(source)!
		saved := present(source)!
		if relative == 'kak/kakrc' && (saved_kakrc != '' || !saved) && os.is_file(target) {
			current := settings_block(target)!
			owned := if saved_kakrc == '' { '' } else { settings_block(saved_kakrc)!.owned }
			separator := if owned != '' && current.remaining != ''
				&& !current.remaining.ends_with('\n') {
				'\n'
			} else {
				''
			}
			if current.owned != owned {
				replacements << Replacement{
					target:   os.real_path(target)
					contents: current.remaining + separator + owned
					original: current.original
				}
			}
		} else if saved || present(target)! {
			replacements << Replacement{
				target: target
				source: if saved { source } else { '' }
			}
		}
	}
	return replacements
}

fn restore(prefix string, snapshot string) ! {
	mut actions := restoration(prefix, snapshot, snapshot_paths(os.join_path(snapshot, 'paths'),
		tool_paths)!, false, '')!
	personal := os.join_path(snapshot, 'personal-paths')
	if present(personal)! {
		config_path := os.join_path(snapshot, 'config-home')
		if !os.is_file(config_path) || os.is_link(config_path) {
			return error('Missing personal configuration location in ${snapshot}.')
		}
		config := (os.read_file(config_path)!).trim_right('\n')
		if !os.is_abs_path(config) || os.norm_path(config) != config {
			return error('Invalid personal configuration location in ${snapshot}.')
		}
		saved_kakrc := os.join_path(snapshot, 'kakrc-content')
		if os.is_link(saved_kakrc) {
			return error('Refusing redirected saved Kakoune settings.')
		}
		actions << restoration(config, os.join_path(snapshot, 'personal'), snapshot_paths(personal,
			personal_paths)!, true, if present(saved_kakrc)! {
			saved_kakrc
		} else {
			''
		})!
	}
	apply(actions)!
}

fn apply(actions []Replacement) ! {
	mut staged := []string{}
	defer {
		for path in staged {
			if path != '' && !os.is_file(os.join_path(path, 'keep-backup')) {
				os.rmdir_all(path) or { eprintln(err) }
			}
		}
	}
	for action in actions {
		parent := os.dir(action.target)
		os.mkdir_all(parent)!
		directory := os.join_path(parent, '.vlang-restore-' + rand.uuid_v4())
		os.mkdir(directory, mode: 0o700)!
		staged << directory
		old := os.join_path(directory, 'previous')
		next := os.join_path(directory, 'next')
		if present(action.target)! {
			copy_entry(action.target, old)!
		}
		if contents := action.contents {
			// Write to the original inode when applying the block so linked settings keep their identity.
			os.write_file(next, contents)!
		} else if action.source != '' {
			copy_entry(action.source, next)!
		}
	}
	for index, action in actions {
		commit(action, staged[index]) or {
			for previous := index - 1; previous >= 0; previous-- {
				backup := os.join_path(staged[previous], 'previous')
				revert(actions[previous], backup) or {
					eprintln('Could not revert ${actions[previous].target}: ${err}. Kept ${staged[previous]}.')
					staged[previous] = ''
				}
			}
			return err
		}
	}
}

fn commit(action Replacement, stage string) ! {
	next := os.join_path(stage, 'next')
	if _ := action.contents {
		if !os.is_file(action.target) || os.is_link(action.target)
			|| os.read_file(action.target)! != action.original {
			return error('Kakoune settings changed during restore: ${action.target}.')
		}
		contents := os.read_file(next)!
		os.write_file(action.target, contents) or {
			os.write_file(action.target, action.original) or {
				os.write_file(os.join_path(stage, 'keep-backup'), '') or { eprintln(err) }
				eprintln('Could not revert ${action.target}: ${err}. Backup is in ${stage}.')
			}
			return err
		}
	} else {
		replace(action.target, next)!
	}
}

fn revert(action Replacement, backup string) ! {
	if _ := action.contents {
		os.write_file(action.target, action.original)!
	} else {
		replace(action.target, backup)!
	}
}

fn replace(target string, staged string) ! {
	if present(staged)! {
		os.rename_dir(staged, target)!
	} else if present(target)! {
		os.rm(target)!
	}
}

fn main() {
	if os.args.len != 4 || !os.is_abs_path(os.args[2]) || os.args[3] == '' {
		eprintln('Usage: managed-snapshot.vsh snapshot|snapshot-personal|restore ABSOLUTE_ROOT DIRECTORY')
		exit(2)
	}
	root := os.real_path(os.args[2])
	directory := os.abs_path(os.args[3])
	match os.args[1] {
		'snapshot' { save_group(root, directory, tool_paths, false) or { fatal(err) } }
		'snapshot-personal' { save_group(root, directory, personal_paths, true) or { fatal(err) } }
		'restore' { restore(root, directory) or { fatal(err) } }
		else { fatal(error('Unknown snapshot operation.')) }
	}
}

fn fatal(err IError) {
	eprintln(err)
	exit(1)
}
