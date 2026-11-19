// Exercise interrupted-update recovery with a real Kakoune owner and tmux views.
import editorui { quote }
import os
import rand
import releasetest { capture }
import time

const editor_timeout = 20 * time.second
const shutdown_timeout = 10 * time.second
const poll_interval = 100 * time.millisecond
const activation_anchor = '"$script_dir/managed-state.sh" record "$prefix" "$config_home" "$vls_mode"'
const owner = 'client0'
const extra = 'client1'
const both_clients = 'client0 client1'
const owner_selection = '2.2,2.3'
const extra_selection = '1.2,1.4'
// /proc/PID/stat fields after the process name begin at field 3.
const process_start_index = 22 - 3

struct Session {
	root      string
	repo      string
	prefix    string
	kak       string
	tmux_path string
	name      string
	env       map[string]string
}

fn require(condition bool, detail string) ! {
	if !condition {
		return error(detail)
	}
}

fn wait_for(label string, timeout time.Duration, ready fn () !bool) ! {
	deadline := time.sys_mono_now() + u64(timeout)
	for time.sys_mono_now() < deadline {
		if ready()! {
			return
		}
		time.sleep(poll_interval)
	}
	return error('Timed out: ${label}')
}

fn (session Session) setup_args() []string {
	return ['--prefix', session.prefix, '--no-build', '--no-lsp', '--no-vls', '--no-explorer']
}

fn (session Session) tmux(args []string) !string {
	mut command := ['-L', session.name]
	command << args
	return capture(session.tmux_path, command, true,
		environment: session.env
		timeout:     editor_timeout
	)
}

fn (session Session) post(command string) ! {
	capture(session.kak, ['-p', session.name], true,
		environment: session.env
		input:       command + '\n'
		timeout:     editor_timeout
	)!
}

fn (session Session) remote(client string, command string) ! {
	session.post('evaluate-commands -client ${quote(client)} %{ ${command} }')!
}

fn (session Session) value(client string, report string, expression string) !string {
	path := os.join_path(session.root, report)
	if os.exists(path) {
		os.rm(path)!
	}
	session.remote(client, 'echo -to-file ${quote(path)} ${expression}')!
	wait_for(report, editor_timeout, fn [path] () !bool {
		text := os.read_file(path) or { return false }
		return text.trim_space() != ''
	})!
	return os.read_file(path)!.trim_space()
}

fn (session Session) interrupt_update() ! {
	// The barrier lives in an isolated source copy after the launchers have changed.
	fixture := os.join_path(session.root, 'update-source')
	releasetest.copy_source(session.repo, fixture)!
	implementation := os.join_path(fixture, 'scripts/setup-impl.sh')
	text := os.read_file(implementation)!
	require(text.count(activation_anchor) == 1, 'Expected one activation record boundary')!
	barrier := os.join_path(session.root, 'update-barrier')
	stop := 'touch ${os.quoted_path(barrier)}\nwhile :; do sleep 1; done\n'
	os.write_file(implementation, text.replace(activation_anchor, stop + activation_anchor))!
	mut args := session.setup_args()
	args << ['--pane-mode', 'off']
	releasetest.interrupt_at_marker(os.join_path(fixture, 'scripts/update.sh'), args, barrier,
		environment: session.env
		timeout:     editor_timeout
	)!
}

fn (session Session) recover_update() ! {
	state := os.join_path(session.prefix, 'opt/vlang-state')
	pending := os.ls(state)!.filter(it.starts_with('pending.'))
	require(pending.len == 1, 'Expected one pending update after the interruption')!
	snapshot := os.join_path(state, pending[0])
	capture(os.join_path(session.repo, 'scripts/lock.sh'),
		['--prefix', session.prefix, '--clear-stale'], true,
		environment: session.env
	)!
	capture(os.join_path(session.repo, 'scripts/rollback.sh'),
		['--prefix', session.prefix, '--recover', snapshot], true,
		environment: session.env
	)!
	generated := os.join_path(session.prefix, 'opt/vlang-kakoune/ide-config/kak/kakrc')
	require(os.read_file(generated)!.contains('v_pane_mode auto'), 'Rollback did not restore pane mode')!
}

