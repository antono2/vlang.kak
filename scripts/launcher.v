// Keep the managed editor's release lease and replay checkpoints after a restart.
module main

import os
import rand

const restart_status = 75
const command_not_found_status = 127
const server_flags = ['-c', '-C', '-d', '-p', '-f']
const leased_tools = ['kakoune', 'kak-lsp', 'vls', 'v']

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn owns_client(args []string) bool {
	mut value := false
	for arg in args {
		if value {
			value = false
			continue
		}
		if arg == '--' {
			break
		}
		if arg in server_flags {
			return false
		}
		value = arg in ['-e', '-E', '-s', '-ui', '-debug', '-i']
	}
	return true
}

fn directory_args(args []string) ![]string {
	// Connection, filter and headless modes retain Kakoune's original CLI.
	mut directory := ''
	mut commands := []string{}
	mut result := []string{}
	mut options := true
	mut index := 0
	for index < args.len {
		arg := args[index]
		if options && arg == '--' {
			options = false
			index++
			continue
		}
		if options && arg in server_flags {
			return args
		}
		if options && arg in ['-e', '-E', '-s', '-ui', '-debug', '-i'] && index + 1 < args.len {
			if arg == '-e' { commands << args[index + 1] } else { result << args[index..index + 2] }
			index += 2
			continue
		}
		if (!options || (!arg.starts_with('-') && !arg.starts_with('+'))) && os.is_dir(arg) {
			if directory != '' {
				return error('Open one directory per kak-v session.')
			}
			directory = os.real_path(arg)
		} else {
			result << if !options && (arg.starts_with('-') || arg.starts_with('+')) {
				os.abs_path(arg)
			} else {
				arg
			}
		}
		index++
	}
	if args.len == 0 {
		directory = os.getwd()
	}
	if directory != '' {
		commands.prepend('v-workspace-start ' + quote(directory))
	}
	if commands.len > 0 { result << ['-e', commands.join('\n')] }
	return result
}

fn has_checkpoint(path string) bool {
	info := os.stat(path) or { return false }
	return info.size > 0
}

fn start_editor(args []string, env map[string]string) !int {
	editor := os.find_abs_path_of_executable('kak') or {
		return error_with_code('kak: executable not found', command_not_found_status)
	}
	mut child := os.new_process(editor)
	defer { child.close() }
	child.set_args(args)
	child.set_environment(env)
	child.run()
	child.wait()
	if child.code < 0 {
		return error('Could not wait for Kakoune: ${child.err}')
	}
	return child.code
}

fn launch(args []string) !int {
	editor_args := directory_args(args)!
	prefix := os.getenv('VLANG_KAK_PREFIX')
	if !os.is_abs_path(prefix) {
		return error('The managed launcher requires an absolute VLANG_KAK_PREFIX.')
	}
	directory := os.join_path(prefix, 'opt', 'vlang-kakoune', 'restart.' + rand.uuid_v4())
	os.mkdir(directory, mode: 0o700)!
	owner := os.join_path(directory, 'owner-pid')
	releases := os.join_path(directory, 'tool-releases')
	state := os.join_path(directory, 'state.kak')
	replay := os.join_path(directory, 'replay.kak')
	defer {
		for path in [owner, releases, state, replay] {
			os.rm(path) or {}
		}
		os.rmdir(directory) or {}
	}
	os.write_file(owner, os.getpid().str() + '\n')!
	mut tool_paths := []string{}
	for tool in leased_tools {
		current := os.join_path(prefix, 'opt', 'vlang-' + tool, 'current')
		if os.is_dir(current) {
			tool_paths << os.real_path(current) + '\n'
		}
	}
	os.write_file(releases, tool_paths.join(''))!

	mut env := os.environ()
	env['VLANG_KAK_RESTART_STATE'] = state
	env['VLANG_KAK_RESTART_ALLOWED'] = if owns_client(args) { '1' } else { '0' }
	for {
		mut editor_env := env.clone()
		replaying := has_checkpoint(state)
		if replaying {
			os.rename_dir(state, replay)!
			editor_env['VLANG_KAK_RESTART_SOURCE'] = replay
		}
		status := start_editor(editor_args, editor_env)!
		if replaying {
			os.rm(replay) or {}
		}
		if status != restart_status || !has_checkpoint(state) {
			return status
		}
	}
	return 0
}

fn main() {
	status := launch(os.args[1..]) or {
		eprintln(err)
		exit(if err.code() == command_not_found_status { command_not_found_status } else { 1 })
	}
	exit(status)
}
