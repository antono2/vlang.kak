// Exercise VLS features through the installed Kakoune launcher and its JSON UI.
module liveeditor

import editorui { quote }
import os
import time

const response_timeout = 15 * time.second
const edit_timeout = 20 * time.second
const format_timeout = 30 * time.second
const poll_interval = 100 * time.millisecond
// Kakoune's selections are one-based. These address the declaration and call
// in the live protocol fixture.
const call_cursor = '9.15,9.15'
const hover_cursor = '9.16,9.16'
const signature_cursor = '9.22,9.22'
const callee_cursor = '4.5,4.5'
const caller_cursor = '8.5,8.5'
const clean = 'module main\nfn broken() int { return 1 }\n'
const unformatted = 'module main\nfn format_probe(){println(1)}\n'

struct Check {
	root      string
	main_file string
mut:
	editor &editorui.Client
}

fn (mut check Check) command(command string) ! {
	check.editor.remote(command)!
}

fn (mut check Check) select_source(cursor string, command string) ! {
	check.command('buffer ${quote(check.main_file)}\nselect ${cursor}\n${command}')!
}

fn (mut check Check) mapped(keys string) ! {
	check.command('execute-keys -with-hooks -with-maps ${keys}')!
}

fn (mut check Check) wait_location(buffer string, line int, column int, require_results bool) ! {
	identity_path := os.join_path(check.root, 'navigation-buffer')
	position_path := os.join_path(check.root, 'navigation')
	identity := if os.is_abs_path(buffer) { '%val{buffile}' } else { '%val{bufname}' }
	deadline := time.sys_mono_now() + u64(response_timeout)
	for time.sys_mono_now() < deadline {
		check.command('echo -to-file ${quote(identity_path)} ${identity}\necho -to-file ${quote(position_path)} %val{cursor_line} %val{cursor_column} %opt{modelinefmt}')!
		fields := os.read_file(position_path)!.split_nth(' ', 3)
		if fields.len == 3 && os.read_file(identity_path)!.trim_space() == buffer
			&& (line == 0 || fields[0].int() == line) && (column == 0 || fields[1].int() == column)
			&& (!require_results || fields[2].contains('Tab/S-Tab browse')) {
			return
		}
		time.sleep(poll_interval)
	}
	return check.editor.diagnostic('Timed out waiting for ${buffer} at ${line}:${column}')
}

fn (mut check Check) wait_text(command string, needles []string, timeout time.Duration, draft bool) ! {
	path := os.join_path(check.root, 'selection')
	deadline := time.sys_mono_now() + u64(timeout)
	for time.sys_mono_now() < deadline {
		if os.is_file(path) {
			os.rm(path)!
		}
		read_selection := '${command}\necho -to-file ${quote(path)} %val{selection}'
		check.editor.remote_allow_error(if draft {
			'evaluate-commands -draft %{\n${read_selection}\n}'
		} else {
			read_selection
		})!
		selection := os.read_file(path) or { '' }
		if needles.all(selection.contains(it)) {
			return
		}
		time.sleep(poll_interval)
	}
	return check.editor.diagnostic('Timed out waiting for editor text: ${needles.join(', ')}')
}

fn (mut check Check) wait_buffer(buffer string, needles []string, timeout time.Duration) ! {
	check.wait_text('buffer ${quote(buffer)}\nexecute-keys <percent>', needles, timeout, false)!
}

fn (mut check Check) check_symbols() ! {
	check.select_source(call_cursor, 'v-symbols')!
	check.wait_location('*goto*', 0, 0, true)!
	check.mapped('gg<tab>')!
	check.wait_location('*goto*', 2, 0, false)!
	check.mapped('<space>n')!
	check.wait_location('*goto*', 3, 0, false)!
	check.mapped('<space>N')!
	check.wait_location('*goto*', 2, 0, false)!
	check.mapped('<space><ret>')!
	check.wait_location(check.main_file, 4, 0, false)!
	for cancel in ['<esc>', 'q', '<space>q'] {
		check.select_source(call_cursor, 'v-symbols')!
		check.wait_location('*goto*', 0, 0, true)!
		check.mapped('<tab>' + cancel)!
		check.wait_location(check.main_file, 9, 15, false)!
	}
	check.command('v-workspace-symbols\nexecute-keys -with-hooks -with-maps add<ret>')!
	check.wait_location('*symbols*', 1, 0, true)!
	check.wait_text('execute-keys <percent>', ['add (Function)'], response_timeout, true)!
	check.mapped('<tab><ret>')!
	check.wait_location(check.main_file, 4, 0, false)!
	check.select_source(call_cursor, 'v-workspace-symbols\nexecute-keys vlang_no_such_symbol_725<ret>')!
	check.wait_location('*symbols*', 1, 0, true)!
	check.mapped('<tab>q')!
	check.wait_location(check.main_file, 9, 15, false)!
}

