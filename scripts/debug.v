// Runs the GDB machine-interface bridge and terminal transport used by Kakoune debugging.
module main

import x.json2
import os
import time

#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/file.h>

fn C.open(&char, int, int) int
fn C.flock(int, int) int
fn C.posix_openpt(int) int
fn C.grantpt(int) int
fn C.unlockpt(int) int
fn C.ptsname(int) &char
fn C.read(int, voidptr, usize) isize
fn C.write(int, voidptr, usize) isize
fn C.close(int) int
fn C.dup(int) int
fn C.setsid() int
fn C.fcntl(int, int, ...int) int

const debug_start_timeout = 2 * time.second
const debug_poll = 20 * time.millisecond
const debug_ready = 'R'

// Runs inside GDB's existing Python runtime; no external Python helper.
const v_gdb_printers = r"
import gdb
import json

class VString:
    def __init__(self, value):
        self.value = value
    def to_string(self):
        length = int(self.value['len'])
        if length < 0 or length > 10000000:
            return '<invalid V string length>'
        if not length:
            return json.dumps('')
        try:
            data = gdb.selected_inferior().read_memory(int(self.value['str']), min(length, 4096))
        except (gdb.error, RuntimeError):
            return '<unreadable V string>'
        text = bytes(data).decode('utf-8', errors='replace')
        return json.dumps(text, ensure_ascii=False) + (' …' if length > 4096 else '')

class VArray:
    def __init__(self, value, element):
        self.value, self.element = value, element
    def to_string(self):
        length = int(self.value['len'])
        if length < 0 or length > 10000000:
            return '<invalid V array length>'
        suffix = '; first 100 shown' if length > 100 else ''
        return '[]' + str(self.element).replace('main__', '') + ' (len=' + str(length) + suffix + ')'
    def children(self):
        length = int(self.value['len'])
        if length < 0 or length > 10000000:
            return
        data = self.value['data'].cast(self.element.pointer())
        for index in range(min(length, 100)):
            yield '[' + str(index) + ']', data[index]

class VStruct:
    def __init__(self, value, name):
        self.value, self.name = value, name
    def to_string(self):
        return self.name.replace('__', '.')
    def children(self):
        for field in self.value.type.strip_typedefs().fields():
            if field.name:
                yield field.name, self.value[field.name]

def vlang_printer(value):
    name = str(value.type.unqualified())
    raw = value.type.strip_typedefs()
    if name == 'string' and raw.code == gdb.TYPE_CODE_STRUCT:
        return VString(value)
    if name.startswith('Array_') and raw.code == gdb.TYPE_CODE_STRUCT:
        try:
            element = gdb.lookup_type(name[len('Array_'):])
            if element.sizeof == int(value['element_size']):
                return VArray(value, element)
        except (gdb.error, RuntimeError):
            pass
    if '__' in name and raw.code == gdb.TYPE_CODE_STRUCT:
        return VStruct(value, name)
    return None

vlang_printer.name = 'vlang'
gdb.pretty_printers.insert(0, vlang_printer)
"

struct Settings {
mut:
	session          string
	client           string
	kak              string
	adapter          string
	adapter_args     []string
	build            string
	program          string
	target           string
	cwd              string
	args             []string
	env              map[string]string
	entry            string
	break_on_failure bool
	pretty_print     bool
	build_enabled    bool
	source           string
}

struct Breakpoint {
mut:
	file      string
	line      int
	condition string
	verified  bool
	message   string
}

struct State {
mut:
	phase           string = 'idle'
	message         string
	file            string
	line            int
	thread_id       int
	frame_id        int
	frames          []json2.Any
	variables       []json2.Any
	watch_refs      map[string]int
	variables_ready bool
	watches         map[string]string
	breakpoints     []Breakpoint
	output          string
}

struct Action {
	command string
	args    []string
}

struct Request {
	command    string
	reference  int
	revision   int
	expression string
	source     string
}

struct Debugger {
mut:
	dir                   string
	settings              Settings
	state                 State
	adapter               &os.Process = unsafe { nil }
	seq                   int
	pending               map[int]Request
	capabilities          map[string]json2.Any
	input                 string
	configured            bool
	configuration_pending int
	revision              int
	scope_pending         int
	scope_values          map[int][]json2.Any
	scope_order           []int
	stopping              bool
	stop_requested        bool
	stop_time             i64
	last_editor_check     i64
	pty                   int = -1
}

fn quote(value string) string {
	return "'${value.replace("'", "''")}'"
}

fn shell_quote(value string) string {
	return "'${value.replace("'", "'\\''")}'"
}

fn string_field(m map[string]json2.Any, key string) string {
	if value := m[key] {
		return value.str()
	}
	return ''
}

fn value(m map[string]json2.Any, key string) json2.Any {
	return m[key] or { json2.Any(json2.Null{}) }
}

fn int_field(m map[string]json2.Any, key string) int {
	if value := m[key] {
		return value.int()
	}
	return 0
}

fn words(value string) []string {
	mut result := []string{}
	mut word := ''
	mut quoted := u8(0)
	mut escaped := false
	mut started := false
	for ch in value.bytes() {
		if escaped {
			word += ch.ascii_str()
			escaped = false
			started = true
			continue
		}
		if ch == `\\` && quoted != `'` {
			escaped = true
			continue
		}
		if quoted != 0 {
			if ch == quoted {
				quoted = 0
			} else {
				word += ch.ascii_str()
			}
			continue
		}
		if ch == `'` || ch == `"` {
			quoted = ch
			started = true
			continue
		}
		if ch == ` ` || ch == `\n` || ch == `\t` {
			if started {
				result << word
				word = ''
				started = false
			}
		} else {
			word += ch.ascii_str()
			started = true
		}
	}
	if started { result << word }
	return result
}

fn root_for(file string) string {
	mut dir := os.dir(os.real_path(file))
	fallback := dir
	for {
		if os.exists(os.join_path(dir, 'v.mod')) || os.exists(os.join_path(dir, '.git')) {
			return dir
		}
		parent := os.dir(dir)
		if parent == dir {
			return fallback
		}
		dir = parent
	}
	return fallback
}

