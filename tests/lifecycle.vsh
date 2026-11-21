// Verify managed ownership, settings, and editor checkpoints on isolated paths.
import crypto.sha256
import editorui { quote }
import os
import rand
import releasetest { capture, execute }
import time

const setup_timeout = time.minute
// Keep the release in use until the test's deferred cleanup stops the worker.
const release_worker_sleep_seconds = '60'
const release_worker_exec_polls = 100
const release_worker_exec_poll = 10 * time.millisecond
const saved_selection = '1.2,1.3'
const personal_header = '# personal\n'

struct Lifecycle {
	root   string
	repo   string
	prefix string
	config string
	kak    string
	env    map[string]string
}

fn require(condition bool, detail string) ! {
	if !condition {
		return error(detail)
	}
}

fn (life Lifecycle) script(name string, args []string) !string {
	return capture(os.join_path(life.repo, 'scripts', name + '.sh'), args, true,
		environment: life.env
		timeout:     setup_timeout
	)
}

fn (life Lifecycle) snapshot_restore() ! {
	prefix := os.join_path(life.root, 'snapshot prefix')
	launcher := os.join_path(prefix, 'bin', 'kak-v')
	new_launcher := os.join_path(prefix, 'bin', 'v')
	current := os.join_path(prefix, 'opt', 'vlang-vls', 'current')
	os.mkdir_all(os.dir(launcher))!
	os.mkdir_all(os.dir(current))!
	os.write_file(launcher, '# previous launcher\n')!
	os.chmod(launcher, 0o750)!
	os.symlink('releases/previous', current)!
	config := os.join_path(life.root, 'snapshot config')
	kakrc := os.join_path(config, 'kak', 'kakrc')
	linked := os.join_path(life.root, 'settings target')
	alias := os.join_path(life.root, 'settings hard link')
	os.mkdir_all(os.dir(kakrc))!
	block := '# >>> vlang.kak managed >>>\n# previous block\n# <<< vlang.kak managed <<<\n'
	os.write_file(linked, '# original personal settings\n' + block)!
	os.link(linked, alias)!
	os.symlink(linked, kakrc)!
	snapshot := os.join_path(life.root, 'snapshot data')
	life.script('managed-state', ['snapshot', prefix, snapshot])!
	life.script('managed-state', ['snapshot-personal', prefix, config, snapshot])!
	os.write_file(launcher, '# active launcher\n')!
	os.chmod(launcher, 0o700)!
	os.write_file(new_launcher, '# new launcher\n')!
	os.rm(current)!
	os.symlink('releases/active', current)!
	edited := '# new personal settings\n'
	os.write_file(linked, edited + block.replace('previous', 'active'))!
	marker := os.join_path(snapshot, 'paths')
	paths := os.read_file(marker)!
	os.write_file(marker, paths + '../outside\n')!
	refused := execute(os.join_path(life.repo, 'scripts/managed-state.sh'), [
		'restore',
		prefix,
		snapshot,
	], false,
		environment: life.env
		timeout:     setup_timeout
	)!
	require(refused.stderr.contains('Unexpected snapshot path:')
		&& !refused.stderr.contains('Using shell recovery')
		&& os.read_file(launcher)! == '# active launcher\n',
		'Malformed snapshot partly restored managed files')!
	os.write_file(marker, paths)!
	life.script('managed-state', ['restore', prefix, snapshot])!
	require(os.readlink(current)! == 'releases/previous'
		&& os.read_file(launcher)! == '# previous launcher\n'
		&& os.stat(launcher)!.mode & 0o777 == 0o750 && !os.exists(new_launcher),
		'Restore changed a link target or launcher permissions, or kept a new launcher')!
	require(os.readlink(kakrc)! == linked && os.read_file(alias)! == edited + block,
		'Restore changed the settings file identity or discarded personal edits')!
	state := os.join_path(prefix, 'opt', 'vlang-state')
	os.mkdir_all(state)!
	os.rename_dir(snapshot, os.join_path(state, 'previous'))!
	active_block := block.replace('previous', 'active')
	os.write_file(linked, edited + active_block)!
	life.script('rollback', ['--prefix', prefix])!
	require(os.read_file(alias)! == edited + block, 'Rollback did not restore the saved block')!
	life.script('rollback', ['--prefix', prefix])!
	require(os.read_file(alias)! == edited + active_block,
		'Second rollback did not restore the newer block')!
}

