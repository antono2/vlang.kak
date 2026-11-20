// Run editor integration cases with the selected Kakoune executable.
import editorui { quote }
import os
import rand
import releasetest { capture, capture_result, run_inherited }
import time

const kak_case_timeout = 30 * time.second
const fixtures = os.join_path(@DIR, 'fixtures')
const cases = os.join_path(@DIR, 'cases')

struct Suite {
	scratch string
	kak     string
	env     map[string]string
mut:
	case_number int
}

fn (suite Suite) script(name string, args []string) ! {
	mut command := ['run', os.join_path(@DIR, name)]
	command << args
	run_inherited('v', command)!
}

fn (mut suite Suite) kak_case(description string, file string, case_file string) ! {
	failure := os.join_path(suite.scratch, 'failure')
	if os.exists(failure) {
		os.rm(failure)!
	}
	suite.case_number++
	session := 'vlang-kak-test-${os.getpid()}-${suite.case_number}'
	source := 'source ' + quote(os.join_path(cases, case_file))
	result := capture_result(suite.kak, [os.join_path(suite.scratch, file), '-s', session, '-ui',
		'json', '-e', source],
		work_folder:     suite.scratch
		environment:     suite.env
		keep_stdin_open: true
		timeout:         kak_case_timeout
	) or { return error('not ok - ${description}\n${err}') }
	message := if os.exists(failure) { os.read_file(failure)! } else { '' }
	if result.code != 0 {
		return error('not ok - ${description} (Kakoune exited with ${result.code})\n${message}${result.stderr}${result.stdout}')
	}
	if message != '' {
		return error('not ok - ${description}\n${message}')
	}
	println('ok - ${description}')
}

fn (suite Suite) check_file(name string, expected string, first_line bool) ! {
	path := os.join_path(suite.scratch, name)
	mut actual := os.read_file(path)!
	if first_line {
		actual = actual.all_before('\n')
	} else {
		actual = actual.trim_right('\n')
	}
	if actual != expected {
		return error('Expected ${name} to contain ${expected}, got ${actual}')
	}
}

fn (suite Suite) compare_file(expected string, actual string, description string) ! {
	want := os.join_path(fixtures, expected)
	got := os.join_path(suite.scratch, actual)
	if os.read_file(want)! != os.read_file(got)! {
		eprintln('not ok - ${description}')
		// The comparison is native V. Use diff for diagnostics when available.
		run_inherited('diff', ['-u', want, got]) or {}
		return error('Expected ${got} to match ${want}')
	}
	println('ok - ${description}')
}

fn (suite Suite) highlighting(file string, expectations string) ! {
	result := capture_result(suite.kak, [file, '-ui', 'json', '-e', 'execute-keys j'],
		work_folder: suite.scratch
		environment: suite.env
		timeout:     kak_case_timeout
	)!
	// The JSON UI can report a client error when stdin closes after the first draw.
	if result.code !in [0, 255] {
		return error('Rendering ${file} exited ${result.code}\n${result.stderr}')
	}
	transcript := os.join_path(suite.scratch, '${file}.jsonl')
	os.write_file(transcript, result.stdout)!
	suite.script('assert_highlighting.vsh', [transcript, os.join_path(fixtures, expectations)])!
}

fn (mut suite Suite) history() ! {
	project := os.join_path(suite.scratch, 'history-project')
	source := os.join_path(project, 'main.v')
	initial := 'module main\n\nfn old_version() {}\n'
	edited := 'module main\n\nfn working_version() {}\n'
	os.mkdir(project)!
	os.write_file(source, initial)!
	capture('git', ['init', '-q'], true, work_folder: project)!
	capture('git', ['add', 'main.v'], true, work_folder: project)!
	capture('git', ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm',
		'first V version'], true, work_folder: project)!
	os.write_file(source, edited)!
	suite.kak_case('historical V scratch view', 'history-project/main.v', 'history.kak')!
	suite.compare_file('expected/history.v', 'history-content',
		'history view shows the committed version')!
	if os.read_file(source)! != edited {
		return error('The history view changed the working file')
	}
}

fn (mut suite Suite) detect(file string, expected string) ! {
	detected := os.join_path(suite.scratch, 'detected')
	if os.exists(detected) {
		os.rm(detected)!
	}
	suite.kak_case('filetype detection for ${file}', 'detection/${file}', 'filetype.kak')!
	suite.check_file('detected', expected, true)!
}