fn write_json[T](path string, value T) ! {
	tmp := '${path}.${os.getpid()}.tmp'
	os.write_file(tmp, json2.encode(value))!
	os.mv(tmp, path, overwrite: true)!
}

fn read_state(dir string) State {
	return json2.decode[State](os.read_file(os.join_path(dir, 'state.json')) or { return State{} }) or { State{} }
}

fn read_breakpoints(dir string) []Breakpoint {
	return json2.decode[[]Breakpoint](os.read_file(os.join_path(dir, 'breakpoints.json')) or { return []Breakpoint{} }) or { []Breakpoint{} }
}

fn active(dir string) bool {
	path := os.join_path(dir, 'lock')
	fd := C.open(path.str, 2 | 64, 0o600)
	if fd < 0 {
		return false
	}
	locked := C.flock(fd, 2 | 4) != 0
	C.close(fd)
	return locked
}

fn acquire_debug_lock(dir string, wait_for_cleanup bool) !int {
	path := os.join_path(dir, 'lock')
	fd := C.open(path.str, C.O_RDWR | C.O_CREAT, 0o600)
	if fd < 0 {
		return error('Could not open debugger lock: ${path}')
	}
	// Exit status can reach the editor just before the adapter releases the lock.
	deadline := time.sys_mono_now() + u64(debug_start_timeout)
	for C.flock(fd, C.LOCK_EX | C.LOCK_NB) != 0 {
		if !wait_for_cleanup || read_state(dir).phase !in ['idle', 'exited', 'failed']
			|| time.sys_mono_now() >= deadline {
			C.close(fd)
			return error('A debugger is already active. Stop it before launching again.')
		}
		time.sleep(debug_poll)
	}
	return fd
}

fn configure(dir string) ! {
	file := os.getenv('kak_buffile')
	if file == '' || !os.is_file(file) {
		return error('Open a saved V source file before debugging.')
	}
	if os.getenv('kak_modified') == 'true' {
		return error('Save source edits before building the debug target.')
	}
	mut settings := Settings{
		pretty_print:     os.getenv('kak_opt_v_debug_pretty_print') != 'false'
		source:           os.real_path(file)
		session:          os.getenv('kak_session')
		client:           os.getenv('kak_client')
		kak:              os.find_abs_path_of_executable('kak')!
		adapter:          os.getenv('kak_opt_v_debug_adapter')
		adapter_args:     words(os.getenv('kak_quoted_opt_v_debug_adapter_args'))
		build:            os.getenv('kak_opt_v_debug_build_command')
		args:             words(os.getenv('kak_quoted_opt_v_debug_args'))
		entry:            os.getenv('kak_opt_v_debug_entry')
		break_on_failure: os.getenv('kak_opt_v_debug_break_on_failure') != 'false'
		build_enabled:    os.getenv('kak_opt_v_debug_build') != 'false'
	}
	settings.cwd = os.getenv('kak_opt_v_debug_cwd')
	if settings.cwd == '' {
		settings.cwd = root_for(file)
	}
	settings.cwd = os.real_path(settings.cwd)
	if !os.is_dir(settings.cwd) {
		return error('Debug working directory does not exist: ${settings.cwd}')
	}
	settings.program = os.getenv('kak_opt_v_debug_program')
	if settings.program == '' {
		settings.program = os.join_path(dir, 'program')
	}
	if !os.is_abs_path(settings.program) {
		settings.program = os.join_path(settings.cwd, settings.program)
	}
	settings.target = if os.getenv('kak_opt_v_project_target') != '' { os.real_path(os.getenv('kak_opt_v_project_target')) } else if file.ends_with('_test.v') { os.real_path(file) } else { settings.cwd }
	for entry in words(os.getenv('kak_quoted_opt_v_debug_env')) {
		pair := entry.split_nth('=', 2)
		if pair.len != 2 {
			return error('Debugger environment entries must be NAME=value.')
		}
		settings.env[pair[0]] = pair[1]
	}
	os.find_abs_path_of_executable(settings.adapter)!
	for name in os.ls(dir)! {
		if name.starts_with('request-') && name.ends_with('.json') { os.rm(os.join_path(dir, name))! }
	}
	write_json(os.join_path(dir, 'settings.json'), settings)!
	mut state := State{ phase: 'building', message: 'Building debug target', breakpoints: read_breakpoints(dir), watches: read_state(dir).watches }
	if !settings.build_enabled {
		state.phase = 'starting'
		state.message = 'Starting debugger'
	}
	write_json(os.join_path(dir, 'state.json'), state)!
}

fn (mut d Debugger) send(command string, arguments map[string]json2.Any, reference int) {
	d.seq++
	d.pending[d.seq] = Request{ command: command, reference: reference, revision: d.revision, expression: string_field(arguments, 'expression'), source: string_field(value(arguments, 'source').as_map(), 'path') }
	body := json2.encode({
		'seq':       json2.Any(d.seq)
		'type':      json2.Any('request')
		'command':   json2.Any(command)
		'arguments': json2.Any(arguments)
	})
	d.adapter.stdin_write('Content-Length: ${body.len}\r\n\r\n${body}')
}

fn (mut d Debugger) editor(commands string) bool {
	if d.settings.session == '' {
		return true
	}
	mut p := os.new_process(d.settings.kak)
	p.set_args(['-p', d.settings.session])
	p.set_redirect_stdio()
	p.run()
	p.stdin_write(commands + '\n')
	unsafe { C.close(p.stdio_fd[0]) }
	p.stdio_fd[0] = -1
	p.wait()
	ok := p.code == 0
	p.close()
	return ok
}

fn (mut d Debugger) log(text string) {
	d.state.output += text
	if d.state.output.len > 200000 {
		d.state.output = d.state.output[d.state.output.len - 150000..]
	}
}

fn (mut d Debugger) publish() {
	write_json(os.join_path(d.dir, 'state.json'), d.state) or { eprintln(err) }
	// Read the latest state when the editor processes the update. Separate
	// kak -p connections can otherwise deliver an old running menu after a stop.
	// argv[0] keeps the cache path usable if the helper binary is replaced.
	d.editor('evaluate-commands %sh{ ${shell_quote(os.args[0])} sync ${shell_quote(d.dir)} }')
}

