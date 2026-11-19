// Report the tools, configuration, and recovery state of a Kakoune IDE installation.
import os
import time

const poll_interval = 5 * time.millisecond

struct Installation {
	prefix string
	config string
	repo   string
}

fn env_path(name string, fallback string) string {
	value := os.getenv(name)
	return if value == '' { fallback } else { value }
}

fn tool(name string) string {
	return os.find_abs_path_of_executable(name) or { '' }
}

fn regular_file(path string) bool {
	info := os.stat(path) or { return false }
	return info.get_filetype() == .regular
}

fn report_path(label string, path string) int {
	if path == '' {
		println('${label}: missing')
		return 1
	}
	println('${label}: ${path}')
	return 0
}

fn run_child(program string, args []string) int {
	mut child := os.new_process(program)
	defer { child.close() }
	child.set_args(args)
	child.run()
	child.wait()
	return child.code
}

struct Output {
	code   int
	stdout string
	stderr string
}

fn capture(program string, args []string) Output {
	mut child := os.new_process(program)
	defer { child.close() }
	child.set_args(args)
	child.set_redirect_stdio()
	child.run()
	// Version and debugger probes expect EOF.
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	mut output := ''
	mut diagnostics := ''
	for child.is_alive() {
		output += child.stdout_read()
		diagnostics += child.stderr_read()
		time.sleep(poll_interval)
	}
	output += child.stdout_slurp()
	diagnostics += child.stderr_slurp()
	child.wait()
	return Output{ code: child.code, stdout: output.trim_right('\n'), stderr: diagnostics }
}

fn report_version(label string, path string, flag string) int {
	if path == '' {
		return report_path(label, path)
	}
	result := capture(path, [flag])
	eprint(result.stderr)
	if result.code != 0 {
		return result.code
	}
	println('${label}: ${path} (${result.stdout})')
	return 0
}

fn report_debugger() {
	gdb := tool('gdb')
	if gdb == '' {
		println('Debugger: missing GDB; install GDB 14 or newer with Python support to debug')
	} else if capture(gdb, ['-q', '-nx', '--interpreter=dap']).code == 0 {
		println('Debugger: ${gdb} (GDB DAP available)')
	} else {
		println('Debugger: GDB lacks DAP support; install GDB 14 or newer with Python support')
	}
}

fn (install Installation) check(live_lsp bool) int {
	compiler := tool('v')
	mut status := report_path('V', compiler)
	kak := tool('kak')
	kak_status := report_version('Kakoune', kak, '-version')
	if kak != '' && kak_status != 0 {
		return kak_status
	}
	status |= kak_status
	managed_lsp := os.join_path(install.prefix, 'opt/vlang-kak-lsp/current/bin/kak-lsp')
	if os.is_executable(managed_lsp) && regular_file(managed_lsp) {
		lsp_status := report_version('kak-lsp', managed_lsp, '--version')
		if lsp_status != 0 {
			return lsp_status
		}
	} else {
		status |= report_path('kak-lsp', tool('kak-lsp'))
	}
	status |= report_path('VLS', tool('vls'))

	autoload := os.join_path(install.prefix, 'opt/vlang-kakoune/ide-config/kak/autoload')
	plugin := os.join_path(autoload, 'vlang.kak')
	if os.is_link(plugin) && os.real_path(plugin) == os.join_path(install.repo, 'rc/vlang.kak') {
		println('Plugin: ${plugin}')
	} else {
		println('Plugin: missing from the managed Kakoune autoload')
		status = 1
	}
	runtime := os.join_path(autoload, 'vlang-site-runtime')
	if os.is_link(runtime) && os.is_dir(runtime) {
		println('Kakoune runtime: ${os.real_path(runtime)}')
	} else {
		println('Kakoune runtime: not linked into user autoload')
		status = 1
	}
	user_config := os.join_path(install.config, 'kak/vlang-user.kak')
	if regular_file(user_config) {
		println('Customization: ${user_config}')
	} else {
		println('Customization: no vlang-user.kak file')
	}
	// A missing debugger does not prevent editing or language-server checks.
	report_debugger()
	if live_lsp {
		if status != 0 {
			eprintln('Live VLS check skipped until the installation checks pass.')
		} else if run_child(compiler, ['run', os.join_path(@DIR, 'check-vls.vsh'), '--editor',
			'--prefix', install.prefix]) != 0 {
			status = 1
		}
	}
	return status
}

