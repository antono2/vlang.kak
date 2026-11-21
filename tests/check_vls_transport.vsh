// Verify command acknowledgment and failure forwarding with a real Kakoune client.
import editorui { quote }
import os
import rand

const delayed_response_seconds = '0.2'

fn verify(mut editor editorui.Client, root string) ! {
	result := os.join_path(root, 'result')
	os.write_file(result, 'stale\n')!
	// Socket delivery finishes before the sleeping editor command writes its result.
	editor.remote('nop %sh{ sleep ${delayed_response_seconds} }\necho -to-file ${quote(result)} fresh')!
	if os.read_file(result)!.trim_space() != 'fresh' {
		return error('Read stale state before editor execution')
	}
	mut rejected := false
	editor.remote("fail 'transport probe failure'") or {
		rejected = err.msg().contains('transport probe failure')
	}
	if !rejected {
		return error('Editor errors must reach the checker')
	}
	editor.remote_allow_error('buffer *not-created-yet*')!
	editor.remote('nop')!
	if os.ls(root)!.any(it.starts_with('command-')) {
		return error('Command response files leaked')
	}
}

fn run(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-command-check-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	source := os.join_path(root, 'main')
	os.write_file(source, '')!
	mut editor := editorui.open(kak, root, source)!
	verify(mut editor, root) or {
		editor.close()
		return err
	}
	editor.close()
	editor.save_artifacts()!
	println('ok - live VLS command execution acknowledgment and errors')
}

kak := os.find_abs_path_of_executable(if os.args.len > 1 { os.args[1] } else { 'kak' }) or {
	eprintln(err)
	exit(1)
}
run(kak) or {
	eprintln(err)
	exit(1)
}