fn (mut d Debugger) clear_stop() {
	d.revision++
	d.state.frames = []json2.Any{}
	d.state.variables = []json2.Any{}
	d.state.variables_ready = false
	d.state.file = ''
	d.state.line = 0
	d.state.frame_id = 0
	d.state.watch_refs = map[string]int{}
	d.scope_pending = 0
	d.scope_order = []int{}
	d.scope_values = map[int][]json2.Any{}
}

fn (mut d Debugger) set_breakpoints(file string) {
	mut points := []json2.Any{}
	for point in d.state.breakpoints {
		if point.file != file {
			continue
		}
		mut item := {
			'line': json2.Any(point.line)
		}
		if point.condition != '' {
			item['condition'] = json2.Any(point.condition)
		}
		points << json2.Any(item)
	}
	d.send('setBreakpoints', {
		'source':      json2.Any({
			'path': json2.Any(file)
		})
		'breakpoints': json2.Any(points)
	}, 0)
}

fn (mut d Debugger) refresh_variables(frame int) {
	d.revision++
	d.state.frame_id = frame
	d.state.variables = []json2.Any{}
	d.state.variables_ready = false
	d.scope_values = map[int][]json2.Any{}
	d.scope_order = []int{}
	d.scope_pending = 0
	d.send('scopes', {
		'frameId': json2.Any(frame)
	}, 0)
	for expression, _ in d.state.watches {
		d.send('evaluate', {
			'expression': json2.Any(expression)
			'frameId':    json2.Any(frame)
			'context':    json2.Any('watch')
		}, 0)
	}
}

fn (mut d Debugger) configure_adapter() {
	if d.configured {
		return
	}
	d.configured = true
	if d.pty >= 0 {
		tty := unsafe { cstring_to_vstring(C.ptsname(d.pty)) }
		d.send('evaluate', {
			'expression': json2.Any('set inferior-tty ${tty}')
			'context':    json2.Any('repl')
		}, 0)
	}
	d.send('evaluate', {
		'expression': json2.Any('file ' + shell_quote(d.settings.program))
		'context':    json2.Any('repl')
	}, 0)
	if d.settings.pretty_print {
		d.send('evaluate', {
			'expression': json2.Any('python exec(' + json2.encode(v_gdb_printers) + ')')
			'context':    json2.Any('repl')
		}, -2)
	}
	if d.settings.break_on_failure {
		// Match existing V runtime symbols without creating unresolved breakpoints
		// for a prebuilt executable which does not contain the V runtime.
		for name in ['builtin___v_panic', 'builtin__panic', 'builtin__panic_debug',
			'builtin____print_assert_failure', 'main__NormalTestRunner_assert_fail'] {
			d.send('evaluate', {
				'expression': json2.Any('rbreak ^${name}\$')
				'context':    json2.Any('repl')
			}, 0)
		}
	}
	if d.settings.entry != '' && d.state.breakpoints.len == 0 {
		d.send('evaluate', {
			'expression': json2.Any('tbreak ' + d.settings.entry)
			'context':    json2.Any('repl')
		}, 0)
	}
	mut files := map[string]bool{}
	for point in d.state.breakpoints {
		files[point.file] = true
	}
	for file, _ in files {
		d.set_breakpoints(file)
		d.configuration_pending++
	}
	if d.configuration_pending == 0 { d.send('configurationDone', map[string]json2.Any{}, 0) }
}

fn (mut d Debugger) launch() {
	mut env := os.environ()
	for name, val in d.settings.env {
		env[name] = val
	}
	mut launch_args := []json2.Any{}
	for arg in d.settings.args {
		launch_args << json2.Any(arg)
	}
	mut environment := map[string]json2.Any{}
	for name, val in env {
		environment[name] = json2.Any(val)
	}
	d.send('launch', {
		'args':        json2.Any(launch_args)
		'env':         json2.Any(environment)
		'stopOnEntry': json2.Any(false)
	}, 0)
}

