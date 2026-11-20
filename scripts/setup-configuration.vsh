// Activate the prepared tools and publish the configuration and ownership records.
import editorui { quote }
import managedfiles { settings_block }
import managedrecord
import os
import rand
import setupconfig

const launcher_template = $embed_file('setup-ide-launcher.sh.in')
const block_start = '# >>> vlang.kak managed >>>'
const block_end = '# <<< vlang.kak managed <<<'
const isolated_marker = '# vlang.kak managed isolated configuration'
const launcher_marker = '# vlang.kak managed IDE launcher'
const kakoune_marker = '# vlang.kak managed Kakoune launcher'

struct Setup {
	prefix          string
	repo            string
	config_home     string
	runtime         string
	lsp             string
	integrate       string
	compiler        string
	compiler_policy string
	explorer        string
	live_search     string
	pane_mode       string
	backend         string
	managed_kak     bool
}

fn selected(args []string) !Setup {
	if args.len != 13 || !args[..4].all(os.is_abs_path(it)) {
		return error('Expected the setup paths and selected configuration options.')
	}
	if ![args[5], args[8], args[9], args[12]].all(it in ['true', 'false'])
		|| args[6] !in ['true', 'false', 'auto', 'system']
		|| args[7] !in ['auto', 'managed', 'system'] || args[10] !in ['auto', 'always', 'off']
		|| args[11] !in ['auto', 'tmux', 'zellij', 'wezterm', 'kitty', 'screen', 'native'] {
		return error('Invalid selected configuration options.')
	}
	return Setup{
		prefix:          args[0]
		repo:            args[1]
		config_home:     args[2]
		runtime:         args[3]
		lsp:             args[4]
		integrate:       args[5]
		compiler:        args[6]
		compiler_policy: args[7]
		explorer:        args[8]
		live_search:     args[9]
		pane_mode:       args[10]
		backend:         args[11]
		managed_kak:     args[12] == 'true'
	}
}

fn shell_quote(value string) string {
	return "'" + value.replace("'", "'\\''") + "'"
}

// Quote data placed inside shell double quotes while leaving the intended PATH expansion literal.
fn shell_double(value string) string {
	return value.replace_each(['\\', '\\\\', '"', '\\"', '$', '\\$', '`', '\\`'])
}

fn (setup Setup) compiler_path() string {
	return if setup.compiler == 'true' {
		os.join_path(setup.prefix, 'opt', 'vlang-v', 'current')
	} else {
		''
	}
}

fn (setup Setup) config_lines(user_config string, enable_lsp bool) []string {
	mut lines := []string{}
	if enable_lsp && setup.lsp != '' && os.is_executable(setup.lsp) {
		compiler := setup.compiler_path()
		path := setup.prefix + '/bin:' + if compiler == '' { '' } else { compiler + ':' }
		lines << 'eval %sh{ PATH="${shell_double(path)}\$PATH" "${shell_double(setup.lsp)}" }'
		lines << 'set-option global lsp_cmd ' +
			quote('"${shell_double(setup.lsp)}" --session "\$kak_session"')
	}
	lines << ['set-option global v_explorer_enabled ${setup.explorer}',
		'set-option global v_live_search_enabled ${setup.live_search}',
		'set-option global v_pane_mode ${setup.pane_mode}',
		'set-option global v_window_backend ${setup.backend}', 'source ' + quote(user_config)]
	return lines
}

fn regular_file(path string) bool {
	info := os.stat(path) or { return false }
	return info.get_filetype() == .regular
}

fn managed_file(path string, marker string) ! {
	if os.is_link(path)
		|| (os.exists(path) && (!regular_file(path) || marker !in os.read_lines(path)!)) {
		return error('Existing unmanaged file: ${path}. Choose another --prefix or move it yourself.')
	}
}

fn publish(path string, contents string, mode int) ! {
	pending := path + '.next.' + rand.uuid_v4()
	defer { os.rm(pending) or {} }
	os.write_file(pending, contents)!
	if mode != 0 { os.chmod(pending, mode)! }
	os.rename_dir(pending, path)!
}

fn available_link(path string) ! {
	if os.exists(path) && !os.is_link(path) {
		return error('Existing unmanaged autoload entry at ${path}')
	}
}

fn publish_link(target string, path string) ! {
	available_link(path)!
	pending := path + '.next.' + rand.uuid_v4()
	defer { os.rm(pending) or {} }
	os.symlink(target, pending)!
	os.rename_dir(pending, path)!
}

fn (setup Setup) autoload(config string) ! {
	path := os.join_path(config, 'autoload')
	os.mkdir_all(path)!
	publish_link(os.join_path(setup.runtime, 'rc'), os.join_path(path, 'vlang-site-runtime'))!
	publish_link(os.join_path(setup.repo, 'rc', 'vlang.kak'), os.join_path(path, 'vlang.kak'))!
}