fn (mut check Check) check_hover() ! {
	hover_offset := check.editor.offset()
	check.select_source(hover_cursor, 'v-hover')!
	check.editor.wait_event(hover_offset, 'info_show', ['fn add(left', 'Adds two values.'])!
	signature_offset := check.editor.offset()
	check.select_source(signature_cursor, 'v-signature')!
	check.editor.wait_info(signature_offset, 'right int')!
	check.select_source(hover_cursor, 'v-doc')!
	check.wait_buffer('*hover*', ['fn add(left int, right int) int', 'Adds two values.'], response_timeout)!
	check.wait_location('*hover*', 0, 0, false)!
	for cancel in ['q', '<esc>', '<space>q'] {
		if cancel != 'q' {
			check.select_source(hover_cursor, 'v-doc')!
			check.wait_location('*hover*', 0, 0, false)!
		}
		baseline := check.editor.offset()
		check.mapped('<space>')!
		check.editor.wait_info(baseline, 'Return to source')!
		check.command('execute-keys <esc>')!
		check.mapped(cancel)!
		check.wait_location(check.main_file, 9, 16, false)!
	}
}

fn (mut check Check) check_navigation(source string) ! {
	check.select_source(call_cursor, 'v-select-syntax')!
	check.editor.wait_value('%opt{lsp_selection_range_selected}', '1', false, 'Kakoune syntax selection range')!
	check.command('execute-keys <esc>\nselect ${call_cursor}\nv-highlight-references')!
	check.select_source(call_cursor, 'v-definition')!
	check.wait_location(check.main_file, 4, 0, false)!
	check.select_source(callee_cursor, 'v-incoming-calls')!
	check.wait_buffer('*callers*', ['main'], response_timeout)!
	check.select_source(caller_cursor, 'v-outgoing-calls')!
	check.wait_buffer('*callees*', ['add'], response_timeout)!
	check.select_source(call_cursor, 'v-rename-to sum_values')!
	check.wait_buffer(check.main_file, ['fn sum_values(left int, right int) int',
		'result := sum_values(1, 2)'], edit_timeout)!
	check.unchanged(check.main_file, source, 'rename')!
}

fn (check Check) unchanged(path string, expected string, label string) ! {
	if os.read_file(path)! != expected {
		return error('Kakoune saved the ${label} probe unexpectedly')
	}
}

fn (mut check Check) check_edits(imports string) ! {
	imports_file := os.join_path(check.root, 'imports.v')
	os.write_file(imports_file, imports)!
	baseline := check.editor.offset()
	check.command('edit -- ${quote(imports_file)}\nv-organize-imports')!
	check.editor.wait_event(baseline, 'menu_show', ['Organize Imports'])!
	check.command('execute-keys <ret>')!
	check.wait_buffer(imports_file, ['import math\nimport os'], edit_timeout)!
	check.unchanged(imports_file, imports, 'organize imports')!

	broken_file := os.join_path(check.root, 'broken.v')
	os.write_file(broken_file, clean)!
	check.command("edit -- ${quote(broken_file)}\nset-register v %{'wrong'}\nselect 2.26,2.26\nexecute-keys -with-hooks c<c-r>v<esc>")!
	check.wait_text('buffer ${quote(broken_file)}\nv-diagnostics\nbuffer *diagnostics*\nexecute-keys <percent>',
		['cannot use'], edit_timeout, false)!
	check.unchanged(broken_file, clean, 'diagnostic')!

	format_file := os.join_path(check.root, 'format.v')
	os.write_file(format_file, unformatted)!
	check.command('edit -- ${quote(format_file)}\nv-format')!
	check.wait_buffer(format_file, ['fn format_probe() {'], format_timeout)!
	check.unchanged(format_file, unformatted, 'formatting')!
}

fn (mut check Check) run(source string, imports string) ! {
	filetype := check.editor.value('%opt{filetype}')!
	if filetype != 'v' {
		return error('V source detected as ${filetype}; check filetype hook precedence')
	}
	check.check_symbols()!
	check.check_hover()!
	check.check_navigation(source)!
	check.check_edits(imports)!
}

pub fn run(kak string, launcher string, root string, source string, imports string) ! {
	main_file := os.join_path(root, 'main.v')
	mut editor := editorui.open_managed(kak, launcher, root, main_file)!
	mut check := Check{
		root:      root
		main_file: main_file
		editor:    editor
	}
	check.run(source, imports) or {
		editor.remote('evaluate-commands -buffer *debug* %{ write -force ${quote(os.join_path(root, 'editor-debug'))} }') or {}
		editor.close()
		editor.save_artifacts() or {}
		return err
	}
	editor.close()
	editor.save_artifacts()!
	println('ok - Kakoune symbol browsing, hover, syntax, navigation, calls, rename, imports, diagnostics, formatting')
}