fn (session Session) exercise() ! {
	first := os.join_path(session.root, 'first.txt')
	second := os.join_path(session.root, 'second.txt')
	os.write_file(first, 'first\nsecond\n')!
	os.write_file(second, 'other\n')!
	ready := os.join_path(session.root, 'ready')
	launcher := os.join_path(session.prefix, 'bin/kak-v')
	client_args := [launcher, '-s', session.name, '-e', 'echo -to-file ${quote(ready)} ready',
		first]
	command := client_args.map(os.quoted_path(it)).join(' ')
	// Fixed dimensions and an empty tmux configuration isolate the test from user settings.
	session.tmux(['-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', '140', '-y', '40',
		command])!
	wait_for('owner client', editor_timeout, fn [ready] () !bool {
		return os.is_file(ready)
	})!
	session.remote(owner, 'execute-keys iUnsaved<esc>; select ${owner_selection}; v-new-view')!
	wait_for('extra pane', editor_timeout, fn [session] () !bool {
		return session.tmux(['list-panes', '-F', '#{pane_id}'])!.split_into_lines().len == 2
	})!
	wait_for('second client', editor_timeout, fn [session] () !bool {
		return session.value(owner, 'clients', '%val{client_list}')! == both_clients
	})!
	session.remote(extra, 'edit ${quote(second)}; select ${extra_selection}')!

	session.interrupt_update()!
	session.recover_update()!
	require(session.value(owner, 'still-open', '%val{client_list}')! == both_clients,
		'Rolling back closed one of the live clients')!
	old_pid := session.value(owner, 'oldpid', '%val{client_pid}')!
	os.rm(ready)!
	session.remote(owner, 'v-restart-recover-now')!
	wait_for('restored owner ready', editor_timeout, fn [ready] () !bool {
		return os.is_file(ready)
	})!
	wait_for('owner restart', editor_timeout, fn [session, old_pid] () !bool {
		return session.value(owner, 'newpid', '%val{client_pid}')! != old_pid
	})!
	wait_for('restored view', editor_timeout, fn [session] () !bool {
		return session.value(owner, 'clients-restored', '%val{client_list}')! == both_clients
	})!
	location := '%val{buffile} %val{selections_desc}'
	require(session.value(owner, 'position0', location)! == '${first} ${owner_selection}'
		&& session.value(extra, 'position1', location)! == '${second} ${extra_selection}',
		'Restart did not restore both buffers and selections')!
	recovered := os.join_path(session.root, 'recovered')
	session.remote(owner, 'write ${quote(recovered)}')!
	wait_for('recovered source', editor_timeout, fn [recovered] () !bool {
		text := os.read_file(recovered) or { return false }
		return text != ''
	})!
	require(os.read_file(recovered)!.starts_with('Unsaved') && os.read_file(first)!.starts_with('first'),
		'Restart did not preserve the unsaved source independently of the file on disk')!
	require(session.tmux(['list-panes', '-F', '#{pane_id}'])!.split_into_lines().len == 2,
		'Restart did not restore both tmux panes')!
	// The editors can answer remote commands before tmux has redrawn their buffers.
	wait_for('restored pane text', editor_timeout, fn [session] () !bool {
		panes := session.tmux(['list-panes', '-F', '#{pane_id}'])!.fields()
		screens := panes.map(session.tmux(['capture-pane', '-p', '-t', it])!)
		return screens.any(it.contains('Unsavedfirst')) && screens.any(it.contains('other'))
	})!
}

fn process_state(pid int) []string {
	entry := os.read_file('/proc/${pid}/stat') or { return [] }
	end := entry.last_index(') ') or { return [] }
	return entry[end + 2..].fields()
}

fn exited(pid int, start string) bool {
	fields := process_state(pid)
	return fields.len <= process_start_index || fields[process_start_index] != start
		|| fields[0] in ['Z', 'X']
}

fn (session Session) close() ! {
	// tmux can report shutdown before the pane processes finish setting down their state.
	managed := os.join_path(session.prefix, 'opt/vlang-kakoune')
	mut candidates := (session.tmux(['list-panes', '-F', '#{pane_pid}']) or { '' }).fields()
	for entry in os.ls(managed) or { []string{} } {
		if entry.starts_with('restart.') {
			candidates << (os.read_file(os.join_path(managed, entry, 'owner-pid')) or { '' }).trim_space()
		}
	}
	mut owners := map[int]string{}
	for candidate in candidates {
		pid := candidate.int()
		if pid > 0 {
			fields := process_state(pid)
			if fields.len > process_start_index {
				owners[pid] = fields[process_start_index]
			}
		}
	}
	session.post('kill!') or {}
	session.tmux(['kill-server']) or {}
	wait_for('test launcher and client shutdown', shutdown_timeout, fn [owners] () !bool {
		for pid, start in owners {
			if !exited(pid, start) {
				return false
			}
		}
		return true
	})!
}

fn (session Session) diagnostics() {
	panes := session.tmux(['list-panes', '-F', '#{pane_id}']) or { '' }
	for pane in panes.split_into_lines() {
		eprintln(session.tmux(['capture-pane', '-p', '-t', pane]) or { err.msg() })
	}
	debug := os.join_path(session.root, 'debug')
	session.post("evaluate-commands -buffer '*debug*' %{ write ${quote(debug)} }") or {}
	if os.is_file(debug) {
		eprintln(os.read_file(debug) or { err.msg() })
	}
}

fn run(kak_path string) ! {
	kak := os.real_path(os.find_abs_path_of_executable(kak_path)!)
	name := 'vlang-recovery-' + rand.uuid_v4()
	root := os.join_path(os.temp_dir(), name)
	os.mkdir(root, mode: 0o700)!
	mut keep_root := false
	defer {
		if !keep_root {
			os.rmdir_all(root) or {}
		}
	}
	prefix := os.join_path(root, 'prefix')
	env := releasetest.editor_environment(root, prefix, os.join_path(root, 'config'), kak)!
	lsp := os.join_path(root, 'bin/kak-lsp')
	os.write_file(lsp, '#!/bin/sh\nprintf \'declare-option str lsp_cmd ""\\n\'\n')!
	os.chmod(lsp, 0o755)!
	os.signal_ignore(.pipe)
	session := Session{
		root:      root
		repo:      os.dir(@DIR)
		prefix:    prefix
		kak:       kak
		tmux_path: os.find_abs_path_of_executable('tmux')!
		name:      name
		env:       env
	}
	capture(os.join_path(session.repo, 'scripts/setup.sh'), session.setup_args(), true,
		environment: env
	)!
	session.exercise() or {
		exercise_error := err.msg()
		session.diagnostics()
		session.close() or {
			keep_root = true
			return error('${exercise_error}\n${err}. Test files: ${root}')
		}
		return error(exercise_error)
	}
	session.close() or {
		keep_root = true
		return error('${err}. Test files: ${root}')
	}
	println('ok - interrupted update recovery and real restart preserve unsaved source and multiple client buffers/selections')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/lifecycle_sessions.vsh KAKOUNE')
	exit(2)
}
run(os.args[1]) or {
	eprintln('not ok - live recovery: ${err}')
	exit(1)
}