fn fixture_git(repo string, args []string) !string {
	mut command := ['-C', repo, '-c', 'user.name=Rollback Test', '-c',
		'user.email=rollback@example.invalid', '-c', 'commit.gpgsign=false']
	command << args
	return capture('git', command, true)!.trim_right('\n')
}

fn (life Lifecycle) rollback_plugin() ! {
	repo := os.join_path(life.root, 'plugin checkout')
	os.mkdir(repo)!
	fixture_git(repo, ['init', '-q'])!
	plugin := os.join_path(repo, 'plugin.kak')
	os.write_file(plugin, '# previous revision\n')!
	fixture_git(repo, ['add', 'plugin.kak'])!
	fixture_git(repo, ['commit', '-qm', 'previous'])!
	previous := fixture_git(repo, ['rev-parse', 'HEAD'])!
	os.write_file(plugin, '# active revision\n')!
	fixture_git(repo, ['commit', '-qam', 'active'])!
	current := fixture_git(repo, ['rev-parse', 'HEAD'])!
	prefix := os.join_path(life.root, 'rollback prefix')
	launcher := os.join_path(prefix, 'bin', 'kak-v')
	state := os.join_path(prefix, 'opt', 'vlang-state')
	snapshot := os.join_path(state, 'previous')
	os.mkdir_all(os.dir(launcher))!
	os.write_file(launcher, '# previous launcher\n')!
	life.script('managed-state', ['snapshot', prefix, snapshot])!
	revision := os.join_path(snapshot, 'plugin-revision')
	os.write_file(revision, 'missing-commit\n')!
	os.write_file(os.join_path(snapshot, 'plugin-repo'), repo + '\n')!
	os.write_file(launcher, '# active launcher\n')!
	rollback := os.join_path(life.repo, 'scripts', 'rollback.sh')
	args := ['--prefix', prefix]
	invalid := execute(rollback, args, false, environment: life.env, timeout: setup_timeout)!
	require(invalid.stderr.contains('rev-parse') && os.read_file(launcher)! == '# active launcher\n'
		&& fixture_git(repo, ['rev-parse', 'HEAD'])! == current,
		'Rollback mutated the installation before validating its saved Git revision')!
	os.write_file(revision, previous + '\n')!
	config_marker := os.join_path(state, 'config-home')
	os.write_file(config_marker, 'invalid-relative-config\n')!
	failure := execute(rollback, args, false, environment: life.env, timeout: setup_timeout)!
	require(failure.stderr.contains('Pre-rollback snapshot retained')
		&& os.read_file(launcher)! == '# active launcher\n'
		&& fixture_git(repo, ['rev-parse', 'HEAD'])! == current
		&& os.read_file(revision)! == previous + '\n' && !os.exists(os.join_path(state, 'lock')),
		'Rollback did not restore the active installation after ownership recording failed')!
	os.rm(config_marker)!
	life.script('rollback', args)!
	require(os.read_file(launcher)! == '# previous launcher\n'
		&& fixture_git(repo, ['rev-parse', 'HEAD'])! == previous,
		'Rollback did not restore the launcher and checkout together')!
	os.write_file(plugin, '# personal plugin edit\n')!
	output := life.script('rollback', args)!
	require(output.contains('local edits') && os.read_file(launcher)! == '# active launcher\n'
		&& fixture_git(repo, ['rev-parse', 'HEAD'])! == previous
		&& os.read_file(plugin)! == '# personal plugin edit\n',
		'Rollback overwrote local plugin edits')!
}

