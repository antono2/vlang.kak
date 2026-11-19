// Persist a single IDE setting in the marked block of the user's Kakoune configuration.
import os
import rand
import strings

const block_start = '# >>> vlang.kak preferences >>>'
const block_end = '# <<< vlang.kak preferences <<<'
const opt_command = 'set-option global '
const update_option = 'v_update_check_enabled'

fn allowed(name string, value string) bool {
	return match name {
		'v_explorer_enabled', 'v_live_search_enabled', update_option {
			value in ['true', 'false']
		}
		'v_pane_mode' {
			value in ['auto', 'always', 'off']
		}
		'v_window_backend' {
			value in ['auto', 'tmux', 'zellij', 'wezterm', 'kitty', 'screen', 'native']
		}
		else { false }
	}
}

fn settings_text(original string, name string, value string) !string {
	command := opt_command + name + ' '
	setting := command + value
	entry := if name == update_option { 'try %{ ${setting} }' } else { setting }
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

fn persist(name string, value string) ! {
	mut home := os.getenv('VLANG_KAK_CONFIG_HOME')
	if home == '' {
		home = os.getenv('XDG_CONFIG_HOME')
	}
	if home == '' {
		home = os.join_path(os.home_dir(), '.config')
	}
	config := os.join_path(home, 'kak')
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
		println('Usage: settings.sh SETTING VALUE')
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
