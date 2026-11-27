// Verify context-aware command menus and task transitions in the real Kakoune UI.
import editorui { quote }
import os
import rand
import releasetest { capture }
import time

const task_receipt_timeout = 10 * time.second
const task_receipt_poll = 30 * time.millisecond
// Kakoune accepts idle_timeout in milliseconds. Keep idle hooks responsive in this test.
const kak_idle_timeout_ms = 50

fn check_items(text string, items []string, present bool) ! {
	for item in items {
		if text.contains(item) != present {
			return error('Unexpected visibility of ${item} in ${text}')
		}
	}
}

fn check_helpers(root string, file string) ! {
	helper := os.join_path(os.dir(@DIR), 'scripts', 'helper-cache.sh')
	mut native := os.environ()
	native['XDG_CACHE_HOME'] = os.join_path(root, 'native-menus')
	capture(helper, ['context', '--prepare'], true, environment: native)!
	cache := os.join_path(native['XDG_CACHE_HOME'], 'vlang.kak')
	assert os.ls(cache)!.any(it.starts_with('context-') && os.is_executable(os.join_path(cache, it)))
	no_compiler := os.join_path(root, 'compiler-free')
	os.mkdir(no_compiler)!
	for program in ['basename', 'cksum', 'dirname', 'git', 'grep', 'readlink', 'sed', 'sh'] {
		os.symlink(os.find_abs_path_of_executable(program)!, os.join_path(no_compiler, program))!
	}
	mut fallback := native.clone()
	fallback['PATH'] = no_compiler
	fallback['XDG_CACHE_HOME'] = os.join_path(root, 'fallback-menus')
	for lane in [native, fallback] {
		mut env := lane.clone()
		env['kak_buffile'] = file
		env['kak_bufname'] = file
		env['kak_opt_filetype'] = 'v'
		env['kak_modified'] = 'false'
		env['kak_opt_readonly'] = 'false'
		env['kak_opt_v_debug_enabled'] = 'true'
		env['kak_opt_v_debug_adapter'] = 'sh'
		env['kak_opt_v_debug_build'] = 'true'
		env['kak_opt_v_window_backend'] = 'auto'
		env['kak_opt_v_context_keys'] = 'true'
		env['kak_opt_v_plugin_source'] = os.join_path(os.dir(@DIR), 'rc', 'vlang.kak')
		env['VLANG_KAK_RESTART_ALLOWED'] = '1'
		env['VLANG_KAK_PREFIX'] = root
		env['kak_opt_v_debug_phase'] = 'idle'
		idle := capture(helper, ['context', 'editor one'], true, environment: env)!
		check_items(idle, ['Debug V test', 'Test at cursor', 'trigger-user-hook VKeysApplied'],
			true)!
		check_items(idle, ['unmap window v-maintenance u', "unmap -- window v-maintenance 'u'"],
			false)!
		multiple :=
			capture(helper, ['context', 'editor one', 'editor two'], true, environment: env)!
		assert multiple.contains('unmap window v-maintenance u')
			|| multiple.contains("unmap -- window v-maintenance 'u'")
		env['kak_opt_v_debug_phase'] = 'running'
		running := capture(helper, ['context', 'editor one'], true, environment: env)!
		check_items(running, ['Pause debugging', 'Send program input', 'Stop debugging'], true)!
		check_items(running, ['Continue debugging', 'Run to cursor'], false)!
		env['kak_opt_v_debug_phase'] = 'stopped'
		env['kak_opt_v_debug_has_watches'] = 'true'
		stopped := capture(helper, ['context', 'editor one'], true, environment: env)!
		check_items(stopped, ['Continue debugging', 'Run to cursor', 'Remove watch'], true)!
		signature :=
			stopped.split_into_lines()[1].all_after("set-option window v_keys_context '").trim_right("'")
		assert signature != ''
		env['kak_opt_v_keys_context'] = signature
		assert capture(helper, ['context', 'editor one'], true, environment: env)! == ''

		env['kak_opt_v_debug_status'] = 'true'
		suffix := '  [debug: %opt{v_debug_phase}]'
		shown := capture(helper, ['context', 'editor one'], true, environment: env)!
		assert shown == 'set-option -add window modelinefmt ${quote(suffix)}\n' +
			'set-option window v_debug_status_visible true\n'
		env['kak_opt_v_debug_status_visible'] = 'true'
		personal := "Owner's modeline\n"
		env['kak_opt_modelinefmt'] = personal + suffix
		assert capture(helper, ['context', 'editor one'], true, environment: env)! == ''
		env['kak_opt_v_debug_status'] = 'false'
		hidden := capture(helper, ['context', 'editor one'], true, environment: env)!
		assert hidden == 'set-option window modelinefmt ${quote(personal)}\n' +
			'set-option window v_debug_status_visible false\n'
		env['kak_opt_modelinefmt'] = personal + suffix + ' %opt{v_lsp_progress}'
		shared := capture(helper, ['context', 'editor one'], true, environment: env)!
		assert shared == 'set-option window modelinefmt ${quote(personal + ' %opt{v_lsp_progress}')}\n' +
			'set-option window v_debug_status_visible false\n'
		env['kak_opt_modelinefmt'] = personal
		replaced := capture(helper, ['context', 'editor one'], true, environment: env)!
		assert replaced == 'set-option window v_debug_status_visible false\n'
		env['kak_opt_v_debug_status_visible'] = 'false'
		env['kak_opt_v_debug_phase'] = 'idle'
		env['kak_opt_v_keys_context'] = ''
		env['kak_opt_filetype'] = 'json'
		env['kak_buffile'] = os.join_path(os.dir(file), 'v.mod')
		os.write_file(env['kak_buffile'], "Module { name: 'context' }\n")!
		project := capture(helper, ['context', 'editor one'], true, environment: env)!
		check_items(project, ['Find project file', 'Build project', 'v-run-project',
			'v-default-maintenance-keys', 'VProjectKeysApplied'], true)!
		check_items(project, ['v-default-source-keys', 'v-references', 'v-test-nearest'], false)!
		env['kak_buffile'] = os.join_path(os.dir(file), 'unrelated.json')
		assert capture(helper, ['context', 'editor one'], true, environment: env)! == ''
	}
	assert !os.exists(fallback['XDG_CACHE_HOME'])
}

