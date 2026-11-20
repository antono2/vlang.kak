// Exercise browsing, project targets and live search in Kakoune's JSON UI.
import editorui { quote }
import os
import rand
import time
import x.json2

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

fn search_row(mut editor editorui.Client, path string) !int {
	deadline := time.sys_mono_now() + u64(15 * time.second)
	for time.sys_mono_now() < deadline {
		editor.remote('write -force ${quote(path)}')!
		for i, line in os.read_lines(path)! {
			if line.contains(marker) {
				return i + 1
			}
		}
		time.sleep(50 * time.millisecond)
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
	deadline := time.sys_mono_now() + u64(15 * time.second)
	for time.sys_mono_now() < deadline {
		editor.remote('write -force ${quote(report)}')!
		if os.read_file(report)!.contains('Target: ' + target) {
			break
		}
		time.sleep(50 * time.millisecond)
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
	os.write_file(source, 'module main\nfn main() {}\n// root_browsing_marker\n')!
	os.write_file(os.join_path(project, 'v.mod'), "Module { name: 'browsing' }\n")!
	os.write_file(target, 'module main\n// ${marker}\nfn helper() {}\n')!
	os.write_file(os.join_path(config, 'kakrc'),
		'source ${quote(plugin)}\nset-option global v_pane_mode off\n')!
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
	editor.wait_value('%val{bufname}', '*grep*', false, 'search results opened')!
	result_row := search_row(mut editor, os.join_path(root, 'results'))!
	select_line(mut editor, result_row)!
	editor.keys('<ret>')
	editor.wait_value('${buffer_file} %val{cursor_line}', '${target} 2', false,
		'search opened the matching source line')!

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
	check_project_targets(mut editor, root, project, target)!
	println('ok - rendered tree, project prompts and completion, and live search')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/browsing.vsh KAKOUNE')
	exit(2)
}
exercise(os.abs_path(os.args[1])) or {
	eprintln(err)
	exit(1)
}