fn backup_file(path string, backup string) ! {
	mut child := os.new_process('/bin/cp')
	defer { child.close() }
	child.set_args(['-p', '--', path, backup])
	child.run()
	child.wait()
	if child.code != 0 {
		return error('Could not back up ${path}.')
	}
}

fn (setup Setup) integrate_config(config string, user_config string) ! {
	kakrc := os.join_path(config, 'kakrc')
	if os.is_link(kakrc) && !os.exists(kakrc) {
		return error('Broken kakrc link: ${kakrc}. Resolve it before --integrate.')
	}
	if !os.exists(kakrc) {
		os.write_file(kakrc, '')!
	}
	if !regular_file(kakrc) {
		return error('Expected a regular kakrc file at ${kakrc}.')
	}
	block := settings_block(kakrc) or {
		return error('Malformed managed block in ${kakrc}; refusing to rewrite user settings.')
	}
	if block_end in block.remaining.split_into_lines() {
		return error('Malformed managed block in ${kakrc}; refusing to rewrite user settings.')
	}
	links := os.join_path(config, 'autoload')
	plugin := os.join_path(links, 'vlang.kak')
	site := os.join_path(links, 'vlang-site-runtime')
	available_link(plugin)!
	available_link(site)!
	if os.is_link(plugin)
		&& os.real_path(plugin) != os.real_path(os.join_path(setup.repo, 'rc', 'vlang.kak')) {
		return error('Conflicting plugin link: ${plugin}. Keep it or move it yourself before --integrate.')
	}
	if os.is_link(site) && os.real_path(site) != os.real_path(os.join_path(setup.runtime, 'rc'))
		&& block.owned == '' {
		return error('Conflicting runtime link: ${site}. Resolve it before --integrate.')
	}
	mut text := block.remaining
	if text != '' && !text.ends_with('\n') {
		text += '\n'
	}
	existing_lsp := text.split_into_lines().any(it.all_before('#').contains('kak-lsp'))
	mut lines := [block_start, 'v-enable-filetype-detection']
	lines << setup.config_lines(user_config, !existing_lsp)
	lines << block_end
	text += lines.join('\n') + '\n'
	setup.autoload(config)!
	target := os.real_path(kakrc)
	if text == block.original {
		println('Configuration unchanged: ${target}')
	} else {
		if os.read_file(target)! != block.original {
			return error('Kakoune settings changed while setup was running: ${target}')
		}
		backup := target + '.vlang-backup.' + rand.uuid_v4()
		backup_file(target, backup)!
		// Write through the existing inode to preserve symlinks, hard links, and permissions.
		os.write_file(target, text) or {
			os.write_file(target, block.original) or {
				eprintln('Settings backup retained at ${backup}: ${err}')
			}
			return err
		}
		println('Configured ${target} (backup: ${backup})')
	}
	if existing_lsp {
		println('Existing kak-lsp startup kept. Check that it uses the installed kak-lsp and VLS.')
	}
}

