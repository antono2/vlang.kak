// Drive real tmux clients through tree, definition peek, and shared-view workflows.
import editorui { quote }
import os
import rand
import time

const pane_timeout = 20 * time.second
const poll_interval = 100 * time.millisecond
const stop_timeout = 10 * time.second
// These one-based coordinates identify the call and declaration in the fixture.
const source_at_call = '9.14,9.14'
const source_at_definition = '4.4,4.4'
const definition_title = 'main.v 4:4'
const call_title = 'main.v 9:14'
const first_line_title = 'main.v 1:1'
const fixture = 'module main

// Add two numbers.
fn add(a int, b int) int {
    return a + b
}

fn main() {
    println(add(1, 2))
}
'

struct PaneCheck {
	kak     string
	tmux    string
	session string
	root    string
	source  string
}

fn command_line(program string, args []string) string {
	mut words := [program]
	words << args
	return words.map(os.quoted_path(it)).join(' ')
}

fn command(line string) !string {
	result := os.execute(line)
	if result.exit_code != 0 {
		return error('Command failed (${result.exit_code}): ${line}\n${result.output}')
	}
	return result.output
}

fn wait_for(label string, ready fn () !bool) ! {
	deadline := time.sys_mono_now() + u64(pane_timeout)
	for time.sys_mono_now() < deadline {
		if ready()! {
			return
		}
		time.sleep(poll_interval)
	}
	return error('Timed out: ${label}')
}

fn (check PaneCheck) run_tmux(args []string) !string {
	mut tmux_args := ['-L', check.session]
	tmux_args << args
	return command(command_line(check.tmux, tmux_args))
}

fn (check PaneCheck) post(text string) ! {
	// Kakoune reads commands from stdin until EOF. A file also keeps multiline
	// commands intact through the tmux test's nested quoting.
	command_file := os.join_path(check.root, 'remote-command')
	os.write_file(command_file, text + '\n')!
	command(command_line(check.kak, ['-p', check.session]) + ' < ' + os.quoted_path(command_file))!
}

fn (check PaneCheck) remote(text string) ! {
	check.post('evaluate-commands -client client0 %{ ${text} }')!
}

fn (check PaneCheck) position() !string {
	path := os.join_path(check.root, 'position')
	if os.exists(path) {
		os.rm(path)!
	}
	check.remote('echo -to-file ${quote(path)} %val{buffile} %val{cursor_line} %val{cursor_column}')!
	wait_for('source position', fn [path] () !bool {
		return os.is_file(path) && os.file_size(path) > 0
	})!
	return os.read_file(path)!.trim_space()
}

fn (check PaneCheck) assert_position(position string, label string) ! {
	actual := check.position()!
	if actual != '${check.source} ${position}' {
		return error('${label}: unexpected source position ${actual}')
	}
}

fn (check PaneCheck) panes() ![]string {
	return check.run_tmux(['list-panes', '-F', '#{pane_id}'])!.split_into_lines()
}

fn (check PaneCheck) opened_pane(original string, label string) !string {
	wait_for(label, fn [check] () !bool {
		return check.panes()!.len == 2
	})!
	for pane in check.panes()! {
		if pane != original {
			return pane
		}
	}
	return error('${label}: missing auxiliary pane')
}

fn (check PaneCheck) wait_text(args []string, text string, label string) ! {
	wait_for(label, fn [check, args, text] () !bool {
		return check.run_tmux(args)!.contains(text)
	})!
}

fn title_query(pane string) []string {
	return ['display-message', '-p', '-t', pane, '#{pane_title}']
}

fn (check PaneCheck) close_pane(pane string, keys []string, label string) ! {
	mut args := ['send-keys', '-t', pane]
	args << keys
	check.run_tmux(args)!
	wait_for(label, fn [check] () !bool {
		return check.panes()!.len == 1
	})!
}

fn (check PaneCheck) exercise(original string, tree_close_keys []string) ! {
	check.remote('select ${source_at_call}')!
	check.run_tmux(['send-keys', '-t', original, 'Space', 'F'])!
	tree := check.opened_pane(original, 'tree pane')!
	check.wait_text(['capture-pane', '-p', '-t', tree], 'q close pane', 'tree close hint')!
	check.assert_position('9 14', 'Tree changed the source cursor')!
	target := os.join_path(check.root, "a quoted 'target'.v")
	check.wait_text(['capture-pane', '-p', '-t', tree], os.base(target),
		'tree includes the quoted file')!
	// The first entry below the root is the quoted fixture.
	check.run_tmux(['send-keys', '-t', tree, 'g', 'g', 'j', 'j', 'j', 'j', 'Enter'])!
	wait_for('tree opens the selected file in the source pane', fn [check, target] () !bool {
		return check.position()!.starts_with(target + ' ')
	})!
	check.close_pane(tree, tree_close_keys, 'tree closes')!
	check.remote('edit -existing -- ${quote(check.source)}; select ${source_at_call}')!
	check.assert_position('9 14', 'Restoring the source cursor after tree navigation')!

	check.run_tmux(['send-keys', '-t', original, 'Space', 'g'])!
	peek := check.opened_pane(original, 'definition pane')!
	check.wait_text(title_query(peek), definition_title, 'definition target')!
	check.close_pane(peek, ['q'], 'peek closes')!
	check.assert_position('9 14', 'Peek changed the source cursor')!

	check.run_tmux(['send-keys', '-t', original, 'Space', 'w'])!
	extra := check.opened_pane(original, 'extra view')!
	check.wait_text(title_query(extra), call_title, 'same file and cursor in extra view')!
	check.run_tmux(['send-keys', '-t', extra, 'g', 'g'])!
	check.wait_text(title_query(extra), first_line_title, 'extra cursor moves independently')!
	check.assert_position('9 14', 'Moving the extra view changed the source cursor')!
	check.remote('select ${source_at_definition}')!
	check.assert_position('4 4', 'Source cursor did not move')!
	if !check.run_tmux(title_query(extra))!.contains(first_line_title) {
		return error('Moving the source changed the extra view cursor')
	}
	check.close_pane(extra, ['Space', 'q'], 'extra view closes')!
}

