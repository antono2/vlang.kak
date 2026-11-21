// Verify the real Kakoune debugger against GDB's Debug Adapter Protocol.
import editorui { quote }
import json2
import os
import rand
import releasetest { capture }
import time

#include <unistd.h>

fn C.dup2(int, int) int

const debugger_timeout = 30 * time.second
const cleanup_timeout = 5 * time.second
const poll = 30 * time.millisecond
const editor_idle_timeout_ms = 50
// Leave the fake build running long enough for the debugger to cancel it.
const cancellable_build_seconds = 30
// One-based source and panel positions in the fixtures below.
const addition_line = 4
const return_line = 5
const entry_line = 7
const caller_line = 8
const print_line = 9
const test_line = 4
const values_line = 11
// Well beyond the fixture and the source lines GDB can map to generated code.
const nonexistent_source_line = 99999
const first_row = '2.1,2.1'
const caller_row = '3.1,3.1'
const watch_row = '4.1,4.1'
const sum_watch = 'a + b'
const source = 'module main
import os
fn add(a int, b int) int {
    result := a + b
    return result
}
fn main() {
    answer := add(2, 3)
    println(answer)
    text := os.input("input: ")
    println("received: " + text)
    println(os.args.last())
    println(os.getenv("MODE"))
}
'
const inspected_source = 'module main
struct Person {
 name string
 age int
}
fn main() {
 greeting := "hello V"
 numbers := [2, 3, 5]
 person := Person{"Ada", 36}
 empty := []int{}
 println(greeting)
 println(numbers)
 println(person)
 println(empty)
}
'

struct Breakpoint {
	line     int
	verified bool
}

struct Variable {
	name      string
	value     string
	reference int @[json: 'variablesReference']
}

struct Frame {
	id int
}

struct State {
	phase           string
	message         string
	file            string
	line            int
	frames          []Frame
	variables       []Variable
	variables_ready bool
	watches         map[string]string
	watch_refs      map[string]int
	breakpoints     []Breakpoint
	output          string
}

struct Check {
	root      string
	script    string
	main_file string
	state_dir string
mut:
	editor &editorui.Client
}

fn require(condition bool, detail string) ! {
	if !condition {
		return error(detail)
	}
}

fn (state State) stopped_at(line int) bool {
	return state.phase == 'stopped' && state.line == line && state.variables_ready
}

fn (state State) stopped_in(path string) bool {
	return state.phase == 'stopped' && state.file == path && state.variables_ready
}

fn (state State) variable(name string) !Variable {
	for item in state.variables {
		if item.name == name {
			return item
		}
	}
	return error('Debugger did not expose variable ${name}')
}

fn (check Check) state() State {
	text := os.read_file(os.join_path(check.state_dir, 'state.json')) or { return State{} }
	return json2.decode[State](text) or { State{} }
}

fn (mut check Check) wait_state(label string, ready fn (State) bool) !State {
	deadline := time.sys_mono_now() + u64(debugger_timeout)
	for time.sys_mono_now() < deadline {
		check.editor.offset()
		state := check.state()
		if ready(state) {
			return state
		}
		time.sleep(poll)
	}
	return check.editor.diagnostic('Timed out waiting for ${label}\nState: ${check.state()}')
}

fn (mut check Check) stopped(line int) !State {
	return check.wait_state('stop at V line ${line}', fn [line] (state State) bool {
		return state.stopped_at(line)
	})
}

fn (mut check Check) phase(phase string) !State {
	return check.wait_state('debugger phase ${phase}', fn [phase] (state State) bool {
		return state.phase == phase
	})
}

fn (mut check Check) sync_phase() ! {
	path := os.join_path(check.root, 'editor-phase')
	deadline := time.sys_mono_now() + u64(debugger_timeout)
	for time.sys_mono_now() < deadline {
		check.command('echo -to-file ${quote(path)} %opt{v_debug_phase}')!
		if os.read_file(path)!.trim_space() == check.state().phase {
			return
		}
		time.sleep(poll)
	}
	return check.editor.diagnostic('Kakoune did not reach the debugger phase in state.json')
}

