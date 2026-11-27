// Render context-sensitive Kakoune menus and the debugger modeline status.
module main

import crypto.sha256
import io
import os
import projectroot
import time
import windowhost

const active_phases = ['building', 'starting', 'running', 'stopped']
const idle_phases = ['idle', 'failed', 'exited']
const debug_status_suffix = '  [debug: %opt{v_debug_phase}]'
const results_types = ['lsp-document-symbol', 'lsp-goto', 'lsp-diagnostics', 'grep']
const context_types = ['v', 'v-tree', 'v-doc', 'v-recovery', 'v-debug-stack', 'v-debug-variables',
	'v-debug-output', 'v-debug-breakpoints']

struct Editor {
	filetype        string
	buffer          string
	file            string
	previous        string
	doc_origin      string
	results_origin  string
	explorer        bool
	tree_pane       bool
	pane_mode       string
	backend         string
	context_keys    bool
	task_output     bool
	task_available  bool
	last_test       bool
	has_lsp         bool
	readonly        bool
	modified        bool
	restart         bool
	managed         bool
	debug_phase     string
	debug_source    bool
	debug_directory bool
	debug_enabled   bool
	debug_adapter   string
	debug_build     bool
	debug_watches   bool
}

struct Commands {
mut:
	lines []string
}

fn option(name string) string {
	return os.getenv('kak_opt_' + name)
}

fn enabled(name string) bool {
	return option(name) == 'true'
}

fn read_editor(clients int) Editor {
	phase := option('v_debug_phase')
	return Editor{
		filetype:        option('filetype')
		buffer:          os.getenv('kak_bufname')
		file:            os.getenv('kak_buffile')
		previous:        option('v_keys_context')
		doc_origin:      option('v_doc_origin')
		results_origin:  option('v_results_origin')
		explorer:        enabled('v_explorer_enabled')
		tree_pane:       enabled('v_tree_is_pane')
		pane_mode:       option('v_pane_mode')
		backend:         option('v_window_backend')
		context_keys:    option('v_context_keys') != 'false'
		task_output:     enabled('v_task_output')
		task_available:  enabled('v_task_available')
		last_test:       option('v_last_test_command') != ''
		has_lsp:         option('v_menu_lsp') == 'nop'
		readonly:        enabled('readonly')
		modified:        os.getenv('kak_modified') != 'false'
		restart:         os.getenv('VLANG_KAK_RESTART_ALLOWED') == '1' && clients == 1
			&& phase !in active_phases
		managed:         os.getenv('VLANG_KAK_PREFIX') != ''
		debug_phase:     phase
		debug_source:    enabled('v_debug_source')
		debug_directory: option('v_debug_directory') != ''
		debug_enabled:   enabled('v_debug_enabled')
		debug_adapter:   option('v_debug_adapter')
		debug_build:     option('v_debug_build') != 'false'
		debug_watches:   enabled('v_debug_has_watches')
	}
}

fn (editor Editor) context() string {
	if editor.filetype == 'grep' && !enabled('v_search_results') {
		return ''
	}
	if os.file_name(editor.file) == 'v.mod'
		|| (editor.buffer == '*project*' && option('v_workspace_root') != '') {
		return 'v-project'
	}
	if editor.buffer == '*hover*' && editor.doc_origin != '' {
		return 'v-doc'
	}
	if editor.filetype in context_types || editor.filetype == 'make'
		|| editor.filetype in results_types {
		return editor.filetype
	}
	return if editor.debug_source && editor.debug_phase in active_phases {
		'debug-source'
	} else {
		''
	}
}

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn (mut out Commands) bind(mode string, key string, command string, label string) {
	out.lines << 'map -docstring ' + quote(label) + ' -- window ' + mode + ' ' + quote(key) + ' ' +
		quote(':' + command + '<ret>')
}

fn (mut out Commands) user(key string, command string, label string) {
	out.bind('user', key, command, label)
}

fn (mut out Commands) unmap(mode string, keys []string) {
	for key in keys {
		out.lines << 'try %{ unmap -- window ' + mode + ' ' + quote(key) + ' }'
	}
}

