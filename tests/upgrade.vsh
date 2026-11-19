// Exercise upgrades from published tags with copied tools and isolated settings.
import editorui { quote }
import os
import rand
import time

const default_base = 'v1.1.1'
const pre_manifest_release = 'v1.1.1'
const command_timeout = 3 * time.minute
const command_poll = 20 * time.millisecond
const personal_text = 'declare-option str upgrade_personal_setting preserved\n'
const kakrc_text = '# original personal configuration\n'
const inherited_note = 'personal file in an inherited tool release\n'
const isolated_note = '# personal isolated autoload\n'
const prefix_note = 'unrecorded personal file\n'

struct Upgrade {
	root      string
	checkout  string
	prefix    string
	config    string
	personal  string
	kakrc     string
	unrelated string
	vls       string
}

fn require(condition bool, detail string) ! {
	if !condition {
		return error(detail)
	}
}

fn command(program string, args []string, success bool) !string {
	program_path := os.find_abs_path_of_executable(program)!
	mut child := os.new_process(program_path)
	child.set_args(args)
	child.use_pgroup = true
	child.set_redirect_stdio()
	child.run()
	defer { child.close() }
	// Setup and Kakoune must see EOF immediately on their input.
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	deadline := time.sys_mono_now() + u64(command_timeout)
	mut output := ''
	mut diagnostics := ''
	for child.is_alive() && time.sys_mono_now() < deadline {
		output += child.stdout_read()
		diagnostics += child.stderr_read()
		time.sleep(command_poll)
	}
	if child.is_alive() {
		child.signal_pgkill()
		child.wait()
		return error('${program} ${args.join(' ')} timed out\n${output}${diagnostics}')
	}
	output += child.stdout_read()
	diagnostics += child.stderr_read()
	require((child.code == 0) == success,
		'${program} ${args.join(' ')} exited ${child.code}\n${output}${diagnostics}')!
	return output
}

fn (upgrade Upgrade) prepare(tools string) ! {
	os.mkdir_all(os.join_path(upgrade.config, 'autoload'))!
	os.mkdir(os.dir(upgrade.personal))!
	os.write_file(upgrade.personal, personal_text)!
	os.write_file(upgrade.kakrc, kakrc_text)!
	os.symlink(upgrade.personal, os.join_path(upgrade.config, 'vlang-user.kak'))!
	os.symlink(upgrade.kakrc, os.join_path(upgrade.config, 'kakrc'))!
	os.symlink(upgrade.personal, upgrade.unrelated)!
	for tool in ['vlang-kakoune', 'vlang-kak-lsp'] {
		installed := os.real_path(os.join_path(tools, 'opt', tool, 'current'))
		tool_root := os.join_path(upgrade.prefix, 'opt', tool)
		releases := os.join_path(tool_root, 'releases')
		target := os.join_path(releases, os.file_name(installed))
		os.mkdir_all(releases)!
		// Preserve links within cached tool releases, along with executable modes.
		command('cp', ['-a', '--', installed, target], true)!
		os.symlink(target, os.join_path(tool_root, 'current'))!
	}
	vls_source := os.real_path(os.join_path(tools, 'bin', 'vls'))
	command('cp', ['-p', '--', vls_source, upgrade.vls], true)!
	os.setenv('XDG_CONFIG_HOME', os.dir(upgrade.config), true)
	os.setenv('XDG_CACHE_HOME', os.join_path(upgrade.root, 'cache'), true)
	os.setenv('VLANG_KAK_PREFIX', upgrade.prefix, true)
	os.setenv('VLANG_KAK_SKIP_PULL', '1', true)
	os.unsetenv('VLANG_KAK_CONFIG_HOME')
	kak := os.join_path(upgrade.prefix, 'opt/vlang-kakoune/current')
	lsp := os.join_path(upgrade.prefix, 'opt/vlang-kak-lsp/current')
	os.setenv('PATH', os.join_path(kak, 'bin') + ':' + os.join_path(lsp, 'bin') + ':' +
		os.getenv('PATH'), true)
	os.setenv('KAKOUNE_RUNTIME', os.join_path(kak, 'share/kak'), true)
}

fn (upgrade Upgrade) checkout_revision(revision string) ! {
	command('git', ['-C', upgrade.checkout, 'checkout', '--quiet', '--detach', revision], true)!
}

fn (upgrade Upgrade) script(name string, extra []string, success bool) !string {
	mut args := ['--prefix', upgrade.prefix]
	args << extra
	return command(os.join_path(upgrade.checkout, 'scripts', name + '.sh'), args, success)
}

fn (upgrade Upgrade) setup(extra []string, success bool) ! {
	mut args := ['--integrate', '--no-build', '--no-lsp']
	args << extra
	upgrade.script('setup', args, success)!
}

fn (upgrade Upgrade) verify_settings() ! {
	require(os.readlink(os.join_path(upgrade.config, 'vlang-user.kak'))! == upgrade.personal
		&& os.readlink(upgrade.unrelated)! == upgrade.personal && os.readlink(os.join_path(upgrade.config,
		'kakrc'))! == upgrade.kakrc, 'Personal configuration symlinks changed')!
	require(os.read_file(upgrade.personal)! == personal_text && os.read_file(upgrade.kakrc)! == kakrc_text,
		'Personal configuration contents changed')!
}

