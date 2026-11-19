// Build a Kakoune release and install it in the managed user prefix.
import os
import rand
import strconv

const upstream = 'https://github.com/mawww/kakoune.git'
const launcher_marker = '# vlang.kak managed Kakoune launcher'
const usage = 'Usage: v run scripts/build-kakoune.vsh [--latest | --version TAG_OR_COMMIT_OR_master]
                                       [--prefix DIRECTORY] [--jobs NUMBER]
Install the selected Kakoune revision under PREFIX/opt/vlang-kakoune and
create a managed PREFIX/bin/kak launcher. Default: latest stable tag,
PREFIX=$HOME/.local.'

struct Options {
mut:
	revision string = 'latest'
	prefix   string
	jobs     int = 2
}

fn parse_args(args []string) !Options {
	mut opts := Options{ prefix: os.join_path(os.home_dir(), '.local') }
	for i := 0; i < args.len; i++ {
		option := args[i]
		if option == '--latest' {
			opts.revision = 'latest'
			continue
		}
		if option !in ['--version', '--prefix', '--jobs'] {
			return error('Unknown option: ${option}')
		}
		i++
		if i == args.len {
			return error('Missing value for ${option}')
		}
		match option {
			'--version' { opts.revision = args[i] }
			'--prefix' { opts.prefix = args[i] }
			'--jobs' {
				opts.jobs = strconv.atoi(args[i]) or { return error('--jobs requires a positive integer.') }
				if opts.jobs < 1 {
					return error('--jobs requires a positive integer.')
				}
			}
			else {}
		}
	}
	check_prefix(opts.prefix)!
	return opts
}

fn check_prefix(prefix string) ! {
	if prefix == '' || prefix.contains_any("'\r\n") {
		return error('The installation prefix must be nonempty and cannot contain quotes or newlines.')
	}
}

fn command(name string) !string {
	return os.find_abs_path_of_executable(name) or { error('Missing required tool: ${name}') }
}

fn run(program string, args []string) ! {
	mut process := os.new_process(program)
	defer { process.close() }
	process.set_args(args)
	process.wait()
	if process.code != 0 {
		return error('${program} ${args.join(' ')} exited ${process.code}')
	}
}

fn output(program string, args []string) !string {
	mut process := os.new_process(program)
	defer { process.close() }
	process.set_args(args)
	process.set_redirect_stdio()
	process.run()
	out_text := process.stdout_slurp()
	error_text := process.stderr_slurp()
	process.wait()
	if process.code != 0 {
		return error('${program} ${args.join(' ')} exited ${process.code}\n${error_text.trim_space()}')
	}
	return out_text.trim_space()
}

fn is_stable_tag(tag string) bool {
	return tag.len == 11 && tag[0] == `v` && tag[5] == `.` && tag[8] == `.`
		&& (tag[1..5] + tag[6..8] + tag[9..11]).bytes().all(it >= `0` && it <= `9`)
}

fn is_commit(revision string) bool {
	return revision.len == 40 && revision.bytes().all((it >= `0` && it <= `9`)
		|| (it >= `a` && it <= `f`))
}

fn select_revision(requested string) !string {
	if requested == 'latest' {
		git := command('git')!
		refs := output(git, ['ls-remote', '--tags', '--refs', upstream, 'v20*'])!
		mut tags := []string{}
		for line in refs.split_into_lines() {
			tag := line.all_after_last('refs/tags/')
			if is_stable_tag(tag) {
				tags << tag
			}
		}
		if tags.len == 0 {
			return error('Upstream returned no stable Kakoune tag.')
		}
		tags.sort()
		return tags.last()
	}
	if requested == 'master' {
		git := command('git')!
		refs := output(git, ['ls-remote', upstream, 'refs/heads/master'])!
		commit := refs.all_before('\t')
		if !is_commit(commit) {
			return error('Could not resolve Kakoune master to an upstream commit.')
		}
		return commit
	}
	if !is_stable_tag(requested) && !is_commit(requested) {
		return error('Select a stable tag, master or a full upstream commit hash.')
	}
	return requested
}

fn new_scratch_dir(parent string, stem string) !string {
	path := os.join_path(parent, stem + rand.uuid_v4())
	os.mkdir(path, mode: 0o700)!
	return path
}

fn complete_release(path string) bool {
	binary := os.join_path(path, 'bin', 'kak')
	return os.is_file(binary) && os.is_executable(binary)
		&& os.is_dir(os.join_path(path, 'share', 'kak', 'rc'))
}