fn tracked(file string) bool {
	git := os.find_abs_path_of_executable('git') or { return false }
	mut child := os.new_process(git)
	defer { child.close() }
	child.set_args(['--literal-pathspecs', '-C', os.dir(file), 'ls-files', '--error-unmatch', '--',
		os.file_name(file)])
	child.set_redirect_stdio()
	child.run()
	for child.is_alive() {
		_ = child.stdout_read()
		_ = child.stderr_read()
		time.sleep(time.millisecond)
	}
	child.wait()
	return child.code == 0
}

fn saved_test(file string, modified bool) bool {
	if modified || !file.ends_with('_test.v') {
		return false
	}
	mut source := os.open(file) or { return false }
	defer { source.close() }
	mut lines := io.new_buffered_reader(reader: source)
	for {
		line := lines.read_line() or { return false }
		if projectroot.test_name(line) != '' {
			return true
		}
	}
	return false
}

fn (editor Editor) source_keys(mut out Commands, saved bool) {
	backend := windowhost.detect(editor.backend) or { 'none' }
	has_pane := backend != 'none' && editor.pane_mode != 'off'
	out.lines << 'v-default-source-keys'
	if !editor.explorer {
		out.user('F', 'v-project-path', 'Open project path…')
	}
	if !has_pane {
		out.user('g', 'v-peek-definition', 'Open documentation (peek fallback)')
	}
	if !editor.context_keys {
		return
	}
	if !has_pane {
		out.unmap('user', ['g'])
	}
	if backend == 'none' {
		out.unmap('user', ['w'])
	}
	if !editor.task_available {
		out.unmap('user', ['[', ']'])
	}
	history := saved && tracked(editor.file)
	if !editor.has_lsp || editor.file == '' {
		out.unmap('user', ['d', 'g', 'r', 'R', 'a', 'o', 'h', 'H', '(', 's', 'S', 'e', 'n', 'N'])
		out.unmap('v-investigation', ['c', 'D', 'i', 'm', 'z', 'j', 'k', 'l'])
		if !history {
			out.unmap('user', ['i'])
		}
		out.user('f', 'v-fmt', 'Format and save with V')
	}
	if editor.readonly || editor.file == '' {
		out.unmap('user', ['R', 'a', 'o', 'f'])
	}
	if !saved {
		out.unmap('user', ['b', 't', 'u'])
		out.unmap('v-testing', ['C', 't', 'T', 'v'])
	}
	if saved && saved_test(editor.file, editor.modified) {
		out.user('T', 'v-test-nearest', 'Test at cursor')
		if editor.last_test {
			out.user('x', 'v-repeat-test', 'Rerun last test')
		}
	} else {
		out.unmap('v-testing', ['T'])
	}
	if !editor.last_test {
		out.unmap('v-testing', ['x'])
	}
	if !history {
		out.unmap('v-investigation', ['V'])
	}
	if !editor.restart {
		out.unmap('v-maintenance', ['u', 'r', 'v'])
	}
	if !editor.managed {
		out.unmap('v-maintenance', ['b', 'f', 'c', 'C', 'x', 'R'])
	}
}

fn (editor Editor) tree_keys(mut out Commands) {
	out.user('<ret>', 'v-tree-action open', 'Open file or toggle directory')
	out.user('l', 'v-tree-action expand', 'Expand directory')
	out.user('h', 'v-tree-action collapse', 'Collapse directory or move to parent')
	out.user('p', 'v-tree-action preview', 'Preview file')
	out.user('.', 'v-tree-hidden', 'Toggle hidden files')
	out.user('r', 'v-tree-refresh', 'Refresh project tree')
	label := if editor.tree_pane { 'Close tree pane' } else { 'Return to source' }
	out.user('q', 'v-tree-close', label)
}

