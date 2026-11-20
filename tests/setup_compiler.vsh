// Check setup compiler policy without downloading a managed toolchain.
import os
import rand
import releasetest { capture, execute }

const test_compiler = '#!/bin/sh\n[ "$1" = -check ] || exit 2\nIFS= read -r imported < "$2"\n[ "$imported" = "import $ACCEPTED_IMPORT" ]\n'

fn install_fake(directory string, script string) ! {
	os.mkdir_all(directory)!
	path := os.join_path(directory, 'v')
	os.write_file(path, script)!
	os.chmod(path, 0o755)!
}

fn expected(policy string, mode string, install bool, path string) string {
	return '${policy}\n${mode}\n${install}\n${path}.'
}

fn check(root string) ! {
	source := os.join_path(os.dir(@DIR), 'scripts', 'setup-compiler.vsh')
	selector := os.join_path(root, 'setup-compiler')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', selector, source], true)!
	prefix := os.join_path(root, 'prefix with spaces')
	settings := os.join_path(root, 'kakrc')
	system := os.join_path(root, 'system bin')
	current := os.join_path(prefix, 'opt', 'vlang-v', 'current')
	candidate := os.join_path(prefix, 'opt', 'vlang-v', 'candidate')
	install_fake(system, test_compiler)!
	no_compiler := os.join_path(root, 'empty bin')
	os.mkdir(no_compiler)!
	mut env := os.environ()
	env['PATH'] = no_compiler
	assert capture(selector, [prefix, settings, 'auto', 'false', 'false', 'false', 'skip'], true,
		environment: env
	)! == expected('auto', 'auto', false, no_compiler)
	assert capture(selector, [prefix, settings, 'auto', 'false', 'true', 'false', 'skip'], true,
		environment: env
	)! == expected('auto', 'auto', true, no_compiler)

	env['PATH'] = system
	env['ACCEPTED_IMPORT'] = 'x.json2'
	assert capture(selector, [prefix, settings, 'auto', 'false', 'false', 'true', 'external'],
		true, environment: env)! == expected('auto', 'auto', false, system)
	assert capture(selector, [prefix, settings, 'auto', 'false', 'false', 'false', 'upstream'],
		true, environment: env)! == expected('auto', 'auto', true, system)
	refused := execute(selector,
		[prefix, settings, 'system', 'false', 'false', 'false', 'upstream'], false, environment: env)!
	assert refused.stderr.contains('Selected system V cannot compile')

	env['ACCEPTED_IMPORT'] = 'json2'
	install_fake(current, '#!/bin/sh\nexit 1\n')!
	install_fake(candidate, '#!/bin/sh\nexit 1\n')!
	assert capture(selector, [prefix, settings, 'auto', 'false', 'false', 'false', 'skip'], true,
		environment: env
	)! == expected('auto', 'true', true, current + ':' + system)
	os.write_file(settings, '# vlang.kak compiler-policy: system\n')!
	unusual := os.join_path(root, 'directory ending with newline') + '\n'
	env['PATH'] = [current, system, candidate, unusual].join(':')
	assert capture(selector, [prefix, settings, 'auto', 'false', 'false', 'false', 'upstream'],
		true, environment: env)! == expected('system', 'system', false, system + ':' + unusual)
	assert capture(selector, [prefix, settings, 'true', 'false', 'false', 'false', 'skip'], true,
		environment: env
	)! == expected('managed', 'true', true, current + ':' + env['PATH'])
}

scratch := os.join_path(os.temp_dir(), 'vlang-compiler-policy.' + rand.uuid_v4())
os.mkdir(scratch) or { panic(err) }
defer { os.rmdir_all(scratch) or {} }
check(scratch) or { panic(err) }
println('ok - setup compiler selection handles saved policy, tool requirements and the VLS import')
