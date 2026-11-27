// Check visible feedback while requests have not produced any editor response.
import editorui { quote }
import os
import rand
import releasetest { capture }

fn check(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-feedback-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	config := os.join_path(root, 'config', 'kak')
	os.mkdir_all(config)!
	plugin := os.join_path(os.dir(@DIR), 'rc', 'vlang.kak')
	os.write_file(os.join_path(config, 'kakrc'), 'source ${quote(plugin)}\n' +
		'declare-option str lsp_progress_indicator ""\ndeclare-option str lsp_modeline_progress ""\n' +
		'define-command lsp-references %{ nop }\n')!
	file := os.join_path(root, 'main.v')
	os.write_file(file, 'module main\nfn main() {}\n')!
	os.setenv('XDG_CACHE_HOME', os.join_path(root, 'cache'), true)
	helper := os.join_path(os.dir(@DIR), 'scripts', 'helper-cache.sh')
	for tool in ['context', 'navigation', 'preferences'] {
		capture(helper, [tool, '--prepare'], true)!
	}
	mut editor := editorui.open(kak, root, file)!
	defer { editor.close() }
	mut offset := editor.offset()
	editor.remote('v-references')!
	editor.wait_event(offset, 'draw_status', ['Finding references', 'results may take a moment'])!
	assert editor.value('%val{buffile}')! == file
	editor.remote('set-option window modelinefmt custom\nv-lsp-progress-install')!
	offset = editor.offset()
	editor.remote("set-option global lsp_modeline_progress 'indexing'")!
	editor.wait_event(offset, 'draw_status', ['custom', 'VLS working'])!
	assert editor.value('%opt{v_lsp_progress}')! == '[VLS working]'
	editor.remote("set-option global lsp_modeline_progress ''")!
	assert editor.value('%opt{v_lsp_progress}')! == ''
	assert editor.value('%opt{modelinefmt}')! == 'custom %opt{v_lsp_progress}'
	editor.remote('set-option global v_lsp_feedback false')!
	offset = editor.offset()
	editor.remote('echo quiet\nv-references\nset-option global lsp_modeline_progress indexing')!
	assert !editor.transcript(offset).contains('Finding references')
	assert editor.value('%opt{v_lsp_progress}')! == ''
	// Actual errors remain visible and do not get replaced by a success message.
	editor.remote("define-command -override lsp-references %{ fail 'VLS unavailable' }\nset-option global v_lsp_feedback true")!
	offset = editor.offset()
	editor.remote('try %{ v-references } catch %{ echo -markup %val{error} }')!
	assert editor.transcript(offset).contains('VLS unavailable')
	println('ok - rendered LSP request feedback, server progress, personal modeline, opt-out and errors')
}

check(os.find_abs_path_of_executable(os.args[1] or { 'kak' })!) or {
	eprintln(err)
	exit(1)
}
