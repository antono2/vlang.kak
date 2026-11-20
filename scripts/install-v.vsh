// Prepare a release-tested compiler alongside the active user-local installation.
import os
import rand

const v_remote = 'https://github.com/vlang/v.git'
const vc_remote = 'https://github.com/vlang/vc.git'
const git_sha_length = 40

struct Pins {
	v  string
	vc string
}

fn pins() !Pins {
	mut values := map[string]string{}
	for line in os.read_lines(os.join_path(os.dir(@DIR), 'tests', 'release.env'))! {
		key, revision := line.split_once('=') or { continue }
		if key !in ['V_REF', 'VC_REF'] {
			continue
		}
		if key in values || revision.len != git_sha_length
			|| !revision.bytes().all(it.is_digit() || (it >= `a` && it <= `f`)) {
			return error('Expected one pinned Git revision for ${key}.')
		}
		values[key] = revision
	}
	if 'V_REF' !in values || 'VC_REF' !in values {
		return error('The compiler and bootstrap revisions must both be pinned.')
	}
	return Pins{
		v:  values['V_REF']
		vc: values['VC_REF']
	}
}

fn run(program string, args []string) ! {
	mut child := os.new_process(program)
	defer { child.close() }
	child.set_args(args)
	child.run()
	child.wait()
	if child.code != 0 {
		return error('${program} failed with exit status ${child.code}.')
	}
}

fn fetch(repo string, remote string, revision string) ! {
	run('git', ['init', '-q', repo])!
	run('git', ['-C', repo, 'fetch', '--depth', '1', remote, revision])!
	run('git', ['-C', repo, 'checkout', '-q', '--detach', 'FETCH_HEAD'])!
}

fn compile_at_release(release string) ! {
	gc := os.join_path(release, 'thirdparty', 'libgc')
	gc_source := os.join_path(gc, 'gc.c')
	gc_include := os.join_path(gc, 'include')
	library := os.join_path(release, 'thirdparty', 'tcc', 'lib')
	object := os.join_path(library, 'gc.o')
	os.mkdir_all(library)!
	// Match the bootstrap GC configuration used by the pinned make invocation.
	run('gcc', ['-O2', '-fPIC', '-DGC_THREADS=1', '-DTHREAD_LOCAL_ALLOC=1', '-DGC_BUILTIN_ATOMIC=1',
		'-DALL_INTERIOR_POINTERS=1', '-I', gc_include, '-c', gc_source, '-o', object])!
	run('ar', ['rcs', os.join_path(library, 'libgc.a'), object])!
	run('make', ['-C', release, 'local=1', 'CC=gcc', 'VFLAGS=-cc gcc'])!
	run(os.join_path(release, 'v'), ['version'])!
}

fn prepare(releases string, release string, pin Pins) ! {
	if !os.is_link(release) && os.is_executable(os.join_path(release, 'v')) && (os.read_file(os.join_path(release, '.vlang-revision')) or {
		''
	}).trim_right('\n') == pin.v {
		return
	}
	if os.exists(release) || os.is_link(release) {
		return error('Incomplete V release at ${release}; inspect it before retrying.')
	}
	stage := os.join_path(releases, '.stage.' + rand.uuid_v4())
	os.mkdir(stage, mode: 0o700)!
	mut reserved := false
	mut complete := false
	defer {
		if os.is_dir(stage) { os.rmdir_all(stage) or { eprintln(err) } }
		if reserved && !complete { os.rmdir_all(release) or { eprintln(err) } }
	}
	fetch(stage, v_remote, pin.v)!
	fetch(os.join_path(stage, 'vc'), vc_remote, pin.vc)!
	// Reserve the version atomically. The compiler embeds its source path.
	os.mkdir(release, mode: 0o700) or {
		return error('Could not reserve V release at ${release}: ${err}')
	}
	reserved = true
	os.rename_dir(stage, release)!
	compile_at_release(release)!
	os.rmdir_all(os.join_path(release, '.git'))!
	os.rmdir_all(os.join_path(release, 'vc', '.git'))!
	os.write_file(os.join_path(release, '.vlang-revision'), pin.v + '\n')!
	complete = true
}

fn link_available(path string) ! {
	if os.exists(path) && !os.is_link(path) {
		return error('Existing unmanaged path: ${path}')
	}
}

fn install(prefix string) ! {
	pin := pins()!
	root := os.join_path(prefix, 'opt', 'vlang-v')
	releases := os.join_path(root, 'releases')
	os.mkdir_all(releases)!
	os.mkdir_all(os.join_path(prefix, 'bin'))!
	if os.real_path(releases) != releases {
		return error('Compiler release directory has been redirected: ${releases}')
	}
	current := os.join_path(root, 'current')
	candidate := os.join_path(root, 'candidate')
	staging := os.getenv('VLANG_KAK_STAGE') == '1'
	link_available(candidate)!
	if !staging { link_available(current)! }
	release := os.join_path(releases, pin.v)
	prepare(releases, release, pin)!
	pending := os.join_path(root, '.candidate.' + rand.uuid_v4())
	os.symlink(release, pending)!
	defer { os.rm(pending) or {} }
	link_available(candidate)!
	os.rename_dir(pending, candidate)!
	if !staging {
		link_available(current)!
		os.rename_dir(candidate, current)!
	}
	println('Managed V: ${current}/v (prepared candidate when staging)')
}

if os.args.len != 2 || !os.is_abs_path(os.args[1]) {
	eprintln('Usage: v run scripts/install-v.vsh ABSOLUTE_PREFIX')
	exit(2)
}
install(os.real_path(os.abs_path(os.args[1]))) or {
	eprintln(err)
	exit(1)
}