fn (life Lifecycle) settings_and_ownership() ! {
	setup := ['--prefix', life.prefix, '--no-build', '--no-lsp', '--no-vls', '--no-explorer']
	life.script('setup', setup)!
	state := os.join_path(life.prefix, 'opt/vlang-state')
	manifest := os.join_path(state, 'manifest.tsv')
	require(os.is_file(manifest), 'Setup did not create an ownership manifest')!
	user := os.join_path(life.config, 'kak/vlang-user.kak')
	os.write_file(user, personal_header)!
	life.script('settings', ['v_pane_mode', 'off'])!
	life.script('settings', ['v_live_search_enabled', 'false'])!
	life.script('settings', ['v_pane_mode', 'auto'])!
	settings := os.read_file(user)!
	require(settings.starts_with(personal_header) && settings.count('v_pane_mode') == 1,
		'Settings did not preserve personal text or wrote a duplicate setting')!

	launcher := os.join_path(life.prefix, 'bin/kak-v')
	before := os.read_bytes(launcher)!
	mut missing := setup.clone()
	missing << ['--vls', os.join_path(life.root, 'missing')]
	refused := execute(os.join_path(life.repo, 'scripts/setup.sh'), missing, false,
		environment: life.env
		timeout:     setup_timeout
	)!
	require(refused.stderr.contains('Previous managed tool activation restored')
		&& os.read_bytes(launcher)! == before, 'Failed setup did not restore the active launcher')!

	// The isolated installation cannot adopt personal autoload files.
	autoload := os.join_path(life.config, 'kak/autoload')
	os.mkdir(autoload)!
	other := os.join_path(life.root, 'other.kak')
	os.write_file(other, '# other\n')!
	personal_link := os.join_path(autoload, 'vlang.kak')
	os.symlink(other, personal_link)!
	ide_config := os.join_path(life.prefix, 'opt/vlang-kakoune/ide-config/kak')
	isolated_custom := os.join_path(ide_config, 'autoload/custom.kak')
	os.write_file(isolated_custom, '# my isolated configuration\n')!
	life.script('setup', setup)!
	owned := os.read_file(manifest)!
	require(!owned.contains(personal_link) && !owned.contains(isolated_custom),
		'Setup adopted an unowned autoload file')!

	life.cleanup_releases(state)!
	os.write_file(launcher, os.read_file(launcher)! + '# my edit\n')!
	preview := life.script('uninstall', ['--prefix', life.prefix])!
	require(os.is_file(launcher) && preview.contains('Keep changed:'),
		'Uninstall preview lost the edited launcher')!
	life.script('uninstall', ['--prefix', life.prefix, '--apply'])!
	require(os.is_file(launcher) && os.is_file(user) && os.readlink(personal_link)! == other
		&& os.is_file(isolated_custom) && !os.exists(os.join_path(ide_config, 'kakrc')),
		'Uninstall did not preserve personal files and remove unchanged owned files')!
}

fn (life Lifecycle) repair_links() ! {
	prefix := os.join_path(life.root, 'repair prefix')
	state := os.join_path(prefix, 'opt', 'vlang-state')
	tool := os.join_path(prefix, 'opt', 'vlang-vls')
	config := os.join_path(life.root, 'repair config')
	outside := os.join_path(life.root, 'repair outside')
	os.mkdir_all(state)!
	os.mkdir_all(tool)!
	os.mkdir(outside)!
	os.write_file(os.join_path(state, 'config-home'), config + '\n')!
	current := os.join_path(tool, 'current')
	candidate := os.join_path(tool, 'candidate')
	autoload := os.join_path(config, 'kak', 'autoload', 'vlang.kak')
	replacement := os.join_path(prefix, 'bin', 'vls')
	redirect := os.join_path(tool, 'redirect')
	os.mkdir_all(os.dir(replacement))!
	os.symlink('releases/personal', candidate)!
	os.write_file(replacement, 'personal launcher')!
	os.symlink(outside, redirect)!
	rows := [
		'link\treleases/previous\t${current}',
		'link\treleases/recorded\t${candidate}',
		'link\t${tool}/runtime.kak\t${autoload}',
		'link\t${tool}/bin/vls\t${replacement}',
		'link\tignored\t${redirect}/missing/link',
		'link\tignored\t${tool}/../../unrecognized',
	]
	manifest := os.join_path(state, 'manifest.tsv')
	os.write_file(manifest, rows.join('\n') + '\n')!
	life.script('managed-state', ['repair-links', prefix])!
	require(os.readlink(current)! == 'releases/previous'
		&& os.readlink(autoload)! == '${tool}/runtime.kak',
		'Repair did not restore the recorded links')!
	require(os.readlink(candidate)! == 'releases/personal'
		&& os.read_file(replacement)! == 'personal launcher', 'Repair replaced a user change')!
	require(os.ls(outside)!.len == 0 && !os.is_link(os.join_path(prefix, 'unrecognized')),
		'Repair followed a redirected ancestor or path traversal')!
	require(life.script('managed-state', ['repair-links', prefix])!.contains('Keep changed link:'),
		'Repeated repair did not preserve the changed link')!
}

