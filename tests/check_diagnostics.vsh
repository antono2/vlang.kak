// Exercise both diagnostic commands with an isolated managed installation.
import os
import rand
import releasetest { capture_result }

fn write_fixture_tool(path string, script string) ! {
	os.write_file(path, '#!/bin/sh\n' + script + '\n')!
	os.chmod(path, 0o755)!
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'kak-diagnostics-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	prefix := os.join_path(root, "prefix with 'quotes'")
	bin := os.join_path(prefix, 'bin')
	config := os.join_path(root, 'config')
	kakrc := os.join_path(prefix, 'opt/vlang-kakoune/ide-config/kak')
	autoload := os.join_path(kakrc, 'autoload')
	managed := os.join_path(prefix, 'opt/vlang-v/current')
	managed_lsp := os.join_path(prefix, 'opt/vlang-kak-lsp/current/bin')
	state := os.join_path(prefix, 'opt/vlang-state')
	pending := os.join_path(state, 'pending.interrupted')
	scratch := os.join_path(root, 'scratch')
	for directory in [bin, os.join_path(config, 'kak'), autoload, managed, managed_lsp, pending,
		os.join_path(state, 'pending.incomplete'), os.join_path(state, 'previous'), scratch] {
		os.mkdir_all(directory)!
	}
	compiler_log := os.join_path(root, 'compiler.log')
	compiler := os.join_path(managed, 'v')
	// Health can also build the independent native pane helpers.
	write_fixture_tool(compiler, 'case "$4" in */diagnostics.vsh) printf "%s\\n" "$1" >> ' +
		os.quoted_path(compiler_log) + ' ;; esac\nexec ' + os.quoted_path(@VEXE) + ' "$@"')!
	write_fixture_tool(os.join_path(bin, 'kak'), 'echo fixture-kak')!
	write_fixture_tool(os.join_path(managed_lsp, 'kak-lsp'), 'echo fixture-kak-lsp')!
	write_fixture_tool(os.join_path(bin, 'vls'), 'exit 0')!
	write_fixture_tool(os.join_path(bin, 'gdb'), 'exit 1')!
	os.write_file(os.join_path(kakrc, 'kakrc'), '# vlang.kak compiler: managed\n')!
	custom := os.join_path(config, 'kak/vlang-user.kak')
	os.write_file(custom, '')!
	os.write_file(os.join_path(state, 'manifest.tsv'), '')!
	os.write_file(os.join_path(state, 'previous/paths'), '')!
	os.write_file(os.join_path(pending, 'ready'), '')!
	repo := os.dir(@DIR)
	plugin := os.join_path(autoload, 'vlang.kak')
	os.symlink(os.join_path(repo, 'rc/vlang.kak'), plugin)!
	os.symlink(config, os.join_path(autoload, 'vlang-site-runtime'))!

	mut env := os.environ()
	env['VLANG_KAK_PREFIX'] = prefix
	env['VLANG_KAK_CONFIG_HOME'] = config
	env['XDG_CACHE_HOME'] = os.join_path(root, 'cache')
	env['TMPDIR'] = scratch
	env['kak_opt_v_window_backend'] = 'tmux'
	env.delete('kak_client_env_TMUX')
	checker := os.join_path(repo, 'scripts/check.sh')
	health := os.join_path(repo, 'scripts/health.sh')
	check_result := capture_result(checker, [], environment: env)!
	assert check_result.code == 0, '${check_result}'
	assert check_result.stdout.contains('V: ${compiler}')
	assert check_result.stdout.contains('Kakoune: ${bin}/kak (fixture-kak)')
	assert check_result.stdout.contains('kak-lsp: ${managed_lsp}/kak-lsp (fixture-kak-lsp)')
	assert check_result.stdout.contains('Customization: ${custom}')
	assert check_result.stdout.contains('Debugger: GDB lacks DAP support')
	assert os.read_lines(compiler_log)! == ['-skip-running']

	report := capture_result(health, ['--report'], environment: env)!
	assert report.code == 0, '${report}'
	assert report.stdout.contains('Pane backend: none'), '${report}'
	assert report.stdout.contains('Ownership manifest: present')
	assert report.stdout.contains('Installation lock: none')
	assert report.stdout.contains('Interrupted setup snapshot: ${pending}')
	assert report.stdout.contains('Incomplete setup snapshot:')
	assert report.stdout.contains('Previous installation snapshot:')
	assert report.stdout.contains('Review this report before sharing:')
	assert report.stdout.contains('--prefix ${os.quoted_path(prefix)}')
	assert os.read_lines(compiler_log)!.filter(it == '-skip-running').len == 2

	os.rm(plugin)!
	bad := capture_result(checker, ['--live-lsp'], environment: env)!
	assert bad.code == 1, '${bad}'
	assert bad.stdout.count('V: ') == 1
	assert bad.stdout.contains('Plugin: missing')
	assert bad.stderr.contains('Live VLS check skipped')
	assert os.read_lines(compiler_log)!.filter(it == '-skip-running').len == 3

	// A broken compiler must still leave the shell diagnostic usable.
	write_fixture_tool(compiler, 'exit 11')!
	fallback := capture_result(health, ['--report'], environment: env)!
	assert fallback.code == 1, '${fallback}'
	assert fallback.stdout.contains('Plugin: missing')
	assert fallback.stdout.contains('Installation lock: none')
	assert fallback.stdout.contains('Interrupted setup snapshot: ${pending}')

	os.rm(compiler)!
	minimal_path := os.join_path(root, 'pre-v-bin')
	os.mkdir(minimal_path)!
	for name in ['dirname', 'grep', 'readlink'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(minimal_path, name))!
	}
	env['PATH'] = minimal_path
	missing := capture_result(health, ['--report'], environment: env)!
	assert missing.code == 1, '${missing}'
	assert missing.stdout.contains('V: missing')
	assert missing.stdout.contains('Compiler: missing; rerun setup')
	assert missing.stdout.contains('Installation lock: none')
	assert os.ls(scratch)!.len == 0
	println('ok - managed diagnostic selection, health report, failure exit, and compiler fallback')
}

check() or {
	eprintln(err)
	exit(1)
}
