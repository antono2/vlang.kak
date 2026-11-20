// Shared tool pins and bounded subprocesses for isolated managed release tests.
module releasetest

import os
import time

const command_timeout = 3 * time.minute
const command_poll = 20 * time.millisecond

pub struct Pins {
pub:
	kakoune string
	kak_lsp string
	vls_ref string
}

pub fn read_assignments(path string) !map[string]string {
	mut values := map[string]string{}
	for line in os.read_lines(path)! {
		if line == '' || line.starts_with('#') {
			continue
		}
		name, value := line.split_once('=') or {
			return error('Invalid release pin in ${path}: ${line}')
		}
		values[name] = value
	}
	return values
}

pub fn read_pins(path string) !Pins {
	values := read_assignments(path)!
	for name in ['KAKOUNE_VERSION', 'LSP_VERSION', 'VLS_REF'] {
		if values[name] == '' {
			return error('Missing ${name} in ${path}')
		}
	}
	override := os.getenv('VLANG_RELEASE_KAKOUNE_REF')
	return Pins{
		kakoune: if override != '' { override } else { values['KAKOUNE_VERSION'] }
		kak_lsp: values['LSP_VERSION']
		vls_ref: values['VLS_REF']
	}
}

pub fn (pins Pins) setup_args(prefix string) []string {
	return ['--prefix', prefix, '--kakoune-version', pins.kakoune, '--lsp-version', pins.kak_lsp,
		'--vls-ref', pins.vls_ref]
}

@[params]
pub struct ProcessOptions {
pub:
	work_folder     string
	environment     map[string]string
	input           string
	keep_stdin_open bool
	timeout         time.Duration = command_timeout
}

fn start(program string, args []string, options ProcessOptions) !&os.Process {
	program_path := os.find_abs_path_of_executable(program)!
	mut child := os.new_process(program_path)
	child.set_args(args)
	if options.work_folder != '' {
		child.set_work_folder(options.work_folder)
	}
	if options.environment.len > 0 {
		child.set_environment(options.environment)
	}
	child.use_pgroup = true
	child.set_redirect_stdio()
	child.run()
	// Only short Kakoune commands are sent before draining the result.
	if options.input != '' {
		child.stdin_write(options.input)
	}
	// Most clients expect EOF. Kakoune cases that issue their own quit keep stdin open.
	if !options.keep_stdin_open {
		os.fd_close(child.stdio_fd[0])
		child.stdio_fd[0] = -1
	}
	return child
}

pub struct CommandOutput {
pub:
	code   int
	stdout string
	stderr string
}

pub fn capture(program string, args []string, success bool, options ProcessOptions) !string {
	return execute(program, args, success, options)!.stdout
}

pub fn execute(program string, args []string, success bool, options ProcessOptions) !CommandOutput {
	result := capture_result(program, args, options)!
	if (result.code == 0) != success {
		return error('${program} ${args.join(' ')} exited ${result.code}\n${result.stdout}${result.stderr}')
	}
	return result
}

pub fn capture_result(program string, args []string, options ProcessOptions) !CommandOutput {
	mut child := start(program, args, options)!
	defer { child.close() }
	deadline := time.sys_mono_now() + u64(options.timeout)
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
	for {
		out := child.stdout_read()
		err := child.stderr_read()
		if out == '' && err == '' {
			break
		}
		output += out
		diagnostics += err
	}
	return CommandOutput{
		code:   child.code
		stdout: output
		stderr: diagnostics
	}
}

pub fn copy_source(repo string, target string) ! {
	os.mkdir(target)!
	// Keep uncommitted source edits while excluding Git metadata and ignored artifacts.
	files := capture('git', ['-C', repo, 'ls-files', '--cached', '--others', '--exclude-standard',
		'-z'], true)!
	mut args := ['-a', '--parents', '--target-directory', target, '--']
	for file in files.split('\0') {
		source := os.join_path(repo, file)
		if file != '' && (os.exists(source) || os.is_link(source)) {
			args << file
		}
	}
	capture('cp', args, true, work_folder: repo)!
}

pub fn editor_environment(root string, prefix string, config string, kak string) !map[string]string {
	bin := os.join_path(root, 'bin')
	os.mkdir(bin)!
	os.symlink(kak, os.join_path(bin, 'kak'))!
	mut env := os.environ()
	env['PATH'] = bin + ':' + os.getenv('PATH')
	env['XDG_CONFIG_HOME'] = config
	env['XDG_CACHE_HOME'] = os.join_path(root, 'cache')
	env['VLANG_KAK_PREFIX'] = prefix
	env['VLANG_KAK_SKIP_PULL'] = '1'
	env.delete('VLANG_KAK_CONFIG_HOME')
	return env
}

// Pause an isolated fixture after the first activation rename to test recovery.
pub fn instrument_tool_activation(source string, marker string) !string {
	boundary := 'os.rename_dir(staged, destination)!'
	if source.count(boundary) != 1 || !source.contains('import os\n') {
		return error('Cannot instrument the managed tool activation boundary')
	}
	marker_literal := marker.replace_each(['\\', '\\\\', "'", "\\'", '$', '\\$', '\n', '\\n', '\r',
		'\\r'])
	barrier := "\n\tif destination.ends_with('/opt/vlang-kakoune/current') {\n\t\tos.write_file('${marker_literal}', '')!\n\t\tfor { time.sleep(time.second) }\n\t}"
	return source.replace_once('import os\n', 'import os\nimport time\n').replace_once(boundary,

		boundary + barrier)
}

pub fn interrupt_at_marker(program string, args []string, marker string, options ProcessOptions) ! {
	mut child := start(program, args, options)!
	defer { child.close() }
	deadline := time.sys_mono_now() + u64(options.timeout)
	mut output := ''
	for !os.is_file(marker) && child.is_alive() && time.sys_mono_now() < deadline {
		output += child.stdout_read() + child.stderr_read()
		time.sleep(command_poll)
	}
	reached := os.is_file(marker) && child.is_alive()
	if child.is_alive() {
		child.signal_pgkill()
		child.wait()
	}
	if !reached {
		return error('${program} did not reach ${marker} before interruption\n${output}${child.stdout_read()}${child.stderr_read()}')
	}
}

// Drain both streams while the child runs so a long test can write directly to disk.
pub fn log_command(program string, args []string, mut log os.File) !int {
	mut child := start(program, args)!
	defer {
		if child.is_alive() {
			child.signal_pgkill()
			child.wait()
		}
		child.close()
	}
	for {
		running := child.is_alive()
		out := child.stdout_read()
		diagnostics := child.stderr_read()
		if out == '' && diagnostics == '' {
			if !running {
				return child.code
			}
			time.sleep(command_poll)
			continue
		}
		log.write_string(out)!
		log.write_string(diagnostics)!
	}
	return child.code
}

pub fn run_inherited(program string, args []string) ! {
	program_path := os.find_abs_path_of_executable(program)!
	mut child := os.new_process(program_path)
	child.set_args(args)
	child.run()
	defer { child.close() }
	// Stream child output directly to the caller.
	child.wait()
	if child.code != 0 {
		return error('${program} ${args.join(' ')} exited ${child.code}')
	}
}
