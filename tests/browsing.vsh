// Exercise browsing, project targets and live search in Kakoune's JSON UI.
import editorui { quote }
import os
import rand
import releasetest { capture }
import time
import x.json2

const buffer_write_timeout = 15 * time.second
const buffer_write_poll = 50 * time.millisecond
const marker = 'unique_browsing_marker'
const buffer_file = '%val{buffile}'

fn require(condition bool, message string) ! {
	if !condition {
		return error(message)
	}
}

fn tree_row(mut editor editorui.Client, path string) !int {
	state := editor.value('%opt{v_tree_state}')!
	value := json2.decode[json2.Any](os.read_file(state)!)!.as_map()
	rows := value['rows'] or { return error('Missing file tree rows') }
	for i, row in rows.as_array() {
		if row is map[string]json2.Any {
			file := row['path'] or { continue }
			if file.str() == path {
				return i + 1
			}
		}
	}
	return error('File missing from the tree: ${path}')
}

fn select_line(mut editor editorui.Client, line int) ! {
	editor.remote('select ${line}.1,${line}.1')!
}

fn check_failed_helper(mut editor editorui.Client, root string, source string, plugin string, result string) ! {
	editor.remote('set-option global v_plugin_source ${quote(plugin)}')!
	editor.remote('try %{ v-tree } catch %{ nop }')!
	require(editor.value(buffer_file)! == source && editor.value('%opt{readonly}')! == 'false',
		'Failed tree helper changed the source buffer')!
	path := os.join_path(root, result)
	editor.remote('write -force ${quote(path)}')!
	require(os.read_file(path)! == os.read_file(source)!, 'Failed tree helper changed source text')!
}

fn search_row(mut editor editorui.Client, path string, target string) !int {
	deadline := time.sys_mono_now() + u64(buffer_write_timeout)
	for time.sys_mono_now() < deadline {
		editor.remote('write -force ${quote(path)}')!
		for i, line in os.read_lines(path)! {
			if line.contains(marker) && line.contains(target) {
				return i + 1
			}
		}
		time.sleep(buffer_write_poll)
	}
	return editor.diagnostic('Search results did not contain the expected row')
}

fn check_project_targets(mut editor editorui.Client, root string, project string, quoted_file string) ! {
	target := os.join_path(project, "a quote's %{ \$HOME\nlast.v")
	test := os.join_path(project, 'excluded_test.v')
	os.write_file(target, 'module main\nfn main() {}\n')!
	os.write_file(test, 'module main\nfn main() {}\n')!
	mut offset := editor.offset()
	editor.remote('v-project-targets')!
	menu := editor.wait_event(offset, 'menu_show', ['last.v', 'Choose another V target'])!
	require(!menu.contains('excluded_test.v'), 'A test file appeared in the runnable target menu')!
	editor.keys('<ret>')
	editor.wait_value('%opt{v_project_target}', target, false,
		'selection preserved the complete target filename')!
	editor.remote('edit ${quote(quoted_file)}')!
	editor.wait_value('%opt{v_project_target}', target, false,
		'the target was stored under the project root')!
	editor.remote('v-project-settings')!
	editor.wait_value('%val{bufname}', '*make*', false,
		'project settings opened in the task buffer')!
	report := os.join_path(root, 'project-settings')
	deadline := time.sys_mono_now() + u64(buffer_write_timeout)
	for time.sys_mono_now() < deadline {
		editor.remote('write -force ${quote(report)}')!
		if os.read_file(report)!.contains('Target: ' + target) {
			break
		}
		time.sleep(buffer_write_poll)
	}
	require(os.read_file(report)!.contains('Target: ' + target),
		'Project settings did not display the stored target path')!

	empty := os.join_path(root, 'no runnable sources')
	os.mkdir(empty)!
	os.write_file(os.join_path(empty, 'v.mod'), "Module { name: 'empty' }\n")!
	file := os.join_path(empty, 'helper.v')
	os.write_file(file, 'module example\nfn helper() {}\n')!
	editor.remote('edit ${quote(file)}')!
	offset = editor.offset()
	editor.remote('v-project-targets')!
	editor.wait_event(offset, 'menu_show', ['Choose another V target'])!
	offset = editor.offset()
	editor.keys('<ret>')
	editor.wait_event(offset, 'draw_status', ['Target:'])!
	editor.keys('<esc>')
	println('ok - rendered project targets preserve quoted and multiline filenames and offer a manual path')
}