fn (mut check Check) menu(needle string, submenu bool) !string {
	check.editor.keys('<esc>')
	check.sync_phase()!
	start := check.editor.offset()
	check.editor.keys('<space>')
	if submenu {
		check.editor.keys('B')
	}
	text := check.editor.wait_info(start, needle)!
	check.editor.keys('<esc>')
	return text
}

fn (mut check Check) wait_prompt(offset int) ! {
	deadline := time.sys_mono_now() + u64(debugger_timeout)
	for time.sys_mono_now() < deadline {
		if check.editor.transcript(offset).contains('Program input: ') {
			return
		}
		time.sleep(poll)
	}
	return check.editor.diagnostic('Kakoune did not display the program input prompt')
}

fn (mut check Check) wait_unlocked() ! {
	deadline := time.sys_mono_now() + u64(debugger_timeout)
	for time.sys_mono_now() < deadline {
		check.editor.offset()
		// The debugger sends output before the lock is removed on exit.
		result := os.execute('${os.quoted_path(check.script)} active ${os.quoted_path(check.state_dir)}')
		if result.exit_code != 0 {
			return
		}
		time.sleep(poll)
	}
	return check.editor.diagnostic('Debugger lock was not released')
}

fn (mut check Check) command(command string) ! {
	check.editor.remote_for(command, debugger_timeout)!
}

fn (mut check Check) stop() ! {
	check.sync_phase()!
	check.command('v-debug-stop')!
}

fn (mut check Check) select_row(row string) ! {
	check.command('select ${row}')!
}

fn (mut check Check) stack_frame(row string) ! {
	// state.json can reach a stop before Kakoune has handled the UI update.
	check.sync_phase()!
	check.command('v-debug-stack')!
	check.select_row(row)!
	check.editor.keys('<ret>')
}

fn (mut check Check) navigation() ! {
	check.command("set-option global v_debug_args 'two words'; set-option global v_debug_env 'MODE=local test'")!
	check.command('select ${line_start_selection(addition_line)}; v-debug-breakpoint-if "a == 2"')!
	require(check.state().breakpoints.map(it.line) == [addition_line], 'Wrong conditional breakpoint line')!
	launch := check.menu('Build and debug', true)!
	require(launch.contains('Toggle breakpoint') && !launch.contains('Run to cursor'), 'Wrong launch menu')!
	check.editor.keys('<space>BB')
	state := check.stopped(addition_line)!
	require(!state.output.contains('tbreak main__main'), 'Normal launch set an entry breakpoint')!
	menu := check.menu('Continue debugging', false)!
	require(['Step over', 'Run to cursor', 'Add watch', 'Evaluate expression'].all(menu.contains(it)),
		'Missing stopped debugger actions')!
	rejection := os.join_path(check.root, 'restart-rejection')
	for command in ['v-restart', 'v-update --no-build --no-lsp', 'v-debug'] {
		if os.exists(rejection) {
			os.rm(rejection)!
		}
		check.command('try %{ ${command}; echo -to-file ${quote(rejection)} allowed } catch %{ echo -to-file ${quote(rejection)} %val{error} }')!
		expected := if command == 'v-debug' { 'A debugger is already active' } else { 'Stop debugging' }
		require(os.read_file(rejection)!.contains(expected) && check.state().phase == 'stopped',
			'The live debugger did not block ${command}')!
	}
	require(state.file == check.main_file && state.breakpoints.len == 1 && state.breakpoints[0].verified
		&& state.variable('a')!.value == '2', 'Wrong stopped source, breakpoint, or argument')!
	check.command('set-register v sentinel; v-debug-variables')!
	require(check.editor.value('%val{bufname} %reg{v}')! == '*v-debug-variables* sentinel',
		'Opening variables changed the user register')!
	check.command('v-debug-return')!
	check.stack_frame(caller_row)!
	check.wait_state('selected caller stack frame', fn (state State) bool {
		return state.line == caller_line
	})!
	check.stack_frame(first_row)!
	check.stopped(addition_line)!
	check.command('v-debug-call action watch "${sum_watch}"')!
	check.wait_state('expression watch', fn (state State) bool {
		return state.watches[sum_watch] == '5'
	})!
	check.command('v-debug-next')!
	require(check.stopped(return_line)!.variable('result')!.value == '5', 'Wrong result after step over')!
	check.command('set-option buffer readonly true')!
	require(!check.menu('Step over', false)!.contains('Run to cursor'), 'Readonly buffer offered Run to Cursor')!
	check.command('declare-option str v_test_cursor_error; try %{ v-debug-run-to-cursor } catch %{ set-option global v_test_cursor_error %val{error} }')!
	check.editor.wait_value('%opt{v_test_cursor_error}', 'Run to cursor requires an unmodified saved source file',
		true, 'refuse run to cursor in a read-only buffer')!
	check.command('set-option buffer readonly false')!
	check.command('v-debug-call action runToCursor ${quote(check.main_file)} ${nonexistent_source_line}')!
	invalid := check.wait_state('invalid run-to-cursor location', fn (state State) bool {
		return state.message.contains('No line')
	})!
	require(invalid.stopped_at(return_line), 'Invalid Run to Cursor changed the stopped frame')!
	check.select_row(line_start_selection(print_line))!
	check.editor.keys('<space>G')
	at_print := check.stopped(print_line)!
	require(at_print.breakpoints.map(it.line) == [addition_line]
		&& at_print.output.contains('tbreak ') && at_print.output.contains(':${print_line}')
		&& at_print.watches[sum_watch].starts_with('<unavailable:'), 'Run to Cursor or watch invalidation failed')!
}

