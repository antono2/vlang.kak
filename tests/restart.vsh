// Exercise the managed editor update and restart over a real Kakoune session.
import editorui { quote }
import os
import rand
import releasetest { capture_result }
import time

const setup_timeout = time.minute
const cursor_expression = '%val{buffile} %val{cursor_line} %val{cursor_column}'
const pid_expression = '%val{client_pid}'
const setting_expression = '%opt{release_test_setting}'
const personal_text = 'declare-option str release_test_setting preserved\n'
const first_text = 'first line\nsecond line\n'
const no_install = ['--no-build', '--no-lsp']

fn require(condition bool, message string) ! {
	if !condition {
		return error(message)
	}
}

fn setup_tools(root string, kak string) !string {
	bin := os.join_path(root, 'bin')
	os.mkdir(bin)!
	os.symlink(kak, os.join_path(bin, 'kak'))!
	lsp := os.join_path(bin, 'kak-lsp')
	real_tools := os.getenv('VLANG_TEST_REAL_TOOLS_PREFIX')
	vls := if real_tools != '' {
		tools := os.real_path(real_tools)
		os.symlink(os.join_path(tools, 'opt/vlang-kak-lsp/current/bin/kak-lsp'), lsp)!
		os.join_path(tools, 'bin', 'vls')
	} else {
		// This same test binary supplies the minimal kak-lsp configuration in the lightweight lane.
		os.symlink(os.executable(), lsp)!
		'/bin/true'
	}
	os.setenv('XDG_CONFIG_HOME', os.join_path(root, 'config'), true)
	os.setenv('PATH', bin + ':' + os.getenv('PATH'), true)
	os.setenv('VLANG_KAK_SKIP_PULL', '1', true)
	os.unsetenv('VLANG_KAK_CONFIG_HOME')
	return vls
}

fn launcher_pid(prefix string) !string {
	root := os.join_path(prefix, 'opt', 'vlang-kakoune')
	directories := (os.ls(root)!).filter(it.starts_with('restart.'))
	require(directories.len == 1, 'Expected one active launcher state directory')!
	return os.read_file(os.join_path(root, directories[0], 'owner-pid'))!.trim_space()
}

