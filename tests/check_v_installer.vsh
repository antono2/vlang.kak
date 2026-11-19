// Verify compiler builds, staging, and failure recovery against local Git inputs.
import os
import rand
import releasetest { capture, execute }

const compiler_remote = 'https://github.com/vlang/v.git'
const bootstrap_remote = 'https://github.com/vlang/vc.git'

fn commit(repo string, payload string) !string {
	os.write_file(os.join_path(repo, 'payload'), payload)!
	capture('git', ['-C', repo, 'add', 'payload'], true)!
	capture('git', ['-C', repo, '-c', 'user.name=Installer Test', '-c',
		'user.email=installer@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm',
		payload], true)!
	return capture('git', ['-C', repo, 'rev-parse', 'HEAD'], true)!.trim_space()
}

fn shim(bin string, name string, content string) ! {
	path := os.join_path(bin, name)
	os.write_file(path, '#!/bin/sh\nset -eu\n' + content)!
	os.chmod(path, 0o755)!
}

fn fixture_source(root string) !string {
	source := os.join_path(root, 'fixture', 'scripts')
	os.mkdir_all(source)!
	os.mkdir_all(os.join_path(root, 'fixture', 'tests'))!
	for name in ['install-v.vsh', 'install-v.sh', 'install-v-posix', 'managed-v.inc'] {
		os.cp(os.join_path(os.dir(@DIR), 'scripts', name), os.join_path(source, name))!
	}
	return source
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-compiler-fixture-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	compiler := os.join_path(root, 'compiler source')
	bootstrap := os.join_path(root, 'bootstrap source')
	for repo in [compiler, bootstrap] {
		capture('git', ['init', '-q', repo], true)!
	}
	first := commit(compiler, 'first release')!
	second := commit(compiler, 'second release')!
	vc := commit(bootstrap, 'bootstrap')!
	source := fixture_source(root)!
	pins := os.join_path(os.dir(source), 'tests', 'release.env')
	os.write_file(pins, 'V_REF=${first}\nVC_REF=${vc}\n')!
	program := os.join_path(root, 'install-v-test')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', program,
		os.join_path(source, 'install-v.vsh')], true)!
	bin := os.join_path(root, 'build tools')
	os.mkdir(bin)!
	shim(bin, 'gcc', r'while [ "$1" != -o ]; do shift; done
: > "$2"
')!
	shim(bin, 'ar', r': > "$2"
')!
	shim(bin, 'make', r'[ "$1" = -C ] && [ "$2" = "$FIXTURE_RELEASE" ]
[ -f "$2/thirdparty/tcc/lib/libgc.a" ]
printf "%s\n" "$2" >> "$FIXTURE_BUILD_LOG"
[ "${FIXTURE_FAIL:-0}" = 0 ] || exit 15
printf "#!/bin/sh\n[ \"\$1\" = version ]\n" > "$2/v"
chmod +x "$2/v"
')!
	prefix := os.join_path(root, 'prefix with spaces')
	tool := os.join_path(prefix, 'opt', 'vlang-v')
	releases := os.join_path(tool, 'releases')
	release := os.join_path(releases, first)
	current := os.join_path(tool, 'current')
	candidate := os.join_path(tool, 'candidate')
	build_log := os.join_path(root, 'build.log')
	mut env := os.environ()
	env['PATH'] = bin + ':' + env['PATH']
	env['GIT_CONFIG_COUNT'] = '2'
	env['GIT_CONFIG_KEY_0'] = 'url.${compiler}.insteadOf'
	env['GIT_CONFIG_VALUE_0'] = compiler_remote
	env['GIT_CONFIG_KEY_1'] = 'url.${bootstrap}.insteadOf'
	env['GIT_CONFIG_VALUE_1'] = bootstrap_remote
	env['GIT_ALLOW_PROTOCOL'] = 'file'
	env['FIXTURE_BUILD_LOG'] = build_log
	env['FIXTURE_RELEASE'] = release
	env['VLANG_KAK_STAGE'] = '1'
	capture(program, [prefix], true, environment: env)!
	assert os.readlink(candidate)! == release && !os.is_link(current)
	assert os.read_file(os.join_path(release, '.vlang-revision'))! == first + '\n'
	assert !os.exists(os.join_path(release, '.git'))
	assert !os.exists(os.join_path(release, 'vc/.git'))
	env['VLANG_KAK_STAGE'] = '0'
	capture(program, [prefix], true, environment: env)!
	assert os.readlink(current)! == release && !os.is_link(candidate)
	assert os.read_lines(build_log)! == [release]

	failed := os.join_path(releases, second)
	os.write_file(pins, 'V_REF=${second}\nVC_REF=${vc}\n')!
	env['FIXTURE_RELEASE'] = failed
	env['FIXTURE_FAIL'] = '1'
	result := execute(program, [prefix], false, environment: env)!
	assert result.stderr.contains('make failed with exit status 15.')
	assert os.ls(releases)! == [first] && os.readlink(current)! == release
	assert !os.is_link(candidate)
	assert os.read_lines(build_log)! == [release, failed]

	os.write_file(candidate, 'personal file')!
	conflict := execute(program, [prefix], false, environment: env)!
	assert conflict.stderr.contains('Existing unmanaged path:')
	assert os.read_file(candidate)! == 'personal file'
	os.rm(candidate)!
	os.write_file(pins, 'V_REF=../not-a-revision\nVC_REF=${vc}\n')!
	invalid := execute(program, [prefix], false, environment: env)!
	assert invalid.stderr.contains('Expected one pinned Git revision for V_REF.')
	assert os.readlink(current)! == release && !os.is_link(candidate)
	os.write_file(pins, 'V_REF=${first}\nVC_REF=${vc}\n')!
	// Use the cached bootstrap with a PATH that contains no V compiler.
	for name in ['dirname', 'mktemp', 'rm', 'rmdir', 'ln', 'mv', 'cat', 'sh', 'mkdir'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(bin, name))!
	}
	env['PATH'] = bin
	env['VLANG_KAK_STAGE'] = '1'
	capture(os.join_path(source, 'install-v.sh'), ['--prefix', prefix], true, environment: env)!
	assert os.readlink(candidate)! == release && os.readlink(current)! == release
	assert os.read_lines(build_log)! == [release, failed]
	println('ok - managed V installer stages and reuses pinned releases and cleans up failed builds')
}

check() or {
	eprintln(err)
	exit(1)
}