fn (upgrade Upgrade) exercise(repo string, base_ref string) ! {
	revision := command('git', ['-C', repo, 'rev-parse', 'HEAD'], true)!.trim_space()
	command('git', ['clone', '--quiet', '--no-local', repo, upgrade.checkout], true)!
	base := command('git', ['-C', upgrade.checkout, 'rev-parse', '--verify', '--end-of-options',
		'${base_ref}^{commit}'], true)!.trim_space()
	upgrade.checkout_revision(base)!
	upgrade.setup(['--vls', upgrade.vls], true)!
	manifest_path := os.join_path(upgrade.prefix, 'opt/vlang-state/manifest.tsv')
	require(os.exists(manifest_path) == (base_ref != pre_manifest_release),
		'Published install ownership manifest did not match ${base_ref}')!

	ide_config := os.join_path(upgrade.prefix, 'opt/vlang-kakoune/ide-config/kak')
	generated := os.join_path(ide_config, 'kakrc')
	old_config := os.read_bytes(generated)!
	note := os.join_path(upgrade.prefix, 'my-notes.txt')
	inherited := os.join_path(os.real_path(os.join_path(upgrade.prefix, 'opt/vlang-kak-lsp/current')),
		'my-notes.txt')
	isolated := os.join_path(ide_config, 'autoload/custom.kak')
	os.write_file(note, prefix_note)!
	os.write_file(inherited, inherited_note)!
	os.write_file(isolated, isolated_note)!
	vls_before := os.read_bytes(upgrade.vls)!

	upgrade.checkout_revision(revision)!
	upgrade.setup(['--pane-mode', 'off'], true)!
	require(os.read_file(generated)!.contains('v_pane_mode off'), 'Upgrade did not apply the requested pane mode')!
	require(os.real_path(os.join_path(upgrade.prefix, 'bin/vls')) == upgrade.vls
		&& !os.exists(os.join_path(upgrade.prefix, 'opt/vlang-v')), 'Upgrade changed external compiler or VLS ownership')!
	manifest := os.read_file(manifest_path)!
	require(!manifest.contains(os.real_path(inherited)) && !manifest.contains(isolated),
		'Upgrade adopted unowned files into its manifest')!

	launcher := os.join_path(upgrade.prefix, 'bin/kak-v')
	launcher_before := os.read_bytes(launcher)!
	upgrade.setup(['--vls', os.join_path(upgrade.root, 'missing-vls')], false)!
	require(os.read_bytes(launcher)! == launcher_before, 'Failed setup changed the active launcher')!
	upgrade.script('rollback', [], true)!
	require(os.read_bytes(generated)! == old_config, 'Rollback did not restore the published configuration')!
	require(os.readlink(os.join_path(upgrade.config, 'vlang-user.kak'))! == upgrade.personal
		&& os.read_file(upgrade.personal)!.ends_with('preserved\n'),
		'Rollback changed the personal setting or symlink')!
	upgrade.setup([], true)!
	observed := os.join_path(upgrade.root, 'observed')
	command(launcher, ['-ui', 'json', '-e',
		'echo -to-file ${quote(observed)} %opt{upgrade_personal_setting}; quit!'], true)!
	require(os.read_file(observed)!.trim_space() == 'preserved',
		'Managed Kakoune no longer reads the personal setting')!

	preview := upgrade.script('uninstall', [], true)!
	require(preview.contains('Preview only') && os.is_file(launcher), 'Uninstall preview removed the launcher')!
	upgrade.script('uninstall', ['--apply'], true)!
	require(!os.exists(launcher), 'Uninstall left its managed launcher')!
	require(os.read_file(note)! == prefix_note && os.read_bytes(upgrade.vls)! == vls_before
		&& os.read_file(inherited)! == inherited_note && os.read_file(isolated)! == isolated_note,
		'Uninstall changed an unowned file or external tool')!
	upgrade.verify_settings()!
}

fn run(tools_path string, base_ref string) ! {
	root := os.real_path(os.join_path(os.temp_dir(), 'vlang-upgrade-' + rand.uuid_v4()))
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	config := os.join_path(root, 'config/kak')
	upgrade := Upgrade{
		root:      root
		checkout:  os.join_path(root, 'checkout')
		prefix:    os.join_path(root, 'prefix')
		config:    config
		personal:  os.join_path(root, 'external/personal.kak')
		kakrc:     os.join_path(root, 'external/kakrc')
		unrelated: os.join_path(config, 'autoload/personal.kak')
		vls:       os.join_path(root, 'external/vls')
	}
	upgrade.prepare(os.real_path(tools_path))!
	upgrade.exercise(os.dir(@DIR), base_ref)!
	println('ok - ${base_ref} upgrade, external tools and symlinked settings, failed update, rollback and safe removal')
}

if os.args.len !in [2, 3] {
	eprintln('Usage: v run tests/upgrade.vsh TOOLS_PREFIX [PUBLISHED_TAG]')
	exit(2)
}
base_ref := if os.args.len == 3 { os.args[2] } else { default_base }
run(os.args[1], base_ref) or {
	eprintln('not ok - ${base_ref} upgrade: ${err}')
	exit(1)
}
