// Coordinate preparation, activation, and recovery of a managed installation.
import managedfiles { acquire_lock, git_at, read_manifest, release_lock }
import managedsnapshot
import os
import rand

#include "@DIR/setup-signals.h"

fn C.kak_setup_track_signals() int
fn C.kak_setup_was_interrupted() int

const managed_tools = ['kakoune', 'kak-lsp', 'vls', 'v']
const cancelled_status = 130

fn run(script string, args []string, environment map[string]string) int {
	mut child := os.new_process(os.join_path(@DIR, script))
	defer { child.close() }
	child.set_args(args)
	child.set_environment(environment)
	child.run()
	child.wait()
	return child.code
}

fn prefix_for(args []string) !string {
	mut prefix := os.join_path(os.home_dir(), '.local')
	for i, value in args {
		if value == '--prefix' {
			prefix = args[i + 1] or { return error_with_code('--prefix requires a directory.', 2) }
		}
	}
	if !os.is_abs_path(prefix) {
		return error_with_code('Use an absolute installation prefix.', 2)
	}
	if prefix.contains_any(":\t'\n") {
		return error_with_code('Colons/quotes/tabs/newlines in installation prefixes are unsupported.',
			2)
	}
	return os.real_path(os.abs_path(prefix))
}

fn retain_unowned_releases(prefix string, state string) ! {
	manifest := os.join_path(state, 'manifest.tsv')
	previous := if os.is_file(manifest) || os.is_link(manifest) {
		read_manifest(manifest)!
	} else {
		map[string]managedfiles.ManifestEntry{}
	}
	path := os.join_path(state, 'unowned-releases')
	mut unowned := map[string]bool{}
	if os.is_file(path) {
		for row in os.read_lines(path)! {
			unowned[row] = true
		}
	}
	// Cached releases without an ownership baseline may contain user additions.
	for tool in managed_tools {
		releases := os.join_path(prefix, 'opt', 'vlang-' + tool, 'releases')
		if !os.is_dir(releases) {
			continue
		}
		for name in os.ls(releases)! {
			release := os.join_path(releases, name)
			if !name.starts_with('.') && os.is_dir(release) && release !in previous {
				unowned[release] = true
			}
		}
	}
	next := os.join_path(state, '.unowned-' + rand.uuid_v4())
	defer { os.rm(next) or {} }
	os.write_file(next, unowned.keys().sorted().map(it + '\n').join(''))!
	os.rename_dir(next, path)!
}

fn save_plugin_revision(repo string, snapshot string) ! {
	if !os.exists(os.join_path(repo, '.git')) || git_at(repo, ['status', '--porcelain'])! != '' {
		return
	}
	setting := os.getenv('VLANG_KAK_PREVIOUS_PLUGIN_REVISION')
	reference := if setting == '' { 'HEAD' } else { setting }
	revision :=
		git_at(repo, ['rev-parse', '--verify', '--end-of-options', '${reference}^{commit}'])!
	os.write_file(os.join_path(snapshot, 'plugin-repo'), repo + '\n')!
	os.write_file(os.join_path(snapshot, 'plugin-revision'), revision + '\n')!
}

fn restore_plugin(repo string, snapshot string) ! {
	marker := os.join_path(snapshot, 'plugin-revision')
	if !os.is_file(marker) || git_at(repo, ['status', '--porcelain'])! != '' {
		return
	}
	revision := (os.read_file(marker)!).trim_right('\n')
	if git_at(repo, ['rev-parse', 'HEAD'])! != revision {
		git_at(repo, ['checkout', '--detach', revision])!
	}
}

fn retain_previous(state string, snapshot string) ! {
	previous := os.join_path(state, 'previous')
	backup := snapshot + '.previous'
	had_previous := os.exists(previous) || os.is_link(previous)
	if had_previous {
		if !os.is_dir(previous) || os.is_link(previous) {
			return error('Previous snapshot has been redirected: ${previous}')
		}
		os.rename_dir(previous, backup)!
	}
	os.rename_dir(snapshot, previous) or {
		if had_previous {
			os.rename_dir(backup, previous) or {
				eprintln('Previous snapshot retained at ${backup}: ${err}')
			}
		}
		return err
	}
	if had_previous {
		os.rmdir_all(backup) or { eprintln('Previous snapshot retained at ${backup}: ${err}') }
	}
}

fn restore_activation(prefix string, repo string, snapshot string) ! {
	managedsnapshot.restore(prefix, snapshot)!
	restore_plugin(repo, snapshot)!
	eprintln('Setup failed. Previous managed tool activation restored.')
}

fn clear_candidates(prefix string) {
	for tool in managed_tools {
		candidate := os.join_path(prefix, 'opt', 'vlang-' + tool, 'candidate')
		if os.is_link(candidate) {
			os.rm(candidate) or { eprintln(err) }
		}
	}
}

fn transaction(prefix string, args []string, mut env map[string]string) !int {
	state := os.join_path(prefix, 'opt', 'vlang-state')
	os.mkdir_all(state)!
	if os.real_path(state) != state {
		return error('The installation state directory has been redirected: ${state}')
	}
	identity := acquire_lock(state, 'setup')!
	defer { release_lock(state, identity) }
	defer { clear_candidates(prefix) }
	snapshot := os.join_path(state, 'pending.' + rand.uuid_v4())
	os.mkdir(snapshot, mode: 0o700)!
	mut keep_snapshot := false
	defer {
		if !keep_snapshot && os.is_dir(snapshot) {
			os.rmdir_all(snapshot) or { eprintln(err) }
		}
	}
	repo := os.dir(@DIR)
	retain_unowned_releases(prefix, state)!
	managedsnapshot.capture(prefix, snapshot)!
	save_plugin_revision(repo, snapshot)!
	os.write_file(os.join_path(snapshot, 'ready'), '')!
	if C.kak_setup_was_interrupted() != 0 {
		return cancelled_status
	}
	env['VLANG_KAK_STAGE'] = '1'
	env['VLANG_KAK_TRANSACTION'] = snapshot
	status := run('setup-impl.sh', args, env)
	interrupted := C.kak_setup_was_interrupted() != 0
	if status == 0 && !interrupted {
		retain_previous(state, snapshot) or {
			failure := err
			restore_activation(prefix, repo, snapshot) or {
				keep_snapshot = true
				eprintln('Automatic restoration failed; inspect ${snapshot}: ${err}')
			}
			return error('Could not finalize the installation: ${failure}')
		}
		return 0
	}
	restore_activation(prefix, repo, snapshot) or {
		keep_snapshot = true
		eprintln('Automatic restoration failed; inspect ${snapshot}: ${err}')
	}
	return if interrupted { cancelled_status } else { status }
}

fn setup(args []string) !int {
	mut env := os.environ()
	if args.any(it in ['--help', '-h']) {
		return run('setup-impl.sh', ['--help'], env)
	}
	prefix := prefix_for(args)!
	if C.kak_setup_track_signals() != 0 {
		return error('Could not register setup signal handlers.')
	}
	if '--install-dependencies' in args {
		status := run('dependencies.sh', ['--apply'], env)
		if status != 0 || C.kak_setup_was_interrupted() != 0 {
			return if C.kak_setup_was_interrupted() != 0 { cancelled_status } else { status }
		}
	}
	status := run('preflight.sh', args, env)
	if status != 0 || C.kak_setup_was_interrupted() != 0 {
		return if C.kak_setup_was_interrupted() != 0 { cancelled_status } else { status }
	}
	return transaction(prefix, args, mut env)
}

exit(setup(os.args[1..]) or {
	eprintln(err)
	if err.code() == 2 { 2 } else { 1 }
})