fn (mut d Debugger) message(message map[string]json2.Any) {
	kind := string_field(message, 'type')
	body := value(message, 'body').as_map()
	if kind == 'event' {
		match string_field(message, 'event') {
			'initialized' { d.configure_adapter() }
			'output' { d.log(string_field(body, 'output')) }
			'stopped' {
				d.clear_stop()
				d.state.phase = 'stopped'
				d.state.message = string_field(body, 'reason')
				d.state.thread_id = int_field(body, 'threadId')
				if d.state.thread_id == 0 {
					d.send('threads', map[string]json2.Any{}, 0)
				} else {
					d.send('stackTrace', {
						'threadId': json2.Any(d.state.thread_id)
					}, 0)
				}
			}
			'continued' {
				d.clear_stop()
				d.state.phase = 'running'
				d.state.message = 'Running'
			}
			'exited' {
				d.clear_stop()
				d.state.phase = 'exited'
				d.state.message = 'Exited with code ${int_field(body, 'exitCode')}'
			}
			'terminated' {
				d.stopping = true
				d.stop_time = time.now().unix_milli()
				d.state.phase = 'exited'
			}
			else {}
		}
	} else if kind == 'response' {
		sequence := int_field(message, 'request_seq')
		request := d.pending[sequence] or { return }
		d.pending.delete(sequence)
		if request.command in ['evaluate', 'scopes', 'variables', 'stackTrace'] && request.revision != d.revision {
			return
		}
		if !value(message, 'success').bool() {
			if request.command == 'evaluate' && request.expression in d.state.watches {
				d.state.watches[request.expression] = '<unavailable: ${string_field(message, 'message')}>'
				d.state.watch_refs[request.expression] = 0
			}
			if request.command in ['continue', 'next', 'stepIn', 'stepOut'] {
				d.state.phase = 'stopped'
				d.send('stackTrace', {
					'threadId': json2.Any(d.state.thread_id)
				}, 0)
			}
			d.state.message = '${request.command}: ${string_field(message, 'message')}'
			d.log('\n${d.state.message}\n')
			if request.command in ['initialize', 'launch', 'configurationDone'] {
				d.state.phase = 'failed'
				d.stopping = true
				d.stop_time = time.now().unix_milli()
			}
		} else {
			match request.command {
				'initialize' { d.capabilities = body.clone() }
				'setBreakpoints', 'setFunctionBreakpoints' {
					if request.command == 'setBreakpoints' {
						returned := value(body, 'breakpoints').as_array()
						mut index := 0
						for mut configured in d.state.breakpoints {
							if configured.file != request.source {
								continue
							}
							if index < returned.len {
								item := returned[index].as_map()
								configured.verified = value(item, 'verified').bool()
								configured.message = string_field(item, 'message')
								actual := int_field(item, 'line')
								if actual > 0 && actual != configured.line {
									configured.message += ' (resolved to line ${actual})'
								}
							}
							index++
						}
					}
				}
				'configurationDone' {
					d.launch()
					d.state.phase = 'running'
					d.state.message = 'Running'
				}
				'threads' {
					threads := value(body, 'threads').as_array()
					if threads.len > 0 {
						d.state.thread_id = int_field(threads[0].as_map(), 'id')
						d.send('stackTrace', {
							'threadId': json2.Any(d.state.thread_id)
						}, 0)
					}
				}
				'stackTrace' {
					if request.revision != d.revision || d.state.phase != 'stopped' {
						return
					}
					d.state.frames = value(body, 'stackFrames').as_array()
					if d.state.frames.len > 0 {
						mut selected := 0
						first_name := string_field(d.state.frames[0].as_map(), 'name')
						if first_name in ['builtin___v_panic', 'builtin__panic', 'builtin__panic_debug',
							'builtin____print_assert_failure', 'main__NormalTestRunner_assert_fail'] {
							d.state.message = if first_name.contains('assert') {
								'V assertion failed'
							} else {
								'V panic'
							}
							project := root_for(d.settings.source) + os.path_separator
							for index, raw in d.state.frames {
								item := raw.as_map()
								name := string_field(item, 'name')
								path := string_field(value(item, 'source').as_map(), 'path')
								if path.starts_with(project) && path.ends_with('.v') && !name.starts_with('builtin__') && !name.contains('TestRunner') {
									selected = index
									break
								}
							}
						}
						frame := d.state.frames[selected].as_map()
						d.state.file = string_field(value(frame, 'source').as_map(), 'path')
						d.state.line = int_field(frame, 'line')
						d.refresh_variables(int_field(frame, 'id'))
						if os.is_file(d.state.file) && d.state.line > 0 {
							d.editor('v-debug-location ${quote(d.settings.client)} ${quote(d.state.file)} ${d.state.line}')
						}
					}
				}
				'scopes' {
					if request.revision != d.revision || d.state.phase != 'stopped' {
						return
					}
					for scope in value(body, 'scopes').as_array() {
						item := scope.as_map()
						reference := int_field(item, 'variablesReference')
						if reference > 0 && !value(item, 'expensive').bool() && string_field(item, 'presentationHint') != 'registers' {
							d.scope_order << reference
							d.scope_pending++
							d.send('variables', {
								'variablesReference': json2.Any(reference)
							}, reference)
						}
					}
					d.state.variables_ready = d.scope_pending == 0
				}
				'variables' {
					if request.revision != d.revision || d.state.phase != 'stopped' {
						return
					}
					values := value(body, 'variables').as_array()
					if request.reference in d.scope_order {
						d.scope_values[request.reference] = values
						d.scope_pending--
						d.state.variables = []json2.Any{}
						d.state.variables_ready = false
						for reference in d.scope_order {
							for item in d.scope_values[reference] {
								d.state.variables << item
							}
						}
					} else {
						d.state.variables = values
					}
					d.state.variables_ready = d.scope_pending == 0
				}
				'evaluate' {
					if request.revision != d.revision {
						return
					}
					result := string_field(body, 'result')
					if request.expression in d.state.watches {
						d.state.watches[request.expression] = result
						d.state.watch_refs[request.expression] = int_field(body, 'variablesReference')
					}
					if request.reference != -2 { d.log('${request.expression}: ${result}\n') }
					if request.reference == -1 && d.state.phase == 'stopped' && !d.stopping {
						if result.contains('Temporary breakpoint ') {
							d.action(Action{ command: 'continue' })
						} else {
							d.state.message = 'Could not set a temporary breakpoint; check debugger output'
						}
					}
				}
				'disconnect' {
					d.stopping = true
					d.stop_time = time.now().unix_milli()
				}
				else {}
			}
		}
		if request.command in ['setBreakpoints', 'setFunctionBreakpoints'] && d.configuration_pending > 0 {
			d.configuration_pending--
			if d.configuration_pending == 0 { d.send('configurationDone', map[string]json2.Any{}, 0) }
		}
	}
	d.publish()
}

