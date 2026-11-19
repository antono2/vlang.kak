// Test published update selection against a local Git remote and setup fixture.
import os
import rand
import releasetest { capture, execute }
import time

const release_tag = 'v99.0.10'
const release_version = 'release-kakoune'
const release_lsp = 'release-lsp'
const release_vls = 'release-vls'
const release_remote = 'https://github.com/antono2/vlang.kak.git'
const timeout = time.minute

fn git(repo string, args []string) !string {
	mut command := ['-C', repo, '-c', 'user.name=Update Test', '-c',
		'user.email=update@example.invalid', '-c', 'commit.gpgsign=false']
	command << args
	return capture('git', command, true)!.trim_right('\n')
}

fn fixture(path string) ! {
	os.mkdir_all(os.dir(path))!
	os.write_file(path, r'#!/bin/sh
set -eu
printf "%s\n" "$VLANG_KAK_PREVIOUS_PLUGIN_REVISION" "$VLANG_KAK_SKIP_PULL" "$@" > "$UPDATE_SETUP_LOG"
exit "${UPDATE_SETUP_STATUS:-0}"
')!
	os.chmod(path, 0o755)!
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-release-update-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	upstream := os.join_path(root, 'published repo')
	checkout := os.join_path(root, 'checkout with spaces')
	for path in ['scripts/update.sh', 'scripts/update.vsh', 'scripts/update-posix',
		'scripts/managed-v.inc', 'scripts/install-v.sh', 'scripts/releaseinfo/releaseinfo.v',
		'tests/release.env'] {
		destination := os.join_path(upstream, path)
		os.mkdir_all(os.dir(destination))!
		os.cp(os.join_path(os.dir(@DIR), path), destination)!
	}
	fixture(os.join_path(upstream, 'scripts', 'setup.sh'))!
	git(upstream, ['init', '-q'])!
	git(upstream, ['add', '.'])!
	git(upstream, ['commit', '-qm', 'installed version'])!
	old := git(upstream, ['rev-parse', 'HEAD'])!
	git(upstream, ['tag', 'v99.0.9'])!
	os.write_file(os.join_path(upstream, 'tests', 'release.env'),
		'KAKOUNE_VERSION=${release_version}\nLSP_VERSION=${release_lsp}\nVLS_REF=${release_vls}\n')!
	git(upstream, ['commit', '-qam', 'published version'])!
	target := git(upstream, ['rev-parse', 'HEAD'])!
	git(upstream, ['tag', '-am', 'published release', release_tag])!
	git(upstream, ['tag', 'v100.0.0-rc.1', old])!
	capture('git', ['clone', '--no-tags', '-q', upstream, checkout], true)!
	git(checkout, ['checkout', '-q', '--detach', old])!
	prefix := os.join_path(root, 'install prefix')
	snapshot := os.join_path(prefix, 'opt', 'vlang-state', 'previous')
	os.mkdir_all(snapshot)!
	setup_log := os.join_path(root, 'setup.log')
	mut environment := os.environ()
	environment['GIT_CONFIG_COUNT'] = '1'
	environment['GIT_CONFIG_KEY_0'] = 'url.${upstream}.insteadOf'
	environment['GIT_CONFIG_VALUE_0'] = release_remote
	environment['UPDATE_SETUP_LOG'] = setup_log
	update := os.join_path(checkout, 'scripts', 'update.sh')
	args := ['--release', '--prefix', prefix, '--pane-mode', 'off']

	dirty := os.join_path(checkout, 'local settings')
	os.write_file(dirty, 'keep my edits')!
	refused := execute(update, args, false, environment: environment, timeout: timeout)!
	assert refused.stderr.contains('requires a clean Git checkout')
	assert os.read_file(dirty)! == 'keep my edits' && !os.exists(setup_log)
	os.rm(dirty)!

	environment['UPDATE_SETUP_STATUS'] = '17'
	capture(update, args, false, environment: environment, timeout: timeout)!
	assert git(checkout, ['rev-parse', 'HEAD'])! == old
	assert !os.exists(os.join_path(snapshot, 'plugin-revision'))
	environment.delete('UPDATE_SETUP_STATUS')
	capture(update, args, true, environment: environment, timeout: timeout)!
	assert git(checkout, ['rev-parse', 'HEAD'])! == target
	assert os.read_lines(setup_log)! == [old, '1', '--update', '--prefix', prefix, '--pane-mode',
		'off', '--managed-v', '--kakoune-version', release_version, '--lsp-version', release_lsp,
		'--vls-ref', release_vls]
	assert os.read_file(os.join_path(snapshot, 'plugin-revision'))! == old + '\n'

	git(checkout, ['commit', '--allow-empty', '-qm', 'newer development revision'])!
	ahead := git(checkout, ['rev-parse', 'HEAD'])!
	os.rm(setup_log)!
	message := capture(update, args, true, environment: environment, timeout: timeout)!
	assert message.contains('keeping the newer development revision')
	assert git(checkout, ['rev-parse', 'HEAD'])! == ahead && !os.exists(setup_log)

	// An unusable V installation must still be able to activate a release.
	git(checkout, ['checkout', '-q', '--detach', old])!
	shim := os.join_path(root, 'bin', 'v')
	os.mkdir_all(os.dir(shim))!
	os.write_file(shim, '#!/bin/sh\nexit 1\n')!
	os.chmod(shim, 0o755)!
	environment['PATH'] = os.dir(shim) + ':' + environment['PATH']
	fallback := execute(update, args, true, environment: environment, timeout: timeout)!
	assert fallback.stderr.contains('Using shell update')
	assert git(checkout, ['rev-parse', 'HEAD'])! == target
	println('ok - release update selects the highest stable tag, preserves local changes, and restores the old revision on setup failure')
}

check() or {
	eprintln('not ok - release update: ${err}')
	exit(1)
}
