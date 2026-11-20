// Translate project tasks and saved-test selections into Kakoune commands.
module main

import os
import projectroot

fn kak_quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn shell_quote(value string) string {
	return "'" + value.replace("'", "'\\''") + "'"
}

fn refuse(message string) {
	println('fail ' + kak_quote(message))
}

fn print_task(root string, command string, remember_test bool) {
	line := kak_quote('cd ' + shell_quote(root) + " && printf 'V task output\\n' && " + command)
	if remember_test {
		println('set-option global v_last_test_command ' + line)
	}
	println('v-make-command ' + line)
}

fn project_task(args []string) {
	task, buffer := args[0], args[1]
	mut command := match task {
		'build' {
			args[2]
		}
		'check' {
			args[3]
		}
		'run' {
			args[4]
		}
		'test' {
			args[5]
		}
		'vet' {
			args[6]
		}
		else {
			refuse('Unknown V task: ' + task)
			return
		}
	}

	if buffer == '' {
		refuse('Open a V file before running a project task')
		return
	}
	file := os.real_path(buffer)
	mut root := projectroot.find(os.dir(file))
	if task == 'check' {
		command += ' ' + shell_quote(file)
	}
	if task == 'run' {
		cwd, target := args[7], args[8]
		if cwd != '' {
			root = cwd
		}
		if target != '' && command.ends_with(' .') {
			command = command[..command.len - 1] + shell_quote(target)
		}
		for argument in args[9..] {
			command += ' ' + shell_quote(argument)
		}
	}
	print_task(root, command, task == 'test')
}

fn test_name(line string) string {
	declaration, _ := line.split_once('(') or { return '' }
	words := declaration.fields()
	start := if words.len == 3 && words[0] == 'pub' { 1 } else { 0 }
	if words.len != start + 2 || words[start] != 'fn' || !words[start + 1].starts_with('test_') {
		return ''
	}
	name := words[start + 1]
	suffix := name['test_'.len..]
	return if suffix.len > 0 && suffix.bytes().all(it.is_alnum() || it == `_`) { name } else { '' }
}

fn nearest_task(buffer string, modified string, cursor int, command string) ! {
	if !buffer.ends_with('_test.v') {
		refuse('Open a _test.v file to run a test at the cursor')
		return
	}
	if modified != 'false' {
		refuse('Save the test file before running a test at the cursor')
		return
	}
	if !os.is_file(buffer) {
		refuse('Save the test file first')
		return
	}
	file := os.real_path(buffer)
	mut chosen := ''
	for index, line in os.read_lines(file)! {
		name := test_name(line)
		if name == '' {
			continue
		}
		if index + 1 > cursor {
			if chosen == '' {
				chosen = name
			}
			break
		}
		chosen = name
	}
	if chosen == '' {
		refuse('No test_ function found in this file')
		return
	}
	print_task(projectroot.find(os.dir(file)), command + ' -run-only ' + shell_quote(chosen) + ' ' +
		shell_quote(file), true)
}

fn legacy_run(buffer string, command string, show_info bool, show_debug bool) {
	start := if buffer == '' { os.getwd() } else { os.dir(os.abs_path(buffer)) }
	mut root := start
	mut current := start
	// The synchronous command has always searched at most three parent directories.
	for _ in 0 .. 4 {
		if os.is_file(os.join_path(current, 'v.mod')) {
			root = current
			break
		}
		parent := os.dir(current)
		if current == parent {
			break
		}
		current = parent
	}
	result := os.execute('cd ' + shell_quote(root) + ' && exec sh -c ' + shell_quote(command))
	println('set-option global v_output ' + kak_quote(result.output.trim_right('\n')))
	if show_info {
		println('info %opt{v_output}')
	}
	if show_debug {
		println('echo -debug %opt{v_output}')
	}
}

fn run(args []string) ! {
	if args.len == 0 {
		return error('Expected a task mode')
	}
	mode := args[0]
	values := args[1..]
	match mode {
		'project' {
			if values.len >= 9 {
				project_task(values)
				return
			}
		}
		'nearest' {
			if values.len == 4 {
				nearest_task(values[0], values[1], values[2].int(), values[3])!
				return
			}
		}
		'run' {
			if values.len == 4 {
				legacy_run(values[0], values[1], values[2] == 'true', values[3] == 'true')
				return
			}
		}
		'errors' {
			if values.len == 2 {
				pattern := if values[1].starts_with('^') {
					r'^([^:\n]+):(\d+):(?:(\d+):)?(' + values[0] + r'\N*)'
				} else {
					values[0]
				}
				println('set-option buffer make_error_pattern ' + kak_quote(pattern))
				return
			}
		}
		else {}
	}

	return error('Expected task mode and arguments')
}

fn main() {
	run(os.args[1..]) or { refuse(err.msg()) }
}
