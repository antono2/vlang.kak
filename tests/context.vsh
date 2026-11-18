// Verify context-aware command menus and task transitions in the real Kakoune UI.
import editorui { quote }
import os
import rand
import time

fn check_items(text string, items []string, present bool) ! {
	for item in items {
		if text.contains(item) != present {
			return error('Unexpected visibility of ${item} in ${text}')
		}
	}
}

fn menu(mut editor editorui.Client, expected string, group string) !string {
	editor.keys('<esc>')
	editor.remote('nop')!
	offset := editor.offset()
	editor.keys('<space>' + group)
	return editor.wait_info(offset, expected)
}

fn wait_for_run(mut editor editorui.Client, path string, expected string) ! {
	deadline := time.sys_mono_now() + u64(10 * time.second)
	for time.sys_mono_now() < deadline {
		content := os.read_file(path) or { '' }
		if (expected == '' && content != '') || (expected != '' && content == expected) {
			return
		}
		editor.offset()
		time.sleep(30 * time.millisecond)
	}
	return editor.diagnostic('The task did not produce the expected receipt')
}

fn prelude(mut editor editorui.Client, test string) ! {
	text := menu(mut editor, 'Testing', '')!
	check_items(text, ['Test at cursor', 'Rerun last test', 'Go to definition',
		'View file at Git revision…', 'Update and restart', 'Test V project',
		'Check project with v vet', 'Check file for compile errors', 'Find callers'], false)!
	check_items(text, ['Format and save with V', 'Testing', 'Maintenance'], true)!
	editor.remote('set-option global v_explorer_enabled false')!
	check_items(menu(mut editor, 'Open project path', '')!, ['Project explorer'], false)!
	editor.keys('<esc>')
	editor.remote('set-option global v_explorer_enabled true')!
	menu(mut editor, 'Project explorer', '')!
	editor.keys('<esc>')
	tests_menu := menu(mut editor, 'Test V project', 't')!
	check_items(tests_menu, ['Test at cursor', 'Rerun last test'], false)!
	check_items(tests_menu, ['Check project with v vet', 'Check file for compile errors'], true)!
	check_items(menu(mut editor, 'Show pane backend', 'U')!,
		['Update and restart', 'Restart V IDE'], false)!
	editor.remote("hook global User VKeysApplied %{ map window v-testing v ':echo custom<ret>' -docstring 'Personal vet' }; v-bind-keys")!
	menu(mut editor, 'Personal vet', 't')!
	editor.keys('<esc>')
	editor.remote('v-bind-keys')!
	menu(mut editor, 'Personal vet', 't')!
	editor.keys('<esc>')
	editor.remote('set-option buffer readonly true')!
	check_items(menu(mut editor, 'Testing', '')!, ['Format and save with V'], false)!
	editor.keys('<esc>')
	editor.remote('set-option buffer readonly false')!
	editor.remote('edit ${quote(test)}')!
	menu(mut editor, 'Test at cursor', '')!
	editor.keys('<esc>')
	editor.remote("execute-keys -with-hooks 'A <esc>'")!
	check_items(menu(mut editor, 'Testing', '')!, ['Test at cursor'], false)!
	editor.keys('<esc>')
	editor.remote('write')!
	menu(mut editor, 'Test at cursor', '')!
	editor.keys('<esc>')
}

fn task_and_overrides(mut editor editorui.Client, root string, source string) ! {
	editor.remote('edit ${quote(source)}; select 2.4,2.4')!
	runs := os.join_path(root, 'runs')
	editor.remote('set-option buffer v_test_command ${quote('printf x >> ' + os.quoted_path(runs) +
		'; printf done')}; v-test')!
	wait_for_run(mut editor, runs, '')!
	text := menu(mut editor, 'Rerun this task', '')!
	check_items(text, ['Return to source', 'Open location on this line'], true)!
	check_items(text, ['Test at cursor', 'Build V project'], false)!
	editor.keys('r')
	wait_for_run(mut editor, runs, 'xx')!
	menu(mut editor, 'Return to source', '')!
	editor.keys('q')
	if editor.value('%val{buffile} %val{cursor_line} %val{cursor_column}')! != '${source} 2 4'
		|| editor.value('%opt{makecmd}')! != 'make' {
		return error('Returning from the V task did not restore the source position and make command')
	}
	check_items(menu(mut editor, 'Test V project', 't')!, ['Rerun last test'], true)!
	editor.keys('<esc>')

	// Personal bindings must win on both initial registration and context refresh.
	editor.remote("hook global User VKeysApplied %{ map window user b ':echo custom<ret>' -docstring 'Personal build' }; v-bind-keys")!
	menu(mut editor, 'Personal build', '')!
	editor.keys('<esc>')
	editor.remote('set-option global v_context_keys false')!
	check_items(menu(mut editor, 'Personal build', '')!, ['Testing', 'Go to definition'], true)!
	menu(mut editor, 'Test at cursor', 't')!
	editor.keys('<esc>')
	editor.remote('set-option global v_context_keys true')!
	check_items(menu(mut editor, 'Testing', '')!, ['Test at cursor'], false)!
	editor.keys('<esc>')
	editor.remote('set-option window filetype text')!
	editor.remote("set-option window makecmd 'printf ordinary'; make; v-refresh-keys")!
	editor.remote('debug mappings')!
	debug := os.join_path(root, 'debug')
	editor.remote('evaluate-commands -buffer *debug* %{ write -force ${quote(debug)} }')!
	check_items(os.read_file(debug)!, ['Rerun this task', 'error while parsing kakrc'], false)!
}

fn exercise(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-context-' + rand.uuid_v4())
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	config := os.join_path(root, 'config', 'kak')
	os.mkdir_all(config)!
	plugin := os.join_path(os.dir(@DIR), 'rc', 'vlang.kak')
	os.write_file(os.join_path(config, 'kakrc'),
		'source ${quote(plugin)}\nset-option global idle_timeout 50\n')!
	source := os.join_path(root, 'main.v')
	test := os.join_path(root, 'main_test.v')
	os.write_file(source, 'module main\nfn main() {}\n')!
	os.write_file(test, 'module main\nfn test_one() { assert true }\n')!
	os.unsetenv('VLANG_KAK_RESTART_ALLOWED')
	mut editor := editorui.open(kak, root, source)!
	defer { editor.close() }
	prelude(mut editor, test)!
	task_and_overrides(mut editor, root, source)!
	println('ok - context-aware Space menus, saved-test gating, task rerun/return and personal overrides')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/context.vsh KAKOUNE')
	exit(2)
}
exercise(os.abs_path(os.args[1])) or {
	eprintln(err)
	exit(1)
}