fn (mut d Debugger) action(action Action) {
	match action.command {
		'stop' {
			d.stop_requested = true
			d.send('disconnect', {
				'terminateDebuggee': json2.Any(true)
			}, 0)
			d.stopping = true
			d.stop_time = time.now().unix_milli()
		}
		'breakpoint' {
			d.state.breakpoints = read_breakpoints(d.dir)
			for file in action.args {
				d.set_breakpoints(file)
			}
		}
		'continue', 'next', 'stepIn', 'stepOut' {
			if d.state.phase != 'stopped' {
				d.state.message = 'Pause the program before stepping or continuing'
				d.publish()
				return
			}
			d.clear_stop()
			d.state.phase = 'running'
			d.state.message = 'Running'
			d.send(action.command, {
				'threadId': json2.Any(d.state.thread_id)
			}, 0)
		}
		'runToCursor' {
			if d.state.phase != 'stopped' || action.args.len < 2 {
				return
			}
			file := os.real_path(action.args[0])
			line := action.args[1].int()
			if !os.is_file(file) || line < 1 {
				d.state.message = 'Run to cursor requires a saved file and a positive source line'
				d.publish()
				return
			}
			// Continue only after GDB confirms the temporary breakpoint was set.
			d.send('evaluate', {
				'expression': json2.Any('with breakpoint pending off -- tbreak ' + "'" + file.replace('\\', '\\\\').replace("'", "\\'") + "'" + ':${line}')
				'context':    json2.Any('repl')
			}, -1)
		}
		'pause' {
			if d.state.phase == 'running' {
				d.send('pause', {
					'threadId': json2.Any(d.state.thread_id)
				}, 0)
			}
		}
		'frame' {
			if d.state.phase != 'stopped' || action.args.len == 0 {
				return
			}
			index := action.args[0].int()
			if index < 0 || index >= d.state.frames.len {
				return
			}
			frame := d.state.frames[index].as_map()
			d.state.file = string_field(value(frame, 'source').as_map(), 'path')
			d.state.line = int_field(frame, 'line')
			d.refresh_variables(int_field(frame, 'id'))
			if os.is_file(d.state.file) {
				d.editor('v-debug-location ${quote(d.settings.client)} ${quote(d.state.file)} ${d.state.line}')
			}
		}
		'expand' {
			if d.state.phase != 'stopped' || action.args.len == 0 {
				return
			}
			reference := action.args[0].int()
			if reference > 0 {
				d.send('variables', {
					'variablesReference': json2.Any(reference)
				}, reference)
			}
		}
		'evaluate', 'watch' {
			if d.state.phase != 'stopped' || action.args.len == 0 {
				return
			}
			expression := action.args.join(' ')
			if action.command == 'watch' {
				d.state.watches[expression] = ''
			}
			d.send('evaluate', {
				'expression': json2.Any(expression)
				'frameId':    json2.Any(d.state.frame_id)
				'context':    json2.Any('watch')
			}, 0)
		}
		'unwatch' {
			if action.args.len > 0 {
				d.state.watches.delete(action.args.join(' '))
				d.state.watch_refs.delete(action.args.join(' '))
			}
		}
		'console' {
			if action.args.len == 0 {
				return
			}
			d.send('evaluate', {
				'expression': json2.Any(action.args.join(' '))
				'frameId':    json2.Any(d.state.frame_id)
				'context':    json2.Any('repl')
			}, 0)
		}
		'input' {
			if d.pty >= 0 {
				text := action.args.join(' ') + '\n'
				unsafe { C.write(d.pty, text.str, usize(text.len)) }
			}
		}
		else {}
	}
	d.publish()
}

fn render_commands(dir string, state State) string {
	mut commands := 'try %{ declare-option -hidden bool v_debug_has_watches false }\nset-option global v_debug_directory ${quote(dir)}\nset-option global v_debug_phase ${quote(state.phase)}\n'
	commands += 'set-option global v_debug_message ${quote(state.message)}\n'
	commands += 'set-option global v_debug_has_watches ${state.watches.len > 0}\n'
	commands += 'evaluate-commands -buffer * %{ set-option buffer v_debug_current_line 0; set-option buffer v_debug_breakpoint_lines %val{timestamp} }\n'
	if state.phase !in ['building', 'starting', 'running', 'stopped'] {
		commands += 'evaluate-commands -buffer * %{ set-option buffer v_debug_source false }\n'
	}
	mut files := map[string][]string{}
	for point in state.breakpoints {
		files[point.file] << '${point.line}|●'
	}
	for file, lines in files {
		commands += 'try %{ evaluate-commands -buffer ${quote(file)} %{ set-option buffer v_debug_breakpoint_lines %val{timestamp} ${lines.join(' ')} } }\n'
	}
	if state.phase == 'stopped' && state.file != '' {
		commands += 'try %{ evaluate-commands -buffer ${quote(state.file)} %{ set-option buffer v_debug_source true; set-option buffer v_debug_current_line ${state.line} } }\n'
	}
	mut stack := 'Stack frames (Enter selects; Space for debugger actions)\n'
	for i, raw in state.frames {
		frame := raw.as_map()
		file := string_field(value(frame, 'source').as_map(), 'path')
		stack += '${i}: ${string_field(frame, 'name')} — ${file}:${int_field(frame, 'line')}\n'
	}
	mut variables := 'Variables (Enter expands; Delete removes watch; q returns to source)\n'
	for raw in state.variables {
		item := raw.as_map()
		reference := int_field(item, 'variablesReference')
		text := string_field(item, 'value')
		type_name := string_field(item, 'type')
		variables += '${reference}| ${string_field(item, 'name')} = ${if text == '' && reference > 0 {
			'<expand fields>'
		} else {
			text
		}}${if type_name != '' { '  (${type_name})' } else { '' }}\n'
	}
	for expression, result in state.watches {
		variables += '${state.watch_refs[expression]}| watch ${expression} = ${result}\n'
	}
	mut points := 'Breakpoints (Enter opens source; Delete removes; q returns to source)\n'
	for point in state.breakpoints {
		points += '${point.file}:${point.line} [${point.condition}] ${if point.verified {
			'verified'
		} else {
			'pending'
		}} ${point.message}\n'
	}
	for name, text in {
		'stack':       stack
		'variables':   variables
		'breakpoints': points
		'output':      'Debugger: ${state.phase} — ${if state.phase == 'running' {
			'Enter sends program input; '
		} else {
			''
		}}Space for debugger actions; q returns to source\n\n${state.output}'
	} {
		path := os.join_path(dir, '${name}.txt')
		if (os.read_file(path) or { '\x00' }) == text {
			continue
		}
		os.write_file(path, text) or {}
		commands += 'v-debug-render ${quote('*v-debug-${name}*')} ${quote(text)}\n'
	}
	commands += 'try %{ evaluate-commands -client ${quote(os.getenv('kak_client'))} %{ v-refresh-keys } }\n'
	return commands
}

