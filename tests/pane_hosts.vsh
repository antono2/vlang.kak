// Check real terminal rendering, client navigation, and independent panes.
import editorui { quote }
import os
import rand
import releasetest { capture }
import terminalhosts
import time
import x.json2

const wait_timeout = 30 * time.second
const server_timeout = 10 * time.second
const debug_write_grace_period = 100 * time.millisecond
const navigation_repetitions = 2
const usage = 'Usage: v run tests/pane_hosts.vsh PREFIX BACKEND [--artifacts DIRECTORY]'
const source_client = 'source'
const unsaved_marker = 'unsaved pane check'
// One-based positions in the source below and in auxiliary clients.
const call_selection = '9.14,9.14'
const callee_selection = '4.4,4.4'
const call_position = '9 14'
const callee_position = '4 4'
const start_position = '1 1'
const fixture = 'module main\n\n// Add two numbers.\nfn add(a int, b int) int {\n    return a + b\n}\n\nfn main() {\n    println(add(1, 2))\n}\n'
const detect_backend = r'%sh{: "$kak_client_env_ZELLIJ" "$kak_client_env_ZELLIJ_SESSION_NAME" "$kak_client_env_WEZTERM_PANE" "$kak_client_env_KITTY_WINDOW_ID" "$kak_client_env_STY" "$kak_client_env_DISPLAY" "$kak_client_env_WAYLAND_DISPLAY"; source=$(readlink -f "$kak_opt_v_plugin_source"); "${source%/rc/vlang.kak}/scripts/windowing.sh" detect auto}'

struct Check {
	kak    string
	source string
	target string
	host   &terminalhosts.Host
}

struct Requested {
	prefix    string
	backend   string
	artifacts string
}

fn require(condition bool, detail string) ! {
	if !condition {
		return error(detail)
	}
}

fn await_condition(label string, ready fn () !bool) ! {
	terminalhosts.wait_for(label, wait_timeout, ready)!
}

fn (check Check) post(command string) ! {
	capture(check.kak, ['-p', check.host.name], true,
		environment: check.host.env
		input:       command + '\n'
		timeout:     server_timeout
	)!
}

fn (check Check) remote(client string, command string) ! {
	done := os.join_path(check.host.root, 'done-' + rand.uuid_v4())
	defer { os.rm(done) or {} }
	check.post('evaluate-commands -client ${quote(client)} %{\n${command}\necho -to-file ${quote(done)} done\n}')!
	await_condition('command: ${command}', fn [done] () !bool {
		text := os.read_file(done) or { return false }
		return text.trim_space() == 'done'
	})!
}

fn (check Check) value(client string, expression string) !string {
	path := os.join_path(check.host.root, 'value')
	if os.exists(path) {
		os.rm(path)!
	}
	check.remote(client, 'echo -to-file ${quote(path)} ${expression}')!
	return os.read_file(path)!.trim_space()
}

fn (check Check) position(client string) !string {
	return check.value(client, '%val{buffile} %val{cursor_line} %val{cursor_column}')
}

fn (check Check) position_is(client string, expected string) ! {
	await_condition('position ${expected} in ${client}', fn [check, client, expected] () !bool {
		return check.position(client)! == expected
	})!
}

fn (check Check) pane_count(count int, label string) ! {
	await_condition(label, fn [check, count] () !bool {
		return check.host.panes()!.len == count
	})!
}

fn (check Check) display_contains(pane string, snippet string, label string) ! {
	await_condition(label, fn [check, pane, snippet] () !bool {
		return check.host.capture(pane)!.contains(snippet)
	})!
}

fn (check Check) other_client() !string {
	for client in check.value(source_client, '%val{client_list}')!.fields() {
		if client != source_client {
			return client
		}
	}
	return ''
}

fn (check Check) auxiliary(original string, label string) !(string, string) {
	check.pane_count(2, label)!
	await_condition('${label} client', fn [check] () !bool {
		return check.other_client()! != ''
	})!
	for pane in check.host.panes()! {
		if pane != original {
			return pane, check.other_client()!
		}
	}
	return error('No auxiliary pane for ${label}')
}

fn (check Check) assert_backend() ! {
	actual := check.value(source_client, detect_backend)!
	expected := if check.host.backend == 'wayland' { 'native' } else { check.host.backend }
	if actual != expected {
		eprintln('Plugin source: ' + check.value(source_client, '%opt{v_plugin_source}')!)
		eprintln('Client environment: ' + check.value(source_client,
			'%val{client_env_ZELLIJ} %val{client_env_ZELLIJ_SESSION_NAME}')!)
		return error('Expected ${expected} backend for ${check.host.backend}, got ${actual}')
	}
}