fn (setup Setup) write_configuration() ! {
	root := os.join_path(setup.prefix, 'opt', 'vlang-kakoune')
	isolated := os.join_path(root, 'ide-config')
	kakrc := os.join_path(isolated, 'kak', 'kakrc')
	launcher := os.join_path(setup.prefix, 'bin', 'kak-v')
	kakoune := os.join_path(setup.prefix, 'bin', 'kak')
	managed_file(kakrc, isolated_marker)!
	managed_file(launcher, launcher_marker)!
	if setup.managed_kak {
		managed_file(kakoune, kakoune_marker)!
	}
	kak_config := os.join_path(setup.config_home, 'kak')
	os.mkdir_all(kak_config)!
	config := os.real_path(kak_config)
	user_config := os.join_path(config, 'vlang-user.kak')
	if os.is_link(user_config) && !os.exists(user_config) {
		return error('Broken personal configuration link: ${user_config}. Resolve it before setup.')
	}
	if !os.exists(user_config) {
		os.write_file(user_config,
			'# Personal V IDE settings. setup.sh and update.sh keep this file.\n')!
	}
	if setup.integrate == 'true' { setup.integrate_config(config, user_config)! }
	setup.autoload(os.dir(kakrc))!
	compiler := setup.compiler_path()
	choice := if compiler == '' { 'system' } else { 'managed' }
	mut contents := [isolated_marker, 'v-enable-filetype-detection',
		'# vlang.kak integrate: ${setup.integrate}', '# vlang.kak compiler: ${choice}',
		'# vlang.kak compiler-policy: ${setup.compiler_policy}']
	contents << setup.config_lines(user_config, true)
	contents << ['hook -once global ClientCreate .* %{ evaluate-commands %sh{',
		'  if [ -n "\${VLANG_KAK_RESTART_SOURCE:-}" ]; then',
		'    printf "source \'%s\'\\\\n" "\$VLANG_KAK_RESTART_SOURCE"', '  fi', '} }']
	publish(kakrc, contents.join('\n') + '\n', 0)!
	os.mkdir_all(os.dir(launcher))!
	if setup.managed_kak {
		binary := os.join_path(root, 'current', 'bin', 'kak')
		wrapper := ['#!/bin/sh', kakoune_marker, 'KAKOUNE_RUNTIME=' + shell_quote(setup.runtime),
			'export KAKOUNE_RUNTIME', 'exec ${shell_quote(binary)} "\$@"']
		publish(kakoune, wrapper.join('\n') + '\n', 0o755)!
	}
	text := launcher_template.to_string().replace_each([
		'@ISOLATED@',
		shell_quote(isolated),
		'@CONFIG_HOME@',
		shell_quote(setup.config_home),
		'@BIN@',
		shell_quote(os.dir(launcher)),
		'@COMPILER_PATH@',
		if compiler == '' { '' } else { shell_quote(compiler) + ':' },
		'@PREFIX@',
		shell_quote(setup.prefix),
		'@REPO@',
		shell_quote(setup.repo),
		'@RESTART_PATTERN@',
		shell_quote(os.join_path(root, 'restart.XXXXXXXX')),
		'@TOOL_PREFIX@',
		shell_quote(os.join_path(setup.prefix, 'opt', 'vlang-')),
	])
	publish(launcher, text, 0o755)!
}

fn prepare_helper(repo string, name string) int {
	mut child := os.new_process(os.join_path(repo, 'scripts', name))
	defer { child.close() }
	child.set_args(['--prepare'])
	child.run()
	child.wait()
	// The shell bootstrap reserves 125 for helper compilation failures.
	return if child.code < 0 || child.code == 125 { 1 } else { child.code }
}

fn finish_setup(before Setup, vls_mode string, vls_path string, install_lsp bool) ! {
	setupconfig.activate(os.real_path(before.prefix), vls_mode, vls_path) or {
		return error(err.msg())
	}
	current := os.join_path(before.prefix, 'opt', 'vlang-kakoune', 'current', 'share', 'kak')
	managed := before.managed_kak || os.is_dir(current)
	setup := Setup{
		...before
		managed_kak: managed
		runtime:     if managed { current } else { before.runtime }
		lsp:         if install_lsp {
			os.join_path(before.prefix, 'opt', 'vlang-kak-lsp', 'current', 'bin', 'kak-lsp')
		} else {
			before.lsp
		}
	}
	setup.write_configuration() or { return error(err.msg()) }
	if setup.explorer == 'true' {
		status := prepare_helper(setup.repo, 'explorer.sh')
		if status != 0 {
			return error_with_code('Could not prepare the project explorer.', status)
		}
	}
	gdb := os.find_abs_path_of_executable('gdb') or { '' }
	compiler := os.find_abs_path_of_executable('v') or { '' }
	if gdb != '' && compiler != '' {
		status := prepare_helper(setup.repo, 'debug.sh')
		if status != 0 {
			return error_with_code('Could not prepare the debugger client.', status)
		}
	} else {
		println('Debugging: install GDB 14 or newer with Python support, then use Space B.')
	}
	println('Explorer: ${setup.explorer}. Live search: ${setup.live_search}. Pane mode: ${setup.pane_mode}. Customize ${setup.config_home}/kak/vlang-user.kak.')
	println('Launch with ${setup.prefix}/bin/kak-v or run scripts/check.sh.')
	managedrecord.record(setup.prefix, setup.config_home, vls_mode) or { return error(err.msg()) }
}

fn main() {
	finish := (os.args[1] or { '' }) == '--finish'
	args := if finish { os.args[2..] } else { os.args[1..] }
	if finish && (args.len != 16 || args[13] !in ['upstream', 'skip', 'external']
		|| args[15] !in ['true', 'false']) {
		eprintln('Expected configuration options, VLS mode and path, and kak-lsp installation choice.')
		exit(2)
	}
	setup := selected(if finish { args[..13] } else { args }) or {
		eprintln(err)
		exit(2)
	}
	if finish {
		finish_setup(setup, args[13], args[14], args[15] == 'true') or {
			eprintln(err)
			exit(if err.code() > 0 && err.code() != 125 { err.code() } else { 1 })
		}
	} else {
		setup.write_configuration() or {
			eprintln(err)
			exit(1)
		}
	}
}