fn exercise(root string, kak string) ! {
	repo := os.dir(@DIR)
	prefix := os.join_path(root, 'prefix')
	vls := setup_tools(root, kak)!
	mut setup_args := no_install.clone()
	setup_args << ['--prefix', prefix, '--vls', vls]
	setup := capture_result(os.join_path(repo, 'scripts', 'setup.sh'), setup_args,
		timeout: setup_timeout
	)!
	require(setup.code == 0, 'Setup failed\n${setup.stdout}${setup.stderr}')!

	personal := os.join_path(root, 'config', 'kak', 'vlang-user.kak')
	os.write_file(personal, personal_text)!
	first := os.join_path(root, 'first.txt')
	second := os.join_path(root, 'second.txt')
	os.write_file(first, first_text)!
	os.write_file(second, 'other buffer\n')!
	mut editor := editorui.open_managed(kak, os.join_path(prefix, 'bin', 'kak-v'), root, first)!
	defer { editor.close() }

	editor.remote('edit -- ${quote(second)}\nbuffer ${quote(first)}\nselect 2.2,2.2')!
	expected_cursor := '${first} 2 2'
	require(editor.value(cursor_expression)! == expected_cursor, 'Initial cursor position differs')!
	original_pid := editor.value(pid_expression)!
	launcher := launcher_pid(prefix)!
	$if linux {
		program := os.readlink('/proc/${launcher}/exe')!
		require(os.file_name(program).starts_with('launcher-'),
			'Expected the managed session to run under the V launcher, got ${program}')!
	}
	require(editor.value(setting_expression)! == 'preserved', 'Personal settings were not loaded')!

	// Exercise the V entry point directly so a compilation failure cannot hide behind the fallback.
	compiler := os.find_abs_path_of_executable('v')!
	helper := os.join_path(repo, 'scripts', 'update-session.vsh')
	refused := capture_result(compiler, ['run', helper, prefix, editor.session_name(),
		editor.client_name(), original_pid, '--prefix', root], timeout: setup_timeout)!
	require(refused.code == 2 && refused.stderr.contains('keeps the current installation prefix'),
		'V update handoff accepted an alternate prefix\n${refused.stdout}${refused.stderr}')!

	mut failure_args := [prefix, editor.session_name(), editor.client_name(), original_pid, '--vls',
		os.join_path(root, 'missing-vls')]
	failure_args << no_install
	failed := capture_result(os.join_path(repo, 'scripts', 'update-session.sh'), failure_args,
		timeout: setup_timeout
	)!
	require(failed.code != 0 && failed.stderr.contains('VLS is not executable'),
		'Failed update was not reported\n${failed.stdout}${failed.stderr}')!
	require(editor.value(pid_expression)! == original_pid, 'Failed update restarted Kakoune')!

	editor.restart('v-update --no-build --no-lsp')!
	require(launcher_pid(prefix)! == launcher, 'Restart replaced the launcher process')!
	require(!os.exists(os.join_path(prefix, 'opt', 'vlang-v')),
		'External VLS update installed a managed compiler')!
	require(editor.value(pid_expression)! != original_pid,
		'The launcher did not create a new Kakoune client')!
	require(editor.value(setting_expression)! == 'preserved'
		&& os.read_file(personal)! == personal_text,
		'Update changed or stopped loading personal settings')!
	generated := os.join_path(prefix, 'opt/vlang-kakoune/ide-config/kak/kakrc')
	require(os.read_file(generated)!.contains(personal),
		'Update changed the customization source path')!
	require(editor.value(cursor_expression)! == expected_cursor,
		'Update did not restore the file and cursor')!
	editor.remote('buffer ${quote(second)}')!
	require(editor.value('%val{buffile}')! == second,
		'Update did not restore the other open buffer')!

	editor.remote('buffer ${quote(first)}\nselect 1.1,1.1\nexecute-keys iX<esc>')!
	before_unsaved := editor.value(pid_expression)!
	editor.remote_allow_error('v-restart')!
	require(editor.value('%val{modified}')! == 'true'
		&& editor.value(pid_expression)! == before_unsaved,
		'Restart did not keep the unsaved buffer open in the same client')!
	require(os.read_file(first)! == first_text, 'Restart wrote the unsaved edit to disk')!
	editor.quit()!
	os.rm(os.join_path(root, 'ready'))!
	os.write_file(personal, personal_text + 'set-option global v_pane_mode off\n')!
	project := os.join_path(root, 'directory project')
	os.mkdir(project)!
	os.write_file(os.join_path(project, 'v.mod'), "Module { name: 'restart' }\n")!
	main_file := os.join_path(project, 'main.v')
	os.write_file(main_file, 'module main\nfn main() {}\n')!
	mut directory := editorui.open_managed(kak, os.join_path(prefix, 'bin', 'kak-v'), root, project)!
	defer { directory.close() }
	directory.wait_value('%opt{filetype}', 'v-tree', false, 'directory startup tree')!
	directory.keys('q')
	directory.remote('edit -- ${quote(main_file)}\nselect 2.2,2.2')!
	directory.restart('v-restart')!
	require(directory.value('%opt{v_workspace_root}')! == project,
		'Directory restart lost the workspace root')!
	require(directory.value(cursor_expression)! == '${main_file} 2 2',
		'Directory restart reopened the startup tree instead of restoring the source')!
	// A directory selected later must survive, rather than reverting to the CLI directory.
	other := os.join_path(root, 'another workspace')
	os.mkdir(other)!
	other_manifest := os.join_path(other, 'v.mod')
	os.write_file(other_manifest, "Module { name: 'another' }\n")!
	directory.remote('v-open-project ${quote(other)}')!
	directory.keys('q')
	directory.wait_value('%val{buffile}', other_manifest, false, 'switched directory manifest')!
	directory.restart('v-restart')!
	require(directory.value('%opt{v_workspace_root}')! == other,
		'Restart reverted to the original directory argument')!
	directory.quit()!
}

fn check(kak_path string) ! {
	kak := os.find_abs_path_of_executable(kak_path)!
	root := os.join_path(os.temp_dir(), 'vlang-kak-restart-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	exercise(root, kak)!
	println('ok - update preserves settings and cursor; failed updates and unsaved edits stay open')
}

if os.file_name(os.args[0]) == 'kak-lsp' {
	println('declare-option str lsp_cmd ""')
} else {
	kak := if os.args.len > 1 { os.args[1] } else { 'kak' }
	check(kak) or {
		eprintln('not ok - in-editor update and restart: ${err}')
		exit(1)
	}
}