fn (mut check Check) input_and_exit() ! {
	check.command('v-debug-continue')!
	check.wait_input()!
	menu := check.menu('Pause debugging', false)!
	require(!menu.contains('Step over') && !menu.contains('Run to cursor'), 'Running program offered stopped actions')!
	check.command('try %{ v-debug-run-to-cursor } catch %{ set-option global v_test_cursor_error %val{error} }')!
	check.editor.wait_value('%opt{v_test_cursor_error}', 'Pause debugging before running to the cursor',
		true, 'refuse run to cursor while running')!
	check.command('v-debug-pause')!
	check.wait_state('pause running program', fn (state State) bool {
		return state.phase == 'stopped' && state.frames.len > 0
	})!
	check.sync_phase()!
	check.command('declare-option str v_test_input_error; try %{ v-debug-input } catch %{ set-option global v_test_input_error %val{error} }')!
	check.editor.wait_value('%opt{v_test_input_error}', 'Program input is available while running',
		true, 'refuse program input while stopped')!
	check.command('v-debug-continue')!
	check.phase('running')!
	check.command('v-debug-output')!
	check.menu('Send program input', false)!
	start := check.editor.offset()
	check.editor.keys('<ret>')
	check.wait_prompt(start)!
	check.editor.keys('discard this<esc>')
	check.command('nop')!
	state := check.state()
	require(state.phase == 'running' && !state.output.contains('received:'), 'Escape submitted program input')!
	start_again := check.editor.offset()
	check.editor.keys('<ret>')
	check.wait_prompt(start_again)!
	check.editor.keys('hello IDE<ret>')
	completed := check.wait_state('program output and exit', fn (state State) bool {
		return state.phase == 'exited' && state.output.contains('received: hello IDE')
	})!
	require(completed.output.contains('two words') && completed.output.contains('local test'),
		'Debug command lost program arguments or environment')!
	check.command('v-debug-return')!
	idle := check.menu('Debugging', false)!
	require(!idle.contains('Step over') && !idle.contains('Run to cursor'), 'Idle editor offered stopped actions')!
	check.wait_unlocked()!
	check.command('v-debug-output; v-debug-output; v-debug-return')!
}

fn (mut check Check) wait_input() ! {
	check.wait_state('program input prompt', fn (state State) bool {
		return state.phase == 'running' && state.output.contains('input:')
	})!
}

fn (mut check Check) entry_stop() ! {
	check.wait_state('entry stop', fn (state State) bool {
		return state.stopped_at(entry_line) || state.stopped_at(caller_line)
	})!
}

