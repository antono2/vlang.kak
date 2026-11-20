// Write and replay recovery instructions for buffers and client selections.
import crypto.sha256
import os
import rand

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn write_checkpoint(directory string, name string, mode string, text string) ! {
	mut file := os.open_file(os.join_path(directory, name), mode, 0o600)!
	defer { file.close() }
	file.write_string(text)!
	file.flush()
}

fn save_buffer(directory string, name string) ! {
	if name == '*debug*' {
		return
	}
	file := os.getenv('kak_buffile')
	// Older Kakoune releases report a scratch buffer's name as its buffile.
	path := if file.starts_with('/') { file } else { '' }
	modified := os.getenv('kak_modified') == 'true'
	mut commands := if path == '' {
		'try %{ buffer ${quote(name)} } catch %{ edit -scratch ${quote(name)} }\n'
	} else {
		'edit -existing -- ${quote(path)}\n'
	}
	mut snapshot := ''
	if path == '' || modified || !os.is_file(path) {
		snapshot = os.join_path(directory, 'buffer-' + sha256.hexhash(name))
		keys := ('%|cat -- ' + os.quoted_path(snapshot)).replace('<', '<lt>') + '<ret>'
		commands += 'set-option buffer readonly false\nexecute-keys ${quote(keys)}\n'
	}
	filetype := os.getenv('kak_opt_filetype')
	auxiliary := filetype in ['v-tree', 'v-doc', 'make'] || filetype.starts_with('v-debug-')
		|| filetype.starts_with('lsp-') || name == '*hover*'
	restored_type := if path == '' && auxiliary { 'v-recovery' } else { filetype }
	readonly := os.getenv('kak_opt_readonly')
	commands += 'set-option buffer filetype ${quote(restored_type)}\nset-option buffer readonly ${readonly}\n'
	write_checkpoint(directory, 'buffers.kak', 'a', commands)!
	if snapshot != '' {
		// The editor writes a recovery copy with its project write hooks disabled.
		println('evaluate-commands -no-hooks %{ write -force -- ${quote(snapshot)} }')
	}
}

fn save_client(directory string, name string) ! {
	client := os.getenv('kak_client')
	selections := os.getenv('kak_selections_desc')
	identity := sha256.hexhash(client)
	write_checkpoint(directory, 'client-${identity}.kak', 'w',
		'rename-client ${quote(client)}\nbuffer ${quote(name)}\nselect ${selections}\n')!
	write_checkpoint(directory, 'clients', 'a', identity + '\n')!
}

fn begin_checkpoint(root string) ! {
	os.mkdir_all(root, mode: 0o700)!
	directory := os.join_path(os.real_path(root), 'checkpoint.' + rand.uuid_v4())
	os.mkdir(directory, mode: 0o700)!
	writer := os.join_path(directory, 'session-checkpoint')
	copy_writer(os.executable(), writer) or {
		os.rm(writer) or {}
		os.rmdir(directory) or {}
		return err
	}
	println('set-option global v_session_checkpoint ${quote(directory)}')
}

fn copy_writer(source string, writer string) ! {
	os.cp(source, writer)!
	os.chmod(writer, 0o700)!
}

fn finish_checkpoint(directory_arg string, backend string) ! {
	directory := os.real_path(directory_arg)
	if backend == '' || backend.contains('\n')
		|| !os.is_file(os.join_path(directory, 'buffers.kak')) {
		return error('Checkpoint buffers or pane host are missing')
	}
	main_id := sha256.hexhash(os.getenv('kak_client'))
	clients := os.read_lines(os.join_path(directory, 'clients'))!
	if main_id !in clients {
		return error('Checkpoint main client is missing from its client list')
	}
	for identity in clients {
		client_source(directory, identity)!
	}
	write_checkpoint(directory, 'main-client', 'w', main_id + '\n')!
	write_checkpoint(directory, 'backend', 'w', backend + '\n')!
	os.rm(os.join_path(directory, 'session-checkpoint'))!
	root := os.dir(directory)
	stage := os.join_path(root, '.latest-' + rand.uuid_v4())
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	next := os.join_path(stage, 'latest')
	os.symlink(directory, next)!
	os.rename_dir(next, os.join_path(root, 'latest'))!
	println('echo -debug "Session checkpoint saved; v-session-restore reopens it"')
}

fn client_source(directory string, identity string) !string {
	if identity.len != sha256.size * 2 || !identity.bytes().all(it.is_digit()
		|| (it >= `a` && it <= `f`)) {
		return error('Invalid checkpoint client identity')
	}
	path := os.join_path(directory, 'client-${identity}.kak')
	if !os.is_file(path) {
		return error('Checkpoint client instructions are missing')
	}
	return path
}

