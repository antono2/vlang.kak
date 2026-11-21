// Entry points for the Kakoune matrix and managed release jobs.
import os
import releasetest
import time

// The pinned Git repositories use SHA-1 object IDs.
const git_sha1_hex_digits = 40
const kakoune_master = 'refs/heads/master'
const upstream_kakoune = 'https://github.com/mawww/kakoune.git'

fn run_test(script string, args []string) ! {
	mut command := ['run', os.join_path(@DIR, script)]
	command << args
	releasetest.run_inherited('v', command)!
}

fn github_line(file_env string, line string) ! {
	path := os.getenv(file_env)
	if path == '' {
		return error('${file_env} is required')
	}
	releasetest.append_line(path, line)!
}

fn revision(value string) !string {
	if value.len != git_sha1_hex_digits || !value.bytes().all((it >= `0` && it <= `9`) || (it >= `a` && it <= `f`)) {
		return error('Expected a full Git revision, got "${value}"')
	}
	return value
}

fn build_kakoune(version string, prefix string) ! {
	run_test('../scripts/build-kakoune.vsh', ['--version', version, '--prefix', prefix])!
	github_line('GITHUB_ENV', 'KAK=' + os.join_path(prefix, 'bin', 'kak'))!
	runtime := os.join_path(prefix, 'opt', 'vlang-kakoune', 'current', 'share', 'kak')
	github_line('GITHUB_ENV', 'KAKOUNE_RUNTIME=' + runtime)!
}

fn check_shell_wrappers() ! {
	scripts_dir := os.join_path(@DIR, '..', 'scripts')
	mut scripts := os.ls(scripts_dir)!.filter(it.ends_with('.sh'))
	scripts.sort()
	for script in scripts {
		path := os.join_path(scripts_dir, script)
		releasetest.capture('sh', ['-n', path], true)!
		releasetest.capture(path, ['--help'], true)!
	}
}

fn identify_compiler_cache() ! {
	pins := releasetest.read_assignments(os.join_path(@DIR, 'release.env'))!
	v_ref := revision(pins['V_REF'])!
	vc_ref := revision(pins['VC_REF'])!
	gcc := releasetest.capture('gcc', ['-dumpfullversion'], true)!.trim_space()
	if gcc == '' {
		return error('GCC did not report its version')
	}
	github_line('GITHUB_OUTPUT', 'pins=${v_ref}-${vc_ref}')!
	github_line('GITHUB_OUTPUT', 'gcc=${gcc}')!
}

fn install_compiler(prefix string) ! {
	started := time.sys_mono_now()
	// The pinned compiler's build should discover its own V executable.
	os.unsetenv('VEXE')
	releasetest.run_inherited(os.join_path(@DIR, '..', 'scripts', 'install-v.sh'), [prefix])!
	compiler_dir := os.join_path(prefix, 'opt', 'vlang-v', 'current')
	releasetest.run_inherited(os.join_path(compiler_dir, 'v'), ['version'])!
	github_line('GITHUB_PATH', compiler_dir)!
	elapsed := (time.sys_mono_now() - started) / u64(time.second)
	cache_status := if os.getenv('COMPILER_CACHE_HIT') == 'true' { 'hit' } else { 'miss' }
	summary := 'V compiler cache: ${cache_status}; build/reuse: ${elapsed} seconds'
	println(summary)
	github_line('GITHUB_STEP_SUMMARY', summary)!
}

fn resolve_kakoune_master(remote string) ! {
	result := releasetest.capture('git', ['ls-remote', '--exit-code', remote, kakoune_master],
		true)!
	value, ref := result.trim_space().split_once('\t') or {
		return error('Expected a tab-separated Git revision and reference')
	}
	if ref != kakoune_master {
		return error('Expected only ${kakoune_master}, got "${ref}"')
	}
	commit := revision(value)!
	github_line('GITHUB_ENV', 'VLANG_RELEASE_KAKOUNE_REF=${commit}')!
	github_line('GITHUB_OUTPUT', 'revision=${commit}')!
}

fn validate_release(directory string, log_path string) ! {
	mut logfile := os.create(log_path)!
	defer { logfile.close() }
	code := releasetest.log_command('v', ['run', os.join_path(@DIR, 'release.vsh'), directory],
		mut logfile,
		echo: true
	)!
	if code != 0 {
		return error('Managed release validation exited ${code}. See ${log_path}')
	}
}

fn check_pane_clients(prefix string, artifacts string) ! {
	for program in ['screen', 'xterm', 'foot', 'sway'] {
		flag := if program == 'xterm' { '-version' } else { '--version' }
		releasetest.run_inherited(program, [flag])!
	}
	for backend in ['zellij', 'wezterm', 'kitty', 'screen', 'native', 'wayland'] {
		run_test('pane_hosts.vsh', [prefix, backend, '--artifacts', os.join_path(artifacts, backend)])!
	}
}

const usage = 'Usage: v run tests/ci.vsh COMMAND
  packaged-kakoune
  build-kakoune VERSION PREFIX
  installer-tests
  shell-checks
  compiler-cache
  compiler PREFIX
  kakoune-master [REMOTE]
  release DIRECTORY LOG
  pane-clients PREFIX ARTIFACTS'

fn run(args []string) ! {
	match args {
		['packaged-kakoune'] {
			kak := os.find_abs_path_of_executable('kak')!
			github_line('GITHUB_ENV', 'KAK=${kak}')!
			return
		}
		['installer-tests'] {
			for script in ['check_v_installer.vsh', 'check_vls_installer.vsh'] {
				run_test(script, [])!
			}
			return
		}
		['shell-checks'] {
			return check_shell_wrappers()
		}
		['compiler-cache'] {
			return identify_compiler_cache()
		}
		['kakoune-master'] {
			return resolve_kakoune_master(upstream_kakoune)
		}
		['--help'], ['-h'] {
			println(usage)
			return
		}
		else {}
	}
	if args.len == 2 {
		match args[0] {
			'compiler' { return install_compiler(args[1]) }
			'kakoune-master' { return resolve_kakoune_master(args[1]) }
			else {}
		}
	}
	if args.len == 3 {
		match args[0] {
			'build-kakoune' { return build_kakoune(args[1], args[2]) }
			'release' { return validate_release(args[1], args[2]) }
			'pane-clients' { return check_pane_clients(args[1], args[2]) }
			else {}
		}
	}
	return error_with_code(usage, 2)
}

run(os.args[1..]) or {
	eprintln(err)
	exit(if err.code() == 2 { 2 } else { 1 })
}