fn (mut check Check) launch_modes() ! {
	check.command('select ${line_start_selection(addition_line)}; v-debug-breakpoint')!
	require(check.state().breakpoints.len == 0, 'Toggling the breakpoint left an active breakpoint')!
	check.command('v-debug')!
	check.wait_input()!
	require(!check.state().output.contains('tbreak main__main'), 'No-breakpoint launch stopped at entry')!
	check.stop()!
	check.phase('idle')!
	check.command('set-option global v_debug_entry main__main; v-debug')!
	check.entry_stop()!
	check.command('v-debug-next')!
	check.stopped(caller_line)!
	check.command('v-debug-step-in')!
	check.stopped(addition_line)!
	check.command('v-debug-step-out')!
	check.wait_state('step out', fn (state State) bool {
		return state.phase == 'stopped' && state.line in [caller_line, print_line]
	})!
	check.stop()!
	idle := check.phase('idle')!
	require(idle.line == 0 && idle.variables.len == 0, 'Stop retained frame variables')!
	check.command("set-option global v_debug_build_command 'sleep ${cancellable_build_seconds} #'; v-debug")!
	check.phase('building')!
	check.stop()!
	cancelled := check.phase('idle')!
	require(cancelled.output.contains('Debug build cancelled'), 'Stop did not cancel the active build')!
	check.wait_unlocked()!
	check.command('set-option global v_debug_build_command false; v-debug')!
	require(check.phase('failed')!.message.contains('Debug build failed'), 'Failed build lacked a diagnostic')!
	check.command('set-option global v_debug_build false; v-debug')!
	check.entry_stop()!
	check.stop()!
	check.phase('idle')!
	check.wait_unlocked()!
}

fn (mut check Check) test_targets() ! {
	test := os.join_path(check.root, 'math_test.v')
	test_source := 'module main\nfn test_math() {\n    result := 2 + 3\n    println(result)\n    assert result == 5\n}\n'
	os.write_file(test, test_source)!
	check.command('edit ${quote(test)}; set-option global v_debug_build true; set-option global v_debug_build_command "v -g -cc gcc"; select ${line_start_selection(test_line)}; v-debug-breakpoint; v-debug')!
	state := check.wait_state('V test breakpoint', fn [test] (state State) bool {
		return state.stopped_in(test) && state.line == test_line
	})!
	require(state.variable('result')!.value == '5', 'Wrong stopped test value')!
	check.stack_frame(caller_row)!
	check.wait_state('generated C caller frame', fn (state State) bool {
		return state.file.ends_with('.c')
	})!
	require(check.menu('Continue debugging', false)!.contains('Step over'), 'Generated C caller lost debugger actions')!
	check.command('v-debug-unwatch "${sum_watch}"; v-debug-continue')!
	check.phase('exited')!
	check.wait_unlocked()!
	check.command('v-debug-return; edit ${quote(test)}; select ${line_start_selection(test_line)}; v-debug-breakpoint; set-option global v_debug_entry ""')!
	require(check.state().breakpoints.len == 0, 'Test breakpoint was not removed')!
	os.write_file(test, test_source.replace('result == 5', 'result == 6'))!
	check.command('edit! ${quote(test)}; v-debug')!
	failed := check.wait_state('failed V test stops without breakpoints', fn [test] (state State) bool {
		return state.stopped_in(test)
	})!
	require(failed.message == 'V assertion failed' && failed.variable('result')!.value == '5',
		'Failed test did not expose the V assertion and value')!
	check.command('v-debug-continue')!
	check.phase('exited')!
}

fn (mut check Check) runtime_errors() ! {
	dir := os.join_path(check.root, 'errors')
	os.mkdir(dir)!
	path := os.join_path(dir, 'main.v')
	os.write_file(path, 'module main\nfn main() {\n    panic("debugger test panic")\n}\n')!
	check.command('edit ${quote(path)}; v-debug')!
	require(check.runtime_stop(path, 'panic')!.message == 'V panic', 'Wrong panic classification')!
	check.command('v-debug-continue')!
	// The DAP exit event and the last program output arrive on separate streams.
	check.wait_state('panic output after program exit', fn (state State) bool {
		return state.phase == 'exited' && state.output.contains('debugger test panic')
	})!

	os.write_file(path, 'module main\nfn main() {\n    assert 2 == 3\n}\n')!
	check.command('edit! ${quote(path)}; v-debug')!
	require(check.runtime_stop(path, 'assertion')!.message == 'V assertion failed', 'Wrong assertion classification')!
	check.stop()!
	check.phase('idle')!

	os.write_file(path, 'module main\nfn main() {\n    unsafe { p := &int(0); println(*p) }\n}\n')!
	check.command('edit! ${quote(path)}; v-debug')!
	message := check.runtime_stop(path, 'native fault')!.message.to_lower()
	require(message.contains('signal') || message.contains('exception'), 'Wrong native fault classification: ${message}')!
	check.stop()!
	check.phase('idle')!
}

