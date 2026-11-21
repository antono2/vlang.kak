// Verify native helper caching across source edits and compiler availability.
import os
import rand
import releasetest { capture, execute }

const native_pane_exit_status = 125
const checkpoint_timestamp_offset_seconds = 60

fn check() ! {
	root := os.join_path(os.temp_dir(), 'vlang-helper-cache-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer { os.rmdir_all(root) or {} }
	tools := os.join_path(os.dir(@DIR), 'scripts')
	scripts := os.join_path(root, "test's scripts")
	os.mkdir(scripts)!
	for name in ['helper-cache.sh', 'helper-cache.vsh', 'preferences.sh', 'windowing.sh',
		'session-buffer.sh'] {
		target := os.join_path(scripts, name)
		os.cp(os.join_path(tools, name), target)!
		if name.ends_with('.sh') { os.chmod(target, 0o755)! }
	}
	source := os.join_path(scripts, 'preferences.v')
	helper := os.join_path(scripts, 'preferences.sh')
	body := 'import os\nfn main() {\nprintln("first")\nfor arg in os.args[1..] { println(arg) }\n}\n'
	os.write_file(source, body)!
	stamp := os.file_last_mod_unix(source)
	mut env := os.environ()
	env['XDG_CACHE_HOME'] = os.join_path(root, 'cache with spaces')
	cache := os.join_path(env['XDG_CACHE_HOME'], 'vlang.kak')
	args := ['an argument', "it's literal", '$HOME']

	assert capture(helper, ['--prepare'], true, environment: env)! == ''
	assert capture(helper, args, true, environment: env)!.split_into_lines() == [
		'first',
		'an argument',
		"it's literal",
		'$HOME',
	]
	entries := os.ls(cache)!.sorted()
	assert entries.len == 2 && entries[0].starts_with('helper-dispatch-')
		&& entries[1].starts_with('preferences-')

	bin := os.join_path(root, 'compiler-free path')
	os.mkdir(bin)!
	for name in ['dirname', 'cksum'] {
		os.symlink(os.find_abs_path_of_executable(name)!, os.join_path(bin, name))!
	}
	mut without_compiler := env.clone()
	without_compiler['PATH'] = bin
	assert capture(helper, args, true, environment: without_compiler)!.starts_with('first\n')
	mut legacy_env := without_compiler.clone()
	legacy_env['XDG_CACHE_HOME'] = os.join_path(root, 'previous cache')
	legacy_cache := os.join_path(legacy_env['XDG_CACHE_HOME'], 'vlang.kak')
	os.mkdir_all(legacy_cache)!
	checksum :=
		capture('sh', ['-c', 'printf "%s" "$1" | cksum', 'cache', source], true)!.all_before(' ')
	legacy := os.join_path(legacy_cache, 'preferences-' + checksum)
	os.cp(os.join_path(cache, entries[1]), legacy)!
	os.chmod(legacy, 0o755)!
	assert capture(helper, args, true, environment: legacy_env)!.starts_with('first\n')
	os.write_file(source, body.replace_once('first', 'later'))!
	os.utime(source, stamp, stamp)!
	miss := execute(helper, args, false, environment: without_compiler)!
	assert miss.stderr.contains('V is required to build')
	assert os.ls(cache)!.sorted() == entries
	assert capture(helper, args, true, environment: env)!.starts_with('later\n')
	assert capture(helper, args, true, environment: without_compiler)!.starts_with('later\n')

	os.write_file(source, 'invalid helper source')!
	failure := execute(helper, ['--prepare'], false, environment: env)!
	assert failure.stderr.contains('Could not build the Kakoune preferences helper')
	assert os.ls(cache)!.len == 3
	assert os.ls(cache)!.all(!it.starts_with('.'))

	pane := os.join_path(scripts, 'windowing.sh')
	pane_source := os.join_path(scripts, 'windowing.v')
	pane_dependencies := os.join_path(scripts, 'windowhost')
	os.mkdir(pane_dependencies)!
	os.cp(os.join_path(tools, 'windowhost', 'detect.v'),
		os.join_path(pane_dependencies, 'detect.v'))!
	posix := os.join_path(scripts, 'windowing-posix')
	os.write_file(posix, '#!/bin/sh\nprintf "POSIX pane\\n"\n')!
	os.chmod(posix, 0o755)!
	os.write_file(pane_source, 'invalid pane source')!
	fallback := execute(pane, ['open'], true, environment: env)!
	assert fallback.stdout == 'POSIX pane\n' && fallback.stderr == ''
	os.write_file(pane_source, "fn main() { println('Native pane'); exit(${native_pane_exit_status}) }")!
	native := execute(pane, ['open'], false, environment: env)!
	assert native.code == native_pane_exit_status && native.stdout == 'Native pane\n'
	assert capture(pane, ['open'], true, environment: without_compiler)! == 'POSIX pane\n'

	session := os.join_path(scripts, 'session-buffer.sh')
	checkpoint_source := os.join_path(scripts, 'session-checkpoint.vsh')
	checkpoint_posix := os.join_path(scripts, 'session-checkpoint-posix')
	os.write_file(checkpoint_source, 'import os\nfn main() { println(os.args[1]) }')!
	os.write_file(checkpoint_posix, '#!/bin/sh\nprintf "POSIX checkpoint\\n"\n')!
	os.chmod(checkpoint_posix, 0o755)!
	first := os.join_path(root, "first user's checkpoint")
	second := os.join_path(root, 'second checkpoint')
	os.mkdir(first)!
	os.mkdir(second)!
	assert capture(session, ['--prepare', first], true, environment: env)! == ''
	writers := os.ls(cache)!.filter(it.starts_with('checkpoint-'))
	assert writers.len == 1
	writer := os.join_path(cache, writers[0])
	// A rewrite would change the sentinel timestamp even if the cache name stayed the same.
	saved_stamp := os.file_last_mod_unix(writer) - checkpoint_timestamp_offset_seconds
	os.utime(writer, saved_stamp, saved_stamp)!
	assert capture(session, ['--prepare', second], true, environment: without_compiler)! == ''
	assert os.ls(second)!.len == 0
	assert capture(session, ['--prepare', second], true, environment: env)! == ''
	assert os.file_last_mod_unix(writer) == saved_stamp
	assert os.ls(first)! == ['session-checkpoint']
	assert os.ls(second)! == ['session-checkpoint']
	os.rm(writer)!
	env['kak_opt_v_session_checkpoint'] = first
	assert capture(session, ['main'], true, environment: env)! == 'main\n'
	os.write_file(checkpoint_source, 'invalid checkpoint source')!
	fallback_writer := execute(session, ['--prepare', second], true, environment: env)!
	assert fallback_writer.stderr.contains('using the POSIX writer')
	assert os.ls(second)!.len == 0
	env['kak_opt_v_session_checkpoint'] = second
	assert capture(session, ['main'], true, environment: env)! == 'POSIX checkpoint\n'
	println('ok - native helpers preserve arguments, reuse cached binaries without V and rebuild on content changes')
}

fn main() {
	check() or {
		eprintln(err)
		exit(1)
	}
}
