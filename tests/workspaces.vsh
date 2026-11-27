// Open directories through the actual V launcher and exercise the rendered UI.
import editorui { quote }
import os
import rand
import releasetest { capture }
import x.json2

fn require(condition bool, message string) ! {
	if !condition {
		return error(message)
	}
}

fn exercise(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-workspace-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	repo := os.dir(@DIR)
	helper := os.join_path(repo, 'scripts', 'helper-cache.sh')
	prefix := os.join_path(root, 'prefix')
	os.mkdir_all(os.join_path(prefix, 'opt', 'vlang-kakoune'))!
	bin := os.join_path(root, 'bin')
	os.mkdir(bin)!
	os.symlink(kak, os.join_path(bin, 'kak'))!
	os.setenv('PATH', bin + ':' + os.getenv('PATH'), true)
	os.setenv('XDG_CONFIG_HOME', os.join_path(root, 'config'), true)
	os.setenv('XDG_CACHE_HOME', os.join_path(root, 'cache'), true)
	os.setenv('XDG_STATE_HOME', os.join_path(root, 'state'), true)
	os.setenv('VLANG_KAK_PREFIX', prefix, true)
	config := os.join_path(root, 'config', 'kak')
	os.mkdir_all(config)!
	plugin := os.join_path(repo, 'rc', 'vlang.kak')
	os.write_file(os.join_path(config, 'kakrc'), 'source ${quote(plugin)}\nset-option global v_pane_mode off\n')!
	for tool in ['launcher', 'workspace', 'explorer', 'context', 'preferences', 'navigation'] {
		capture(helper, [tool, '--prepare'], true)!
	}
	launcher := os.join_path(root, 'kak-v')
	os.write_file(launcher, '#!/bin/sh\nexec ' + os.quoted_path(helper) + ' launcher "$@"\n')!
	os.chmod(launcher, 0o755)!
	project := os.join_path(root, "project's %{literal} \$HOME")
	os.mkdir(project)!
	manifest := os.join_path(project, 'v.mod')
	os.write_file(manifest, "Module { name: 'workspace' }\n")!
	file := os.join_path(project, 'main.v')
	os.write_file(file, 'module main\nfn main() {}\n')!
	mut editor := editorui.open_managed(kak, launcher, root, project)!
	defer { editor.close() }
	editor.wait_value('%opt{filetype}', 'v-tree', false, 'directory opened the tree')!
	require(editor.value('%opt{v_workspace_root}')! == project, 'Directory root was not preserved')!
	require(editor.value('%opt{v_tree_origin}')! == manifest, 'Directory did not open root v.mod: ' + editor.value('%opt{v_tree_origin}')!)!
	editor.keys('q')
	editor.wait_value('%val{buffile}', manifest, false, 'q returned to the manifest')!
	menu_offset := editor.offset()
	editor.keys('<space>')
	menu := editor.wait_info(menu_offset, 'Find project file')!
	require(menu.contains('Build project') && !menu.contains('Find references'), 'Manifest menu has incorrect actions')!
	editor.keys('<esc>')
	prompt_offset := editor.offset()
	editor.keys('<space>Uo')
	editor.wait_event(prompt_offset, 'draw_status', ['Project directory:'])!
	editor.keys('<esc>')
	editor.wait_value('%val{buffile}', manifest, false, 'directory prompt cancellation preserved the manifest')!
	editor.remote('edit -- ${quote(file)}')!
	editor.remote('v-tree')!
	editor.keys('q')
	editor.wait_value('%val{buffile}', file, false, 'tree returned to the current source')!
	editor.quit()!
	os.rm(os.join_path(root, 'ready'))!
	mut reopened := editorui.open_managed(kak, launcher, root, project)!
	defer { reopened.close() }
	reopened.wait_value('%opt{filetype}', 'v-tree', false, 'reopened directory tree')!
	require(reopened.value('%opt{v_tree_origin}')! == file, 'Directory did not restore the recent source')!
	reopened.quit()!
	os.rm(os.join_path(root, 'ready'))!
	os.rm(file)!
	mut deleted := editorui.open_managed(kak, launcher, root, project)!
	defer { deleted.close() }
	deleted.wait_value('%opt{v_tree_origin}', manifest, false, 'missing recent file fell back to v.mod')!
	deleted.quit()!
	os.rm(os.join_path(root, 'ready'))!
	// No project metadata: retain the exact directory, and give q a valid target.
	empty := os.join_path(root, 'empty')
	os.mkdir(empty)!
	mut blank := editorui.open_managed(kak, launcher, root, empty)!
	defer { blank.close() }
	blank.wait_value('%opt{filetype}', 'v-tree', false, 'empty directory tree')!
	state := json2.decode[json2.Any](os.read_file(blank.value('%opt{v_tree_state}')!)!)!.as_map()
	require(state['root'] or { json2.Any('') }.str() == empty, 'Metadata-free directory has the wrong root')!
	blank.keys('q')
	blank.wait_value('%val{bufname}', '*project*', false, 'empty tree returned to its project buffer')!
	blank.quit()!
	os.rm(os.join_path(root, 'ready'))!
	// The shell fallback must interpret options and quoted directory arguments too.
	fallback := os.join_path(repo, 'scripts', 'launcher-posix')
	mut shell_editor := editorui.open_managed(kak, fallback, root, project)!
	defer { shell_editor.close() }
	shell_editor.wait_value('%opt{v_tree_origin}', manifest, false, 'POSIX launcher directory startup')!
	shell_editor.quit()!
	os.rm(os.join_path(root, 'ready'))!
	child := os.join_path(empty, 'child')
	os.mkdir(child)!
	child_manifest := os.join_path(child, 'v.mod')
	os.write_file(child_manifest, "Module { name: 'child' }\n")!
	mut nested := editorui.open_managed(kak, launcher, root, empty)!
	defer { nested.close() }
	nested.wait_value('%opt{v_tree_origin}', child_manifest, false, 'nested module discovery')!
	nested.quit()!
	os.rm(os.join_path(root, 'ready'))!
	// Personal startup choices are applied before directory startup.
	os.write_file(os.join_path(config, 'kakrc'), 'source ${quote(plugin)}\n' +
		'set-option global v_startup_tree false\nset-option global v_restore_last_file false\n')!
	mut quiet := editorui.open_managed(kak, launcher, root, project)!
	defer { quiet.close() }
	quiet.wait_value('%val{buffile}', manifest, false, 'startup tree opt-out')!
	require(quiet.value('%opt{v_tree_state}')! == '', 'Startup ignored tree opt-out')!
	quiet.quit()!
	println('ok - directory launcher, quoted paths, recent file, removed file, exact roots and tree return')
}

exercise(os.find_abs_path_of_executable(os.args[1] or { 'kak' })!) or {
	eprintln(err)
	exit(1)
}
