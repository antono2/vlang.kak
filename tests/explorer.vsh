// Exercise explorer state across a nested V project, including escaped paths.
import json
import os
import rand

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
	state := json.decode(ExplorerState, os.read_file(state_path)!)!
	for index, row in state.rows {
		if row.path == path {
			// Explorer commands use one-based display rows.
			return (index + 1).str()
		}
	}
	return error('Missing explorer row for ${path}')
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
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/explorer.vsh EXPLORER')
	exit(2)
}
check(os.args[1]) or {
	eprintln(err)
	exit(1)
}
println('ok - built-in project explorer')