fn (mut d Debugger) run() ! {
	defer {
		if !isnil(d.adapter) {
			if d.adapter.is_alive() { d.adapter.signal_kill() }
			d.adapter.wait()
			d.adapter.close()
		}
		if d.pty >= 0 { C.close(d.pty) }
		if d.stop_requested || d.state.phase !in ['failed', 'exited'] {
			d.state.phase = 'idle'
			d.state.message = 'Debugger stopped'
		}
		d.clear_stop()
		d.publish()
	}
	d.publish()
	if d.settings.build_enabled {
		mut command := d.settings.build
		if command == 'v -g -cc gcc' {
			help := os.execute('v help build-c').output
			if help.contains('-old-compiler') {
				command = 'v -old-compiler -g -cc gcc'
			}
		}
		d.log('Build: ${command}\n')
		flags := if d.settings.target.ends_with('_test.v') { ' -keepc -skip-running' } else { '' }
		mut build := os.new_process('/bin/sh')
		build.set_args(['-c',
			'${command}${flags} -o ${shell_quote(d.settings.program)} ${shell_quote(d.settings.target)}'])
		build.set_work_folder(d.settings.cwd)
		build.set_redirect_stdio()
		build.use_pgroup = true
		build.run()
		for build.is_alive() {
			chunk := build.stdout_read() + build.stderr_read()
			if chunk != '' {
				d.log(chunk)
				d.publish()
			}
			for name in os.ls(d.dir)! {
				if name.starts_with('request-') && name.ends_with('.json') {
					request := json2.decode[Action](os.read_file(os.join_path(d.dir, name))!) or { continue }
					if request.command == 'stop' {
						build.signal_pgkill()
						build.wait()
						build.close()
						d.stop_requested = true
						d.log('Debug build cancelled\n')
						return
					}
				}
			}
			time.sleep(30 * time.millisecond)
		}
		d.log(build.stdout_read())
		d.log(build.stderr_read())
		build.wait()
		code := build.code
		build.close()
		if code != 0 {
			return error('Debug build failed (exit ${code}); open debugger output for details')
		}
	}
	if !os.is_file(d.settings.program) {
		return error('Debug executable not found: ${d.settings.program}')
	}
	d.state.breakpoints = read_breakpoints(d.dir)
	d.state.phase = 'starting'
	d.state.message = 'Initializing debug adapter'
	d.adapter = os.new_process(d.settings.adapter)
	d.adapter.set_args(d.settings.adapter_args)
	d.adapter.set_work_folder(d.settings.cwd)
	d.adapter.set_redirect_stdio()
	d.adapter.run()
	// A PTY gives debug programs real standard input and terminal output.
	d.pty = C.posix_openpt(2 | 256 | 2048)
	if d.pty >= 0 && (C.grantpt(d.pty) != 0 || C.unlockpt(d.pty) != 0) {
		C.close(d.pty)
		d.pty = -1
	}
	d.send('initialize', {
		'clientID':        json2.Any('vlang.kak')
		'adapterID':       json2.Any('gdb')
		'linesStartAt1':   json2.Any(true)
		'columnsStartAt1': json2.Any(true)
		'pathFormat':      json2.Any('path')
	}, 0)
	started := time.now().unix_milli()
	for {
		chunk := d.adapter.stdout_read()
		d.input += chunk
		d.log(d.adapter.stderr_read())
		for {
			separator := d.input.index('\r\n\r\n') or { break }
			header := d.input[..separator]
			length := header.all_after('Content-Length:').trim_space().int()
			if length <= 0 || length > 10000000 {
				return error('Invalid DAP message length')
			}
			offset := separator + 4
			if d.input.len < offset + length {
				break
			}
			message := json2.decode[map[string]json2.Any](d.input[offset..offset + length])!
			d.input = d.input[offset + length..]
			d.message(message)
		}
		if d.pty >= 0 {
			mut bytes := []u8{len: 8192}
			count := unsafe { C.read(d.pty, bytes.data, usize(bytes.len)) }
			if count > 0 {
				d.log(bytes[..int(count)].bytestr())
				d.publish()
			}
		}
		mut names := os.ls(d.dir)!
		names.sort()
		for name in names {
			if !name.starts_with('request-') || !name.ends_with('.json') {
				continue
			}
			path := os.join_path(d.dir, name)
			request := json2.decode[Action](os.read_file(path)!) or {
				os.rm(path) or {}
				continue
			}
			os.rm(path) or {}
			d.action(request)
		}
		now := time.now().unix_milli()
		if d.stopping && now - d.stop_time > 1000 {
			break
		}
		if !d.adapter.is_alive() {
			if !d.stopping && d.state.phase !in ['exited', 'idle'] {
				return error('Debug adapter exited unexpectedly. See debugger output.')
			}
			break
		}
		if !d.configured && now - started > 10000 {
			return error('Adapter did not initialize. GDB must include DAP support.')
		}
		if now - d.last_editor_check > 5000 {
			d.last_editor_check = now
			if !d.editor('nop') {
				d.send('disconnect', {
					'terminateDebuggee': json2.Any(true)
				}, 0)
				d.stopping = true
				d.stop_time = now
			}
		}
		time.sleep(20 * time.millisecond)
	}
}

fn show_panel(dir string, name string) string {
	if dir == '' {
		return 'fail ' + quote('Launch the debugger or set a breakpoint first')
	}
	if name !in ['stack', 'variables', 'breakpoints', 'output'] {
		return 'fail ' + quote('Unknown debugger panel')
	}
	buffer := quote('*v-debug-${name}*')
	text := os.read_file(os.join_path(dir, '${name}.txt')) or { '' }
	return 'edit -scratch ${buffer}\nv-debug-render ${buffer} ${quote(text.trim_right('\n'))}\nset-option buffer filetype v-debug-${name}\nv-refresh-keys'
}

fn panel_row_command(state State, panel string, action string, line int) string {
	// The first line is the panel heading. Editor lines start at one.
	index := line - 2
	if panel == 'v-debug-breakpoints' && index >= 0 && index < state.breakpoints.len {
		point := state.breakpoints[index]
		if action == 'delete' {
			return 'v-debug-call action toggle ${quote(point.file)} ${point.line}'
		}
		return 'edit -existing ${quote(point.file)} ${point.line}'
	}
	if panel == 'v-debug-variables' && action == 'delete' {
		watch_index := index - state.variables.len
		expressions := state.watches.keys()
		if watch_index >= 0 && watch_index < expressions.len {
			return 'v-debug-call action unwatch ${quote(expressions[watch_index])}'
		}
		return 'fail ' + quote('Select a watch row to remove it')
	}
	return ''
}

