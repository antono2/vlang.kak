// Check that setup and migration preserve personal files, symlinks and settings.
import os
import rand
import time

const process_timeout = 20 * time.second
const process_poll = 10 * time.millisecond
const original_settings = '# personal settings\nmap global user b ":echo mine<ret>"\n'
const personal_settings = '# keep my settings\n'
const unrelated_plugin = '# another plugin\n'

struct SetupFixture {
	prefix string
	env    map[string]string
}

fn (fixture SetupFixture) setup(options []string, failure string) ! {
	program := os.join_path(@DIR, '..', 'scripts', 'setup.sh')
	mut args := ['--prefix', fixture.prefix, '--no-build', '--no-lsp', '--no-vls', '--no-explorer']
	args << options
	mut child := os.new_process(program)
	child.set_args(args)
	child.set_environment(fixture.env)
	child.set_redirect_stdio()
	child.run()
	defer { child.close() }
	deadline := time.sys_mono_now() + u64(process_timeout)
	mut output := ''
	mut errors := ''
	for child.is_alive() {
		output += child.stdout_read()
		errors += child.stderr_read()
		if time.sys_mono_now() >= deadline {
			child.signal_kill()
			child.status = .running
			child.wait()
			return error('Setup timed out\n${output}${errors}')
		}
		time.sleep(process_poll)
	}
	output += child.stdout_read()
	errors += child.stderr_read()
	if failure == '' {
		if child.code != 0 {
			return error('Setup exited with status ${child.code}\n${output}${errors}')
		}
	} else if child.code == 0 || !errors.contains(failure) {
		return error('Setup did not report ${failure}\n${output}${errors}')
	}
}

fn check(root string, kak string) ! {
	config := os.join_path(root, "personal config's")
	kak_config := os.join_path(config, 'kak')
	prefix := os.join_path(root, 'prefix')
	target := os.join_path(root, 'real-kakrc')
	kakrc := os.join_path(kak_config, 'kakrc')
	personal := os.join_path(kak_config, 'vlang-user.kak')
	autoload := os.join_path(kak_config, 'autoload')
	unrelated := os.join_path(root, 'other-plugin.kak')
	link := os.join_path(autoload, 'vlang.kak')
	os.mkdir_all(autoload)!
	os.write_file(target, original_settings)!
	os.symlink(target, kakrc)!
	os.write_file(personal, personal_settings)!
	os.write_file(unrelated, unrelated_plugin)!
	os.symlink(unrelated, link)!

	bindir := os.join_path(root, 'bin')
	os.mkdir(bindir)!
	os.symlink(os.real_path(kak), os.join_path(bindir, 'kak'))!
	mut env := os.environ()
	env['PATH'] = bindir + ':' + env['PATH']
	env['XDG_CONFIG_HOME'] = config
	env['VLANG_KAK_SKIP_PULL'] = '1'
	env.delete('VLANG_KAK_CONFIG_HOME')
	fixture := SetupFixture{
		prefix: prefix
		env:    env
	}
	fixture.setup([], '')!
	fixture.setup(['--pane-mode', 'off', '--window-backend', 'tmux', '--no-live-search'], '')!
	fixture.setup([], '')!
	generated_config := os.join_path(prefix, 'opt', 'vlang-kakoune', 'ide-config')
	generated := os.join_path(generated_config, 'kak', 'kakrc')
	baseline := os.read_file(generated)!
	for setting in ['v_pane_mode off', 'v_window_backend tmux', 'v_live_search_enabled false'] {
		assert baseline.contains('set-option global ' + setting)
	}
	fixture.setup(['--update'], '')!
	assert os.read_file(generated)!.contains('set-option global v_pane_mode off')
	assert os.read_file(target)! == original_settings
	assert os.is_link(kakrc)
	assert os.real_path(link) == unrelated
	assert os.read_file(personal)! == personal_settings
	fixture.setup(['--integrate'], 'Conflicting plugin link')!
	assert os.real_path(link) == unrelated && os.read_file(target)! == original_settings

	launcher := os.join_path(prefix, 'bin', 'kak-v')
	launcher_text := os.read_file(launcher)!
	os.rm(launcher)!
	os.symlink(unrelated, launcher)!
	fixture.setup([], 'Existing unmanaged file')!
	assert os.is_link(launcher) && os.read_file(unrelated)! == unrelated_plugin
	os.rm(launcher)!
	os.write_file(launcher, launcher_text)!
	os.chmod(launcher, 0o755)!

	// Recover the original path, including its apostrophe, from an older launcher.
	mut old_env := env.clone()
	old_env['XDG_CONFIG_HOME'] = generated_config
	legacy := SetupFixture{
		prefix: prefix
		env:    old_env
	}
	legacy.setup(['--update'], '')!
	assert os.read_file(generated)!.contains(personal.replace("'", "''"))
	assert os.read_file(target)! == original_settings
	syntax := os.execute('sh -n ' + os.quoted_path(launcher))
	assert syntax.exit_code == 0, syntax.output

	os.rm(link)!
	malformed := original_settings + '# >>> vlang.kak managed >>>\n# user content follows\n'
	os.write_file(target, malformed)!
	fixture.setup(['--integrate'], 'Malformed managed block')!
	assert os.read_file(target)! == malformed && !os.exists(link)
	os.write_file(target, original_settings)!
	fixture.setup(['--integrate'], '')!
	assert os.read_file(target)!.starts_with(original_settings)
	assert os.is_link(kakrc)
	assert !os.ls(kak_config)!.any(it.starts_with('kakrc.vlang-backup'))
	mut baseline_preserved := false
	for path in os.ls(root)!.filter(it.starts_with('real-kakrc.vlang-backup.')) {
		if os.read_file(os.join_path(root, path))! == original_settings {
			baseline_preserved = true
			break
		}
	}
	assert baseline_preserved
	fixture.setup(['--update'], '')!
	assert os.read_file(target)!.starts_with(original_settings)
	assert os.read_file(personal)! == personal_settings
	assert os.real_path(link) == os.join_path(os.dir(@DIR), 'rc', 'vlang.kak')
}

fn run(kak string) ! {
	root := os.join_path(os.temp_dir(), 'vlang-settings-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	check(os.real_path(root), kak)!
	println('ok - setup preserves personal settings, symlinks, conflicts and legacy update paths')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/settings.vsh KAKOUNE')
	exit(2)
}
run(os.args[1]) or {
	eprintln(err)
	exit(1)
}
