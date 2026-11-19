// Record the README demonstration from a real managed Kakoune session.
import demoframes
import editorui { quote }
import os
import rand
import releasetest { capture }
import time
import x.json2

const usage = 'Usage: v run tests/record_demo.vsh MANAGED_PREFIX OUTPUT.gif [--frames DIRECTORY]'
const poll = 100 * time.millisecond
const action_timeout = 30 * time.second
const test_timeout = 60 * time.second
const debugger_timeout = 90 * time.second
const pane = 'test:0.0'
const client = 'demo'
const frame_count = 6
const frame_delay = '300' // GIF delay is measured in hundredths of a second.
// One-based selections in the two demo sources.
const definition_line = '4'
const call_selection = '9.14,9.14'
const test_selection = '4.5,4.5'
const breakpoint_selection = '5.5,5.5'
const demo_source = 'module main

// Add two numbers.
fn add(a int, b int) int {
    return a + b
}

fn main() {
    println(add(1, 2))
}
'

const demo_test = 'module main

fn test_add() {
    assert add(1, 2) == 3
}
'

struct Recorder {
	root          string
	project       string
	session       string
	kak           string
	imagemagick   string
	compiler_root string
	environment   map[string]string
mut:
	frames []string
}

fn wait_for(label string, timeout time.Duration, ready fn () !bool) ! {
	deadline := time.sys_mono_now() + u64(timeout)
	for time.sys_mono_now() < deadline {
		if ready()! {
			return
		}
		time.sleep(poll)
	}
	return error('Timed out waiting for ${label}')
}

fn (rec Recorder) tmux(args []string) !string {
	mut command := ['-S', os.join_path(rec.root, 'tmux.sock')]
	command << args
	return capture('tmux', command, true, work_folder: rec.project, environment: rec.environment)!
}

fn (rec Recorder) send(command string) ! {
	capture(rec.kak, ['-p', rec.session], true, environment: rec.environment, input: command + '\n')!
}

fn (rec Recorder) remote(command string) ! {
	done := os.join_path(rec.root, 'done')
	if os.exists(done) {
		os.rm(done)!
	}
	rec.send('evaluate-commands -client ${client} %{ ${command}\necho -to-file ${quote(done)} done }')!
	wait_for(command, action_timeout, fn [done] () !bool {
		return os.is_file(done) && os.read_file(done)!.trim_space() == 'done'
	})!
}

fn (rec Recorder) value(expression string) !string {
	path := os.join_path(rec.root, 'value')
	rec.remote('echo -to-file ${quote(path)} ${expression}')!
	return os.read_file(path)!.trim_space()
}

fn (rec Recorder) keys(keys []string) ! {
	mut args := ['send-keys', '-t', pane]
	args << keys
	rec.tmux(args)!
}

fn (rec Recorder) wait_screen(text string, timeout time.Duration) ! {
	wait_for(text, timeout, fn [rec, text] () !bool {
		return rec.tmux(['capture-pane', '-p', '-t', pane])!.contains(text)
	})!
}

fn (mut rec Recorder) frame(title string) ! {
	screen := rec.tmux(['capture-pane', '-p', '-e', '-t', pane])!
	// Replace only the fixture path and session label before drawing.
	mut normalized := screen.replace(rec.project, '~/demo').replace(rec.root, '~/demo-recording').replace(rec.session,
		'vlang-demo')
	if rec.compiler_root != '' {
		normalized = normalized.replace(rec.compiler_root, '~/.v')
	}
	stem := os.join_path(rec.root, 'demo-${rec.frames.len + 1}')
	drawing_path := stem + '.mvg'
	frame_path := stem + '.png'
	os.write_file(stem + '.ansi', normalized)!
	caption := '${rec.frames.len + 1} / ${frame_count}   ${title}'
	os.write_file(drawing_path, demoframes.drawing(normalized, caption))!
	capture(rec.imagemagick, ['mvg:${drawing_path}', '-alpha', 'remove', '-depth', '8',
		'PNG:${frame_path}'], true)!
	rec.frames << frame_path
}

