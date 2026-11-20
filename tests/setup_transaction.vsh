// Exercise setup transaction outcomes without building or installing tools.
import os
import rand
import releasetest { capture, execute }

const owner = '# vlang.kak managed IDE launcher\n'

fn launcher_text(note string) string {
	return owner + note + '\n'
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
	assert os.read_lines(env['FIXTURE_OPTIONS'])! == ['--install', prefix,
		os.join_path(root, 'source'), env['VLANG_KAK_CONFIG_HOME'], '', '', 'false', 'system',
		'system', 'true', 'true', 'auto', 'native', 'false', 'external', '--install-dependencies',
		'false', 'latest', 'latest', '--prefix']

	missing := os.join_path(root, 'invalid option prefix')
	result := execute(program, ['--prefix', missing, '--vls'], false, environment: env)!
	assert result.code == 2 && result.stderr.contains('--vls requires a value')
	assert !os.exists(missing)
	refused := execute(program, ['--prefix', missing, '--install-dependencies'], false,
		environment: env
	)!
	assert refused.code == 99 && !os.exists(missing)
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-setup-transaction-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	source := os.join_path(root, 'source', 'scripts')
	os.mkdir_all(source)!
	repo_scripts := os.join_path(os.dir(@DIR), 'scripts')
	for name in ['setup.vsh', 'setup-help.txt', 'maintenance-signals.h'] {
		os.cp(os.join_path(repo_scripts, name), os.join_path(source, name))!
	}
	for name in ['managedfiles', 'managedsnapshot', 'setupconfig'] {
		os.cp_all(os.join_path(repo_scripts, name), os.join_path(source, name), false)!
	}
	// Any fallback to the former shell worker or check wrappers must fail.
	for name in ['preflight.sh', 'dependencies.sh', 'setup-impl.sh'] {
		path := os.join_path(source, name)
		os.write_file(path, '#!/bin/sh\nexit 88\n')!
		os.chmod(path, 0o755)!
	}
	os.write_file(os.join_path(source, 'setup-checks.vsh'), r'import os
if os.args[1] == "dependencies" { exit(99) }
assert os.args[1] == "preflight"
os.write_file(os.getenv("FIXTURE_PREFLIGHT"), os.args[2..].join("\n") + "\n") or { panic(err) }
')!
	os.write_file(os.join_path(source, 'setup-configuration.vsh'), r'import os
#include <signal.h>
fn C.kill(int, int) int
os.write_file(os.getenv("FIXTURE_OPTIONS"), os.args[1..].join("\n") + "\n") or { panic(err) }
action := os.getenv("FIXTURE_ACTION")
launcher := os.getenv("FIXTURE_LAUNCHER")
os.write_file(launcher, "# vlang.kak managed IDE launcher\n" + action + "\n") or { panic(err) }
match action {
	"fail" { exit(17) }
	"cancel" { C.kill(os.getppid(), C.SIGTERM) }
	"corrupt" {
		mut stream := os.open_append(os.join_path(os.getenv("VLANG_KAK_TRANSACTION"), "paths")) or { panic(err) }
		stream.writeln("../outside") or { panic(err) }
		stream.close()
		exit(18)
	}
	else {}
}
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
	os.write_file(launcher, launcher_text('previous'))!
	args := ['--prefix', prefix, '--no-build', '--no-lsp', '--no-vls', '--no-explorer']
	mut env := os.environ()
	env['VLANG_KAK_CONFIG_HOME'] = os.join_path(root, 'personal config')
	env['FIXTURE_LAUNCHER'] = launcher
	env['FIXTURE_ACTION'] = 'success'
	env['FIXTURE_PREFLIGHT'] = os.join_path(root, 'preflight-arguments')
	env['FIXTURE_OPTIONS'] = os.join_path(root, 'setup-arguments')
	help := capture(program, ['--help'], true, environment: env)!
	assert help == os.read_file(os.join_path(source, 'setup-help.txt'))!
	check_options(program, root, env)!
	capture(program, args, true, environment: env)!
	assert os.read_file(launcher)! == launcher_text('success')
		&& os.read_file(previous)! == launcher_text('previous')
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
		assert os.read_file(launcher)! == launcher_text('success')
			&& os.read_file(previous)! == launcher_text('previous')
		assert !os.exists(lock_path) && !os.ls(state)!.any(it.starts_with('pending.'))
	}

	previous_dir := os.join_path(state, 'previous')
	snapshot_copy := os.join_path(root, 'original previous snapshot')
	os.rename_dir(previous_dir, snapshot_copy)!
	os.symlink(snapshot_copy, previous_dir)!
	os.write_file(launcher, launcher_text('active before finalization failure'))!
	env['FIXTURE_ACTION'] = 'success'
	publication := execute(program, args, false, environment: env)!
	assert publication.stderr.contains('Could not finalize the installation:')
	assert os.read_file(launcher)! == launcher_text('active before finalization failure')
	assert os.readlink(previous_dir)! == snapshot_copy && !os.exists(lock_path)
	os.rm(previous_dir)!
	os.rename_dir(snapshot_copy, previous_dir)!

	env['FIXTURE_ACTION'] = 'corrupt'
	result := execute(program, args, false, environment: env)!
	assert result.code == 18 && result.stderr.contains('Automatic restoration failed')
	pending := os.ls(state)!.filter(it.starts_with('pending.'))
	assert pending.len == 1 && os.is_file(os.join_path(state, pending[0], 'ready'))
	assert os.read_file(previous)! == launcher_text('previous') && !os.exists(lock_path)
	println('ok - setup publishes snapshots, restores failed and cancelled activations, and retains failed recovery state')
}

check() or {
	eprintln(err)
	exit(1)
}