fn check_alternate_files(mut editor editorui.Client, root string) ! {
	stem := os.join_path(root, "an alternate's %{name} \$HOME\nline")
	source, test := stem + '.v', stem + '_test.v'
	for path in [source, test] {
		os.write_file(path, 'module main\n')!
	}

	bin := os.join_path(root, 'compiler-free')
	os.mkdir(bin)!
	for name in ['cksum', 'dirname', 'sed'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(bin, name))!
	}
	helper := os.join_path(os.dir(@DIR), 'scripts', 'helper-cache.sh')
	mut fallback := os.environ()
	fallback['PATH'] = bin
	fallback['XDG_CACHE_HOME'] = os.join_path(root, 'compiler-free-cache')
	for from, to in {
		source: test
		test:   source
	} {
		editor.remote('edit ${quote(from)}; alt')!
		editor.wait_value(buffer_file, to, false, 'alt opened the matching file')!
		assert capture(helper, ['navigation', 'alternate', from], true, environment: fallback)! == 'edit -- ${quote(to)}\n'
	}

	editor.remote('declare-option str v_alternate_test_error')!
	for from, reason in {
		stem + '-without-test.v':        'test file not found'
		stem + '-without-source_test.v': 'implementation file not found'
		stem + '.txt':                   'alternative file not found'
	} {
		os.write_file(from, 'module main\n')!
		editor.remote('edit ${quote(from)}; try %{ v-alternative-file } catch %{ set-option global v_alternate_test_error %val{error} }')!
		editor.wait_value('%opt{v_alternate_test_error}', reason, true, 'alt reported ${reason}')!
		require(editor.value(buffer_file)! == from, 'alt changed the buffer on failure')!
		assert capture(helper, ['navigation', 'alternate', from], true, environment: fallback)! == 'fail ${quote(reason)}\n'
	}
}

fn check_result_navigation(mut editor editorui.Client, root string) ! {
	source := os.join_path(root, "it's a=source.v")
	os.write_file(source, 'module main\nfn main() {}\n')!
	selection := '2.4,2.7'
	editor.remote('edit ${quote(source)}; select ${selection}')!
	editor.remote("set-option -add global v_results_origins 'unrelated=elsewhere'")!
	editor.remote('v-results-prepare; edit -scratch *navigation-results*; v-results-init')!
	require(editor.value('%opt{v_results_origin}')! == source, 'Results lost the source path')!
	require(editor.value('%opt{modelinefmt}')!.contains('Tab/S-Tab browse'),
		'Results omitted their browse and return hints')!
	editor.keys('q')
	editor.wait_value(buffer_file, source, false, 'q returned to the source file')!
	require(editor.value('%val{selection_desc}')! == selection,
		'Returning from results did not restore the selection')!

	// Simulate the hover view without starting a language server.
	editor.remote("define-command lsp-hover-buffer %{ edit -scratch '*hover*' }")!
	editor.remote('v-doc')!
	require(editor.value('%opt{v_doc_origin}')! == source, 'Hover lost the source path')!
	editor.remote('v-doc-return')!
	require(editor.value(buffer_file)! == source
		&& editor.value('%val{selection_desc}')! == selection,
		'Returning from hover did not restore the source selection')!
}