fn (mut rec Recorder) record() ! {
	source := os.join_path(rec.project, 'main.v')
	test_file := os.join_path(rec.project, 'main_test.v')
	mut daemon := os.new_process(rec.kak)
	daemon.set_args(['-d', '-s', rec.session, source])
	daemon.set_environment(rec.environment)
	daemon.set_work_folder(rec.project)
	daemon.use_pgroup = true
	daemon.run()
	defer {
		if screen := rec.tmux(['capture-pane', '-p', '-t', pane]) {
			os.write_file(os.join_path(rec.root, 'last-screen.txt'), screen) or {}
		}
		rec.tmux(['kill-server']) or {}
		rec.send('kill!') or {}
		if daemon.is_alive() {
			daemon.signal_pgkill()
			daemon.wait()
		}
		daemon.close()
	}

	wait_for('Kakoune server', action_timeout, fn [rec] () !bool {
		sessions := capture(rec.kak, ['-l'], true, environment: rec.environment)!
		return rec.session in sessions.split_into_lines()
	})!
	ready := os.join_path(rec.root, 'ready')
	// tmux takes one shell command. Quote the Kakoune argv individually.
	initial := 'edit -existing ${quote(source)}; rename-client ${client}; echo -to-file ${quote(ready)} ready'
	args := [rec.kak, '-c', rec.session, '-e', initial]
	command := args.map(os.quoted_path(it)).join(' ')
	rec.tmux(['-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', demoframes.columns.str(),
		'-y', demoframes.rows.str(), command])!
	wait_for('demo client', action_timeout, fn [ready] () !bool {
		return os.is_file(ready)
	})!
	rec.tmux(['set-option', 'status', 'off'])!
	rec.remote('select ${call_selection}')!
	wait_for('V language server mappings', action_timeout, fn [rec] () !bool {
		return rec.value('%opt{v_menu_lsp}')! == 'nop'
	})!

	rec.keys(['Space'])!
	rec.wait_screen('Go to definition', action_timeout)!
	rec.frame('Space: commands for the current context')!
	rec.keys(['Escape'])!
	wait_for('source menu to close', action_timeout, fn [rec] () !bool {
		return !rec.tmux(['capture-pane', '-p', '-t', pane])!.contains('user mapping')
	})!
	rec.keys(['Space', 'd'])!
	wait_for('definition jump', action_timeout, fn [rec] () !bool {
		return rec.value('%val{cursor_line}')! == definition_line
	})!
	rec.wait_screen('main.v ${definition_line}:', action_timeout)!
	rec.frame('Space d: jump to a definition')!

	rec.remote('select ${call_selection}')!
	rec.keys(['Space', 'H'])!
	wait_for('documentation buffer', action_timeout, fn [rec] () !bool {
		return rec.value('%val{bufname}')!.starts_with('*hover*')
	})!
	rec.wait_screen('Add two numbers.', action_timeout)!
	rec.frame('Space H: function documentation; q returns')!

	rec.keys(['q'])!
	rec.remote('edit -existing ${quote(source)}')!
	rec.keys(['Space', 'F'])!
	wait_for('explorer buffer', action_timeout, fn [rec] () !bool {
		return rec.value('%val{bufname}')!.starts_with('*v-tree-')
	})!
	rec.wait_screen('main_test.v', action_timeout)!
	rec.frame('Space F: project explorer; Enter opens, q returns')!

	rec.keys(['q'])!
	rec.remote('edit ${quote(test_file)}; select ${test_selection}')!
	rec.keys(['Space', 'T'])!
	rec.wait_screen('1 passed, 1 total', test_timeout)!
	rec.frame('Space T in a test file: run the test at the cursor')!

	rec.remote('edit -existing ${quote(source)}; select ${breakpoint_selection}; v-debug-breakpoint; v-debug')!
	wait_for('debug breakpoint', debugger_timeout, fn [rec] () !bool {
		return rec.value('%opt{v_debug_phase}')! == 'stopped'
	})!
	state_path := os.join_path(rec.value('%opt{v_debug_directory}')!, 'state.json')
	wait_for('debug variables', action_timeout, fn [state_path] () !bool {
		if !os.is_file(state_path) {
			return false
		}
		state := json2.decode[map[string]json2.Any](os.read_file(state_path)!) or { return false }
		ready := state['variables_ready'] or { return false }
		return ready == json2.Any(true)
	})!
	rec.remote('v-debug-variables')!
	rec.wait_screen('a = 1', action_timeout)!
	rec.wait_screen('b = 2', action_timeout)!
	rec.keys(['Space'])!
	rec.wait_screen('Continue', action_timeout)!
	rec.frame('Space while debugging: values, continue and stepping')!
	rec.remote('v-debug-stop')!
}

