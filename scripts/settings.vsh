// Render personal settings commands and persist changes in the user's Kakoune configuration.
import os
import rand
import strings

const block_start = '# >>> vlang.kak preferences >>>'
const block_end = '# <<< vlang.kak preferences <<<'
const opt_command = 'set-option global '
const update_option = 'v_update_check_enabled'

fn allowed(name string, value string) bool {
	return match name {
		'v_explorer_enabled', 'v_live_search_enabled', 'v_startup_tree', 'v_restore_last_file', 'v_lsp_feedback', update_option {
			value in ['true', 'false']
		}
		'v_pane_mode' {
			value in ['auto', 'always', 'off']
		}
		'v_window_backend' {
			value in ['auto', 'tmux', 'zellij', 'wezterm', 'kitty', 'screen', 'native']
		}
		else {
			false
		}
	}
}

fn settings_text(original string, name string, value string) !string {
	command := opt_command + name + ' '
	setting := command + value
	entry := if name in [update_option, 'v_startup_tree', 'v_restore_last_file', 'v_lsp_feedback'] {
		'try %{ ${setting} }'
	} else { setting }
	malformed := 'Malformed preferences block; edit vlang-user.kak to repair it.'
	mut result := strings.new_builder(original.len + entry.len)
	mut in_block := false
	mut found := false
	if original != '' {
		for line in original.trim_string_right('\n').split('\n') {
			match line {
				block_start {
					if found {
						return error(malformed)
					}
					found = true
					in_block = true
				}
				block_end {
					if !in_block {
						return error(malformed)
					}
					result.writeln(entry)
					in_block = false
				}
				else {
					if in_block && line.contains(command) {
						continue
					}
				}
			}

			result.writeln(line)
		}
	}
	if in_block {
		return error(malformed)
	}
	if !found {
		result.writeln('')
		result.writeln(block_start)
		result.writeln(entry)
		result.writeln(block_end)
	}
	return result.str()
}

fn settings_directory() string {
	mut home := os.getenv('VLANG_KAK_CONFIG_HOME')
	if home == '' {
		home = os.getenv('XDG_CONFIG_HOME')
	}
	if home == '' {
		home = os.join_path(os.home_dir(), '.config')
	}
	return os.join_path(home, 'kak')
}

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn toggle_item(label string, name string, current string) string {
	next := if current == 'true' { 'false' } else { 'true' }
	return ' ' + quote('${label}: ${current} (toggle)') + ' ' + quote('v-setting ${name} ${next}')
}

fn render_menu(explorer string, search string, update string, pane string) string {
	mut menu := strings.new_builder(512)
	menu.write_string('menu')
	menu.write_string(toggle_item('Explorer', 'v_explorer_enabled', explorer))
	menu.write_string(toggle_item('Live search', 'v_live_search_enabled', search))
	menu.write_string(toggle_item('Weekly release check', update_option, update))
	for value in ['auto', 'always', 'off'] {
		menu.write_string(' ' + quote('Pane mode: ${value} (current: ${pane})') + ' ' +
			quote('v-setting v_pane_mode ${value}'))
	}
	menu.write_string(" 'Edit all personal settings' 'v-settings-file' 'Project run/debug settings' 'v-project-settings'")
	return menu.str()
}

fn persist(name string, value string) ! {
	config := settings_directory()
	os.mkdir_all(config)!
	lock_dir := os.join_path(config, '.vlang-settings-lock')
	os.mkdir(lock_dir) or { return error('Settings are being edited by another command.') }
	defer { os.rmdir(lock_dir) or {} }
	path := os.join_path(config, 'vlang-user.kak')
	if !os.exists(path) {
		if os.is_link(path) {
			return error('Cannot save settings through a dangling link: ${path}')
		}
		os.write_file(path, '')!
	}
	target := os.real_path(path)
	if !os.is_file(target) {
		return error('Expected a settings file at ${target}')
	}
	original := os.read_file(target)!
	updated := settings_text(original, name, value)!
	// Preserve the backup's metadata and write through the existing inode, as
	// the shell entry did for both symlink targets and hard-linked user files.
	backup := target + '.vlang-backup.' + rand.uuid_v4()
	mut backup_process := os.new_process(os.find_abs_path_of_executable('cp')!)
	backup_process.set_args(['-p', '--', target, backup])
	backup_process.run()
	backup_process.wait()
	code := backup_process.code
	backup_process.close()
	if code != 0 {
		return error('Could not back up ${target}')
	}
	os.write_file(target, updated)!
	println('${opt_command}${name} ${value}\nv-refresh-keys')
	if name == update_option && value == 'true' {
		println('v-update-check-background')
	}
}

fn run(args []string) ! {
	if args.len > 0 && args[0] in ['--help', '-h'] {
		println('Usage: settings.sh SETTING VALUE | --file | --menu EXPLORER SEARCH UPDATE PANE')
		return
	}
	if args == ['--file'] {
		path := os.join_path(settings_directory(), 'vlang-user.kak')
		println('edit -existing ${quote(path)}')
		return
	}
	if args.len == 5 && args[0] == '--menu' && allowed('v_explorer_enabled', args[1])
		&& allowed('v_live_search_enabled', args[2]) && allowed(update_option, args[3]) {
		println(render_menu(args[1], args[2], args[3], args[4]))
		return
	}
	if args.len < 2 || !allowed(args[0], args[1]) {
		return error_with_code('Unsupported setting/value.', 2)
	}
	persist(args[0], args[1])!
}

run(os.args[1..]) or {
	eprintln(err)
	exit(if err.code() == 2 { 2 } else { 1 })
}