fn (check Check) open_quoted_path(tree string, client string) ! {
	state_path := check.value(client, '%opt{v_tree_state}')!
	state := json2.decode[json2.Any](os.read_file(state_path)!)!.as_map()
	rows := state['rows'] or { return error('Tree state lacks rows') }
	for index, row in rows.as_array() {
		path := row.as_map()['path'] or { continue }
		if path.str() == check.target {
			line := index + 1
			check.remote(client, 'select ${line}.1,${line}.1')!
			check.host.send(tree, '\r')!
			await_condition('tree opens quoted path in source client', fn [check] () !bool {
				return check.position(source_client)!.starts_with(check.target + ' ')
			})!
			return
		}
	}
	return error('Tree did not render the quoted target path')
}

fn (check Check) tree(original string, first bool) ! {
	check.remote(source_client, 'select ${call_selection}')!
	check.host.send(original, ' F')!
	tree, client := check.auxiliary(original, 'tree pane')!
	check.display_contains(tree, 'q close pane', 'tree close hint')!
	if first {
		check.open_quoted_path(tree, client)!
	}
	check.host.send(tree, if first { ' q' } else { 'q' })!
	check.pane_count(1, 'tree closes')!
	check.remote(source_client, 'edit -existing ${quote(check.source)}; select ${call_selection}')!
	check.display_contains(original, unsaved_marker, 'source redraw after closing the tree')!
	contents := os.join_path(check.host.root, 'buffer-contents')
	check.remote(source_client, "evaluate-commands -draft %{ execute-keys '%'; echo -to-file ${quote(contents)} %val{selection} }")!
	require(os.read_file(contents)!.contains(unsaved_marker)
		&& !os.read_file(check.source)!.contains(unsaved_marker), 'Closing the tree lost or saved the unsaved edit')!
}

fn (check Check) peek_and_view(original string) ! {
	check.host.send(original, ' g')!
	peek, client := check.auxiliary(original, 'definition peek')!
	check.position_is(client, '${check.source} ${callee_position}')!
	check.host.send(peek, 'q')!
	check.pane_count(1, 'peek closes')!
	require(check.position(source_client)! == '${check.source} ${call_position}', 'Peek moved the source cursor')!

	check.host.send(original, ' w')!
	extra, view := check.auxiliary(original, 'same-file view')!
	check.position_is(view, '${check.source} ${call_position}')!
	check.host.send(extra, 'gg')!
	check.position_is(view, '${check.source} ${start_position}')!
	require(check.position(source_client)! == '${check.source} ${call_position}', 'Moving the auxiliary cursor moved the source cursor')!
	check.remote(source_client, 'select ${callee_selection}')!
	require(check.position(view)! == '${check.source} ${start_position}', 'Moving the source cursor moved the auxiliary cursor')!
	check.host.send(extra, ' q')!
	check.pane_count(1, 'same-file view closes')!
}

fn (check Check) exercise() ! {
	check.pane_count(1, 'initial pane')!
	initial := check.host.panes()!
	require(initial.len == 1, 'The source must start with one pane')!
	original := initial[0]
	check.assert_backend()!
	check.remote(source_client, "execute-keys 'gei // ${unsaved_marker}<esc>'")!
	for attempt in 0 .. navigation_repetitions {
		check.tree(original, attempt == 0)!
		check.peek_and_view(original)!
	}
	println('ok - real ${check.host.backend}: detection, tree/open/close, peek, independent views, unsaved edits and repeated use')
}

fn (check Check) collect() {
	for pane in check.host.panes() or { []string{} } {
		text := check.host.capture(pane) or { continue }
		os.write_file(os.join_path(check.host.root, 'pane-${pane}.txt'), text) or {}
	}
	debug_path := os.join_path(check.host.root, 'kak-debug')
	check.post('evaluate-commands -draft -buffer *debug* %{ write -force ${quote(debug_path)} }') or {}
	time.sleep(debug_write_grace_period)
	check.post('kill!') or {}
}

