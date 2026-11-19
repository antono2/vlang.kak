// Verify managed ownership, settings, and editor checkpoints on isolated paths.
import editorui { quote }
import os
import rand
import releasetest { capture, execute }
import time

const setup_timeout = time.minute
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
	require(os.is_file(launcher) && preview.contains('Keep changed:'), 'Uninstall preview lost the edited launcher')!
	life.script('uninstall', ['--prefix', life.prefix, '--apply'])!
	require(os.is_file(launcher) && os.is_file(user) && os.readlink(personal_link)! == other
		&& os.is_file(isolated_custom) && !os.exists(os.join_path(ide_config, 'kakrc')),
		'Uninstall did not preserve personal files and remove unchanged owned files')!
}

fn (life Lifecycle) cleanup_releases(state string) ! {
	// Cleanup resolves a saved relative link against its original installation root.
	tool := os.join_path(life.prefix, 'opt/vlang-vls')
	releases := os.join_path(tool, 'releases')
	for version in ['old', 'current', 'unused'] {
		release := os.join_path(releases, version)
		os.mkdir_all(release)!
		os.write_file(os.join_path(release, '.vlang-commit'), version)!
		os.write_file(os.join_path(release, 'payload'), version)!
	}
	current := os.join_path(tool, 'current')
	os.symlink('releases/old', current)!
	life.script('managed-state', ['record', life.prefix, life.config])!
	previous := os.join_path(state, 'previous')
	os.rmdir_all(previous)!
	life.script('managed-state', ['snapshot', life.prefix, previous])!
	os.rm(current)!
	os.symlink('releases/current', current)!
	life.script('cleanup', ['--prefix', life.prefix, '--apply'])!
	require(os.is_file(os.join_path(releases, 'old/payload'))
		&& os.is_file(os.join_path(releases, 'current/payload'))
		&& !os.exists(os.join_path(releases, 'unused')), 'Cleanup did not retain the active and rollback releases')!
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
	args := ['one value', "it's literal", '$' + '(touch ${marker})']
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
		'set-option global v_run_command ${printf_args}; v-project-preference load; v-run-project; quit!',
		[source], env)!
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
	life.editor('v-session-restore ${quote(checkpoint)}; write ${quote(source_copy)}; ' +
		'echo -to-file ${quote(position)} %val{selections_desc}; buffer notes; write ${quote(scratch_copy)}; ' +
		'buffer recovered-report; echo -to-file ${quote(recovery_type)} %opt{filetype}; ' +
		'execute-keys -with-maps q; echo -to-file ${quote(after_close)} %val{buflist}; quit!',
		[], env)!
	require(os.read_file(source_copy)!.starts_with('Unsaved') && os.read_file(source)!.starts_with('module')
		&& os.read_file(scratch_copy)!.starts_with('Scratch')
		&& os.read_file(recovery_type)!.trim_space() == 'v-recovery'
		&& !os.read_file(after_close)!.contains('recovered-report')
		&& os.read_file(position)!.trim_space() == saved_selection,
		'Checkpoint did not restore the source, selection, and scratch or recovery buffers')!
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
	life.settings_and_ownership()!
	life.checkpoints()!
	println('ok - owned removal, changed-file preservation, failed setup recovery, persistent settings, literal arguments and buffer checkpoint restoration')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/lifecycle.vsh KAKOUNE')
	exit(2)
}
run(os.args[1]) or {
	eprintln('not ok - lifecycle: ${err}')
	exit(1)
}
