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
	stage := os.join_path(os.dir(state), '.restart-' + rand.uuid_v4())
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	write_checkpoint(stage, 'state.kak', 'w', commands)!
	os.rename_dir(os.join_path(stage, 'state.kak'), state)!
}

fn run(args []string) ! {
	directory := os.getenv('kak_opt_v_session_checkpoint')
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
