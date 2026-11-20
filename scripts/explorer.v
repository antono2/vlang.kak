// Maintains the project-tree view and translates selections into Kakoune commands.
module main

import x.json2
import os
import time

struct Row {
	path      string
	directory bool
}

struct State {
mut:
	root       string
	expanded   []string
	hidden     bool
	focus      string
	rows       []Row
	focus_line int = 4
}

fn kak_quote(value string) string {
	return "'${value.replace("'", "''")}'"
}

fn tree_root(origin string) string {
	mut path := if origin == '' { os.getwd() } else { os.expand_tilde_to_home(origin) }
	if !os.is_dir(path) {
		path = os.dir(path)
	}
	return project_root(os.real_path(path))
}

fn project_root(start string) string {
	mut directory := start
	for {
		git_marker := os.join_path(directory, '.git')
		if os.is_file(os.join_path(directory, 'v.mod')) || os.is_dir(git_marker)
			|| os.is_file(git_marker) {
			return directory
		}
		parent := os.dir(directory)
		if parent == directory {
			return start
		}
		directory = parent
	}
	return start
}

fn buffer_root(file string) string {
	if file == '' {
		return project_root(os.getwd())
	}
	path := if os.is_abs_path(file) { file } else { os.join_path(os.getwd(), file) }
	return project_root(os.dir(path))
}

fn directory_prefix(root string) string {
	return if root == '/' { root } else { root + '/' }
}

fn command_output(root string, program string, args []string) !string {
	path := os.find_abs_path_of_executable(program)!
	mut child := os.new_process(path)
	defer { child.close() }
	child.set_work_folder(root)
	child.set_args(args)
	child.set_redirect_stdio()
	child.run()
	mut output := ''
	for child.is_alive() {
		output += child.stdout_read()
		_ = child.stderr_read()
		time.sleep(5 * time.millisecond)
	}
	output += child.stdout_slurp()
	child.wait()
	// ripgrep reports an empty file list with status 1.
	if child.code != 0 && !(program == 'rg' && child.code == 1) {
		return error('${program} could not list project files')
	}
	return output
}

fn project_candidates(root string) ! {
	output := list_project_files(root)!
	prefix := directory_prefix(root)
	for name in output.split('\x00') {
		// Kakoune's completion protocol accepts one candidate per line.
		if name != '' && !name.contains_any('\n\r') {
			println(prefix + name.trim_string_left('./'))
		}
	}
}

fn list_project_files(root string) !string {
	if _ := os.find_abs_path_of_executable('rg') {
		return command_output(root, 'rg', ['--files', '--hidden', '--glob', '!.git', '-0'])
	}
	git := command_output(root, 'git', ['rev-parse', '--is-inside-work-tree']) or { '' }
	return if git.trim_space() == 'true' {
		command_output(root, 'git',
			['ls-files', '-z', '--cached', '--others', '--exclude-standard'])!
	} else {
		command_output(root, 'find',
			['.', '-name', '.git', '-prune', '-o', '-type', 'f', '-print0'])!
	}
}

fn read_state(path string) !State {
	return json2.decode[State](os.read_file(path)!)!
}

fn write_state(path string, state State) ! {
	temporary := '${path}.tmp'
	os.write_file(temporary, json2.encode(state))!
	os.mv(temporary, path, overwrite: true)!
}

fn visible_entries(directory string, show_hidden bool) []Row {
	mut entries := []Row{}
	for name in os.ls(directory) or { return entries } {
		if name == '.git' || name.contains('\n') || name.contains('\r')
			|| (!show_hidden && name.starts_with('.')) {
			continue
		}
		path := os.join_path(directory, name)
		entries << Row{
			path:      path
			directory: os.is_dir(path) && !os.is_link(path)
		}
	}
	entries.sort_with_compare(fn (a &Row, b &Row) int {
		if a.directory != b.directory {
			return if a.directory { -1 } else { 1 }
		}
		return compare_strings(a.path.to_lower(), b.path.to_lower())
	})
	return entries
}

fn contains(items []string, target string) bool {
	return target in items
}

fn remove(mut items []string, target string) {
	index := items.index(target)
	if index >= 0 {
		items.delete(index)
	}
}

