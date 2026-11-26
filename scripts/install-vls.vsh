// Build upstream VLS in a versioned user-local installation.
import os
import rand

const upstream = 'https://github.com/vlang/vls.git'
const usage = 'Usage: v run scripts/install-vls.vsh [--ref GIT_REF] [--prefix DIRECTORY] [--v-command PATH]
Build the release-tested VLS revision, or a chosen tag or commit, using V.
Install it under PREFIX/opt/vlang-vls and link PREFIX/bin/vls.
Default: VLS_REF from tests/release.env, PREFIX=$HOME/.local, V command from PATH.
Use --ref HEAD to try the latest upstream commit.'

fn tested_ref() !string {
	for line in os.read_lines(os.join_path(os.dir(@DIR), 'tests', 'release.env'))! {
		if line.starts_with('VLS_REF=') {
			revision := line.all_after('VLS_REF=')
			if revision.len == 40 && revision.bytes().all(it.is_hex_digit()) {
				return revision
			}
			return error('Invalid tested VLS revision in tests/release.env.')
		}
	}
	return error('Missing tested VLS revision in tests/release.env.')
}

struct Options {
mut:
	ref       string
	prefix    string
	v_command string = 'v'
}

fn parse_args(args []string) !Options {
	mut opts := Options{
		prefix: os.join_path(os.home_dir(), '.local')
	}
	for i := 0; i < args.len; i += 2 {
		option := args[i]
		if option !in ['--ref', '--prefix', '--v-command'] {
			return error('Unknown option: ${option}')
		}
		if i + 1 >= args.len {
			return error('Missing value for ${option}')
		}
		match option {
			'--ref' { opts.ref = args[i + 1] }
			'--prefix' { opts.prefix = args[i + 1] }
			'--v-command' { opts.v_command = args[i + 1] }
			else {}
		}
	}
	if opts.prefix == '' {
		return error('The installation prefix cannot be empty.')
	}
	return opts
}

fn run(program string, args []string, directory string) ! {
	mut child := os.new_process(program)
	defer { child.close() }
	child.set_args(args)
	if directory != '' {
		child.set_work_folder(directory)
	}
	child.wait()
	if child.code != 0 {
		return error('${program} ${args.join(' ')} exited ${child.code}')
	}
}

fn source_revision(git string, source string) !string {
	mut child := os.new_process(git)
	defer { child.close() }
	child.set_work_folder(source)
	child.set_args(['rev-parse', 'HEAD'])
	child.set_redirect_stdio()
	child.run()
	revision := child.stdout_slurp().trim_space()
	child.wait()
	if child.code != 0 || revision.len != 40 || !revision.bytes().all((it >= `0` && it <= `9`)
		|| (it >= `a` && it <= `f`)) {
		return error('Could not resolve the VLS source commit: ${child.stderr_slurp().trim_space()}')
	}
	return revision
}

fn new_scratch_dir(parent string, stem string) !string {
	path := os.join_path(parent, stem + rand.uuid_v4())
	os.mkdir(path, mode: 0o700)!
	return path
}

fn is_vls_executable(path string) bool {
	return os.is_file(path) && os.is_executable(path)
}

fn replace_link(target string, link string) ! {
	next := link + '.next-' + rand.uuid_v4()
	os.symlink(target, next)!
	defer { os.rm(next) or {} }
	// Rename the link itself, even when the destination points to a directory.
	os.rename_dir(next, link)!
}

fn build_release(compiler string, source string, releases string, commit string) !string {
	release := os.join_path(releases, commit)
	binary := os.join_path(release, 'bin', 'vls')
	if is_vls_executable(binary) {
		return release
	}
	if os.exists(release) || os.is_link(release) {
		return error('Incomplete managed release at ${release}; move it aside and retry.')
	}
	stage := new_scratch_dir(releases, '.stage-${commit}.')!
	defer { os.rmdir_all(stage) or {} }
	os.mkdir(os.join_path(stage, 'bin'))!
	output := os.join_path(stage, 'bin', 'vls')
	run(compiler, ['-o', output, '.'], source) or {
		eprintln('VLS build failed: ${err}')
		run(compiler, ['version'], '') or {}
		return error('Upstream VLS requires a compatible recent V compiler (including json2). See docs/release.md for the tested revision, or supply an existing VLS with setup.sh --vls PATH.')
	}
	if !is_vls_executable(output) {
		return error('VLS build did not produce an executable.')
	}
	os.write_file(os.join_path(stage, '.vlang-commit'), commit + '\n')!
	os.rename_dir(stage, release) or {
		// Another standalone install may have finished this release first.
		if !is_vls_executable(binary) {
			return err
		}
	}
	return release
}

fn install(opts Options) ! {
	compiler := os.find_abs_path_of_executable(opts.v_command) or {
		return error('V compiler is required to build VLS; install V or use --vls PATH with setup.sh.')
	}
	git := os.find_abs_path_of_executable('git') or {
		return error('Git is required to build VLS.')
	}
	os.mkdir_all(opts.prefix)!
	prefix := os.real_path(opts.prefix)
	root := os.join_path(prefix, 'opt', 'vlang-vls')
	releases := os.join_path(root, 'releases')
	bin := os.join_path(prefix, 'bin')
	launcher := os.join_path(bin, 'vls')
	os.mkdir_all(releases)!
	os.mkdir_all(bin)!
	if os.exists(launcher) && !os.is_link(launcher) {
		return error('Existing unmanaged VLS at ${launcher}; choose another --prefix.')
	}

	build := new_scratch_dir(os.temp_dir(), 'vlang-vls-build.')!
	defer { os.rmdir_all(build) or {} }
	source := os.join_path(build, 'vls')
	ref := if opts.ref == '' { tested_ref()! } else { opts.ref }
	if ref == 'HEAD' {
		run(git, ['clone', '--depth', '1', upstream, source], '')!
	} else {
		run(git, ['clone', '--depth', '1', '--no-checkout', upstream, source], '')!
		run(git, ['fetch', '--depth', '1', '--', 'origin', ref], source)!
		run(git, ['checkout', '--detach', 'FETCH_HEAD'], source)!
	}
	commit := source_revision(git, source)!
	release := build_release(compiler, source, releases, commit)!
	if os.getenv('VLANG_KAK_STAGE') == '1' {
		replace_link(release, os.join_path(root, 'candidate'))!
		println('Prepared ${release}')
		return
	}
	replace_link('releases/${commit}', os.join_path(root, 'current'))!
	replace_link(os.join_path(root, 'current', 'bin', 'vls'), launcher)!
	println('VLS ${commit} is available at ${launcher}')
}

args := os.args[1..]
if args in [['--help'], ['-h']] {
	println(usage)
	exit(0)
}
opts := parse_args(args) or {
	eprintln(err)
	eprintln(usage)
	exit(2)
}
install(opts) or {
	eprintln(err)
	exit(1)
}
