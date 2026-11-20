// Check recovery plans and refusals through both checkpoint entry points.
import crypto.sha256
import os
import rand
import releasetest { capture, execute }

fn check_publication(root string, launcher string, lane map[string]string, native bool) ! {
	cache := os.join_path(root, 'published checkpoints')
	os.mkdir(cache)!
	previous := os.join_path(cache, 'previous')
	os.mkdir(previous)!
	latest := os.join_path(cache, 'latest')
	os.symlink(previous, latest)!
	begin := capture(launcher, ['begin', cache], true, environment: lane)!
	directories := os.ls(cache)!.filter(it.starts_with('checkpoint.'))
	assert directories.len == 1
	directory := os.join_path(cache, directories[0])
	assert begin == "set-option global v_session_checkpoint '${directory.replace("'", "''")}'\n"
	assert (os.stat(directory)!.mode & 0o777) == 0o700
	writer := os.join_path(directory, 'session-checkpoint')
	assert os.is_executable(writer) == native
	mut env := lane.clone()
	env['kak_opt_v_session_checkpoint'] = directory
	env['kak_client'] = 'owner'
	env['kak_bufname'] = 'scratch'
	env['kak_selections_desc'] = '1.1,1.1'
	execute(launcher, ['finish', 'tmux'], false, environment: env)!
	assert os.readlink(latest)! == previous
	os.write_file(os.join_path(directory, 'buffers.kak'), '# test buffers\n')!
	assert capture(launcher, ['client'], true, environment: env)! == ''
	output := capture(launcher, ['finish', 'tmux'], true, environment: env)!
	assert output.contains('Session checkpoint saved')
	assert os.readlink(latest)! == directory
	assert os.read_file(os.join_path(latest, 'backend'))! == 'tmux\n'
	assert !os.exists(writer)
	assert os.ls(cache)!.all(!it.starts_with('.latest'))
	assert capture(launcher, ['restore', latest], true, environment: env)!.contains('client-')
}

fn check_saved_file_restart(root string, launcher string, lane map[string]string) ! {
	first := os.join_path(root, "owner's file.v")
	second := os.join_path(root, 'another file.v')
	missing := os.join_path(root, 'scratch buffer')
	state := os.join_path(root, 'saved restart.kak')
	target := os.join_path(root, 'old state')
	for file in [first, second, target] {
		os.write_file(file, 'original\n')!
	}
	os.symlink(target, state)!
	mut env := lane.clone()
	env['VLANG_KAK_RESTART_STATE'] = state
	env['kak_buffile'] = missing
	env['kak_opt_v_update_resume_file'] = first
	env['kak_opt_v_update_resume_line'] = '2'
	env['kak_opt_v_update_resume_column'] = '3'
	assert capture(launcher, ['restart-files', first, missing, second], true, environment: env)! == ''
	first_quoted := first.replace("'", "''")
	second_quoted := second.replace("'", "''")
	assert os.read_file(state)! ==
		"nop\ntry %{ buffer '${first_quoted}' } catch %{ edit -- '${first_quoted}' }\n" +
		"try %{ buffer '${second_quoted}' } catch %{ edit -- '${second_quoted}' }\n" +
		"buffer '${first_quoted}'\nselect 2.3,2.3\n"
	assert !os.is_link(state) && os.read_file(target)! == 'original\n'
	assert (os.stat(state)!.mode & 0o777) == 0o600
	env['kak_buffile'] = second
	env['kak_cursor_line'] = '4'
	env['kak_cursor_column'] = '5'
	assert capture(launcher, ['restart-files', second], true, environment: env)! == ''
	assert os.read_file(state)!.ends_with("buffer '${second_quoted}'\nselect 4.5,4.5\n")
	env.delete('VLANG_KAK_RESTART_STATE')
	failed := execute(launcher, ['restart-files'], false, environment: env)!
	assert failed.stdout.contains('Restart requires the managed kak-v launcher')
}

fn check_session_actions(launcher string, lane map[string]string) ! {
	mut env := lane.clone()
	env['kak_client'] = 'owner'
	mut args := ['', 'owner', "other's %{\n"]
	for action, command in {
		'save-buffers':  'v-session-save-buffer'
		'save-clients':  'v-session-save-client'
		'check-buffers': 'v-session-check-buffer'
	} {
		args[0] = action
		assert capture(launcher, args, true, environment: env)! == "${command} 'owner'\n${command} 'other''s %{\n'\n"
	}
	args[0] = 'close-clients'
	assert capture(launcher, args, true, environment: env)! == "evaluate-commands -client 'other''s %{\n' %{ quit! }\n"
	assert capture(launcher, ['close-clients', 'owner'], true, environment: env)! == ''
	assert capture(launcher, ['check-buffers'], true, environment: env)! == ''
}