fn menu(mut editor editorui.Client, expected string, group string) !string {
	editor.keys('<esc>')
	editor.remote('nop')!
	offset := editor.offset()
	editor.keys('<space>' + group)
	return editor.wait_info(offset, expected)
}

fn wait_for_run(mut editor editorui.Client, path string, expected string) ! {
	deadline := time.sys_mono_now() + u64(task_receipt_timeout)
	for time.sys_mono_now() < deadline {
		content := os.read_file(path) or { '' }
		if (expected == '' && content != '') || (expected != '' && content == expected) {
			return
		}
		editor.offset()
		time.sleep(task_receipt_poll)
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

fn check_restart_menu(kak string, root string, source string) ! {
	// The managed launcher advertises a restart only for one live client.
	os.setenv('VLANG_KAK_RESTART_ALLOWED', '1', true)
	defer { os.unsetenv('VLANG_KAK_RESTART_ALLOWED') }
	mut editor := editorui.open(kak, root, source)!
	defer { editor.close() }
	editor.wait_value('%val{client_list}', editor.client_name(), false, 'first client registered')!
	editor.remote('v-refresh-keys')!
	menu(mut editor, 'Restart V IDE', 'U') or {
		return error('Initial single-client menu: ' + err.msg())
	}
	editor.keys('<esc>')
	ready := os.join_path(root, 'menu-peer-ready')
	mut peer := os.new_process(kak)
	peer.set_args(['-c', editor.session_name(), '-ui', 'json', source, '-e',
		'rename-client menu-peer; echo -to-file ${quote(ready)} ready'])
	peer.set_redirect_stdio()
	peer.run()
	defer {
		if peer.is_alive() {
			peer.signal_term()
			peer.wait()
		}
		peer.close()
	}
	wait_for_run(mut editor, ready, '')!
	assert editor.value('%val{client_list}')!.fields().sorted() == [
		editor.client_name(),
		'menu-peer',
	]
	editor.remote('v-refresh-keys')!
	text := menu(mut editor, 'Show pane backend', 'U')!
	check_items(text, ['Restart V IDE', 'Update and restart'], false)!
	editor.keys('<esc>')
	editor.remote('evaluate-commands -client menu-peer %{ quit }')!
	editor.wait_value('%val{client_list}', editor.client_name(), false, 'peer disconnected')!
	editor.remote('v-refresh-keys')!
	menu(mut editor, 'Restart V IDE', 'U') or {
		return error('Single-client menu after disconnect: ' + err.msg())
	}
	editor.keys('<esc>')
}

fn exercise(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-context-' + rand.uuid_v4())
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	config := os.join_path(root, 'config', 'kak')
	os.mkdir_all(config)!
	plugin := os.join_path(os.dir(@DIR), 'rc', 'vlang.kak')
	os.write_file(os.join_path(config, 'kakrc'),
		'source ${quote(plugin)}\nset-option global idle_timeout ${kak_idle_timeout_ms}\n')!
	source := os.join_path(root, 'main.v')
	test := os.join_path(root, 'main_test.v')
	os.write_file(source, 'module main\nfn main() {}\n')!
	os.write_file(test, 'module main\nfn test_one() { assert true }\n')!
	check_helpers(root, test)!
	os.unsetenv('VLANG_KAK_RESTART_ALLOWED')
	mut editor := editorui.open(kak, root, source)!
	defer { editor.close() }
	prelude(mut editor, test)!
	task_and_overrides(mut editor, root, source)!
	restart_root := os.join_path(root, 'restart')
	os.mkdir(restart_root)!
	os.cp_all(os.join_path(root, 'config'), os.join_path(restart_root, 'config'), false)!
	check_restart_menu(kak, restart_root, source)!
	println('ok - context menus, saved tests, task return, overrides, and single-client restart')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/context.vsh KAKOUNE')
	exit(2)
}
exercise(os.abs_path(os.args[1])) or {
	eprintln(err)
	exit(1)
}