fn (mut check Check) runtime_stop(path string, label string) !State {
	return check.wait_state('${label} stops at its user source', fn [path] (state State) bool {
		return state.stopped_in(path)
	})
}

fn (mut check Check) expanded(names []string) ![]string {
	state := check.wait_state('expanded debugger variables ${names}', fn [names] (state State) bool {
		return state.variables.map(it.name) == names
	})!
	return state.variables.map(it.value)
}

fn line_start_selection(line int) string {
	return '${line}.1,${line}.1'
}

fn (mut check Check) values() ! {
	dir := os.join_path(check.root, 'values')
	os.mkdir(dir)!
	path := os.join_path(dir, 'main.v')
	os.write_file(path, inspected_source)!
	check.command('edit ${quote(path)}; select ${line_start_selection(values_line)}; v-debug-breakpoint; set-option window modelinefmt CUSTOM-STATUS; v-debug')!
	state := check.stopped(values_line)!
	require(state.variable('greeting')!.value == '"hello V"'
		&& state.variable('numbers')!.value == '[]int (len=3)'
		&& state.variable('person')!.value == 'main.Person'
		&& state.variable('empty')!.value == '[]int (len=0)', 'Wrong V pretty-printer values')!
	// Source focus and the modeline update are separate from the stopped-state receipt.
	check.editor.wait_value('%val{buffile}', path, false, 'inspect the stopped source window')!
	check.sync_phase()!
	modeline := check.editor.value('%opt{modelinefmt}')!
	require(modeline.starts_with('CUSTOM-STATUS') && modeline.contains('[debug:'), 'Debugger overwrote the modeline')!
	check.command('v-debug-variables')!
	// The heading occupies line one, followed by variable rows and watch rows.
	array_row := state.variables.map(it.name).index('numbers') + 2
	check.select_row(line_start_selection(array_row))!
	check.editor.keys('<ret>')
	require(check.expanded(['[0]', '[1]', '[2]'])! == ['2', '3', '5'], 'Wrong expanded array values')!
	check.command('v-debug-call action watch person')!
	check.wait_state('pretty-printed struct watch', fn (state State) bool {
		return state.watches['person'] == 'main.Person'
	})!
	watch := check.wait_state('expandable watch reference', fn (state State) bool {
		return state.watch_refs['person'] > 0
	})!
	check.select_row(line_start_selection(watch.variables.len + 2 + watch.watches.keys().index('person')))!
	check.editor.keys('<ret>')
	require(check.expanded(['name', 'age'])! == ['"Ada"', '36'], 'Wrong expanded struct fields')!
	check.menu('Remove watch', false)!
	check.editor.keys('<space>-')
	check.editor.keys('person<ret>')
	check.wait_watch(false)!
	require(!check.menu('Step over', false)!.contains('Remove watch'), 'Removed watch still has a menu action')!
	check.command('v-debug-call action watch person')!
	check.wait_watch(true)!
	check.command('v-debug-variables; select ${watch_row}')!
	check.editor.keys('<del>')
	check.wait_watch(false)!
	literal_watch := "'x' + 0\n"
	check.command('v-debug-call action watch ${quote(literal_watch)}')!
	check.wait_state('literal watch added', fn [literal_watch] (state State) bool {
		return literal_watch in state.watches
	})!
	check.command('v-debug-unwatch ${quote(literal_watch)}')!
	check.wait_state('literal watch removed', fn [literal_watch] (state State) bool {
		return literal_watch !in state.watches
	})!
	check.stop()!
	check.phase('idle')!
	check.command('v-debug-return')!
	require(check.editor.value('%opt{modelinefmt}')! == 'CUSTOM-STATUS', 'Stop did not restore the modeline')!

	check.command('set-option global v_debug_pretty_print false; set-option global v_debug_status false; v-debug')!
	raw := check.stopped(values_line)!
	greeting := raw.variable('greeting')!
	require(greeting.value != '"hello V"' && raw.variable('numbers')!.value != '[]int (len=3)',
		'Disabling pretty printing retained formatted values')!
	check.command('v-debug-call action expand ${greeting.reference}')!
	fields := check.expanded(['str', 'len', 'is_lit'])!
	require(fields[1] == '7', 'Wrong raw string length')!
	check.editor.wait_value('%val{buffile}', path, false, 'inspect the raw source window')!
	require(check.editor.value('%opt{modelinefmt}')! == 'CUSTOM-STATUS', 'Disabled debugger status changed the modeline')!
	check.stop()!
	check.phase('idle')!
	check.command('v-debug-breakpoints; select ${first_row}')!
	check.editor.keys('<ret>')
	check.editor.wait_value('%val{buffile} %val{cursor_line}', '${path} ${values_line}', false,
		'open breakpoint source with Enter')!
	check.command('v-debug-breakpoints; select ${first_row}')!
	check.editor.keys('<del>')
	check.wait_state('remove inactive breakpoint with Delete', fn (state State) bool {
		return state.breakpoints.len == 0
	})!
	for line in check.editor.transcript(0).split_into_lines() {
		detail := line.to_lower()
		require(!(detail.contains('error') && (detail.contains('highlighter') || detail.contains('unknown command'))),
			'Editor reported a debugger UI error: ${line}')!
	}
}

