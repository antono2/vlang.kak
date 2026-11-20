// Check task dispatch with the cached V helper and the compiler-free fallback.
import os
import rand
import releasetest { capture }

fn kak_arg(text string) string {
	return "'" + text.replace("'", "''") + "'"
}

fn shell_command(action string) string {
	argument := action.trim_space().all_after('v-make-command ')
	assert argument.len >= 2 && argument.starts_with("'") && argument.ends_with("'")
	return argument[1..argument.len - 1].replace("''", "'")
}

fn check_lanes(helper string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-tasks-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	repo := os.join_path(root, 'repo')
	project := os.join_path(root, "project's files")
	os.mkdir(repo)!
	capture('git', ['init', '-q'], true, work_folder: repo)!
	capture('git', ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit',
		'--allow-empty', '-qm', 'task fixture'], true, work_folder: repo)!
	capture('git', ['worktree', 'add', '--detach', project], true, work_folder: repo)!
	nested := os.join_path(project, 'nested')
	os.mkdir(nested)!
	source := os.join_path(nested, "it's_test.v")
	os.write_file(source, 'module main\n\npub fn test_first () {}\n\nfn test_second() {}\n')!
	marker := os.join_path(root, 'must-not-exist')
	run := "printf '<%s>\\n' ."
	mut commands := ['task', 'project', 'run', source, 'v .', 'v -check', run, 'v test .', 'v vet .',
		nested, source]
	commands << ['', "argument's value", '$' + '(touch ' + marker + ')', 'line one\nline two']
	mut native := os.environ()
	native['XDG_CACHE_HOME'] = os.join_path(root, 'native-cache')
	capture(helper, ['task', '--prepare'], true, environment: native)!
	bin := os.join_path(root, 'no-v')
	os.mkdir(bin)!
	for name in ['awk', 'cksum', 'dirname', 'readlink', 'sed', 'sh'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(bin, name))!
	}
	mut fallback := native.clone()
	fallback['PATH'] = bin
	fallback['XDG_CACHE_HOME'] = os.join_path(root, 'fallback-cache')
	for lane in [native, fallback] {
		planned := shell_command(capture(helper, commands, true, environment: lane)!)
		output := capture('/bin/sh', ['-c', planned], true)!
		assert output == "V task output\n<${source}>\n<>\n<argument's value>\n<$" + '(touch ' +
			marker + ')>\n<line one\nline two>\n'
		assert !os.exists(marker)
		build := capture(helper, ['task', 'project', 'build', source, 'v .', '', '', '', '', '',
			''], true, environment: lane)!
		assert shell_command(build).starts_with("cd '${project.replace("'", "'\\''")}'")
		assert shell_command(build).ends_with('&& v .')
		for line, name in {
			'1': 'test_first'
			'6': 'test_second'
		} {
			action := capture(helper, ['task', 'nearest', source, 'false', line, 'v test'], true,
				environment: lane
			)!
			assert action.contains('set-option global v_last_test_command')
			assert shell_command(action.split_into_lines().last()).ends_with(
				"-run-only '${name}' " + "'${source.replace("'", "'\\''")}'")
			assert shell_command(action.split_into_lines().last()).starts_with("cd '${project.replace("'",
				"'\\''")}'")
		}
		refused := capture(helper, ['task', 'nearest', source, 'true', '1', 'v test'], true,
			environment: lane
		)!
		assert refused == "fail 'Save the test file before running a test at the cursor'\n"
		legacy := capture(helper, ['task', 'run', source,
			"printf 'out\\n'; printf 'err\\n' >&2; exit 3", 'false', 'false'], true,
			environment: lane
		)!
		assert legacy == 'set-option global v_output ' + kak_arg('out\nerr') + '\n'
		unknown := capture(helper, ['task', 'project', "unknown'task", source, '', '', '', '',
			'', '', ''], true, environment: lane)!
		assert unknown == 'fail ' + kak_arg("Unknown V task: unknown'task") + '\n'
	}
	assert !os.exists(fallback['XDG_CACHE_HOME'])
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/tasks.vsh HELPER_CACHE')
	exit(2)
}
check_lanes(os.args[1]) or {
	eprintln(err)
	exit(1)
}
println('ok - native and compiler-free task dispatch, quoted arguments and linked worktrees')