fn (check PaneCheck) run_client() ! {
	wait_for('Kakoune server', fn [check] () !bool {
		sessions := command(command_line(check.kak, ['-l'])) or { return false }
		return check.session in sessions.split_into_lines()
	})!
	client_file := os.join_path(check.root, 'client')
	client := command_line(check.kak, ['-c', check.session, '-e',
		'edit -existing ${quote(check.source)}; echo -to-file ${quote(client_file)} %val{client}'])
	// Start detached with fixed dimensions and no user's tmux configuration.
	check.run_tmux(['-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', '140', '-y', '40',
		client])!
	wait_for('first client', fn [client_file] () !bool {
		return os.is_file(client_file) && os.file_size(client_file) > 0
	})!
	panes := check.panes()!
	if panes.len != 1 {
		return error('Expected one starting tmux pane, got ${panes.len}')
	}
	check.exercise(panes[0], ['Space', 'q'])!
	check.exercise(panes[0], ['q'])!
	// Directory startup without a module uses a scratch source buffer. The
	// auxiliary client must select that shared buffer rather than edit its name.
	check.remote('edit -scratch *project*; set-option global v_workspace_root ${quote(check.root)}; v-tree-pane')!
	scratch_tree := check.opened_pane(panes[0], 'scratch project tree pane')!
	check.wait_text(['capture-pane', '-p', '-t', scratch_tree], 'q close pane', 'scratch tree close hint')!
	check.close_pane(scratch_tree, ['q'], 'scratch project tree closes')!
	check.remote("edit -existing -- ${quote(check.source)}; set-option global v_workspace_root ''")!
}

fn stop(mut server os.Process) {
	// The remote quit is asynchronous. The launcher cleans its restart
	// directory when Kakoune exits and it can run its EXIT trap.
	deadline := time.sys_mono_now() + u64(stop_timeout)
	for time.sys_mono_now() < deadline && server.is_alive() {
		time.sleep(poll_interval)
	}
	if server.is_alive() {
		server.signal_kill()
		server.status = .running
		server.wait()
	}
	server.close()
}

fn run(prefix_path string) ! {
	prefix := os.real_path(prefix_path)
	bin := os.join_path(prefix, 'bin')
	managed_kak := os.join_path(bin, 'kak')
	kak := if os.is_executable(managed_kak) {
		managed_kak
	} else {
		os.find_abs_path_of_executable('kak')!
	}
	launcher := os.join_path(bin, 'kak-v')
	tmux := os.find_abs_path_of_executable('tmux')!
	if !os.is_executable(launcher) {
		return error('Missing managed launcher: ${launcher}')
	}
	os.setenv('PATH', bin + ':' + os.getenv('PATH'), true)
	session := 'vlang-panes-' + rand.uuid_v4()
	directory := os.join_path(os.temp_dir(), session)
	os.mkdir(directory, mode: 0o700)!
	defer { os.rmdir_all(directory) or {} }
	root := os.join_path(directory, 'project with spaces')
	os.mkdir(root)!
	source := os.join_path(root, 'main.v')
	os.write_file(source, fixture)!
	os.write_file(os.join_path(root, "a quoted 'target'.v"), 'module main\n')!
	os.write_file(os.join_path(root, 'v.mod'), "Module { name: 'pane_check' }\n")!
	check := PaneCheck{
		kak:     kak
		tmux:    tmux
		session: session
		root:    root
		source:  source
	}
	mut server := os.new_process(launcher)
	server.set_args(['-d', '-s', session, source])
	server.run()
	defer {
		check.run_tmux(['kill-server']) or {}
		check.post('kill!') or {}
		stop(mut server)
	}
	check.run_client()!
	println('ok - real tmux tree, definition peek, same-file views and closing (repeated)')
}

if os.args.len != 2 {
	eprintln('Usage: v run tests/panes.vsh PREFIX')
	exit(2)
}
run(os.args[1]) or {
	eprintln('not ok - pane interaction: ${err}')
	exit(1)
}