fn (mut check Check) wait_watch(present bool) ! {
	check.wait_state('struct watch presence ${present}', fn [present] (state State) bool {
		return ('person' in state.watches) == present
	})!
}

fn (mut check Check) default_directory() ! {
	session_file := os.join_path(check.root, 'session-name')
	os.write_file(session_file, check.editor.session_name())!
	checksum := capture('cksum', [session_file], true)!.fields()[0]
	cache := os.getenv('XDG_CACHE_HOME')
	cache_root := if cache == '' { os.join_path(os.home_dir(), '.cache') } else { cache }
	expected := os.join_path(cache_root, 'vlang.kak', 'debug-' + checksum)
	require(!os.exists(expected) && !os.is_link(expected), 'Debugger test cache directory already exists')!
	defer { os.rmdir_all(expected) or {} }
	check.command("set-option global v_debug_directory ''")!
	check.command('select ${line_start_selection(addition_line)}; v-debug-breakpoint')!
	require(check.editor.value('%opt{v_debug_directory}')! == expected && os.is_file(os.join_path(expected, 'breakpoints.json')),
		'Default debugger directory differs from the existing session checksum')!
	check.command('v-debug-breakpoint; set-option global v_debug_directory ${quote(check.state_dir)}')!
}

fn (mut check Check) launch_failure() ! {
	// A directory at the log path forces the detached process to fail before it can run GDB.
	blocker := os.join_path(check.state_dir, 'daemon.log')
	os.mkdir_all(blocker)!
	defer { os.rmdir(blocker) or {} }
	diagnostic := os.join_path(check.root, 'launch-rejection')
	check.command('try %{ v-debug } catch %{ echo -to-file ${quote(diagnostic)} %val{error} }')!
	require(os.read_file(diagnostic)!.contains('Debugger could not start'),
		'Expected a diagnostic for a failed daemon launch')!
	require(check.state().phase == 'failed', 'The failed launch left an active phase on disk')!
	check.wait_unlocked()!
}

fn (mut check Check) exercise() ! {
	empty := os.join_path(check.root, 'empty-panel-guidance')
	check.command("set-option global v_debug_directory ''")!
	check.command('try %{ v-debug-stack } catch %{ echo -to-file ${quote(empty)} %val{error} }')!
	require(os.read_file(empty)!.contains('Launch the debugger or set a breakpoint first'),
		'Missing guidance before a debugger session')!
	check.command('set-option global v_debug_directory ${quote(check.state_dir)}')!
	check.default_directory()!
	check.launch_failure()!
	check.navigation()!
	check.input_and_exit()!
	check.launch_modes()!
	check.test_targets()!
	check.runtime_errors()!
	check.values()!
}