fn replay(directory string, state string) ! {
	buffers := os.join_path(directory, 'buffers.kak')
	if !os.is_file(buffers) {
		return error('No session checkpoint found')
	}
	identity := os.read_file(os.join_path(directory, 'main-client')) or {
		return error('Checkpoint main client is missing')
	}
	main_id := identity.trim_right('\n')
	main_client := client_source(directory, main_id)!
	mut commands := 'source ${quote(buffers)}\nsource ${quote(main_client)}\n'
	if state == '' {
		print(commands)
		return
	}
	backend := os.read_file(os.join_path(directory, 'backend')) or {
		return error('Checkpoint pane host is missing')
	}
	clients := os.read_lines(os.join_path(directory, 'clients')) or {
		return error('Checkpoint client list is missing')
	}
	if main_id !in clients {
		return error('Checkpoint main client is missing from its client list')
	}
	host := backend.trim_right('\n')
	for other in clients {
		path := client_source(directory, other)!
		if path != main_client {
			if host in ['', 'none'] {
				return error('Restoring extra views requires a supported pane host; checkpoint saved')
			}
			commands += 'v-session-open-client ${quote(path)} ${quote(host)}\n'
		}
	}
	write_restart_state(state, commands)!
}

fn write_restart_state(state string, commands string) ! {
	stage := os.join_path(os.dir(state), '.restart-' + rand.uuid_v4())
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	write_checkpoint(stage, 'state.kak', 'w', commands)!
	os.rename_dir(os.join_path(stage, 'state.kak'), state)!
}

fn save_restart_files(files []string) ! {
	state := os.getenv('VLANG_KAK_RESTART_STATE')
	if state == '' {
		return error('Restart requires the managed kak-v launcher')
	}
	mut commands := 'nop\n'
	for name in files {
		if os.is_file(name) {
			quoted := quote(name)
			commands += 'try %{ buffer ${quoted} } catch %{ edit -- ${quoted} }\n'
		}
	}
	mut file := os.getenv('kak_buffile')
	mut line := os.getenv('kak_cursor_line')
	mut column := os.getenv('kak_cursor_column')
	if !os.is_file(file) {
		file = os.getenv('kak_opt_v_update_resume_file')
		line = os.getenv('kak_opt_v_update_resume_line')
		column = os.getenv('kak_opt_v_update_resume_column')
	}
	if os.is_file(file) {
		commands += 'buffer ${quote(file)}\nselect ${line}.${column},${line}.${column}\n'
	}
	write_restart_state(state, commands)!
}

fn plan_session_action(action string, names []string) {
	owner := os.getenv('kak_client')
	for name in names {
		quoted := quote(name)
		match action {
			'save-buffers' { println('v-session-save-buffer ${quoted}') }
			'save-clients' { println('v-session-save-client ${quoted}') }
			'check-buffers' { println('v-session-check-buffer ${quoted}') }
			'close-clients' {
				if name != owner {
					println('evaluate-commands -client ${quoted} %{ quit! }')
				}
			}
			else {}
		}
	}
}

fn run(args []string) ! {
	directory := os.getenv('kak_opt_v_session_checkpoint')
	if directory != '' && args.len == 2 && args[0] == 'finish' {
		finish_checkpoint(directory, args[1])!
		return
	}
	if directory == '' || args.len != 1 {
		return error('Expected a checkpoint directory and one of buffer, client, or main')
	}
	name := os.getenv('kak_bufname')
	match args[0] {
		'buffer' {
			save_buffer(directory, name)!
		}
		'client' {
			save_client(directory, name)!
		}
		'main' {
			identity := sha256.hexhash(os.getenv('kak_client'))
			write_checkpoint(directory, 'main-client', 'w', identity + '\n')!
		}
		else {
			return error('Unknown checkpoint command: ${args[0]}')
		}
	}
}

args := os.args[1..]
if args.len > 0 && args[0] in ['save-buffers', 'save-clients', 'check-buffers', 'close-clients'] {
	plan_session_action(args[0], args[1..])
	exit(0)
}
if args.len > 0 && args[0] == 'restart-files' {
	save_restart_files(args[1..]) or {
		println('fail ${quote(err.msg())}')
		exit(1)
	}
	exit(0)
}
if args.len > 0 && args[0] == 'begin' {
	if args.len != 2 || args[1] == '' {
		println("fail 'Expected a checkpoint root'")
		exit(2)
	}
	begin_checkpoint(args[1]) or {
		println('fail ${quote(err.msg())}')
		exit(1)
	}
	exit(0)
}
if args.len > 0 && args[0] in ['restore', 'restart'] {
	restart := args[0] == 'restart'
	expected := if restart { 3 } else { 2 }
	directory := args[1] or { '' }
	state := args[2] or { '' }
	if args.len != expected || directory == '' || (restart && state == '') {
		println("fail 'Expected a checkpoint directory and restart state when restarting'")
		exit(2)
	}
	replay(directory, state) or {
		println('fail ${quote(err.msg())}')
		exit(1)
	}
	exit(0)
}
run(args) or {
	eprintln(err)
	exit(1)
}
