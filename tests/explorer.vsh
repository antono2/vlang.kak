// Exercise explorer state across a nested V project, including escaped paths.
import os
import rand
import releasetest { capture }
import x.json2

// Both the native helper and the POSIX fallback must fit the same preview.
const expected_search_preview_lines = 12
const expected_search_preview_columns = 140
const clipped_search_marker = 'beyond-preview'

struct Row {
	path string
}

struct ExplorerState {
	rows []Row
}

fn invoke(helper string, args ...string) !string {
	mut command := [helper]
	command << args
	result := os.execute(command.map(os.quoted_path(it)).join(' '))
	if result.exit_code != 0 {
		return error('Explorer ${args[0]} failed (${result.exit_code}): ${result.output}')
	}
	return result.output
}

fn row_number(state_path string, path string) !string {
	state := json2.decode[ExplorerState](os.read_file(state_path)!)!
	for index, row in state.rows {
		if row.path == path {
			// Explorer commands use one-based display rows.
			return (index + 1).str()
		}
	}
	return error('Missing explorer row for ${path}')
}

fn check_project_paths(helper string, root string) ! {
	repo := os.join_path(root, 'repository')
	worktree := os.join_path(root, "worktree's files")
	os.mkdir(repo)!
	capture('git', ['init', '-q'], true, work_folder: repo)!
	os.write_file(os.join_path(repo, 'tracked.v'), 'module main\n')!
	capture('git', ['add', 'tracked.v'], true, work_folder: repo)!
	capture('git', ['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm',
		'project path fixture'], true,
		work_folder: repo
	)!
	capture('git', ['worktree', 'add', '--detach', worktree], true, work_folder: repo)!
	os.write_file(os.join_path(worktree, '.gitignore'), 'ignored.v\n')!
	os.write_file(os.join_path(worktree, 'ignored.v'), 'module main\n')!
	folder := os.join_path(worktree, 'nested')
	os.mkdir(folder)!
	file := os.join_path(folder, "it's café.v")
	os.write_file(file, 'module main\n')!
	pattern := "-needle 'quoted'"
	line := '// ' + pattern + ' ' + 'x'.repeat(expected_search_preview_columns) + ' ' +
		clipped_search_marker
	os.write_file(os.join_path(worktree, 'tracked.v'), (line + '\n').repeat(expected_search_preview_lines + 1))!
	mut env := os.environ()
	env['XDG_CACHE_HOME'] = os.join_path(root, 'native-cache')
	capture(helper, ['--prepare'], true, environment: env)!

	// A controlled PATH makes both lanes use Git rather than ripgrep.
	bin := os.join_path(root, 'no-compiler')
	os.mkdir(bin)!
	for name in ['cksum', 'cut', 'dirname', 'find', 'git', 'grep', 'head', 'sed'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(bin, name))!
	}
	env['PATH'] = bin
	mut fallback := env.clone()
	fallback['XDG_CACHE_HOME'] = os.join_path(root, 'fallback-cache')
	for lane in [env, fallback] {
		prompt := capture(helper, ['prompt', file], true, environment: lane)!
		assert prompt.contains("'${worktree.replace("'", "''")}/' 'Project path: '")
		files := capture(helper, ['candidates', file], true, environment: lane)!.split_into_lines()
		assert file in files && os.join_path(worktree, 'tracked.v') in files
		assert os.join_path(worktree, 'ignored.v') !in files
			&& os.join_path(worktree, '.git') !in files
		preview := capture(helper, ['search', file, 'preview', pattern, 'grep -RHn'], true,
			environment: lane
		)!
		assert preview.starts_with("info -title 'Project search · Enter for all' ")
		assert preview.count('tracked.v:') == expected_search_preview_lines && preview.contains("-needle ''quoted''")
		assert !preview.contains(clipped_search_marker)
		missing := capture(helper, ['search', file, 'preview', 'absent-needle', 'grep -RHn'], true,
			environment: lane
		)!
		assert missing.ends_with("'No matches yet'\n")
		empty := capture(helper, ['search', file, 'preview', '', 'grep -RHn'], true,
			environment: lane
		)!
		assert empty.contains('Type a pattern; Enter opens all results')
		custom := capture(helper, ['search', file, 'results', pattern, 'custom-grep'], true,
			environment: lane
		)!
		assert custom == "grep -e '-needle ''quoted''' '${worktree.replace("'", "''")}'\n"
		default := capture(helper, ['search', file, 'results', pattern, 'grep -RHn'], true,
			environment: lane
		)!
		assert default == "set-option window grepcmd 'grep -RHn --exclude-dir=.git'\n" + custom +
			'unset-option window grepcmd\n'
	}
	assert !os.exists(fallback['XDG_CACHE_HOME'])
	plain := os.join_path(root, 'plain folder')
	os.mkdir(plain)!
	plain_file := os.join_path(plain, 'no-module.v')
	os.write_file(plain_file, 'module main\n')!
	os.rm(os.join_path(bin, 'git'))!
	for lane in [env, fallback] {
		assert capture(helper, ['candidates', plain_file], true, environment: lane)! ==
			plain_file + '\n'
	}
}

fn check(helper string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-kak-explorer-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	os.write_file(os.join_path(root, 'v.mod'), "Module { name: 'tree_test' }\n")!
	source := os.join_path(root, 'src')
	os.mkdir(source)!
	file := os.join_path(source, "it's.v")
	os.write_file(file, 'module main\n\nfn hello() {}\n')!
	os.write_file(os.join_path(root, '.hidden.v'), 'module main\n')!
	state := os.join_path(root, 'state.json')

	invoke(helper, 'init', state, file)!
	tree := invoke(helper, 'render', state, file)!
	assert tree.contains('q back')
	assert invoke(helper, 'render', state, file, 'true')!.contains('q close pane')
	assert tree.contains('▸ src/')
	assert !tree.contains("it's.v")
	assert !tree.contains('.hidden.v')
	source_line := row_number(state, source)!

	assert invoke(helper, 'action', state, source_line, 'expand')!.trim_space() == 'v-tree-refresh'
	expanded := invoke(helper, 'render', state, file)!
	assert expanded.contains('▾ src/')
	assert expanded.contains("it's.v")
	file_line := row_number(state, file)!
	assert invoke(helper, 'action', state, file_line, 'preview')!.contains('fn hello()')
	assert invoke(helper, 'action', state, file_line, 'open')!.contains("it''s.v")

	invoke(helper, 'hidden', state)!
	assert invoke(helper, 'render', state, file)!.contains('.hidden.v')
	invoke(helper, 'action', state, source_line, 'collapse')!
	assert !invoke(helper, 'render', state, file)!.contains("it's.v")
	invoke(helper, 'cleanup', state)!
	assert !os.exists(state)
	os.rm(os.join_path(root, 'v.mod'))!
	check_project_paths(helper, root)!
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/explorer.vsh EXPLORER')
	exit(2)
}
check(os.args[1]) or {
	eprintln(err)
	exit(1)
}
println('ok - built-in explorer and native/POSIX project paths and search')
