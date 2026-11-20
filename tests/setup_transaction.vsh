// Exercise setup transaction outcomes without building or installing tools.
import os
import rand
import releasetest { capture, execute }

fn script(path string, contents string) ! {
	os.write_file(path, '#!/bin/sh\nset -eu\n' + contents)!
	os.chmod(path, 0o755)!
}

fn check_options(program string, root string, environment map[string]string) ! {
	prefix := os.join_path(root, 'option fixture')
	launcher := os.join_path(prefix, 'bin', 'kak-v')
	os.mkdir_all(os.dir(launcher))!
	mut env := environment.clone()
	env['FIXTURE_LAUNCHER'] = launcher
	capture(program, ['--prefix', prefix, '--no-build', '--no-lsp', '--no-explorer', '--explorer',
		'--managed-v', '--system-v', '--vls-ref', '--prefix', '--vls', '--install-dependencies',
		'--window-backend', 'native', '--no-live-search', '--live-search'], true, environment: env)!
	assert os.read_lines(env['FIXTURE_PREFLIGHT'])! == ['--prefix', prefix, '--no-build', '--no-lsp',
		'--no-vls']
	assert os.read_lines(env['FIXTURE_OPTIONS'])! == ['--prepared-options', prefix, '', 'true',
		'true', '', 'native', 'latest', 'latest', '--install-dependencies', 'external', '--prefix',
		'false', 'system', 'false', 'false', 'false']

	missing := os.join_path(root, 'invalid option prefix')
	result := execute(program, ['--prefix', missing, '--vls'], false, environment: env)!
	assert result.code == 2 && result.stderr.contains('--vls requires a value')
	assert !os.exists(missing)
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-setup-transaction-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	source := os.join_path(root, 'source', 'scripts')
	os.mkdir_all(source)!
	repo_scripts := os.join_path(os.dir(@DIR), 'scripts')
	for name in ['setup.vsh', 'setup-signals.h'] {
		os.cp(os.join_path(repo_scripts, name), os.join_path(source, name))!
	}
	for name in ['managedfiles', 'managedsnapshot'] {
		os.cp_all(os.join_path(repo_scripts, name), os.join_path(source, name), false)!
	}
	script(os.join_path(source, 'preflight.sh'),
		r'printf "%s\n" "$@" > "$FIXTURE_PREFLIGHT"' + '\n')!
	script(os.join_path(source, 'dependencies.sh'), 'exit 99\n')!
	script(os.join_path(source, 'setup-impl.sh'), r'printf "%s\n" "$@" > "$FIXTURE_OPTIONS"
case "$FIXTURE_ACTION" in
success) printf "active\n" > "$FIXTURE_LAUNCHER" ;;
fail) printf "failed activation\n" > "$FIXTURE_LAUNCHER"; exit 17 ;;
cancel) printf "cancelled activation\n" > "$FIXTURE_LAUNCHER"; kill -TERM "$PPID" ;;
corrupt) printf "partial activation\n" > "$FIXTURE_LAUNCHER"
  printf "../outside\n" >> "$VLANG_KAK_TRANSACTION/paths"; exit 18 ;;
esac
')!
	program := os.join_path(root, 'setup-test')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', program,
		os.join_path(source, 'setup.vsh')], true)!
	prefix := os.join_path(root, 'install prefix')
	launcher := os.join_path(prefix, 'bin', 'kak-v')
	state := os.join_path(prefix, 'opt', 'vlang-state')
	previous := os.join_path(state, 'previous', 'bin', 'kak-v')
	lock_path := os.join_path(state, 'lock')
	known := os.join_path(prefix, 'opt', 'vlang-v', 'releases', 'owned-release')
	cached := os.join_path(prefix, 'opt', 'vlang-v', 'releases', 'cached-release')
	stage := os.join_path(prefix, 'opt', 'vlang-v', 'releases', '.stage.ignore')
	for directory in [os.dir(launcher), state, known, cached, stage] {
		os.mkdir_all(directory)!
	}
	os.write_file(os.join_path(state, 'manifest.tsv'), 'dir\t-\t${known}\n')!
	os.write_file(launcher, 'previous\n')!
	args := ['--prefix', prefix]
	mut env := os.environ()
	env['FIXTURE_LAUNCHER'] = launcher
	env['FIXTURE_ACTION'] = 'success'
	env['FIXTURE_PREFLIGHT'] = os.join_path(root, 'preflight-arguments')
	env['FIXTURE_OPTIONS'] = os.join_path(root, 'setup-arguments')
	check_options(program, root, env)!
	capture(program, args, true, environment: env)!
	assert os.read_file(launcher)! == 'active\n' && os.read_file(previous)! == 'previous\n'
	assert os.read_lines(os.join_path(state, 'unowned-releases'))! == [cached]
	assert !os.exists(lock_path)

	for action, code in {
		'fail':   17
		'cancel': 130
	} {
		env['FIXTURE_ACTION'] = action
		result := execute(program, args, false, environment: env)!
		assert result.code == code
			&& result.stderr.contains('Previous managed tool activation restored.')
		assert os.read_file(launcher)! == 'active\n' && os.read_file(previous)! == 'previous\n'
		assert !os.exists(lock_path) && !os.ls(state)!.any(it.starts_with('pending.'))
	}

	previous_dir := os.join_path(state, 'previous')
	snapshot_copy := os.join_path(root, 'original previous snapshot')
	os.rename_dir(previous_dir, snapshot_copy)!
	os.symlink(snapshot_copy, previous_dir)!
	os.write_file(launcher, 'active before finalization failure\n')!
	env['FIXTURE_ACTION'] = 'success'
	publication := execute(program, args, false, environment: env)!
	assert publication.stderr.contains('Could not finalize the installation:')
	assert os.read_file(launcher)! == 'active before finalization failure\n'
	assert os.readlink(previous_dir)! == snapshot_copy && !os.exists(lock_path)
	os.rm(previous_dir)!
	os.rename_dir(snapshot_copy, previous_dir)!

	env['FIXTURE_ACTION'] = 'corrupt'
	result := execute(program, args, false, environment: env)!
	assert result.code == 18 && result.stderr.contains('Automatic restoration failed')
	pending := os.ls(state)!.filter(it.starts_with('pending.'))
	assert pending.len == 1 && os.is_file(os.join_path(state, pending[0], 'ready'))
	assert os.read_file(previous)! == 'previous\n' && !os.exists(lock_path)
	println('ok - setup publishes snapshots, restores failed and cancelled activations, and retains failed recovery state')
}

check() or {
	eprintln(err)
	exit(1)
}