fn (life Lifecycle) cleanup_releases(state string) ! {
	// Cleanup resolves a saved relative link against its original installation root.
	tool := os.join_path(life.prefix, 'opt/vlang-vls')
	releases := os.join_path(tool, 'releases')
	for version in ['old', 'current', 'candidate', 'unused', 'modified', 'extra-directory', 'live',
		'session', 'unowned'] {
		release := os.join_path(releases, version)
		os.mkdir_all(release)!
		os.write_file(os.join_path(release, '.vlang-commit'), version)!
		os.write_file(os.join_path(release, 'payload'), version)!
	}
	current := os.join_path(tool, 'current')
	os.symlink('releases/old', current)!
	os.symlink('releases/candidate', os.join_path(tool, 'candidate'))!
	live := os.join_path(releases, 'live', 'worker')
	os.cp(os.find_abs_path_of_executable('sleep')!, live)!
	os.chmod(live, 0o755)!
	life.script('managed-state', ['record', life.prefix, life.config])!
	previous := os.join_path(state, 'previous')
	os.rmdir_all(previous)!
	life.script('managed-state', ['snapshot', life.prefix, previous])!
	os.rm(current)!
	os.symlink('releases/current', current)!
	os.write_file(os.join_path(releases, 'modified', 'payload'), 'user edit')!
	os.mkdir(os.join_path(releases, 'extra-directory', 'user directory'))!
	os.write_file(os.join_path(state, 'unowned-releases'), os.join_path(releases, 'unowned') + '\n')!
	life.script('managed-state', ['record', life.prefix, life.config])!
	restart := os.join_path(life.prefix, 'opt', 'vlang-kakoune', 'restart.cleanup-test')
	os.mkdir(restart)!
	defer { os.rmdir_all(restart) or {} }
	os.write_file(os.join_path(restart, 'owner-pid'), os.getpid().str() + '\n')!
	os.write_file(os.join_path(restart, 'tool-releases'), os.join_path(releases, 'session') + '\n')!
	mut worker := os.new_process(live)
	worker.set_args([release_worker_sleep_seconds])
	worker.run()
	defer {
		if worker.is_alive() {
			worker.signal_kill()
			worker.wait()
		}
		worker.close()
	}
	// Wait for the child to exec so its /proc link identifies the release.
	mut executable := ''
	for _ in 0 .. release_worker_exec_polls {
		executable = os.readlink('/proc/${worker.pid}/exe') or { '' }
		if executable == live {
			break
		}
		time.sleep(release_worker_exec_poll)
	}
	require(executable == live, 'Could not start the release usage control')!
	preview := life.script('cleanup', ['--prefix', life.prefix])!
	require(preview.contains('Remove unused release: ' + os.join_path(releases, 'unused'))
		&& os.is_dir(os.join_path(releases, 'unused')),
		'Preview removed or omitted the unused release')!
	life.script('cleanup', ['--prefix', life.prefix, '--apply'])!
	require(!os.exists(os.join_path(releases, 'unused')),
		'Cleanup left an unchanged inactive release')!
	for version in ['old', 'current', 'candidate', 'modified', 'extra-directory', 'live', 'session',
		'unowned'] {
		require(os.is_file(os.join_path(releases, version, 'payload')),
			'Cleanup removed the protected ${version} release')!
	}
	require(!os.exists(os.join_path(state, 'lock')), 'Cleanup left its installation lock')!
}

fn (life Lifecycle) editor(commands string, open_files []string, env map[string]string) ! {
	failure := os.join_path(life.root, 'failure')
	wrapped := 'try %{ ${commands} } catch %{ echo -debug %val{error}; buffer *debug*; write ${quote(failure)}; quit! }'
	mut args := ['-ui', 'json', '-e', wrapped]
	args << open_files
	capture(life.kak, args, true, environment: env, timeout: setup_timeout)!
	if os.is_file(failure) {
		return error(os.read_file(failure)!)
	}
}

