// Install, exercise, update, and recheck a real stack in an isolated configuration.
import os
import rand
import releasetest

const usage = 'Usage: v run tests/release.vsh [ARTIFACT_DIRECTORY]\nRequires V, build tools, tmux, GDB with DAP, Python 3, and network access.'

fn command(program string, args []string) ! {
	program_path := os.find_abs_path_of_executable(program)!
	mut child := os.new_process(program_path)
	child.set_args(args)
	child.run()
	defer { child.close() }
	// Inherit stdio so the acceptance logs stream to the release runner.
	child.wait()
	if child.code != 0 {
		return error('${program} ${args.join(' ')} exited ${child.code}')
	}
}

fn release(root string) ! {
	repo := os.dir(@DIR)
	pins := releasetest.read_pins(os.join_path(@DIR, 'release.env'))!
	prefix := os.join_path(root, 'prefix')
	os.setenv('XDG_CONFIG_HOME', os.join_path(root, 'config'), true)
	os.setenv('XDG_CACHE_HOME', os.join_path(root, 'cache'), true)
	os.setenv('VLANG_KAK_PREFIX', prefix, true)
	os.setenv('VLANG_KAK_SKIP_PULL', '1', true)
	os.setenv('VLANG_LSP_ARTIFACTS', os.join_path(root, 'lsp'), true)
	os.unsetenv('VLANG_KAK_CONFIG_HOME')
	args := pins.setup_args(prefix)
	check := os.join_path(repo, 'scripts/check.sh')

	println('Release test artifacts: ${root}')
	command(os.join_path(repo, 'scripts/setup.sh'), args)!
	os.setenv('PATH', os.join_path(prefix, 'bin') + ':' + os.getenv('PATH'), true)
	command(check, ['--live-lsp'])!
	command('v', ['run', os.join_path(@DIR, 'lifecycle_stack.vsh'), prefix])!
	for previous in ['v1.1.1', 'v1.2.0'] {
		command('v', ['run', os.join_path(@DIR, 'upgrade.vsh'), prefix, previous])!
	}
	command(os.join_path(@DIR, 'acceptance.sh'), [prefix, os.join_path(root, 'acceptance')])!
	command(os.join_path(repo, 'scripts/update.sh'), args)!
	command(check, ['--live-lsp'])!
	println('ok - clean managed installation, live navigation, debugging, panes, restart and update')
}

fn run(args []string) ! {
	if args in [['--help'], ['-h']] {
		println(usage)
		return
	}
	if args.len > 1 {
		return error_with_code(usage, 2)
	}
	requested := if args.len == 1 { args[0] } else { '' }
	root := if requested == '' {
		os.join_path(os.temp_dir(), 'vlang-release-' + rand.uuid_v4())
	} else {
		os.abs_path(requested)
	}
	if requested == '' {
		os.mkdir(root, mode: 0o700)!
	} else {
		os.mkdir_all(root)!
	}
	release(os.real_path(root))!
}

run(os.args[1..]) or {
	eprintln(err)
	exit(if err.code() == 2 { 2 } else { 1 })
}