fn (rec Recorder) save(output string, frames_dir string) ! {
	animation := os.join_path(rec.root, 'demo.gif')
	mut command := ['-delay', frame_delay, '-loop', '0']
	command << rec.frames
	command << ['-layers', 'Optimize', 'GIF:${animation}']
	capture(rec.imagemagick, command, true)!
	pages := capture(rec.imagemagick, ['-ping', animation, '-format', '%p\n', 'info:'], true)!
	if pages.split_into_lines().len != frame_count {
		return error('Expected ${frame_count} frames in the encoded GIF')
	}
	os.mkdir_all(os.dir(output))!
	temporary := output + '.next-' + rand.uuid_v4()
	defer { os.rm(temporary) or {} }
	os.cp(animation, temporary)!
	os.rename_dir(temporary, output)!
	if frames_dir != '' {
		os.mkdir_all(frames_dir)!
		for frame_path in rec.frames {
			os.cp(frame_path, os.join_path(frames_dir, os.file_name(frame_path)))!
		}
	}
}

fn make_recorder(prefix string) !Recorder {
	imagemagick := os.find_abs_path_of_executable('magick') or {
		os.find_abs_path_of_executable('convert') or {
			return error('ImageMagick is required to encode the demo.')
		}
	}
	kak := os.join_path(prefix, 'bin', 'kak')
	if !os.is_file(kak) || !os.is_executable(kak) {
		return error('Managed Kakoune launcher not found at ${kak}')
	}
	os.find_abs_path_of_executable('tmux')!
	root := os.join_path(os.temp_dir(), 'vlang-demo-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	println('Recording artifacts at ${root}')
	project := os.join_path(root, 'demo')
	os.mkdir(project)!
	os.write_file(os.join_path(project, 'main.v'), demo_source)!
	os.write_file(os.join_path(project, 'main_test.v'), demo_test)!
	os.write_file(os.join_path(project, 'v.mod'), "Module { name: 'demo' }\n")!
	config := os.join_path(root, 'config')
	os.mkdir_all(os.join_path(config, 'kak'))!
	plugin := quote(os.join_path(os.dir(@DIR), 'rc', 'vlang.kak'))
	kakrc := 'eval %sh{kak-lsp}\nset-option global lsp_cmd ' +
		quote('kak-lsp --session "$kak_session"') +
		'\nsource ${plugin}\nset-option global v_pane_mode off\n'
	os.write_file(os.join_path(config, 'kak', 'kakrc'), kakrc)!
	mut env := os.environ()
	env.delete('TMUX')
	env.delete('TMUX_PANE')
	env.delete('VLANG_KAK_CONFIG_HOME')
	env['PATH'] = os.join_path(prefix, 'opt', 'vlang-kak-lsp', 'current', 'bin') + ':' +
		os.join_path(prefix, 'bin') + ':' + os.getenv('PATH')
	// Keep unrelated compiler notices and their local source paths out of the demo.
	env['VFLAGS'] = (os.getenv('VFLAGS') + ' -n -w').trim_space()
	env['VLANG_KAK_PREFIX'] = prefix
	env['XDG_CONFIG_HOME'] = config
	env['XDG_CACHE_HOME'] = os.join_path(root, 'cache')
	prefix_v := os.join_path(prefix, 'bin', 'v')
	managed_v := os.join_path(prefix, 'opt', 'vlang-v', 'current', 'v')
	compiler_path := if os.is_executable(prefix_v) && os.is_executable(managed_v) {
		managed_v
	} else if os.is_executable(prefix_v) {
		prefix_v
	} else {
		os.find_abs_path_of_executable('v')!
	}
	compiler_dir := os.dir(os.real_path(compiler_path))
	return Recorder{
		root:          root
		project:       project
		session:       'vlang-demo-' + rand.uuid_v4()[..10]
		kak:           kak
		imagemagick:   imagemagick
		compiler_root: if os.is_dir(os.join_path(compiler_dir, 'vlib')) { compiler_dir } else { '' }
		environment:   env
	}
}

fn run(args []string) ! {
	if args in [['--help'], ['-h']] {
		println(usage)
		println('Capture six real IDE screens. Requires ImageMagick, DejaVu Sans Mono, tmux and GDB with DAP.')
		return
	}
	mut positional := []string{}
	mut frames_dir := ''
	for i := 0; i < args.len; i++ {
		arg := args[i]
		if arg == '--frames' && i + 1 < args.len {
			i++
			frames_dir = args[i]
		} else if arg.starts_with('--frames=') {
			frames_dir = arg.all_after('=')
		} else if arg.starts_with('-') {
			return error_with_code(usage, 2)
		} else {
			positional << arg
		}
	}
	if positional.len != 2 {
		return error_with_code(usage, 2)
	}
	mut recorder := make_recorder(os.real_path(positional[0]))!
	recorder.record()!
	output := os.abs_path(positional[1])
	recorder.save(output, frames_dir)!
	os.rmdir_all(recorder.root)!
	println('Recorded six real IDE screens at ${output}')
}

run(os.args[1..]) or {
	eprintln(err)
	exit(if err.code() == 2 { 2 } else { 1 })
}
