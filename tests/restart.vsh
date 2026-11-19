// Exercise the managed editor update and restart over a real Kakoune session.
import editorui { quote }
import os
import rand
import time

const setup_timeout = 20 * time.second
const process_poll = 20 * time.millisecond
const cursor_expression = '%val{buffile} %val{cursor_line} %val{cursor_column}'
const pid_expression = '%val{client_pid}'
const setting_expression = '%opt{release_test_setting}'
const personal_text = 'declare-option str release_test_setting preserved\n'
const first_text = 'first line\nsecond line\n'
const no_install = ['--no-build', '--no-lsp']

struct CommandResult {
	code   int
	output string
	errors string
}

fn run_command(program string, args []string) !CommandResult {
	mut child := os.new_process(program)
	child.set_args(args)
	child.set_redirect_stdio()
	child.run()
	defer { child.close() }
	// Setup and the update command expect EOF rather than interactive input.
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	deadline := time.sys_mono_now() + u64(setup_timeout)
	mut output := ''
	mut errors := ''
	for child.is_alive() && time.sys_mono_now() < deadline {
		output += child.stdout_read()
		errors += child.stderr_read()
		time.sleep(process_poll)
	}
	if child.is_alive() {
		child.signal_kill()
		child.status = .running
		child.wait()
		return error('${program} timed out\n${output}${errors}')
	}
	return CommandResult{
		code:   child.code
		output: output + child.stdout_read()
		errors: errors + child.stderr_read()
	}
}

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

fn exercise(root string, kak string) ! {
	repo := os.dir(@DIR)
	prefix := os.join_path(root, 'prefix')
	vls := setup_tools(root, kak)!
	mut setup_args := no_install.clone()
	setup_args << ['--prefix', prefix, '--vls', vls]
	setup := run_command(os.join_path(repo, 'scripts', 'setup.sh'), setup_args)!
	require(setup.code == 0, 'Setup failed\n${setup.output}${setup.errors}')!

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
	require(editor.value(setting_expression)! == 'preserved', 'Personal settings were not loaded')!

	mut failure_args := [prefix, editor.session_name(), editor.client_name(), original_pid, '--vls',
		os.join_path(root, 'missing-vls')]
	failure_args << no_install
	failed := run_command(os.join_path(repo, 'scripts', 'update-session.sh'), failure_args)!
	require(failed.code != 0 && failed.errors.contains('VLS is not executable'),
		'Failed update was not reported\n${failed.output}${failed.errors}')!
	require(editor.value(pid_expression)! == original_pid, 'Failed update restarted Kakoune')!

	editor.restart('v-update --no-build --no-lsp')!
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
