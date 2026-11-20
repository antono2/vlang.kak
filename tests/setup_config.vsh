// Check that native setup resolves configuration paths without losing shell semantics.
import os
import rand
import releasetest { capture, execute }

fn check(root string) ! {
	scripts := os.join_path(os.dir(@DIR), 'scripts')
	defaults := os.join_path(root, 'defaults')
	capture(os.find_abs_path_of_executable('v')!, ['-skip-running', '-o', defaults,
		os.join_path(scripts, 'setup-defaults.vsh')], true)!
	actual := os.join_path(root, 'working directory')
	logical := os.join_path(root, 'logical alias')
	os.mkdir(actual)!
	os.symlink(actual, logical)!

	prefix := os.join_path(root, 'managed prefix')
	args := ['--resolve-config', prefix, '', '', '', '', '']
	mut environment := os.environ()
	environment['PWD'] = logical
	environment['XDG_CONFIG_HOME'] = os.join_path(root, 'ignored XDG config')
	environment['VLANG_KAK_CONFIG_HOME'] = "personal config's"
	personal := logical + "/personal config's"
	output := capture(defaults, args, true, environment: environment, work_folder: actual)!
	assert output.split_into_lines() == [personal, personal + '/kak/kakrc', 'false', 'true', 'true',
		'auto', 'auto']
	assert os.is_dir(actual + "/personal config's")
	assert !os.exists(environment['XDG_CONFIG_HOME'])

	// Defaults come from the isolated kakrc when it exists.
	managed := prefix + '/opt/vlang-kakoune/ide-config/kak/kakrc'
	os.mkdir_all(os.dir(managed))!
	os.write_file(managed, 'set-option global v_pane_mode off\n')!
	with_managed := capture(defaults, args, true, environment: environment, work_folder: actual)!
	assert with_managed.split_into_lines() == [personal, managed, 'false', 'true', 'true', 'off',
		'auto']

	environment.delete('VLANG_KAK_CONFIG_HOME')
	xdg := environment['XDG_CONFIG_HOME']
	with_xdg := capture(defaults, args, true, environment: environment, work_folder: actual)!
	assert with_xdg.split_into_lines()[0] == xdg
	assert os.is_dir(xdg)

	// Creating the config root must not interpret a literal backslash as a separator.
	literal := root + '/config\\literal'
	environment['VLANG_KAK_CONFIG_HOME'] = literal
	with_literal := capture(defaults, args, true, environment: environment, work_folder: actual)!
	assert with_literal.split_into_lines()[0] == literal
	assert os.is_dir(literal) && !os.exists(root + '/config/literal')
	for forbidden in ['missing\tpath', 'missing\npath'] {
		environment['VLANG_KAK_CONFIG_HOME'] = root + '/' + forbidden
		result := execute(defaults, args, false, environment: environment, work_folder: actual)!
		assert result.code == 2 && result.stderr.contains('Tabs/newlines in configuration paths')
		assert !os.exists(environment['VLANG_KAK_CONFIG_HOME'])
	}
}

scratch := os.join_path(os.temp_dir(), 'vlang-setup-config-' + rand.uuid_v4())
os.mkdir(scratch, mode: 0o700) or { panic(err) }
defer { os.rmdir_all(scratch) or {} }
check(scratch) or { panic(err) }
println('ok - setup resolves configuration precedence and preserves logical and literal paths')