fn (install Installation) report_recovery() {
	state := os.join_path(install.prefix, 'opt/vlang-state')
	if regular_file(os.join_path(state, 'manifest.tsv')) {
		println('Ownership manifest: present')
	} else {
		println('Ownership manifest: missing; rerun setup before automated removal.')
	}
	println('')
	// Use the same PID identity check as setup and rollback.
	lock_state := run_child(os.join_path(@DIR, 'lock.sh'), ['--prefix', install.prefix])
	mut entries := os.ls(state) or { []string{} }
	entries.sort()
	for entry in entries {
		pending := os.join_path(state, entry)
		if !entry.starts_with('pending.') || !os.is_dir(pending) {
			continue
		}
		if !regular_file(os.join_path(pending, 'ready')) {
			println('Incomplete setup snapshot: ${pending} (activation snapshot was not completed).')
		} else if lock_state == 1 {
			println('Setup snapshot (operation active): ${pending}')
		} else {
			println('Interrupted setup snapshot: ${pending} (keep it until recovery is complete).')
			println('Recover it: scripts/rollback.sh --prefix ${os.quoted_path(install.prefix)} --recover ${os.quoted_path(pending)}')
		}
	}
	if regular_file(os.join_path(state, 'previous/paths')) {
		println('Previous installation snapshot: available for rollback.')
	}
}

fn (install Installation) health(report bool) int {
	println('V IDE health\n')
	status := install.check(false)
	print('\nPane backend: ')
	flush_stdout()
	run_child(os.join_path(@DIR, 'windowing.sh'), ['detect',
		env_path('kak_opt_v_window_backend', 'auto')])
	print('\nCompiler: ')
	flush_stdout()
	compiler := tool('v')
	if compiler == '' {
		println('missing; rerun setup for a managed compiler')
	} else {
		run_child(compiler, ['version'])
	}
	print('Plugin revision: ')
	git := tool('git')
	revision := if git == '' {
		Output{ code: 1 }
	} else {
		capture(git, ['-C', install.repo, 'describe', '--tags', '--always', '--dirty'])
	}
	println(if revision.code == 0 {
		revision.stdout
	} else {
		'source archive'
	})
	for name in ['gcc', 'rg', 'git', 'tmux'] {
		availability := if tool(name) == '' { 'unavailable' } else { 'available' }
		println('${name}: ${availability}')
	}
	install.report_recovery()
	println('\nRepair: :v-repair or scripts/health.sh --repair')
	println('Rollback: :v-rollback or scripts/rollback.sh')
	println('Missing system dependencies: install through your package manager, then rerun setup.')
	if report {
		println('Review this report before sharing: it contains executable and configuration paths.')
	}
	return status
}

fn run(args []string) int {
	option := args[1] or { '' }
	home := os.home_dir()
	install := Installation{
		prefix: env_path('VLANG_KAK_PREFIX', os.join_path(home, '.local'))
		config: env_path('VLANG_KAK_CONFIG_HOME', env_path('XDG_CONFIG_HOME', os.join_path(home, '.config')))
		repo:   os.dir(@DIR)
	}
	mut path := os.getenv('PATH')
	kakrc := os.join_path(install.prefix, 'opt/vlang-kakoune/ide-config/kak/kakrc')
	if regular_file(kakrc) {
		lines := os.read_lines(kakrc) or { []string{} }
		if '# vlang.kak compiler: managed' in lines {
			path = os.join_path(install.prefix, 'opt/vlang-v/current') + ':' + path
		}
	}
	os.setenv('PATH', os.join_path(install.prefix, 'bin') + ':' + path, true)
	match args[0] or { '' } {
		'check' {
			if option in ['', '--live-lsp'] {
				return install.check(option == '--live-lsp')
			}
			eprintln('Usage: scripts/check.sh')
		}
		'health' {
			if option in ['', '--report'] {
				return install.health(option == '--report')
			}
		}
		else {}
	}
	return 2
}

exit(run(os.args[1..]))