fn check() ! {
	root := os.join_path(os.temp_dir(), "recovery reader's " + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	tools := os.join_path(os.dir(@DIR), 'scripts')
	scripts := os.join_path(root, 'scripts')
	os.mkdir(scripts)!
	for name in ['helper-cache.sh', 'helper-cache.vsh', 'session-buffer.sh', 'session-checkpoint.vsh',
		'session-checkpoint-posix'] {
		target := os.join_path(scripts, name)
		os.cp(os.join_path(tools, name), target)!
		os.chmod(target, 0o700)!
	}
	launcher := os.join_path(scripts, 'session-buffer.sh')
	legacy := os.join_path(scripts, 'session-checkpoint-posix')
	fallback_marker := os.join_path(root, 'used fallback')
	posix := os.read_file(legacy)!
	os.write_file(legacy, posix.replace_once('set -eu\n', 'set -eu\nprintf "%s\\n" fallback >> ' +
		os.quoted_path(fallback_marker) + '\n'))!
	checkpoint := os.join_path(root, 'checkpoint with spaces')
	os.mkdir(checkpoint)!
	main_id := sha256.hexhash('main client')
	other_id := sha256.hexhash('other client')
	buffers := os.join_path(checkpoint, 'buffers.kak')
	main_client := os.join_path(checkpoint, 'client-${main_id}.kak')
	other_client := os.join_path(checkpoint, 'client-${other_id}.kak')
	for path in [buffers, main_client, other_client] {
		os.write_file(path, '# test instructions\n')!
	}
	identity := os.join_path(checkpoint, 'main-client')
	clients := os.join_path(checkpoint, 'clients')
	backend := os.join_path(checkpoint, 'backend')
	os.write_file(identity, main_id + '\n')!
	os.write_file(clients, main_id + '\n' + other_id + '\n')!
	os.write_file(backend, 'tmux\n')!
	mut env := os.environ()
	env['XDG_CACHE_HOME'] = os.join_path(root, 'cache')
	compiler_free := os.join_path(root, 'compiler-free')
	os.mkdir(compiler_free)!
	for name in ['cat', 'cut', 'dirname', 'ln', 'mkdir', 'mktemp', 'mv', 'readlink', 'rm', 'rmdir',
		'sed', 'sha256sum'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(compiler_free, name))!
	}
	mut fallback_env := env.clone()
	fallback_env['PATH'] = compiler_free

	expected := "source '${buffers.replace("'", "''")}'\nsource '${main_client.replace("'", "''")}'\n"
	expected_restart := expected +
		"v-session-open-client '${other_client.replace("'", "''")}' 'tmux'\n"
	state := os.join_path(root, 'state with spaces.kak')
	for i, lane in [env, fallback_env] {
		assert capture(launcher, ['restore', checkpoint], true, environment: lane)! == expected
		assert capture(launcher, ['restart', checkpoint, state], true, environment: lane)! == ''
		assert os.read_file(state)! == expected_restart
		assert (os.stat(state)!.mode & 0o777) == 0o600
		os.write_file(backend, 'none\n')!
		failed := execute(launcher, ['restart', checkpoint, state], false, environment: lane)!
		assert failed.stdout.contains('Restoring extra views requires a supported pane host')
		assert os.read_file(state)! == expected_restart
		os.write_file(backend, 'tmux\n')!
		os.write_file(identity, '../invalid\n')!
		bad := execute(launcher, ['restore', checkpoint], false, environment: lane)!
		assert bad.stdout == "fail 'Invalid checkpoint client identity'\n"
		os.write_file(identity, main_id + '\n')!
		publication := os.join_path(root, 'publication-${i}')
		os.mkdir(publication)!
		check_publication(publication, launcher, lane, i == 0)!
		check_saved_file_restart(publication, launcher, lane)!
		check_session_actions(launcher, lane)!
		assert os.exists(fallback_marker) == (i > 0)
	}

	os.rm(fallback_marker)!
	os.write_file(os.join_path(scripts, 'session-checkpoint.vsh'), 'invalid helper source')!
	assert capture(launcher, ['restore', checkpoint], true, environment: env)! == expected
	assert os.exists(fallback_marker)
	check_session_actions(launcher, env)!
	println('ok - native and POSIX session actions, checkpoints and restart state')
}

check() or {
	eprintln(err)
	exit(1)
}
