// Verify runtime discovery through executable links, installer state, and overrides.
import os
import rand
import releasetest { capture, execute }

fn exercise(program string, args []string, prefix string, root string) ! {
	bin := os.join_path(root, 'search path')
	os.mkdir_all(bin)!
	for name in ['dirname', 'readlink'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(bin, name))!
	}
	mut environment := os.environ()
	environment['PATH'] = bin
	environment.delete('KAKOUNE_RUNTIME')
	missing := execute(program, args, false, environment: environment)!
	assert missing.stderr.contains('Kakoune is not installed.')

	installation := os.join_path(root, 'editor installation')
	actual := os.join_path(installation, 'bin', 'kak')
	default_runtime := os.join_path(installation, 'share', 'kak')
	os.mkdir_all(os.dir(actual))!
	os.write_file(actual, '#!/bin/sh\nexit 0\n')!
	os.chmod(actual, 0o755)!
	os.symlink(actual, os.join_path(bin, 'kak'))!
	assert capture(program, args, true, environment: environment)! == default_runtime + '.'

	override := os.join_path(root, 'runtime override') + '\n'
	environment['KAKOUNE_RUNTIME'] = override
	assert capture(program, args, true, environment: environment)! == override + '.'
	managed := os.join_path(prefix, 'opt', 'vlang-kakoune', 'current', 'share', 'kak')
	os.mkdir_all(managed)!
	assert capture(program, args, true, environment: environment)! == managed + '.'
}

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-runtime-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	scripts := os.join_path(os.dir(@DIR), 'scripts')
	selector := os.join_path(root, 'selector')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', selector,
		os.join_path(scripts, 'setup-runtime.vsh')], true)!
	native := os.join_path(root, 'native prefix')
	exercise(selector, [native], native, os.join_path(root, 'compiled'))!
	fallback := os.join_path(root, 'POSIX prefix')
	exercise(os.find_abs_path_of_executable('sh')!, ['-eu', '-c', 'prefix=$2; . "$1"',
		'resolve-runtime', os.join_path(scripts, 'setup-runtime-posix'), fallback], fallback, os.join_path(root,
		'fallback'))!
}

check() or { panic(err) }
println('ok - Kakoune runtime resolution agrees across V and compiler-free setup')