fn environment(prefix string, root string) map[string]string {
	mut env := os.environ()
	for key in ['TMUX', 'TMUX_PANE', 'ZELLIJ', 'ZELLIJ_SESSION_NAME', 'ZELLIJ_PANE_ID', 'WEZTERM_PANE',
		'WEZTERM_UNIX_SOCKET', 'KITTY_WINDOW_ID', 'KITTY_LISTEN_ON', 'STY', 'WAYLAND_DISPLAY',
		'DISPLAY', 'ITERM_SESSION_ID', 'SWAYSOCK'] {
		env.delete(key)
	}
	env['PATH'] = os.join_path(prefix, 'opt/vlang-kak-lsp/current/bin') + ':' +
		os.join_path(prefix, 'bin') + ':' + env['PATH']
	env['XDG_CONFIG_HOME'] = os.join_path(root, 'config')
	env['XDG_CACHE_HOME'] = os.join_path(root, 'cache')
	env['XDG_DATA_HOME'] = os.join_path(root, 'data')
	return env
}

fn prepare_config(root string, backend string) ! {
	path := os.join_path(root, 'config/kak/kakrc')
	os.mkdir_all(os.dir(path))!
	plugin := quote(os.join_path(os.dir(@DIR), 'rc/vlang.kak'))
	mut lines := [
		'eval %sh{kak-lsp}',
		'set-option global lsp_cmd \'kak-lsp --session "\$kak_session"\'',
		'source ${plugin}',
		'set-option global v_window_backend auto',
	]
	if backend == 'native' {
		lines << 'try %{ declare-option str termcmd }'
		lines << 'set-option global termcmd ${quote(os.quoted_path(os.join_path(root, 'terminal')) + ' sh -c')}'
	}
	os.write_file(path, lines.join('\n') + '\n')!
}

fn run(request Requested) ! {
	name := 'vlang-host-' + rand.uuid_v4()[..12]
	artifacts := if request.artifacts == '' {
		os.join_path(os.temp_dir(), name)
	} else {
		request.artifacts
	}
	os.mkdir_all(artifacts)!
	root := os.real_path(artifacts)
	os.chmod(root, 0o700)!
	prefix := os.real_path(request.prefix)
	kak := os.join_path(prefix, 'bin/kak')
	prepare_config(root, request.backend)!
	project := os.join_path(root, 'project with spaces')
	os.mkdir(project)!
	source := os.join_path(project, 'main.v')
	os.write_file(source, fixture)!
	os.write_file(os.join_path(project, 'v.mod'), "Module { name: 'pane_test' }\n")!
	target := os.join_path(project, "it's.v")
	os.write_file(target, 'module main\nfn other() {}\n')!
	os.signal_ignore(.pipe)
	mut host := terminalhosts.create(request.backend, root, name, environment(prefix, root))!
	host.prepare() or {
		host.stop()
		return err
	}
	mut server_env := host.env.clone()
	if request.backend in ['native', 'wayland'] {
		server_env.delete('DISPLAY')
		server_env.delete('WAYLAND_DISPLAY')
	}
	mut server := os.new_process(kak)
	server.set_args(['-d', '-s', name, source])
	server.set_environment(server_env)
	server.run()
	check := Check{ kak: kak, source: source, target: target, host: host }
	defer {
		check.collect()
		host.stop()
		terminalhosts.finish_process(mut server, false, server_timeout)
		println('Pane test artifacts: ${root}')
	}
	await_condition('Kakoune daemon', fn [check, name] () !bool {
		return name in capture(check.kak, ['-l'], true, environment: check.host.env)!.split_into_lines()
	})!
	ready := os.join_path(root, 'client')
	host.start([kak, '-c', name, '-e',
		'edit -existing ${quote(source)}; rename-client ${source_client}; echo -to-file ${quote(ready)} ready'])!
	await_condition('first client', fn [ready] () !bool {
		return os.is_file(ready)
	})!
	check.exercise()!
}

fn parse(args []string) !Requested {
	if args.len !in [2, 4] || args[1] !in terminalhosts.backends || (args.len == 4 && args[2] != '--artifacts') {
		return error_with_code(usage, 2)
	}
	return Requested{
		prefix:    args[0]
		backend:   args[1]
		artifacts: if args.len == 4 {
			args[3]
		} else {
			''
		}
	}
}

if os.args.len >= 5 && os.args[1] == '--host-child' {
	terminalhosts.launch_background(os.args[2..]) or {
		eprintln(err)
		exit(1)
	}
} else if terminalhosts.is_shim() {
	terminalhosts.launch_shim() or {
		eprintln(err)
		exit(1)
	}
} else if os.args[1..] in [['--help'], ['-h']] {
	println(usage)
	println('Backends: ' + terminalhosts.backends.join(', '))
} else {
	request := parse(os.args[1..]) or {
		eprintln(err)
		exit(2)
	}
	run(request) or {
		eprintln('not ok - real ${request.backend}: ${err}')
		exit(1)
	}
}
