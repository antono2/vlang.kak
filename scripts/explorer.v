// Maintains the project-tree view and translates selections into Kakoune commands.
module main

import x.json2
import os
import projectroot
import rand
import time

const search_preview_lines = 12
const search_preview_columns = 140
const file_preview_lines = 24
const file_preview_columns = 140
const process_poll_interval = 5 * time.millisecond
// Three header lines precede the root in the one-based tree buffer.
const root_display_line = 4
const default_grep_command = 'grep -RHn'
const tree_directory_prefix = 'vlang-kak-tree-'
const tree_state_name = 'tree.json'

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
	focus_line int = root_display_line
}

fn kak_quote(value string) string {
	return "'${value.replace("'", "''")}'"
}

fn tree_root(origin string) string {
	mut path := if origin == '' { os.getwd() } else { os.expand_tilde_to_home(origin) }
	if !os.is_dir(path) {
		path = os.dir(path)
	}
	return projectroot.find(os.real_path(path))
}

fn buffer_root(file string) string {
	if file == '' {
		return projectroot.find(os.getwd())
	}
	path := if os.is_abs_path(file) { file } else { os.join_path(os.getwd(), file) }
	return projectroot.find(os.dir(path))
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
		time.sleep(process_poll_interval)
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

struct SearchPreview {
mut:
	lines []string
	line  string
}

fn (mut preview SearchPreview) append(chunk string) {
	parts := chunk.split('\n')
	for index, part in parts {
		// A UTF-8 character occupies at most four bytes. Bound the partial
		// line even when a match in a generated file spans many read blocks.
		remaining := search_preview_columns * 4 - preview.line.len
		preview.line += if part.len > remaining { part[..remaining] } else { part }
		if index == parts.len - 1 {
			break
		}
		preview.finish_line()
		if preview.lines.len == search_preview_lines {
			break
		}
	}
}

fn (mut preview SearchPreview) finish_line() {
	preview.lines << preview.line.trim_right('\r').limit(search_preview_columns)
	preview.line = ''
}

fn preview_matches(root string, pattern string) ![]string {
	rg := os.find_abs_path_of_executable('rg') or { '' }
	path := if rg != '' { rg } else { os.find_abs_path_of_executable('grep')! }
	mut args := if rg != '' {
		['-n', '--no-heading', '--color', 'never']
	} else {
		['-RHn', '--exclude-dir=.git']
	}
	mut child := os.new_process(path)
	defer { child.close() }
	child.set_work_folder(root)
	args << ['-e', pattern, '.']
	child.set_args(args)
	child.set_redirect_stdio()
	child.run()
	mut matches := SearchPreview{}
	for child.is_alive() {
		chunk := child.stdout_read()
		matches.append(chunk)
		_ = child.stderr_read()
		if matches.lines.len == search_preview_lines {
			child.signal_term()
			child.wait()
			return matches.lines
		}
		if chunk == '' {
			time.sleep(process_poll_interval)
		}
	}
	matches.append(child.stdout_slurp())
	child.wait()
	if matches.line != '' && matches.lines.len < search_preview_lines {
		matches.finish_line()
	}
	return matches.lines
}

fn project_search(root string, mode string, pattern string, grepcmd string) ! {
	match mode {
		'preview' {
			if pattern == '' {
				println("info -title 'Project search' 'Type a pattern; Enter opens all results'")
				return
			}
			lines := preview_matches(root, pattern) or { []string{} }
			message := if lines.len == 0 { 'No matches yet' } else { lines.join('\n') }
			println("info -title 'Project search · Enter for all' ${kak_quote(message)}")
		}
		'results' {
			if pattern == '' {
				return
			}
			if grepcmd == default_grep_command {
				command := if _ := os.find_abs_path_of_executable('rg') {
					'rg -n --no-heading'
				} else {
					'grep -RHn --exclude-dir=.git'
				}
				println('set-option window grepcmd ${kak_quote(command)}')
			}
			println('grep -e ${kak_quote(pattern)} ${kak_quote(root)}')
			if grepcmd == default_grep_command {
				println('unset-option window grepcmd')
			}
		}
		else {
			return error('Expected search mode preview or results')
		}
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

fn begin_tree(origin string, client string) ! {
	root := tree_root(origin)
	directory := os.join_path(os.temp_dir(), tree_directory_prefix + rand.uuid_v4())
	os.mkdir(directory, mode: 0o700)!
	path := os.join_path(directory, tree_state_name)
	write_state(path, State{ root: root, expanded: [root], focus: root }) or {
		os.rm(path + '.tmp') or {}
		os.rmdir(directory) or {}
		return err
	}
	println('v-tree-install ${kak_quote('*v-tree-' + client + '*')} ${kak_quote(path)} ${kak_quote(origin)}')
}

fn cleanup_tree(path string) {
	os.rm(path) or {}
	directory := os.dir(path)
	if os.file_name(path) == tree_state_name
		&& os.file_name(directory).starts_with(tree_directory_prefix) {
		os.rmdir(directory) or {}
	}
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

fn render(path string, origin string, pane bool) !(string, int) {
	mut state := read_state(path)!
	root := projectroot.find(origin)
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
	state.focus_line = root_display_line
	close_hint := if pane { 'q close pane' } else { 'q back' }
	mut lines := ['Project: ${root}',
		'${close_hint}  Enter open/toggle  l expand  h parent  p preview  . hidden  r refresh',
		'', '▾ ${os.base(root)}/']
	visit(root, 1, mut state, mut lines)
	write_state(path, state)!
	return lines.join('\n'), state.focus_line
}

fn preview(target Row, hidden bool) string {
	if target.directory {
		return '${visible_entries(target.path, hidden).len} visible entries'
	}
	content := os.read_file(target.path) or { return err.msg() }
	mut lines := []string{}
	for line in content.split_into_lines() {
		if lines.len == file_preview_lines {
			break
		}
		lines << line.replace('\t', '    ').limit(file_preview_columns)
	}
	return lines.join('\n').replace('\x00', '')
}

fn action(path string, line int, verb string, client string) ! {
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
			command := 'edit -existing -- ${kak_quote(item.path)}'
			if verb == 'open' && client != '' {
				println('evaluate-commands -client ${kak_quote(client)} ${kak_quote(command)}')
			} else {
				println(command)
			}
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
		'begin-tree' {
			client := os.args[3] or { return error('Expected a Kakoune client') }
			begin_tree(path, client)!
		}
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
		'search' {
			if os.args.len != 6 {
				return error('Usage: explorer search BUFFER MODE PATTERN GREPCMD')
			}
			project_search(buffer_root(path), os.args[3], os.args[4], os.args[5])!
		}
		'render', 'render-tree' {
			origin := os.args[3] or { return error('Expected a tree origin') }
			content, line := render(path, origin, os.args.len > 4 && os.args[4] == 'true')!
			if command == 'render-tree' {
				println('v-tree-install-content ${kak_quote(content)}')
				println('select ${line}.1,${line}.1')
			} else {
				println(content)
			}
		}
		'focus' {
			state := read_state(path)!
			println('select ${state.focus_line}.1,${state.focus_line}.1')
		}
		'action' {
			line := os.args[3] or { return error('Expected a tree row') }
			verb := os.args[4] or { return error('Expected a tree action') }
			client := if os.args.len > 6 && os.args[5] == 'true' { os.args[6] } else { '' }
			action(path, line.int(), verb, client)!
		}
		'hidden' {
			mut state := read_state(path)!
			state.hidden = !state.hidden
			write_state(path, state)!
			println('v-tree-refresh')
		}
		'cleanup' {
			cleanup_tree(path)
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
