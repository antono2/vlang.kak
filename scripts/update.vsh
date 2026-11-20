// Update a development checkout or activate a stable release and its tool pins.
import os
import releaseinfo

const pin_keys = ['KAKOUNE_VERSION', 'LSP_VERSION', 'VLS_REF']

fn parse_pins(contents string) !map[string]string {
	mut pins := map[string]string{}
	for line in contents.split_into_lines() {
		key, value := line.split_once('=') or { continue }
		if key !in pin_keys {
			continue
		}
		pin := value.trim_space()
		if key in pins || pin == '' || !pin.bytes().all(it.is_alnum() || it in [`-`, `_`, `.`, `/`]) {
			return error('Invalid release pin for ${key}.')
		}
		pins[key] = pin
	}
	for key in pin_keys {
		if key !in pins {
			return error('Missing release pin for ${key}.')
		}
	}
	return pins
}

fn setup(repo string, args []string, old_revision string) int {
	mut child := os.new_process(os.join_path(repo, 'scripts', 'setup.sh'))
	defer { child.close() }
	mut command := ['--update']
	command << args
	child.set_args(command)
	if old_revision != '' {
		mut env := os.environ()
		env['VLANG_KAK_PREVIOUS_PLUGIN_REVISION'] = old_revision
		env['VLANG_KAK_SKIP_PULL'] = '1'
		child.set_environment(env)
	}
	child.run()
	child.wait()
	return child.code
}

fn prefix_for(args []string) string {
	mut prefix := os.join_path(os.home_dir(), '.local')
	for i, arg in args {
		if arg == '--prefix' && i + 1 < args.len {
			prefix = args[i + 1]
		}
	}
	return prefix
}

fn keep_previous(repo string, prefix string, revision string) ! {
	snapshot := os.join_path(prefix, 'opt', 'vlang-state', 'previous')
	if os.is_dir(snapshot) {
		os.write_file(os.join_path(snapshot, 'plugin-revision'), revision + '\n')!
		os.write_file(os.join_path(snapshot, 'plugin-repo'), repo + '\n')!
	}
}

fn select_release(repo string, args []string) !int {
	root := releaseinfo.git_at(repo, ['rev-parse', '--show-toplevel']) or { '' }
	if root != repo || releaseinfo.git_at(repo, ['status', '--porcelain'])! != '' {
		return error('Release selection requires a clean Git checkout; local changes were kept.')
	}
	published := releaseinfo.latest_release()!
	ref := 'refs/tags/${published.tag}'
	old := releaseinfo.git_at(repo, ['rev-parse', 'HEAD'])!
	releaseinfo.git_at(repo, ['fetch', '--no-tags', releaseinfo.release_remote, '${ref}:${ref}'])!
	if releaseinfo.git_at(repo, ['rev-parse', '--verify', ref])! != published.object {
		return error('Published release ${published.tag} changed while fetching it. Try again.')
	}
	target := releaseinfo.git_at(repo, ['rev-parse', '--verify', '${ref}^{commit}'])!
	if target != old {
		ancestor := releaseinfo.invoke_git(['-C', repo, 'merge-base', '--is-ancestor', target,
			old])
		if ancestor.code == 0 {
			println('Checkout already contains release ${published.tag}; keeping the newer development revision.')
			return 0
		}
		if ancestor.code != 1 {
			return error('Could not compare the installed and released revisions: ${ancestor.diagnostics}')
		}
	}
	pins := parse_pins(releaseinfo.git_at(repo, ['show', '${target}:tests/release.env'])!)!
	if releaseinfo.git_at(repo, ['rev-parse', 'HEAD'])! != old
		|| releaseinfo.git_at(repo, ['status', '--porcelain'])! != '' {
		return error('Checkout changed while looking up ${published.tag}; local changes were kept.')
	}
	releaseinfo.git_at(repo, ['checkout', '--detach', target])!
	mut setup_args := args.filter(it != '--release')
	if os.is_executable(os.join_path(repo, 'scripts', 'install-v.sh')) {
		setup_args << '--managed-v'
	}
	// Published pins take precedence over development defaults and forwarded flags.
	setup_args << ['--kakoune-version', pins['KAKOUNE_VERSION'], '--lsp-version', pins['LSP_VERSION'],
		'--vls-ref', pins['VLS_REF']]
	if setup(repo, setup_args, old) != 0 {
		releaseinfo.git_at(repo, ['checkout', '--detach', old])!
		return 1
	}
	keep_previous(repo, prefix_for(setup_args), old)!
	return 0
}

fn update(args []string) !int {
	repo := os.real_path(os.dir(@DIR))
	if args.any(it in ['--help', '-h']) {
		println('Usage: update.sh [--release] [setup options]')
		mut child := os.new_process(os.join_path(repo, 'scripts', 'setup.sh'))
		defer { child.close() }
		child.set_args(['--help'])
		child.run()
		child.wait()
		return child.code
	}
	if '--release' in args || (os.getenv('VLANG_KAK_SKIP_PULL') != '1'
		&& releaseinfo.invoke_git(['-C', repo, 'symbolic-ref', '-q', 'HEAD']).code != 0) {
		return select_release(repo, args)
	}
	return setup(repo, args, '')
}

exit(update(os.args[1..]) or {
	eprintln(err)
	1
})
