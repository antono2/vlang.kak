// Coordinate preparation, activation, and recovery of a managed installation.
import managedfiles { acquire_lock, git_at, read_manifest, release_lock }
import managedsnapshot
import os
import rand
import setupconfig

#include "@DIR/maintenance-signals.h"

fn C.kak_track_maintenance_signals() int
fn C.kak_maintenance_signal() int

const managed_tools = ['kakoune', 'kak-lsp', 'vls', 'v']
const cancelled_status = 130
const setup_help = $embed_file('setup-help.txt')

fn run(program string, args []string, environment map[string]string) int {
	mut child := os.new_process(program)
	defer { child.close() }
	child.set_args(args)
	child.set_environment(environment)
	child.run()
	child.wait()
	return child.code
}

// Compile the child separately so v run cannot inject compiler variables
// into installers or their build tools.
fn run_native(compiler string, script string, args []string, env map[string]string) !int {
	directory := os.join_path(os.temp_dir(), 'vlang-install-' + rand.uuid_v4())
	os.mkdir(directory, mode: 0o700)!
	defer { os.rmdir_all(directory) or {} }
	program := os.join_path(directory, 'program')
	mut build_env := env.clone()
	build_env['TMPDIR'] = directory
	compiled := run(compiler, ['-skip-running', '-o', program, os.join_path(@DIR, script)],
		build_env)
	if C.kak_maintenance_signal() != 0 {
		return cancelled_status
	}
	if compiled != 0 || !os.is_executable(program) {
		return error('Could not compile ${script} with ${compiler}.')
	}
	status := run(program, args, env)
	return if status < 0 || status == 125 { 1 } else { status }
}

// Empty UI preferences defer to the saved Kakoune configuration.
struct SetupOptions {
mut:
	prefix               string
	integrate            string
	explorer             string
	live_search          string
	pane_mode            string
	window_backend       string
	kakoune_version      string = 'latest'
	lsp_version          string = 'latest'
	vls_path             string
	vls_mode             string = 'auto'
	vls_ref              string
	update               bool
	compiler             string = 'auto'
	repair               bool
	build                bool = true
	install_lsp          bool = true
	install_dependencies bool
}

fn parse_options(args []string) !SetupOptions {
	mut options := SetupOptions{
		prefix: os.join_path(os.home_dir(), '.local')
	}
	mut index := 0
	for index < args.len {
		flag := args[index]
		index++
		value := if flag in ['--prefix', '--pane-mode', '--window-backend', '--vls', '--vls-ref',
			'--kakoune-version', '--lsp-version'] {
			next := args[index] or { return error_with_code('${flag} requires a value.', 2) }
			index++
			next
		} else {
			''
		}
		match flag {
			'--prefix' {
				options.prefix = value
			}
			'--pane-mode' {
				options.pane_mode = value
			}
			'--window-backend' {
				options.window_backend = value
			}
			'--vls' {
				options.vls_path = value
				options.vls_mode = 'external'
			}
			'--vls-ref' {
				options.vls_ref = value
				options.vls_mode = 'upstream'
			}
			'--no-vls' {
				options.vls_mode = 'skip'
			}
			'--vls-upstream' {
				options.vls_mode = 'upstream'
			}
			'--kakoune-version' {
				options.kakoune_version = value
			}
			'--lsp-version' {
				options.lsp_version = value
			}
			'--install-dependencies' {
				options.install_dependencies = true
			}
			'--repair' {
				options.repair = true
			}
			'--system-v' {
				options.compiler = 'system'
			}
			'--managed-v' {
				options.compiler = 'true'
			}
			'--update' {
				options.update = true
			}
			'--integrate' {
				options.integrate = 'true'
			}
			'--explorer' {
				options.explorer = 'true'
			}
			'--no-explorer' {
				options.explorer = 'false'
			}
			'--live-search' {
				options.live_search = 'true'
			}
			'--no-live-search' {
				options.live_search = 'false'
			}
			'--no-build' {
				options.build = false
			}
			'--no-lsp' {
				options.install_lsp = false
			}
			else {
				return error_with_code('Unknown setup option: ${flag}. See --help.', 2)
			}
		}
	}
	return options
}