fn (mut suite Suite) run() ! {
	suite.kak_case('commands and editing hooks', 'project/main.v', 'core.kak')!
	suite.check_file('core-ok', 'ok', true)!
	suite.kak_case('V user-mode bindings', 'project/main.v', 'keymaps.kak')!
	suite.check_file('keymaps-ok', 'ok', true)!
	suite.script('context.vsh', [suite.kak])!
	suite.script('browsing.vsh', [suite.kak])!

	suite.kak_case('test at cursor and rerun', 'project/nearest_test.v', 'nearest_test.kak')!
	suite.check_file('nearest-ok', 'ok', true)!
	suite.kak_case('asynchronous V task dispatch', 'project/nearest_test.v', 'task_dispatch.kak')!
	suite.check_file('task-dispatch-ok', 'ok', true)!
	suite.kak_case('V task failure navigation', 'project/main.v', 'task_errors.kak')!
	suite.check_file('task-errors-ok', 'ok', true)!
	suite.history()!

	suite.compare_file('expected/formatted.v', 'unformatted.v', 'v-fmt formats and saves')!
	suite.compare_file('formatter_failure.v', 'formatter_failure.v',
		'v-fmt preserves files when formatting fails')!
	suite.compare_file('expected/indent.v', 'indent.v', 'newline hook inserts a closing delimiter')!
	suite.compare_file('expected/indent_content.v', 'indent_content.v',
		'newline hook indents typed content')!
	suite.compare_file('expected/indent_nested.v', 'indent_nested.v',
		'newline hook indents nested blocks')!
	suite.compare_file('expected/comment.v', 'comment.v', 'newline hook continues line comments')!
	suite.compare_file('expected/parenthesis.v', 'parenthesis.v', 'newline hook pairs parentheses')!

	suite.kak_case('filetype precedence after runtime autoload and before user overrides',
		'detection/sample.v', 'filetype_precedence.kak')!
	suite.check_file('precedence-before', 'coq', false)!
	suite.check_file('precedence-after', 'v', false)!
	suite.check_file('precedence-custom', 'coq', false)!
	for file in ['sample.v', 'sample.vsh', 'sample.vv', 'sample.c.v'] {
		suite.detect(file, 'v')!
	}
	suite.detect('v.mod', 'json')!
	suite.highlighting('syntax.v', 'highlighting.tsv')!
	suite.highlighting('language_features.v', 'language_highlighting.tsv')!

	for test in ['check_vls_transport.vsh', 'settings.vsh', 'restart.vsh', 'lifecycle.vsh',
		'lifecycle_sessions.vsh'] {
		suite.script(test, [suite.kak])!
	}
	suite.script('setup_transaction.vsh', [])!
	suite.script('install_lock.vsh', [])!
	suite.script('setup_checks.vsh', [])!
	suite.script('setup_compiler.vsh', [])!
	suite.script('update_discovery.vsh', [])!
	suite.script('update_release.vsh', [])!
	scripts := os.real_path(os.join_path(@DIR, '..', 'scripts'))
	suite.script('explorer.vsh', [os.join_path(scripts, 'explorer.sh')])!
	suite.script('windowing.vsh', [os.join_path(scripts, 'windowing.sh')])!
	suite.script('setup_activation.vsh', [])!

	for file in ['syntax.v', 'language_features.v'] {
		path := os.join_path(suite.scratch, file)
		run_inherited('v', ['fmt', '-verify', path])!
		run_inherited('v', ['-check', path])!
	}
	suite.script('active_tools.vsh', [])!
	run_inherited('v', ['test', os.join_path(suite.scratch, 'project')])!
}

fn check() ! {
	requested_kak := os.getenv('KAK')
	kak_input := if requested_kak == '' { 'kak' } else { requested_kak }
	kak := os.find_abs_path_of_executable(kak_input) or {
		return error('Kakoune executable not found: ${kak_input}')
	}
	os.find_abs_path_of_executable('git') or { return error('Git executable not found') }
	scratch := os.join_path(os.temp_dir(), 'vlang-kak-tests.' + rand.uuid_v4())
	os.mkdir(scratch, mode: 0o700)!
	defer { os.rmdir_all(scratch) or {} }
	os.cp_all(fixtures, scratch, false)!
	config := os.join_path(scratch, 'config')
	os.mkdir_all(os.join_path(config, 'kak'))!
	plugin := os.real_path(os.join_path(@DIR, '..', 'rc', 'vlang.kak'))
	// Distinct RGB values let the JSON assertions identify syntax faces by name.
	faces := ['attribute rgb:101001', 'comment rgb:202002', 'function rgb:303003',
		'keyword rgb:404004', 'meta rgb:505005', 'operator rgb:606006', 'string rgb:707007',
		'type rgb:808008', 'value rgb:909009']
	mut kakrc := ['source ' + quote(plugin)]
	kakrc << faces.map('face global ' + it)

	os.write_file(os.join_path(config, 'kak', 'kakrc'), kakrc.join('\n') + '\n')!
	mut env := os.environ()
	env['XDG_CONFIG_HOME'] = config
	mut suite := Suite{
		scratch: scratch
		kak:     kak
		env:     env
	}
	kak_version := capture(kak, ['-version'], true)!.trim_space()
	v_version := capture('v', ['version'], true)!.trim_space()
	println('Testing with ${kak_version} and ${v_version}')
	suite.run()!
	println('All vlang.kak tests passed')
}

check() or {
	eprintln(err)
	exit(1)
}