fn exercise(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-browsing-' + rand.uuid_v4())
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	project := os.join_path(root, 'project with spaces')
	folder := os.join_path(project, 'nested')
	config := os.join_path(root, 'config', 'kak')
	os.setenv('VLANG_KAK_CONFIG_HOME', os.dir(config), true)
	os.setenv('XDG_CACHE_HOME', os.join_path(root, 'cache'), true)
	os.mkdir_all(folder)!
	os.mkdir_all(config)!
	source := os.join_path(project, 'main.v')
	target := os.join_path(folder, "it's.v")
	plugin := os.join_path(os.dir(@DIR), 'rc', 'vlang.kak')
	os.write_file(source, 'module main\nfn main() {}\n// root_browsing_marker\n// ${marker}\n')!
	os.write_file(os.join_path(project, 'v.mod'), "Module { name: 'browsing' }\n")!
	os.write_file(target, 'module main\n// ${marker}\nfn helper() {}\n')!
	os.write_file(os.join_path(config, 'kakrc'),
		'source ${quote(plugin)}\nset-option global v_pane_mode off\n')!
	helper_cache := os.join_path(os.dir(@DIR), 'scripts', 'helper-cache.sh')
	for tool in ['context', 'navigation', 'preferences', 'explorer'] {
		capture(helper_cache, [tool, '--prepare'], true)!
	}
	mut editor := editorui.open(kak, root, source)!
	defer { editor.close() }

	broken := os.join_path(root, 'broken')
	os.mkdir_all(os.join_path(broken, 'scripts'))!
	os.mkdir_all(os.join_path(broken, 'rc'))!
	helper := os.join_path(broken, 'scripts', 'explorer.sh')
	os.write_file(helper, '#!/bin/sh\nexit 1\n')!
	os.chmod(helper, 0o755)!
	check_failed_helper(mut editor, root, source, os.join_path(broken, 'rc', 'vlang.kak'),
		'source-after-failed-helper')!
	check_failed_helper(mut editor, root, source, os.join_path(root, 'missing', 'rc', 'vlang.kak'),
		'source-after-failed-tree')!
	editor.remote('set-option global v_plugin_source ${quote(plugin)}')!
	editor.keys('<space>F')
	editor.wait_value('%val{bufname}', '*v-tree-', true, 'tree opened with Space F')!
	tree := editor.value('%val{bufname}')!
	tree_state := editor.value('%opt{v_tree_state}')!
	require(os.is_file(tree_state), 'Project tree did not create its state')!
	editor.keys('<space>q')
	editor.wait_value(buffer_file, source, false, 'tree returned to the source')!
	editor.keys('<space>F')
	editor.wait_value('%val{bufname}', tree, false, 'tree reopened the existing view')!
	require(editor.value('%opt{v_tree_state}')! == tree_state,
		'Reopening the tree replaced its state')!
	mut offset := editor.offset()
	editor.keys('<space>')
	menu := editor.wait_info(offset, 'Toggle hidden files')!
	require(menu.contains('Return to source'), 'Tree context menu is missing Return to source')!
	editor.keys('<esc>')
	row := tree_row(mut editor, folder)!
	editor.remote('select ${row}.1,${row}.1; execute-keys -with-hooks -with-maps l')!
	select_line(mut editor, tree_row(mut editor, target)!)!
	offset = editor.offset()
	editor.keys('<space>p')
	editor.wait_info(offset, marker)!
	editor.keys('<space><ret>')
	editor.wait_value(buffer_file, target, false, 'tree opened the quoted filename')!
	editor.remote('delete-buffer ${quote(tree)}')!
	require(!os.exists(tree_state) && !os.exists(os.dir(tree_state)),
		'Closing the tree buffer left its temporary state behind')!

	editor.remote('set-option global v_explorer_enabled false')!
	offset = editor.offset()
	editor.keys('<space>F')
	editor.wait_event(offset, 'draw_status', ['Project path:', project + '/'])!
	editor.keys('<esc>')
	editor.wait_value(buffer_file, target, false, 'project path prompt cancellation')!
	editor.remote('edit ${quote(source)}')!
	offset = editor.offset()
	editor.keys('<space>Pnested')
	editor.wait_event(offset, 'menu_show', ['nested', "it''s.v"])!
	editor.keys('<tab><ret>')
	editor.wait_value(buffer_file, target, false, 'project picker opened the quoted path')!
	editor.remote('set-option global v_explorer_enabled true')!

	editor.remote('edit ${quote(source)}')!
	offset = editor.offset()
	editor.keys('<space>/')
	editor.keys(marker)
	editor.wait_info(offset, marker)!
	editor.keys('<esc>')
	editor.wait_value(buffer_file, source, false, 'search cancellation preserved source')!
	editor.keys('<space>/${marker}<ret>')
	editor.wait_value('%val{bufname}', '*v-search*', false, 'search results opened')!
	offset = editor.offset()
	editor.keys('<space>')
	editor.wait_info(offset, 'Next result')!
	editor.keys('<esc>')
	editor.keys('q')
	editor.wait_value(buffer_file, source, false, 'q returned from search results')!
	editor.keys('<space>/${marker}<ret>')
	editor.wait_value('%val{bufname}', '*v-search*', false, 'reopened search results')!
	require(editor.value('%opt{modelinefmt}')!.count('Tab/S-Tab browse') == 1,
		'Reopening results duplicated the modeline controls')!
	result_row := search_row(mut editor, os.join_path(root, 'results'), target)!
	other_row := search_row(mut editor, os.join_path(root, 'results'), source)!
	select_line(mut editor, result_row)!
	editor.keys('<tab>')
	require(editor.value('%val{bufname}')! == '*v-search*', 'Tab closed the search results')!
	editor.wait_value('%val{cursor_line}', other_row.str(), false, 'Tab selected the next search result')!
	editor.keys('<s-tab>')
	editor.wait_value('%val{cursor_line}', result_row.str(), false, 'Shift-Tab selected the previous search result')!
	select_line(mut editor, result_row)!
	editor.keys('<ret>')
	editor.wait_value('${buffer_file} %val{cursor_line}', '${target} 2', false,
		'search opened the matching source line')!
	editor.remote('buffer *v-search*')!
	editor.keys('q')
	editor.wait_value(buffer_file, source, false, 'reopened results retained direct return controls')!
	editor.remote('edit -- ${quote(target)}')!

	offset = editor.offset()
	editor.keys('<space>/root_browsing_marker')
	editor.wait_info(offset, 'main.v:3:// root_browsing_marker')!
	editor.keys('<esc>')
	editor.wait_value(buffer_file, target, false, 'nested search found the project root')!

	editor.remote('edit ${quote(source)}')!
	offset = editor.offset()
	editor.keys('<space>/')
	editor.keys('no_such_browsing_marker_9327')
	editor.wait_info(offset, 'No matches yet')!
	editor.keys('<esc>')
	editor.remote('nop')!
	require(editor.value(buffer_file)! == source, 'Empty search changed the source file')!
	editor.keys('<space>/no_such_browsing_marker_9327<ret>')
	editor.wait_value('%val{bufname}', '*v-search*', false, 'empty search results')!
	editor.keys('<esc>')
	editor.wait_value(buffer_file, source, false, 'Escape returned from empty results')!
	// Ordinary :grep keeps the runtime's controls, even when reusing *v-search*.
	editor.remote('grep -e ${quote(marker)} ${quote(project)}')!
	require(editor.value('%opt{v_search_results}')! == 'false', 'Ordinary grep inherited IDE search controls')!
	editor.remote('edit -- ${quote(source)}')!
	check_project_targets(mut editor, root, project, target)!
	check_result_navigation(mut editor, root)!
	check_alternate_files(mut editor, root)!
	println('ok - rendered project browsing, live search, and alternate files')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/browsing.vsh KAKOUNE')
	exit(2)
}
exercise(os.abs_path(os.args[1])) or {
	eprintln(err)
	exit(1)
}