fn visit(directory string, depth int, mut state State, mut lines []string) {
	for entry in visible_entries(directory, state.hidden) {
		marker := if entry.directory {
			if contains(state.expanded, entry.path) { '▾' } else { '▸' }
		} else {
			' '
		}
		name := os.base(entry.path)
		suffix := if entry.directory { '/' } else { '' }
		lines << '${'  '.repeat(depth)}${marker} ${name}${suffix}'
		state.rows << entry
		if entry.path == state.focus {
			state.focus_line = state.rows.len
		}
		if entry.directory && contains(state.expanded, entry.path) {
			visit(entry.path, depth + 1, mut state, mut lines)
		}
	}
}

fn render(path string, origin string, pane bool) ! {
	mut state := read_state(path)!
	root := project_root(origin)
	if state.root != root {
		state = State{
			root:     root
			expanded: [root]
			hidden:   state.hidden
			focus:    root
		}
	}
	if !contains(state.expanded, root) {
		state.expanded << root
	}
	state.rows = [Row{}, Row{}, Row{}, Row{ path: root, directory: true }]
	state.focus_line = 4
	close_hint := if pane { 'q close pane' } else { 'q back' }
	mut lines := ['Project: ${root}',
		'${close_hint}  Enter open/toggle  l expand  h parent  p preview  . hidden  r refresh',
		'', '▾ ${os.base(root)}/']
	visit(root, 1, mut state, mut lines)
	write_state(path, state)!
	println(lines.join('\n'))
}

fn preview(target Row, hidden bool) string {
	if target.directory {
		return '${visible_entries(target.path, hidden).len} visible entries'
	}
	content := os.read_file(target.path) or { return err.msg() }
	mut lines := []string{}
	for line in content.split_into_lines() {
		if lines.len == 24 {
			break
		}
		lines << line.replace('\t', '    ').limit(140)
	}
	return lines.join('\n').replace('\x00', '')
}

fn action(path string, line int, verb string) ! {
	mut state := read_state(path)!
	if line < 1 || line > state.rows.len || state.rows[line - 1].path == '' {
		println("echo 'Choose a file or directory'")
		return
	}
	item := state.rows[line - 1]
	if verb == 'preview' {
		body := preview(item, state.hidden)
		println('info -title ${kak_quote(os.base(item.path))} ${kak_quote(if body == '' {
			'(empty file)'
		} else {
			body
		})}')
		return
	}
	if !item.directory {
		if verb in ['open', 'expand'] {
			println('edit -existing -- ${kak_quote(item.path)}')
		}
		return
	}
	mut target := item.path
	if verb == 'open' {
		if contains(state.expanded, target) && target != state.root {
			remove(mut state.expanded, target)
		} else if !contains(state.expanded, target) {
			state.expanded << target
		}
	} else if verb == 'expand' {
		if !contains(state.expanded, target) {
			state.expanded << target
		}
	} else if verb == 'collapse' {
		if contains(state.expanded, target) && target != state.root {
			remove(mut state.expanded, target)
		} else {
			target = os.dir(target)
		}
	}
	state.focus = target
	write_state(path, state)!
	println('v-tree-refresh')
}

fn run() ! {
	if os.args.len < 3 {
		return error('Usage: explorer COMMAND STATE [ARG...]')
	}
	command := os.args[1]
	path := os.args[2]
	match command {
		'init' {
			root := tree_root(os.args[3])
			write_state(path, State{ root: root, expanded: [root], focus: root })!
		}
		'prompt' {
			root := kak_quote(directory_prefix(buffer_root(path)))
			println("prompt -file-completion -init ${root} 'Project path: ' %{ edit -existing -- %val{text} }")
		}
		'candidates' {
			project_candidates(buffer_root(path))!
		}
		'render' {
			render(path, os.args[3], os.args.len > 4 && os.args[4] == 'true')!
		}
		'focus' {
			state := read_state(path)!
			println('select ${state.focus_line}.1,${state.focus_line}.1')
		}
		'action' {
			action(path, os.args[3].int(), os.args[4])!
		}
		'hidden' {
			mut state := read_state(path)!
			state.hidden = !state.hidden
			write_state(path, state)!
			println('v-tree-refresh')
		}
		'cleanup' {
			os.rm(path) or {}
		}
		else {
			return error('Unknown explorer command: ${command}')
		}
	}
}

fn main() {
	run() or {
		eprintln(err.msg())
		exit(1)
	}
}
