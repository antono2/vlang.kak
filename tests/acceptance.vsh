// Run the live IDE acceptance checks and retain a log for each stage.
import os
import rand
import releasetest { capture }
import time

const usage = 'Usage: v run tests/acceptance.vsh PREFIX [ARTIFACT_DIRECTORY]\nRequires a managed Kakoune/kak-lsp/VLS stack, V, tmux and GDB DAP.'

struct Stage {
	name    string
	program string
	args    []string
}

fn configure(prefix string, root string) string {
	kakoune := os.join_path(prefix, 'opt/vlang-kakoune/current')
	kak := os.join_path(kakoune, 'bin/kak')
	os.setenv('KAK', kak, true)
	os.setenv('KAKOUNE_RUNTIME', os.join_path(kakoune, 'share/kak'), true)
	os.setenv('PATH', os.join_path(prefix, 'bin') + ':' + os.getenv('PATH'), true)
	os.setenv('XDG_CONFIG_HOME', os.join_path(root, 'config'), true)
	os.setenv('XDG_CACHE_HOME', os.join_path(root, 'cache'), true)
	os.setenv('XDG_STATE_HOME', os.join_path(root, 'state'), true)
	os.setenv('VLANG_TEST_REAL_TOOLS_PREFIX', prefix, true)
	os.setenv('VLANG_DEBUG_ARTIFACTS', os.join_path(root, 'debugger'), true)
	os.setenv('VLANG_LSP_ARTIFACTS', os.join_path(root, 'lsp'), true)
	for name in ['VLANG_KAK_CONFIG_HOME', 'VLANG_KAK_RESTART_ALLOWED', 'VLANG_KAK_RESTART_STATE'] {
		os.unsetenv(name)
	}
	return kak
}

fn write_versions(path string, kak string) ! {
	mut versions := os.create(path)!
	defer { versions.close() }
	versions.write_string(capture(kak, ['-version'], true)!)!
	versions.write_string(capture('v', ['version'], true)!)!
	versions.write_string(capture('gdb', ['--version'], true)!)!
	repo := os.dir(@DIR)
	versions.writeln('Plugin checkout: ${repo}')!
	versions.write_string(capture('git', ['-C', repo, 'rev-parse', 'HEAD'], true) or { '' })!
	versions.write_string(capture('git', ['-C', repo, 'status', '--short'], true) or { '' })!
}

fn run_stage(stage Stage, root string, mut results os.File) ! {
	println('Running ${stage.name} ...')
	path := os.join_path(root, stage.name + '.log')
	mut stage_log := os.create(path)!
	code := releasetest.log_command(stage.program, stage.args, mut stage_log) or {
		stage_log.writeln(err.msg()) or {}
		stage_log.close()
		results.writeln('FAIL ${stage.name} (${err})')!
		return err
	}
	stage_log.close()
	if code == 0 {
		line := 'PASS ${stage.name}'
		results.writeln(line)!
		results.flush()
		println(line)
		return
	}
	line := 'FAIL ${stage.name} (exit ${code})'
	results.writeln(line)!
	results.flush()
	println(line)
	eprint(os.read_file(path)!)
	return error_with_code('${stage.name} failed. Log: ${path}', code)
}

fn acceptance(prefix string, root string) ! {
	kak := configure(prefix, root)
	println('Acceptance artifacts: ${root}')
	mut results := os.create(os.join_path(root, 'results.txt'))!
	defer { results.close() }
	results.writeln('Started: ${time.utc().format_rfc3339()}')!
	results.flush()
	write_versions(os.join_path(root, 'versions.log'), kak)!
	for stage in [
		Stage{ name: 'core', program: os.join_path(@DIR, 'run.sh') },
		Stage{
			name:    'live-vls'
			program: 'v'
			args:    ['run', os.join_path(os.dir(@DIR), 'scripts/check-vls.vsh'), '--editor', '--prefix',
				prefix]
		},
		Stage{ name: 'panes', program: 'v', args: ['run', os.join_path(@DIR, 'panes.vsh'), prefix] },
		Stage{
			name:    'debugger'
			program: 'v'
			args:    ['run', os.join_path(@DIR, 'debugger.vsh'), kak]
		},
	] {
		run_stage(stage, root, mut results)!
	}
	println('All IDE acceptance checks passed. Logs: ${root}')
}

fn run(args []string) ! {
	if args.len == 0 || args in [['--help'], ['-h']] {
		println(usage)
		return
	}
	if args.len > 2 {
		return error_with_code(usage, 2)
	}
	if !os.is_dir(args[0]) {
		return error('Missing managed installation: ${args[0]}')
	}
	prefix := os.real_path(args[0])
	requested := if args.len == 2 { args[1] } else { '' }
	root := if requested == '' {
		os.join_path(os.temp_dir(), 'vlang-acceptance-' + rand.uuid_v4())
	} else {
		os.abs_path(requested)
	}
	if requested == '' {
		os.mkdir(root, mode: 0o700)!
	} else {
		os.mkdir_all(root)!
	}
	acceptance(prefix, os.real_path(root))!
}

run(os.args[1..]) or {
	eprintln(err)
	code := err.code()
	exit(if code > 0 && code < 256 { code } else { 1 })
}
