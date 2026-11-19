// Check setup tools and prepare system packages only when explicitly requested.
import os
import time

const install_tools = ['git', 'sed', 'awk', 'sort', 'mktemp', 'sha256sum', 'readlink']
const debian_packages = ['build-essential', 'git', 'curl', 'tar', 'unzip', 'ripgrep', 'tmux', 'gdb']
const output_poll = 10 * time.millisecond

struct Preflight {
mut:
	failed bool
}

fn (mut check Preflight) need(tool string, reason string) string {
	path := os.find_abs_path_of_executable(tool) or { '' }
	if path == '' || !os.is_file(path) || !os.is_executable(path) {
		eprintln('Missing: ${tool} (${reason})')
		check.failed = true
		return ''
	}
	return path
}

fn supports_cpp23(compiler string) bool {
	mut child := os.new_process(compiler)
	defer { child.close() }
	child.set_args(['-std=c++2b', '-x', 'c++', '-fsyntax-only', '-'])
	child.set_redirect_stdio()
	child.run()
	// The probe is an empty translation unit read from stdin.
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	for child.is_alive() {
		child.stdout_read()
		child.stderr_read()
		time.sleep(output_poll)
	}
	child.wait()
	return child.code == 0
}

fn preflight(args []string) int {
	if args[0] or { '' } in ['--help', '-h'] {
		println('Usage: preflight.sh [setup options]')
		return 0
	}
	mut check := Preflight{}
	for tool in install_tools {
		check.need(tool, 'installation')
	}
	if '--no-build' !in args {
		check.need('make', 'build Kakoune')
		setting := os.getenv('CXX')
		compiler := check.need(if setting == '' { 'c++' } else { setting }, 'build Kakoune')
		if compiler != '' && !supports_cpp23(compiler) {
			eprintln('C++ compiler must support -std=c++2b.')
			check.failed = true
		}
	}
	if '--no-lsp' !in args {
		check.need('curl', 'download kak-lsp')
		check.need('tar', 'extract kak-lsp')
	}
	if !args.any(it in ['--no-vls', '--vls']) || '--no-explorer' !in args || '--managed-v' in args {
		check.need('gcc', 'V compilation')
		check.need('make', 'managed compiler fallback')
		check.need('ar', 'managed compiler fallback')
	}
	if check.failed {
		eprintln('Install the listed dependencies with your system package manager, then rerun setup. No system packages were changed.')
		return 1
	}
	return 0
}

fn release_value(value string) string {
	if value.len >= 2 && value.starts_with("'") && value.ends_with("'") {
		return value[1..value.len - 1]
	}
	if value.len >= 2 && value.starts_with('"') && value.ends_with('"') {
		return value[1..value.len - 1].replace_each(['\\"', '"', '\\$', '$', '\\`', '`', '\\\\',
			'\\'])
	}
	return value
}

fn os_release() !map[string]string {
	contents := os.read_file('/etc/os-release') or {
		return error('Unknown distribution; install Git, Make, GCC/C++, curl, tar, ripgrep, tmux and GDB 14+ using your package manager.')
	}
	mut values := map[string]string{}
	for line in contents.split_into_lines() {
		key, value := line.trim_space().split_once('=') or { continue }
		if key in ['ID', 'PRETTY_NAME'] {
			values[key] = release_value(value)
		}
	}
	return values
}

fn apt(args []string) ! {
	mut package_tool := 'apt-get'
	mut command := args.clone()
	if os.getuid() != 0 {
		package_tool = 'sudo'
		command.prepend('apt-get')
	}
	mut child := os.new_process(package_tool)
	defer { child.close() }
	child.set_args(command)
	child.run()
	child.wait()
	if child.code != 0 {
		return error('${package_tool} failed with exit status ${child.code}.')
	}
}

fn dependencies(args []string) !int {
	option := args[0] or { '' }
	match option {
		'--help', '-h' {
			println('Usage: dependencies.sh [--apply]')
			return 0
		}
		'', '--apply' {}
		else {
			return 2
		}
	}

	values := os_release()!
	id := values['ID']
	if id !in ['ubuntu', 'debian'] {
		return error('No automatic package recipe for ${id}. Install Git, Make, GCC/C++ (C++23), curl, tar, ripgrep, tmux and GDB 14+ using your package manager.')
	}
	println('Distribution: ${values['PRETTY_NAME']}')
	println('Commands:\nsudo apt-get update\nsudo apt-get install --yes ${debian_packages.join(' ')}')
	if option == '--apply' {
		apt(['update'])!
		mut packages := ['install', '--yes']
		packages << debian_packages
		apt(packages)!
	} else {
		println('Preview only. Use --apply or setup.sh --install-dependencies to request system changes.')
	}
	return 0
}

mode := os.args[1] or { '' }
if mode !in ['preflight', 'dependencies'] {
	eprintln('Usage: v run scripts/setup-checks.vsh preflight|dependencies [options]')
	exit(2)
}
if mode == 'preflight' {
	exit(preflight(os.args[2..]))
}
exit(dependencies(os.args[2..]) or {
	eprintln(err)
	1
})
