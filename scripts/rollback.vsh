// Roll back an active installation or recover an interrupted activation.
import managedfiles { acquire_lock, git_at, release_lock }
import managedrecord
import managedsnapshot
import os
import rand

const usage = 'Usage: rollback.sh [--prefix DIRECTORY] [--recover PENDING_SNAPSHOT]'

struct Options {
mut:
	prefix  string
	recover string
}

fn parse(args []string) !Options {
	setting := os.getenv('VLANG_KAK_PREFIX')
	mut options := Options{
		prefix: if setting == '' { os.join_path(os.home_dir(), '.local') } else { setting }
	}
	for i := 0; i < args.len; i += 2 {
		value := args[i + 1] or { '' }
		if value == '' {
			return error_with_code('${args[i]} requires a path.', 2)
		}
		match args[i] {
			'--prefix' { options.prefix = value }
			'--recover' { options.recover = value }
			else { return error_with_code('Unknown option: ${args[i]}', 2) }
		}
	}
	return options
}

fn regular(path string) bool {
	return os.is_file(path) && !os.is_link(path)
}

struct Selection {
	snapshot  string
	recovered string
}

fn select_snapshot(state string, recover string) !Selection {
	mut selected := os.join_path(state, 'previous')
	mut recovered := ''
	if recover != '' {
		if os.is_link(recover) {
			return error('Refusing a redirected recovery snapshot.')
		}
		selected = os.real_path(os.abs_path(recover))
		if os.dir(selected) != state || !os.file_name(selected).starts_with('pending.') {
			return error('Use a pending snapshot from this installation.')
		}
		if !regular(os.join_path(selected, 'ready')) {
			return error('The interrupted setup snapshot is incomplete.')
		}
		recovered = os.join_path(state, os.file_name(selected).replace_once('pending.',
			'recovered.'))
		if os.exists(recovered) || os.is_link(recovered) {
			return error('Recovery destination already exists: ${recovered}')
		}
	}
	if os.is_link(selected) || !regular(os.join_path(selected, 'paths')) {
		return error('No previous installation snapshot.')
	}
	return Selection{
		snapshot:  selected
		recovered: recovered
	}
}

struct Plugin {
	repo     string
	previous string
	current  string
}

fn select_plugin(snapshot string) !Plugin {
	revision := os.join_path(snapshot, 'plugin-revision')
	if !regular(revision) {
		return Plugin{}
	}
	repo_marker := os.join_path(snapshot, 'plugin-repo')
	if !regular(repo_marker) {
		return error('Missing plugin checkout in ${snapshot}.')
	}
	repo := (os.read_file(repo_marker)!).trim_right('\n')
	if !os.is_abs_path(repo) {
		return error('Plugin checkout must be an absolute path.')
	}
	if git_at(repo, ['status', '--porcelain'])! != '' {
		println('Plugin checkout has local edits; rolling back tools only.')
		return Plugin{}
	}
	stored := (os.read_file(revision)!).trim_right('\n')
	previous := git_at(repo, ['rev-parse', '--verify', '--end-of-options', '${stored}^{commit}'])!
	return Plugin{
		repo:     repo
		previous: previous
		current:  git_at(repo, ['rev-parse', 'HEAD'])!
	}
}

fn checkout_plugin(plugin Plugin, next string) !bool {
	if plugin.repo == '' {
		return false
	}
	if git_at(plugin.repo, ['status', '--porcelain'])! != ''
		|| git_at(plugin.repo, ['rev-parse', 'HEAD'])! != plugin.current {
		println('Plugin checkout changed during rollback; rolling back tools only.')
		return false
	}
	os.write_file(os.join_path(next, 'plugin-revision'), plugin.current + '\n')!
	os.write_file(os.join_path(next, 'plugin-repo'), plugin.repo + '\n')!
	if plugin.current == plugin.previous {
		return false
	}
	git_at(plugin.repo, ['checkout', '--detach', plugin.previous])!
	return true
}

fn finalize(selection Selection, next string) ! {
	if selection.recovered != '' {
		os.rename_dir(selection.snapshot, selection.recovered)!
		println('Pre-recovery activation snapshot retained: ${next}')
		return
	}
	old := next + '.previous'
	os.rename_dir(selection.snapshot, old)!
	os.rename_dir(next, selection.snapshot) or {
		os.rename_dir(old, selection.snapshot) or {
			eprintln('Previous snapshot retained: ${old}: ${err}')
		}
		return err
	}
	os.rmdir_all(old) or { eprintln('Previous snapshot retained: ${old}: ${err}') }
}

fn record_activation(prefix string, state string) ! {
	marker := os.join_path(state, 'config-home')
	if regular(marker) {
		managedrecord.record(prefix, (os.read_file(marker)!).trim_right('\n'), '')!
	}
}

fn undo(prefix string, state string, next string) {
	managedsnapshot.restore(prefix, next) or {
		eprintln('Could not restore pre-rollback tools: ${err}')
		return
	}
	record_activation(prefix, state) or {
		eprintln('Could not re-record pre-rollback ownership: ${err}')
	}
}

fn rollback(options Options) ! {
	prefix := os.real_path(os.abs_path(options.prefix))
	state := os.join_path(prefix, 'opt', 'vlang-state')
	if !os.is_dir(state) {
		return error('No previous installation snapshot.')
	}
	if os.real_path(state) != state {
		return error('The installation state directory has been redirected: ${state}')
	}
	identity := acquire_lock(state, 'rollback')!
	defer { release_lock(state, identity) }
	selection := select_snapshot(state, options.recover)!
	plugin := select_plugin(selection.snapshot)!
	next := os.join_path(state, 'rollback.' + rand.uuid_v4())
	os.mkdir(next, mode: 0o700)!
	mut retain := false
	defer {
		if !retain {
			os.rmdir_all(next) or { eprintln(err) }
		}
	}
	managedsnapshot.capture(prefix, next)!
	config := managedsnapshot.configuration(selection.snapshot)!
	if config != '' {
		managedsnapshot.capture_personal(config, next)!
	}
	retain = true
	managedsnapshot.restore(prefix, selection.snapshot) or {
		return error('${err}. Pre-rollback snapshot retained at ${next}.')
	}
	record_activation(prefix, state) or {
		undo(prefix, state, next)
		return error('${err}. Pre-rollback snapshot retained at ${next}.')
	}
	changed_plugin := checkout_plugin(plugin, next) or {
		undo(prefix, state, next)
		return error('${err}. Pre-rollback snapshot retained at ${next}.')
	}
	finalize(selection, next) or {
		if changed_plugin {
			git_at(plugin.repo, ['checkout', '--detach', plugin.current]) or { eprintln(err) }
		}
		undo(prefix, state, next)
		return error('${err}. Pre-rollback snapshot retained at ${next}.')
	}
	println('Previous managed tools restored. Restart Kakoune when convenient.')
}

fn main() {
	if os.args[1..].any(it in ['--help', '-h']) {
		println(usage)
		return
	}
	options := parse(os.args[1..]) or {
		eprintln(err)
		eprintln(usage)
		exit(2)
	}
	rollback(options) or {
		eprintln(err)
		exit(1)
	}
}