fn select_panel_row(dir string, panel string, line int, text string) string {
	if panel == 'v-debug-breakpoints' && dir != '' {
		return panel_row_command(read_state(dir), panel, 'open', line)
	}
	action, number := match panel {
		'v-debug-stack' { 'frame', text.all_before(':') }
		'v-debug-variables' { 'expand', text.all_before('|') }
		else { return '' }
	}
	if number == '' || !number.bytes().all(it >= `0` && it <= `9`) {
		return ''
	}
	return 'v-debug-call action ${action} ${number}'
}

// View commands only read debugger files. They also accept an empty directory
// so the editor can display its normal guidance before the first session.
fn debug_view_command(command string, dir string, args []string) !string {
	if command == 'show-panel' && args.len == 1 {
		return show_panel(dir, args[0])
	}
	if command == 'select-panel-row' && args.len == 3 {
		return select_panel_row(dir, args[0], args[1].int(), args[2])
	}
	if command == 'panel-row' && args.len == 3 {
		if dir == '' {
			return ''
		}
		return panel_row_command(read_state(dir), args[0], args[1], args[2].int())
	}
	return error('Invalid debugger view command arguments')
}

// POSIX cksum folds the byte length into the CRC. Preserve the cache keys
// used by existing sessions so their breakpoints and panel files stay visible.
fn checksum_byte(initial u32, value u8) u32 {
	mut crc := initial ^ (u32(value) << 24)
	for _ in 0 .. 8 {
		high_bit := (crc & 0x80000000) != 0
		crc <<= 1
		if high_bit {
			crc ^= 0x04c11db7
		}
	}
	return crc
}

fn session_checksum(session string) u32 {
	mut crc := u32(0)
	for value in session.bytes() {
		crc = checksum_byte(crc, value)
	}
	mut length := session.len
	for length > 0 {
		crc = checksum_byte(crc, u8(length & 0xff))
		length >>= 8
	}
	return ~crc
}

fn debug_directory(requested string) !string {
	mut directory := requested
	if directory == '' {
		cache := os.getenv_opt('XDG_CACHE_HOME') or { '' }
		root := if cache == '' { os.join_path(os.home_dir(), '.cache') } else { cache }
		directory = os.join_path(root, 'vlang.kak', 'debug-${session_checksum(os.getenv('kak_session'))}')
	}
	dir := os.real_path(directory)
	os.mkdir_all(dir)!
	os.chmod(dir, 0o700) or {}
	return dir
}

fn configure_once(dir string) ! {
	lock_fd := acquire_debug_lock(dir, true)!
	defer { C.close(lock_fd) }
	configure(dir)!
}

fn read_debug_settings(dir string) !Settings {
	return json2.decode[Settings](os.read_file(os.join_path(dir, 'settings.json'))!)
}

fn run_debugger(dir string, settings Settings) {
	mut debugger := Debugger{ dir: dir, settings: settings, state: read_state(dir) }
	debugger.run() or {
		debugger.state.phase = 'failed'
		debugger.state.message = err.msg()
		debugger.log('\n${err.msg()}\n')
		debugger.publish()
	}
}

fn redirect_debugger(dir string) ! {
	mut log := os.open_file(os.join_path(dir, 'daemon.log'), 'w', 0o600)!
	defer { log.close() }
	mut null_input := os.open_file('/dev/null', 'r')!
	defer { null_input.close() }
	if os.fd_dup2(null_input.fd, C.STDIN_FILENO) < 0 || os.fd_dup2(log.fd, C.STDOUT_FILENO) < 0
		|| os.fd_dup2(log.fd, C.STDERR_FILENO) < 0 {
		return error('Could not redirect debugger input and output')
	}
}

fn run_detached_debugger(dir string, lock_fd int) ! {
	if lock_fd <= C.STDERR_FILENO || C.fcntl(lock_fd, C.F_SETFD, C.FD_CLOEXEC) < 0 || C.setsid() < 0 {
		return error('Could not detach the debugger process')
	}
	defer { C.close(lock_fd) }
	os.signal_ignore(.hup)
	settings := read_debug_settings(dir)!
	// Keep a temporary copy of stdout for the launcher's readiness signal.
	ready := C.dup(C.STDOUT_FILENO)
	if ready < 0 {
		return error('Could not open the debugger readiness pipe')
	}
	redirect_debugger(dir) or {
		C.close(ready)
		return err
	}
	acknowledged := C.write(ready, debug_ready.str, usize(debug_ready.len))
	C.close(ready)
	if acknowledged != debug_ready.len {
		return error('Could not acknowledge debugger launch')
	}
	run_debugger(dir, settings)
}

fn launch_debugger(dir string) ! {
	lock_fd := acquire_debug_lock(dir, true)!
	defer { C.close(lock_fd) }
	configure(dir)!
	spawn_debugger(dir, lock_fd) or {
		mut state := read_state(dir)
		state.phase = 'failed'
		state.message = err.msg()
		write_json(os.join_path(dir, 'state.json'), state) or {
			return error('${state.message} Could not record the launch failure: ${err}')
		}
		return err
	}
}

fn spawn_debugger(dir string, lock_fd int) ! {
	// The new process inherits this open lock. It closes it on exit, while
	// the launcher releases its copy after the daemon redirects its output.
	mut child := os.new_process(os.executable())
	defer { child.close() }
	child.set_args(['daemon', dir, lock_fd.str()])
	child.set_redirect_stdio()
	child.run()
	if child.pid <= 0 {
		return error('Could not start the debugger process')
	}
	deadline := time.sys_mono_now() + u64(debug_start_timeout)
	for time.sys_mono_now() < deadline {
		if child.stdout_read() == debug_ready {
			return
		}
		if !child.is_alive() {
			detail := child.stderr_read().trim_space()
			log := os.join_path(dir, 'daemon.log')
			message := if detail == '' {
				'Debugger could not start. See ${log}'
			} else {
				'Debugger could not start. ${detail}'
			}
			return error(message)
		}
		time.sleep(debug_poll)
	}
	child.signal_kill()
	child.wait()
	return error('Debugger did not start. See ${os.join_path(dir, 'daemon.log')}')
}

