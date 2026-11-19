// Validate all prepared tools before switching the managed release links.
import os
import rand

#include <errno.h>

const managed_tools = ['kakoune', 'kak-lsp', 'vls', 'v']

struct LinkChange {
	destination string
	target      string
	previous    string
	candidate   string
}

fn previous_link(path string) !string {
	entry := os.lstat(path) or {
		if err.code() == C.ENOENT {
			return ''
		}
		return err
	}
	if entry.get_filetype() != .symbolic_link {
		return error('Existing unmanaged path: ${path}')
	}
	return os.readlink(path)
}

fn executable_file(path string) bool {
	entry := os.stat(path) or { return false }
	return entry.get_filetype() == .regular && os.is_executable(path)
}

fn plan(prefix string, vls_mode string, vls_path string) ![]LinkChange {
	mut changes := []LinkChange{}
	for name in managed_tools {
		root := os.join_path(prefix, 'opt', 'vlang-' + name)
		candidate := os.join_path(root, 'candidate')
		target := previous_link(candidate)!
		if target == '' {
			continue
		}
		if os.real_path(root) != root || !os.is_dir(candidate)
			|| os.dir(os.real_path(candidate)) != os.join_path(root, 'releases') {
			return error('Prepared release is unavailable or redirected: ${candidate}')
		}
		current := os.join_path(root, 'current')
		changes << LinkChange{
			destination: current
			target:      target
			previous:    previous_link(current)!
			candidate:   candidate
		}
	}
	if vls_mode != 'skip' {
		mut target := vls_path
		if vls_mode == 'upstream' {
			root := os.join_path(prefix, 'opt', 'vlang-vls')
			active := if os.is_link(os.join_path(root, 'candidate')) {
				'candidate'
			} else {
				'current'
			}
			target = os.join_path(root, 'current', 'bin', 'vls')
			if !executable_file(os.join_path(root, active, 'bin', 'vls')) {
				return error('Prepared VLS is unavailable at ${root}/${active}/bin/vls')
			}
		} else if !os.is_abs_path(target) || !executable_file(target) {
			return error('VLS is not executable: ${target}')
		}
		vls_link := os.join_path(prefix, 'bin', 'vls')
		changes << LinkChange{
			destination: vls_link
			target:      target
			previous:    previous_link(vls_link)!
		}
	}
	return changes
}

fn switch_link(target string, destination string) ! {
	os.mkdir_all(os.dir(destination))!
	staged := destination + '.activate.' + rand.uuid_v4()
	defer { os.rm(staged) or {} }
	os.symlink(target, staged)!
	os.rename_dir(staged, destination)!
}

fn restore_link(change LinkChange) ! {
	if previous_link(change.destination)! != change.target {
		return error('Link changed during activation: ${change.destination}')
	}
	if change.previous == '' {
		os.rm(change.destination)!
	} else {
		switch_link(change.previous, change.destination)!
	}
}

fn publish_link(change LinkChange) ! {
	if previous_link(change.destination)! != change.previous {
		return error('Link changed during activation: ${change.destination}')
	}
	switch_link(change.target, change.destination)!
}

fn activate(prefix string, vls_mode string, vls_path string) ! {
	changes := plan(prefix, vls_mode, vls_path)!
	for index, change in changes {
		publish_link(change) or {
			for previous := index - 1; previous >= 0; previous-- {
				restore_link(changes[previous]) or { eprintln('Could not undo activation: ${err}') }
			}
			return err
		}
	}
	for change in changes {
		if change.candidate != '' && (os.readlink(change.candidate) or { '' }) == change.target {
			os.rm(change.candidate) or { eprintln('Could not remove ${change.candidate}: ${err}') }
		}
	}
}

if os.args.len != 4 || !os.is_abs_path(os.args[1])
	|| os.args[2] !in ['upstream', 'external', 'skip'] {
	eprintln('Usage: v run scripts/setup-activation.vsh ABSOLUTE_PREFIX VLS_MODE VLS_PATH')
	exit(2)
}
activate(os.real_path(os.abs_path(os.args[1])), os.args[2], os.args[3]) or {
	eprintln(err)
	exit(1)
}