fn (options SetupOptions) preflight_arguments() []string {
	mut args := ['--prefix', options.prefix]
	if !options.build { args << '--no-build' }
	if !options.install_lsp { args << '--no-lsp' }
	if options.vls_mode in ['skip', 'external'] { args << '--no-vls' }
	if options.explorer == 'false' { args << '--no-explorer' }
	if options.compiler == 'true' { args << '--managed-v' }
	return args
}

fn prepare_install(prefix string, repo string, options SetupOptions, mut env map[string]string) !int {
	paths := setupconfig.resolve(prefix)!
	choices := setupconfig.preferences(paths.settings, paths.personal, setupconfig.Preferences{
		integrate:      options.integrate
		explorer:       options.explorer
		live_search:    options.live_search
		pane_mode:      options.pane_mode
		window_backend: options.window_backend
	})!
	prepared := setupconfig.prepare_paths(prefix, repo, paths.home, choices.integrate == 'true',
		options.repair, options.update)!
	if prepared != 0 || C.kak_maintenance_signal() != 0 {
		return prepared
	}

	vls_mode := if options.vls_mode == 'auto' {
		setupconfig.select_mode(prefix)
	} else {
		options.vls_mode
	}
	if options.vls_mode == 'auto' && vls_mode == 'skip' {
		println('Keeping externally linked VLS. Use --vls-upstream to switch to managed upstream VLS.')
	}
	plan := setupconfig.compiler_plan(prefix, paths.settings, options.compiler, setupconfig.ToolOptions{
		build:       options.build
		install_lsp: options.install_lsp
		explorer:    choices.explorer == 'true'
		vls_mode:    vls_mode
	})!
	env['PATH'] = plan.search_path
	mut mode := plan.mode
	if plan.install {
		installed := run_native(@VEXE, 'install-v.vsh', [prefix], env)!
		if installed != 0 {
			return installed
		}
		env['PATH'] = os.join_path(prefix, 'opt', 'vlang-v', 'candidate') + ':' + plan.search_path
		mode = 'true'
	}
	// Use the selected compiler for configuration while keeping @VEXE available
	// for setups that need no compiler-dependent components.
	old_path := os.getenv('PATH')
	os.setenv('PATH', env['PATH'], true)
	defer { os.setenv('PATH', old_path, true) }
	compiler := os.find_abs_path_of_executable('v') or { @VEXE }
	// Runtime and kak-lsp paths are resolved by the installation worker.
	return run_native(compiler, 'setup-configuration.vsh', ['--install', prefix, repo, paths.home,
		'', '', choices.integrate, mode, plan.policy, choices.explorer, choices.live_search,
		choices.pane_mode, choices.window_backend, options.build.str(), vls_mode, options.vls_path,
		options.install_lsp.str(), options.kakoune_version, options.lsp_version, options.vls_ref],
		env)
}

fn canonical_prefix(prefix string) !string {
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

fn transaction(prefix string, options SetupOptions, mut env map[string]string) !int {
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
	if C.kak_maintenance_signal() != 0 {
		return cancelled_status
	}
	env['VLANG_KAK_STAGE'] = '1'
	env['VLANG_KAK_TRANSACTION'] = snapshot
	status := prepare_install(prefix, repo, options, mut env) or {
		eprintln(err)
		if err.code() == 2 { 2 } else { 1 }
	}
	interrupted := C.kak_maintenance_signal() != 0
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
		print(setup_help.to_string())
		return 0
	}
	options := parse_options(args)!
	prefix := canonical_prefix(options.prefix)!
	if C.kak_track_maintenance_signals() != 0 {
		return error('Could not register setup signal handlers.')
	}
	if options.install_dependencies {
		status := run_native(@VEXE, 'setup-checks.vsh', ['dependencies', '--apply'], env)!
		if status != 0 || C.kak_maintenance_signal() != 0 {
			return if C.kak_maintenance_signal() != 0 { cancelled_status } else { status }
		}
	}
	mut checks := ['preflight']
	checks << options.preflight_arguments()
	status := run_native(@VEXE, 'setup-checks.vsh', checks, env)!
	if status != 0 || C.kak_maintenance_signal() != 0 {
		return if C.kak_maintenance_signal() != 0 { cancelled_status } else { status }
	}
	return transaction(prefix, options, mut env)
}

exit(setup(os.args[1..]) or {
	eprintln(err)
	if err.code() == 2 { 2 } else { 1 }
})