fn (editor Editor) task_keys(mut out Commands) {
	out.user('r', 'v-repeat-task', 'Rerun this task')
	out.user('q', 'v-task-return', 'Return to source')
	out.user('<ret>', 'make-jump', 'Open location on this line')
	out.user(']', 'v-next-task-error', 'Next task error')
	out.user('[', 'v-previous-task-error', 'Previous task error')
	if editor.last_test {
		out.user('x', 'v-repeat-test', 'Rerun last test')
	}
}

fn (mut out Commands) debug_panel(filetype string) {
	out.user('q', 'v-debug-return', 'Return to debug source')
	label := match filetype {
		'v-debug-stack' { 'Open selected stack frame' }
		'v-debug-variables' { 'Expand selected value' }
		'v-debug-breakpoints' { 'Open breakpoint source' }
		else { '' }
	}

	if label != '' {
		out.user('<ret>', 'v-debug-select', label)
	}
}

fn (mut out Commands) result_keys() {
	out.user('n', 'v-results-next', 'Next result')
	out.user('N', 'v-results-previous', 'Previous result')
	out.user('q', 'v-results-cancel', 'Return to source')
 out.user('<ret>', 'v-results-open', 'Open selected result')
}

fn (editor Editor) debug_keys(mut out Commands, saved bool) {
	phase := editor.debug_phase
	is_active := phase in active_phases
	mode := if is_active || editor.filetype.starts_with('v-debug-')
		|| (editor.debug_source && editor.filetype != 'v') {
		'user'
	} else {
		'v-debug'
	}
	first := out.lines.len
	if mode == 'user' && editor.debug_enabled && editor.debug_directory && phase in idle_phases {
		out.bind(mode, 'B', 'v-debug', 'Relaunch debugger')
	}
	if editor.debug_enabled && !editor.modified && editor.filetype == 'v' && saved
		&& windowhost.available(editor.debug_adapter) {
		if phase != 'running' {
			out.bind(mode, '!', 'v-debug-breakpoint', 'Toggle breakpoint')
		}
		out.bind(mode, 'Y', 'v-debug-breakpoints', 'Breakpoints')
		if phase in idle_phases {
			label := if editor.file.ends_with('_test.v') {
				'Debug V test'
			} else if editor.debug_build {
				'Build and debug'
			} else {
				'Debug executable'
			}
			out.bind(mode, 'B', 'v-debug', label)
		}
	}
	if is_active {
		out.bind(mode, 'Z', 'v-debug-stop', 'Stop debugging')
	}
	if is_active || editor.debug_directory {
		out.bind(mode, 'Q', 'v-debug-output', 'Program and debugger output')
	}
	match phase {
		'stopped' {
			out.bind(mode, 'E', 'v-debug-continue', 'Continue debugging')
			out.bind(mode, 'O', 'v-debug-next', 'Step over')
			out.bind(mode, 'I', 'v-debug-step-in', 'Step into')
			out.bind(mode, 'A', 'v-debug-step-out', 'Step out')
			if saved && !editor.modified && !editor.readonly {
				out.bind(mode, 'G', 'v-debug-run-to-cursor', 'Run to cursor')
			}
			out.bind(mode, 'M', 'v-debug-stack', 'Stack frames')
			out.bind(mode, 'L', 'v-debug-variables', 'Variables and watches')
			out.bind(mode, '?', 'v-debug-evaluate', 'Evaluate expression')
			out.bind(mode, 'W', 'v-debug-watch', 'Add watch…')
			if editor.debug_watches {
				out.bind(mode, '-', 'v-debug-unwatch', 'Remove watch')
			}
			out.bind(mode, ':', 'v-debug-console', 'Debugger command')
		}
		'running' {
			out.bind(mode, 'K', 'v-debug-pause', 'Pause debugging')
			out.bind(mode, 'J', 'v-debug-input', 'Send program input')
			if editor.filetype == 'v-debug-output' {
				out.bind(mode, '<ret>', 'v-debug-input', 'Send program input')
			}
		}
		else {}
	}

	if mode == 'v-debug' && out.lines.len != first {
		out.user('B', 'v-debug-menu', 'Debugging…')
	}
}