fn (life Lifecycle) checkpoints() ! {
	project := os.join_path(life.root, "project's with spaces")
	os.mkdir(project)!
	os.write_file(os.join_path(project, 'v.mod'), 'Module { name: "test" }')!
	source := os.join_path(project, "it's.v")
	os.write_file(source, 'module main\nfn main() {}\n')!
	marker := os.join_path(life.root, 'must-not-exist')
	// These strings should reach the project command unchanged as arguments.
	args := ['one value', "it's literal", '', 'line one\nline two', '$' + '(touch ${marker})']
	mut prefs_args := ['args', source]
	prefs_args << args
	prefs := life.script('preferences', prefs_args)!
	require(!os.exists(marker) && prefs.contains("it''s literal")
		&& life.script('preferences', ['show', source])!.contains(args[0]),
		'Preferences did not preserve literal project arguments')!

	editor_config := os.join_path(life.root, 'editor-config')
	os.mkdir_all(os.join_path(editor_config, 'kak'))!
	plugin := os.join_path(life.repo, 'rc/vlang.kak')
	os.write_file(os.join_path(editor_config, 'kak/kakrc'), 'source ${quote(plugin)}\n')!
	mut env := life.env.clone()
	env['XDG_CONFIG_HOME'] = editor_config
	env['VLANG_KAK_CONFIG_HOME'] = life.config
	// With V installed, checkpoint serialization should never call the POSIX hasher.
	hash_marker := os.join_path(life.root, 'shell-hash-used')
	hash_shim := os.join_path(life.root, 'bin', 'sha256sum')
	os.write_file(hash_shim, '#!/bin/sh\n: > ' + os.quoted_path(hash_marker) + '\nexit 1\n')!
	os.chmod(hash_shim, 0o700)!
	record := os.join_path(life.root, 'snapshot-path')
	life.editor('execute-keys iUnsaved<esc>; edit -scratch notes; execute-keys iScratch<esc>; ' +
		'edit -scratch recovered-report; execute-keys iReport<esc>; set-option buffer filetype v-doc; ' +
		'set-option buffer readonly true; buffer ${quote(source)}; select ${saved_selection}; v-session-save; ' +
		'echo -to-file ${quote(record)} %opt{v_session_checkpoint}; quit!', [source], env)!
	checkpoint := os.read_file(record)!.trim_space()
	os.rm(hash_shim)!
	require(!os.exists(hash_marker) && !os.exists(os.join_path(checkpoint, 'session-checkpoint')),
		'The V checkpoint writer used the shell hasher or left its executable behind')!

	dispatch := os.join_path(life.root, 'dispatch')
	printf_args := quote("printf '<%s>\\n' .")
	life.editor('define-command -override -params 1 v-make-command %{ echo -to-file ${quote(dispatch)} %arg{1} }; ' +
		'set-option global v_run_command ${printf_args}; v-project-preference load; v-run-project; quit!', [
		source,
	], env)!
	command := os.read_file(dispatch)!.trim_space()
	output := capture('/bin/sh', ['-c', command], true,
		environment: life.env
		timeout:     setup_timeout
	)!
	require(args.all(output.contains('<${it}>')) && !os.exists(marker),
		'Project command did not receive its arguments literally\n${output}')!

	source_copy := os.join_path(life.root, 'restored-source')
	scratch_copy := os.join_path(life.root, 'restored-scratch')
	position := os.join_path(life.root, 'selection')
	recovery_type := os.join_path(life.root, 'recovery-type')
	after_close := os.join_path(life.root, 'after-close')
	life.editor('v-session-restore; write ${quote(source_copy)}; ' +
		'echo -to-file ${quote(position)} %val{selections_desc}; buffer notes; write ${quote(scratch_copy)}; ' +
		'buffer recovered-report; echo -to-file ${quote(recovery_type)} %opt{filetype}; ' +
		'execute-keys -with-maps q; echo -to-file ${quote(after_close)} %val{buflist}; quit!', [],
		env)!
	require(os.read_file(source_copy)!.starts_with('Unsaved')
		&& os.read_file(source)!.starts_with('module')
		&& os.read_file(scratch_copy)!.starts_with('Scratch')
		&& os.read_file(recovery_type)!.trim_space() == 'v-recovery'
		&& !os.read_file(after_close)!.contains('recovered-report')
		&& os.read_file(position)!.trim_space() == saved_selection,
		'Checkpoint did not restore the source, selection, and scratch or recovery buffers')!
}