fn queue_action(dir string, arguments []string) ! {
	if arguments.len == 0 {
		return error('Expected a debugger action')
	}
	action := arguments[0]
	args := arguments[1..]
	if action != 'toggle' {
		if !active(dir) {
			return error('No active debugger. Run v-debug first.')
		}
		write_json(os.join_path(dir, 'request-${time.now().unix_micro()}-${os.getpid()}.json'),
			Action{ command: action, args: args })!
		return
	}
	if args.len < 2 {
		return error('Breakpoints require a saved file and a positive source line')
	}
	if active(dir) && read_state(dir).phase == 'running' {
		return error('Pause debugging before changing breakpoints')
	}
	file := os.real_path(args[0])
	line := args[1].int()
	if !os.is_file(file) || line < 1 {
		return error('Breakpoints require a saved file and a positive source line')
	}
	condition := if args.len > 2 { args[2] } else { '' }
	mut points := read_breakpoints(dir)
	mut found := -1
	for i, point in points {
		if point.file == file && point.line == line {
			found = i
			break
		}
	}
	if found >= 0 {
		points.delete(found)
	} else {
		points << Breakpoint{ file: file, line: line, condition: condition }
	}
	write_json(os.join_path(dir, 'breakpoints.json'), points)!
	if active(dir) {
		write_json(os.join_path(dir, 'request-${time.now().unix_micro()}-${os.getpid()}.json'),
			Action{ command: 'breakpoint', args: [file] })!
	} else {
		mut state := read_state(dir)
		state.breakpoints = points
		write_json(os.join_path(dir, 'state.json'), state)!
		print(render_commands(dir, state))
	}
}

fn call_debugger(directory string, args []string) ! {
	if args == ['action', 'unwatch'] {
		println("prompt 'Remove watch expression: ' %{ v-debug-call action unwatch %val{text} }")
		return
	}
	if args == ['action', 'input'] {
		if os.getenv('kak_opt_v_debug_phase') != 'running' {
			return error('Program input is available while running; continue the debugger first')
		}
		println("prompt 'Program input: ' %{ v-debug-call action input %val{text} }")
		return
	}
	start := args == ['start']
	if !start && (args.len < 2 || args[0] != 'action') {
		return error('Expected a debugger launch or action')
	}
	action := if args.len > 1 && args[1] == 'run-to-cursor' {
		if os.getenv('kak_opt_v_debug_phase') != 'stopped' {
			return error('Pause debugging before running to the cursor')
		}
		if args.len != 4 || os.getenv('kak_modified') != 'false'
			|| os.getenv('kak_opt_readonly') != 'false' || !os.is_file(args[2]) {
			return error('Run to cursor requires an unmodified saved source file')
		}
		['runToCursor', args[2], args[3]]
	} else {
		args[1..]
	}
	dir := debug_directory(directory)!
	println('set-option global v_debug_directory ${quote(dir)}')
	if start {
		launch_debugger(dir)!
		println("set-option global v_debug_phase building\necho 'Building the debug target; output opens automatically'")
	} else {
		queue_action(dir, action)!
	}
}

fn main() {
	if os.args.len < 3 {
		eprintln('Usage: debug COMMAND DIRECTORY [ARGS...]')
		exit(2)
	}
	command := os.args[1]
	if command in ['show-panel', 'select-panel-row', 'panel-row'] {
		output := debug_view_command(command, os.args[2], os.args[3..]) or {
			eprintln(err)
			exit(2)
		}
		if output != '' {
			println(output)
		}
		return
	}
	if command == 'call' {
		call_debugger(os.args[2], os.args[3..]) or {
			println('fail ${quote(err.msg())}')
		}
		return
	}
	if command == 'daemon' && os.args.len == 4 {
		run_detached_debugger(os.args[2], os.args[3].int()) or {
			eprintln(err)
			exit(1)
		}
		return
	}
	dir := os.real_path(os.args[2])
	os.mkdir_all(dir) or {
		eprintln(err)
		exit(1)
	}
	os.chmod(dir, 0o700) or {}
	match command {
		'configure' {
			configure_once(dir) or {
				println('fail ${quote(err.msg())}')
				exit(1)
			}
		}
		'run' {
			lock_fd := acquire_debug_lock(dir, false) or {
				eprintln(err)
				exit(1)
			}
			defer { C.close(lock_fd) }
			C.fcntl(lock_fd, C.F_SETFD, C.FD_CLOEXEC)
			settings := read_debug_settings(dir) or {
				eprintln(err)
				exit(1)
			}
			run_debugger(dir, settings)
		}
		'active' {
			if !active(dir) { exit(1) }
		}
		'marks' {
			if os.args.len < 4 { exit(2) }
			file := os.real_path(os.args[3])
			state := read_state(dir)
			line := if state.phase == 'stopped' && state.file == file { state.line } else { 0 }
			println('set-option buffer v_debug_current_line ${line}')
			mut marks := []string{}
			for point in state.breakpoints {
				if point.file == file { marks << '${point.line}|●' }
			}
			println('set-option buffer v_debug_breakpoint_lines %val{timestamp} ${marks.join(' ')}')
		}
		'sync' { print(render_commands(dir, read_state(dir))) }
		'location' {
			state := read_state(dir)
			settings := json2.decode[Settings](os.read_file(os.join_path(dir, 'settings.json')) or { '' }) or { Settings{} }
			file := if os.is_file(state.file) { state.file } else { settings.source }
			line := if os.is_file(state.file) && state.line > 0 { state.line } else { 1 }
			if file != '' { println('edit -existing ${quote(file)} ${line}') }
		}
		'queue' {
			queue_action(dir, os.args[3..]) or {
				println('fail ${quote(err.msg())}')
				exit(1)
			}
		}
		else {
			eprintln('Unknown debug command')
			exit(2)
		}
	}
}