fn build_release(releases string, revision string, jobs int) !string {
	release := os.join_path(releases, revision)
	if complete_release(release) {
		return release
	}
	if os.exists(release) || os.is_link(release) {
		return error('Incomplete managed release at ${release}; move it aside and retry.')
	}
	git := command('git')!
	make := command('make')!
	requested_compiler := os.getenv('CXX')
	compiler := command(if requested_compiler == '' { 'c++' } else { requested_compiler })!
	build := new_scratch_dir(os.temp_dir(), 'vlang-kakoune-build.')!
	defer { os.rmdir_all(build) or {} }
	probe := os.join_path(build, 'compiler.cpp')
	os.write_file(probe, '')!
	output(compiler, ['-std=c++2b', '-fsyntax-only', probe]) or {
		return error('Kakoune requires a C++ compiler accepting -std=c++2b.\n${err}')
	}
	stage := new_scratch_dir(releases, '.stage-${revision}.')!
	defer { os.rmdir_all(stage) or {} }
	source := os.join_path(build, 'kakoune')
	run(git, ['init', '-q', source])!
	run(git, ['-C', source, 'fetch', '--depth', '1', upstream, revision])!
	run(git, ['-C', source, 'checkout', '-q', '--detach', 'FETCH_HEAD'])!
	commit := output(git, ['-C', source, 'rev-parse', 'HEAD'])!
	os.write_file(os.join_path(stage, '.vlang-revision'), commit + '\n')!
	// A shallow commit fetch may contain no reachable tag for the Makefile.
	os.write_file(os.join_path(source, '.version'), revision.trim_string_left('v') + '\n')!
	run(make, ['-C', source, '-j', jobs.str()])!
	run(os.join_path(source, 'src', 'kak'), ['-version'])!
	// Upstream's install recipes expand PREFIX without shell quoting.
	install_alias := '.vlang-kakoune-install'
	os.symlink(stage, os.join_path(source, install_alias))!
	run(make, ['-C', source, 'PREFIX=' + install_alias, 'install'])!
	if !complete_release(stage) {
		return error('The Kakoune build did not install its executable and runtime.')
	}
	os.write_file(os.join_path(stage, '.vlang-version'), revision + '\n')!
	os.rename_dir(stage, release) or {
		if !complete_release(release) {
			return err
		}
	}
	return release
}

fn replace_link(target string, link string) ! {
	next := link + '.next-' + rand.uuid_v4()
	os.symlink(target, next)!
	defer { os.rm(next) or {} }
	// Replace the link itself, even when it points to a directory.
	os.rename_dir(next, link)!
}

fn check_launcher(path string) ! {
	if os.is_link(path) || (os.exists(path) && (!os.is_file(path)
		|| launcher_marker !in os.read_lines(path)!)) {
		return error('Existing unmanaged launcher at ${path}; choose another --prefix.')
	}
}

fn write_launcher(root string, launcher string) ! {
	next := launcher + '.next-' + rand.uuid_v4()
	defer { os.rm(next) or {} }
	runtime := os.join_path(root, 'current', 'share', 'kak')
	binary := os.join_path(root, 'current', 'bin', 'kak')
	os.write_file(next, "#!/bin/sh\n${launcher_marker}\nKAKOUNE_RUNTIME='${runtime}'\n" +
		'export KAKOUNE_RUNTIME\nexec \'${binary}\' "\$@"\n')!
	os.chmod(next, 0o755)!
	os.rename_dir(next, launcher)!
}

fn install(opts Options) ! {
	revision := select_revision(opts.revision)!
	os.mkdir_all(opts.prefix)!
	prefix := os.real_path(opts.prefix)
	check_prefix(prefix)!
	root := os.join_path(prefix, 'opt', 'vlang-kakoune')
	releases := os.join_path(root, 'releases')
	bin := os.join_path(prefix, 'bin')
	launcher := os.join_path(bin, 'kak')
	os.mkdir_all(releases)!
	os.mkdir_all(bin)!
	check_launcher(launcher)!
	release := build_release(releases, revision, opts.jobs)!
	if os.getenv('VLANG_KAK_STAGE') == '1' {
		replace_link(release, os.join_path(root, 'candidate'))!
		println('Prepared ${release}')
		return
	}
	replace_link('releases/${revision}', os.join_path(root, 'current'))!
	write_launcher(root, launcher)!
	run(launcher, ['-version'])!
	println('Kakoune ${revision} is available at ${launcher}')
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