fn (life Lifecycle) uninstall_integration() ! {
	prefix := os.join_path(life.root, 'integrated prefix')
	config := os.join_path(life.root, 'integrated config')
	state := os.join_path(prefix, 'opt/vlang-state')
	autoload := os.join_path(config, 'kak/autoload')
	os.mkdir_all(state)!
	os.mkdir_all(autoload)!
	os.write_file(os.join_path(state, 'config-home'), config + '\n')!
	kakrc := os.join_path(config, 'kak/kakrc')
	target := os.join_path(life.root, 'linked kakrc')
	block := '# >>> vlang.kak managed >>>\nset-option global v_pane_mode off\n# <<< vlang.kak managed <<<\n'
	original := '# personal before\n' + block.trim_right('\n')
	os.write_file(target, original)!
	os.chmod(target, 0o600)!
	os.symlink(target, kakrc)!

	kakoune := os.join_path(prefix, 'opt/vlang-kakoune')
	runtime := os.join_path(kakoune, 'releases/fixture/share/kak')
	os.mkdir_all(runtime)!
	payload := os.join_path(runtime, 'runtime.kak')
	os.write_file(payload, 'shared runtime')!
	current := os.join_path(kakoune, 'current')
	os.symlink('releases/fixture', current)!
	runtime_link := os.join_path(autoload, 'vlang-site-runtime')
	os.symlink(runtime, runtime_link)!
	os.write_file(os.join_path(autoload, 'other-plugin.kak'), '# a second consumer')!
	redirected := os.join_path(prefix, 'opt/vlang-vls')
	outside := os.join_path(life.root, 'outside release')
	os.mkdir(outside)!
	os.write_file(os.join_path(outside, 'payload'), 'outside')!
	os.symlink(outside, redirected)!

	rows := [
		'block\t${sha256.hexhash(block)}\t${kakrc}',
		'link\treleases/fixture\t${current}',
		'link\t${runtime}\t${runtime_link}',
		'file\t${sha256.hexhash('shared runtime')}\t${payload}',
		'file\t${sha256.hexhash('outside')}\t${redirected}/payload',
	]
	os.write_file(os.join_path(state, 'manifest.tsv'), rows.join('\n') + '\n')!
	preview := life.script('uninstall', ['--prefix', prefix])!
	require(preview.contains('Eligible block:') && os.read_file(target)! == original,
		'Preview changed the managed block')!
	output := life.script('uninstall', ['--prefix', prefix, '--apply'])!
	require(os.is_link(kakrc) && os.readlink(kakrc)! == target
		&& os.read_file(target)! == '# personal before\n',
		'Removal changed outside settings or replaced the symlink')!
	backups := os.ls(life.root)!.filter(it.starts_with('linked kakrc.vlang-backup.'))
	require(backups.len == 1, 'Removal did not keep exactly one backup')!
	backup := os.join_path(life.root, backups[0])
	require(os.read_file(backup)! == original && os.stat(backup)!.mode & 0o777 == 0o600
		&& os.stat(target)!.mode & 0o777 == 0o600,
		'Backup contents or settings permissions changed')!
	require(output.contains('Keep redirected path:') && os.is_file(os.join_path(outside, 'payload'))
		&& os.is_link(runtime_link) && os.is_link(current) && os.is_file(payload),
		'Removal changed a redirected file or a shared runtime')!
}

fn run(kak_path string) ! {
	kak := os.real_path(os.find_abs_path_of_executable(kak_path)!)
	root := os.join_path(os.temp_dir(), 'vlang-lifecycle-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	prefix := os.join_path(root, 'prefix with spaces')
	config := os.join_path(root, "personal config's")
	life := Lifecycle{
		root:   root
		repo:   os.dir(@DIR)
		prefix: prefix
		config: config
		kak:    kak
		env:    releasetest.editor_environment(root, prefix, config, kak)!
	}
	life.snapshot_restore()!
	life.rollback_plugin()!
	life.settings_and_ownership()!
	life.repair_links()!
	life.uninstall_integration()!
	life.checkpoints()!
	println('ok - link repair, owned removal, changed-file preservation, failed setup recovery, persistent settings, literal arguments and buffer checkpoint restoration')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/lifecycle.vsh KAKOUNE')
	exit(2)
}
run(os.args[1]) or {
	eprintln('not ok - lifecycle: ${err}')
	exit(1)
}