fn (editor Editor) commands(context string) []string {
	mut out := Commands{}
	saved := editor.file != '' && os.is_file(editor.file)
	hook := match context {
		'v-project' {
			out.user('p', 'v-files', 'Open file by path')
			out.user('P', 'v-project-files', 'Find project file')
			out.user('F', 'v-project-path',
				if editor.explorer { 'Open project explorer' } else { 'Open project path…' })
			out.user('/', 'v-search', 'Search project text')
			if saved {
				out.user('b', 'v-build', 'Build project')
				out.user('u', 'v-run-project', 'Run project')
				out.user('t', 'v-testing-menu', 'Testing')
				out.bind('v-testing', 't', 'v-test', 'Test project')
			}
			out.user('U', 'v-maintenance-menu', 'Maintenance')
			out.lines << 'v-default-maintenance-keys'
			if !editor.restart { out.unmap('v-maintenance', ['u', 'r', 'v']) }
			if !editor.managed { out.unmap('v-maintenance', ['b', 'f', 'c', 'C', 'x', 'R']) }
			'VProjectKeysApplied'
		}
		'v' {
			editor.source_keys(mut out, saved)
			'VKeysApplied'
		}
		'v-tree' {
			editor.tree_keys(mut out)
			'VTreeKeysApplied'
		}
		'v-doc' {
			out.user('q', 'v-doc-return', 'Return to source')
			out.bind('normal', 'q', 'v-doc-return', 'Return to source')
			out.bind('normal', '<esc>', 'v-doc-return', 'Return to source')
			'VDocKeysApplied'
		}
		'v-recovery' {
			out.user('q', 'v-recovery-close', 'Close recovered output buffer')
			out.bind('normal', 'q', 'v-recovery-close', 'Close recovered output buffer')
			'VResultsKeysApplied'
		}
		'v-debug-stack', 'v-debug-variables', 'v-debug-breakpoints', 'v-debug-output' {
			out.debug_panel(context)
			'VDebugKeysApplied'
		}
		'debug-source' {
			'VDebugKeysApplied'
		}
		'make' {
			editor.task_keys(mut out)
			'VTaskKeysApplied'
		}
		else {
			out.result_keys()
			'VResultsKeysApplied'
		}
	}

	if !editor.last_test && (context != 'v' || editor.context_keys) {
		out.unmap('user', ['x'])
	}
	editor.debug_keys(mut out, saved)
	out.lines << 'trigger-user-hook ' + hook
	return out.lines
}

fn (editor Editor) render_debug_status() {
	show := enabled('v_debug_status') && editor.debug_phase in active_phases
		&& (editor.filetype == 'v' || editor.filetype.starts_with('v-debug-')
		|| editor.debug_source)
	if show == enabled('v_debug_status_visible') {
		return
	}
	if show {
		println('set-option -add window modelinefmt ' + quote(debug_status_suffix))
	} else {
		current := option('modelinefmt')
		if current.contains(debug_status_suffix) {
			println('set-option window modelinefmt ' +
				quote(current.replace_once(debug_status_suffix, '')))
		}
	}
	println('set-option window v_debug_status_visible ' + show.str())
}

fn main() {
	editor := read_editor(os.args.len - 1)
	editor.render_debug_status()
	context := editor.context()
	if context == '' || (context == 'make' && !editor.task_output) {
		if editor.previous != '' || context == 'make' {
			println("v-unbind-keys\nset-option window v_keys_context ''")
		}
		return
	}
	if context in results_types && editor.results_origin == '' {
		return
	}
	commands := editor.commands(context).join('\n')
	// Include the observable context even when all resulting mappings match.
	// The user hook can use the original readonly and modified state.
	state := [context, editor.doc_origin, editor.pane_mode, editor.readonly.str(),
		editor.modified.str(), editor.debug_phase, editor.debug_watches.str()].join('\x00')
	signature := sha256.hexhash(state + '\x00' + commands)
	if signature == editor.previous {
		return
	}
	println('v-unbind-keys')
	println('set-option window v_keys_context ' + quote(signature))
	println(commands)
}
