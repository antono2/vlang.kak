// Write recovery instructions and client selections from Kakoune's environment.
import crypto.sha256
import os

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

fn run(args []string) ! {
	directory := os.getenv('kak_opt_v_session_checkpoint')
	if directory == '' || args.len != 1 {
		return error('Expected a checkpoint directory and one of buffer, client, or main')
	}
	name := os.getenv('kak_bufname')
	match args[0] {
		'buffer' { save_buffer(directory, name)! }
		'client' { save_client(directory, name)! }
		'main' {
			write_checkpoint(directory, 'main-client', 'w',
				sha256.hexhash(os.getenv('kak_client')) + '\n')!
		}
		else { return error('Unknown checkpoint command: ${args[0]}') }
	}
}

run(os.args[1..]) or {
	eprintln(err)
	exit(1)
}
