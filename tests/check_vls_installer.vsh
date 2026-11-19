// Exercise the public installer with a local Git repository and a test compiler.
import os
import rand
import releasetest { capture }

fn fake_compiler(log string) ! {
	args := os.args[1..]
	if args == ['version'] {
		println('VLS test compiler')
		return
	}
	if args.len != 3 || args[0] != '-o' || args[2] != '.' {
		return error('Unexpected compiler arguments: ${args}')
	}
	source := os.read_file('fixture.txt')!.trim_space()
	mut builds := os.open_append(log)!
	defer { builds.close() }
	builds.writeln(source)!
	if os.getenv('VLS_INSTALLER_FIXTURE_FAIL') == '1' {
		return error('Simulated compiler failure')
	}
	os.cp(os.executable(), args[1])!
	os.chmod(args[1], 0o755)!
}

struct Fixture {
	prefix   string
	git_repo string
	compiler string
	log      string
	scratch  string
}

@[params]
struct Installation {
	ref            string
	stage          bool
	fail_build     bool
	expect_success bool = true
}

fn (fixture Fixture) install(options Installation) !string {
	mut env := os.environ()
	env['GIT_CONFIG_COUNT'] = '1'
	env['GIT_CONFIG_KEY_0'] = 'url.file://${fixture.git_repo}.insteadOf'
	env['GIT_CONFIG_VALUE_0'] = 'https://github.com/vlang/vls.git'
	env['GIT_ALLOW_PROTOCOL'] = 'file'
	env['VLS_INSTALLER_FIXTURE_LOG'] = fixture.log
	env['VLS_INSTALLER_FIXTURE_FAIL'] = if options.fail_build { '1' } else { '0' }
	env['VLANG_KAK_STAGE'] = if options.stage { '1' } else { '0' }
	env['TMPDIR'] = fixture.scratch
	mut args := ['--prefix', fixture.prefix, '--v-command', fixture.compiler]
	if options.ref != '' {
		args << ['--ref', options.ref]
	}
	installer := os.real_path(os.join_path(@DIR, '..', 'scripts', 'install-vls.sh'))
	result := capture(installer, args, options.expect_success, environment: env)!
	assert os.ls(fixture.scratch)!.filter(it.starts_with('vlang-vls-build.')).len == 0
	return result
}

fn commit(git_repo string, description string) !string {
	os.write_file(os.join_path(git_repo, 'fixture.txt'), description + '\n')!
	capture('git', ['add', 'fixture.txt'], true, work_folder: git_repo)!
	capture('git', ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit',
		'-qm', description], true, work_folder: git_repo)!
	return capture('git', ['rev-parse', 'HEAD'], true, work_folder: git_repo)!.trim_space()
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vls-installer-fixture-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	git_repo := os.join_path(root, 'upstream')
	capture('git', ['init', '-q', '--initial-branch=master', git_repo], true)!
	first := commit(git_repo, 'first')!
	capture('git', ['tag', 'v1'], true, work_folder: git_repo)!
	second := commit(git_repo, 'second')!
	third := commit(git_repo, 'third')!

	prefix := os.join_path(root, 'prefix with spaces')
	compiler := os.join_path(root, 'test compiler')
	log := os.join_path(root, 'compiler.log')
	scratch := os.join_path(root, 'scratch')
	os.mkdir(scratch, mode: 0o700)!
	os.symlink(os.executable(), compiler)!
	fixture := Fixture{
		prefix:   prefix
		git_repo: git_repo
		compiler: compiler
		log:      log
		scratch:  scratch
	}
	tool := os.join_path(prefix, 'opt', 'vlang-vls')
	releases := os.join_path(tool, 'releases')
	current := os.join_path(tool, 'current')
	candidate := os.join_path(tool, 'candidate')
	launcher := os.join_path(prefix, 'bin', 'vls')

	fixture.install()!
	assert os.readlink(current)! == 'releases/${third}'
	assert os.readlink(launcher)! == os.join_path(current, 'bin', 'vls')
	assert os.is_executable(launcher)

	fixture.install(ref: 'v1', stage: true)!
	assert os.readlink(candidate)! == os.join_path(releases, first)
	assert os.readlink(current)! == 'releases/${third}'
	assert os.read_file(os.join_path(candidate, '.vlang-commit'))!.trim_space() == first

	// Installing a published release again switches links without recompiling it.
	fixture.install(ref: first)!
	assert os.readlink(current)! == 'releases/${first}'
	assert os.read_lines(log)! == ['third', 'first']

	fixture.install(ref: second, stage: true, fail_build: true, expect_success: false)!
	assert os.readlink(candidate)! == os.join_path(releases, first)
	assert os.readlink(current)! == 'releases/${first}'
	assert os.ls(releases)!.sorted() == [first, third].sorted()
	assert os.read_lines(log)! == ['third', 'first', 'second']

	// Never replace a standalone user binary.
	os.rm(launcher)!
	os.write_file(launcher, 'unmanaged')!
	fixture.install(ref: 'v1', expect_success: false)!
	assert os.read_file(launcher)! == 'unmanaged'
	assert os.read_lines(log)! == ['third', 'first', 'second']
	println('VLS installer checks passed')
}

if log := os.getenv_opt('VLS_INSTALLER_FIXTURE_LOG') {
	fake_compiler(log) or {
		eprintln(err)
		exit(1)
	}
} else {
	check() or {
		eprintln(err)
		exit(1)
	}
}
