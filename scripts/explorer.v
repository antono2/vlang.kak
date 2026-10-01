module main

import x.json2
import os

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

fn project_root(origin string) string {
	mut path := if origin == '' { os.getwd() } else { os.expand_tilde_to_home(origin) }
	if !os.is_dir(path) {
		path = os.dir(path)
	}
	mut directory := os.real_path(path)
	for {
		if os.is_file(os.join_path(directory, 'v.mod')) || os.exists(os.join_path(directory,
			'.git')) {
			return directory
		}
		parent := os.dir(directory)
		if parent == directory {
			return os.real_path(path)
		}
		directory = parent
	}
	return os.real_path(path)
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
		entries << Row{ path: path, directory: os.is_dir(path) && !os.is_link(path) }
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
		state = State{ root: root, expanded: [root], hidden: state.hidden, focus: root }
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
			root := project_root(os.args[3])
			write_state(path, State{ root: root, expanded: [root], focus: root })!
		}
		'render' { render(path, os.args[3], os.args.len > 4 && os.args[4] == 'true')! }
		'focus' {
			state := read_state(path)!
			println('select ${state.focus_line}.1,${state.focus_line}.1')
		}
		'action' { action(path, os.args[3].int(), os.args[4])! }
		'hidden' {
			mut state := read_state(path)!
			state.hidden = !state.hidden
			write_state(path, state)!
			println('v-tree-refresh')
		}
		'cleanup' { os.rm(path) or {} }
		else { return error('Unknown explorer command: ${command}') }
	}
}

fn main() {
	run() or {
		eprintln(err.msg())
		exit(1)
	}
}