fn (mut check Check) close() {
	check.editor.remote_allow_error('try %{ v-debug-stop }') or {}
	deadline := time.sys_mono_now() + u64(cleanup_timeout)
	for time.sys_mono_now() < deadline && check.state().phase in ['building', 'starting', 'running',
		'stopped'] {
		check.editor.offset()
		time.sleep(poll)
	}
	check.editor.close()
}

fn run(kak_path string) ! {
	kak := os.real_path(os.find_abs_path_of_executable(kak_path)!)
	repo := os.dir(@DIR)
	script := os.join_path(repo, 'scripts/debug.sh')
	capture(script, ['--prepare'], true)!
	artifacts := os.getenv('VLANG_DEBUG_ARTIFACTS')
	base := if artifacts == '' { os.temp_dir() } else { os.abs_path(artifacts) }
	os.mkdir_all(base)!
	root := os.join_path(base, 'vlang debug-' + rand.uuid_v4())
	os.mkdir(root, mode: 0o700)!
	defer {
		if artifacts == '' {
			os.rmdir_all(root) or {}
		}
	}
	config := os.join_path(root, 'config/kak')
	os.mkdir_all(config)!
	state_dir := os.join_path(root, 'debug')
	main_file := os.join_path(root, 'main.v')
	os.write_file(main_file, source)!
	adapter_log := quote('set debug dap-log-file ' + os.join_path(root, 'dap.log'))
	config_lines := [
		'source ${quote(os.join_path(repo, 'rc/vlang.kak'))}',
		'set-option global v_debug_directory ${quote(state_dir)}',
		'set-option global idle_timeout ${editor_idle_timeout_ms}',
		'set-option global v_debug_adapter_args -q -nx --interpreter=dap -iex ${adapter_log}',
	]
	os.write_file(os.join_path(config, 'kakrc'), config_lines.join('\n') + '\n')!
	os.setenv('PATH', os.dir(kak) + ':' + os.getenv('PATH'), true)
	transcript := os.join_path(root, 'ui')
	os.setenv('XDG_CONFIG_HOME', os.join_path(root, 'config'), true)
	os.setenv('VLANG_DEBUG_TEST_EDITOR', kak, true)
	os.setenv('VLANG_DEBUG_TEST_TRANSCRIPT', transcript, true)
	mut editor := editorui.open_managed(kak, os.executable(), root, main_file)!
	editor.read_transcript_from(transcript)
	os.unsetenv('VLANG_DEBUG_TEST_EDITOR')
	os.unsetenv('VLANG_DEBUG_TEST_TRANSCRIPT')
	mut check := Check{
		root:      root
		script:    script
		main_file: main_file
		state_dir: state_dir
		editor:    editor
	}
	check.exercise() or {
		detail := check.editor.diagnostic('${err}\nState: ${check.state()}')
		check.close()
		check.editor.save_artifacts() or {}
		return detail
	}
	check.close()
	check.editor.save_artifacts()!
	println('ok - real GDB with Kakoune: V values, source and stack navigation, stepping, watches, input, runtime errors, and cleanup')
}

// Kakoune writes the UI stream directly to disk while the driver controls its input.
fn launch_editor(program string, path string) ! {
	mut file := os.create(path)!
	if C.dup2(file.fd, 1) != 1 {
		file.close()
		return error('Could not redirect the Kakoune JSON transcript')
	}
	if file.fd != 1 {
		file.close()
	}
	os.unsetenv('VLANG_DEBUG_TEST_EDITOR')
	os.unsetenv('VLANG_DEBUG_TEST_TRANSCRIPT')
	os.execvp(program, os.args[1..])!
}

if os.args.len > 2 && os.args[1] == '-ui' && os.getenv('VLANG_DEBUG_TEST_EDITOR') != '' {
	launch_editor(os.getenv('VLANG_DEBUG_TEST_EDITOR'), os.getenv('VLANG_DEBUG_TEST_TRANSCRIPT')) or {
		eprintln(err)
		exit(1)
	}
}
if os.args.len != 2 {
	eprintln('Usage: v run tests/debugger.vsh KAKOUNE')
	exit(2)
}
run(os.args[1]) or {
	eprintln('not ok - ${err}')
	exit(1)
}
