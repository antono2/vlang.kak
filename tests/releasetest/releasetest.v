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

pub fn read_pins(path string) !Pins {
	mut values := map[string]string{}
	for line in os.read_lines(path)! {
		if line == '' || line.starts_with('#') {
			continue
		}
		name, value := line.split_once('=') or { return error('Invalid release pin in ${path}: ${line}') }
		values[name] = value
	}
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
	work_folder string
	environment map[string]string
}

pub fn start(program string, args []string, options ProcessOptions) !&os.Process {
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
	// Installers and editor clients must see EOF rather than interactive input.
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	return child
}

pub fn capture(program string, args []string, success bool, options ProcessOptions) !string {
	mut child := start(program, args, options)!
	defer { child.close() }
	deadline := time.sys_mono_now() + u64(command_timeout)
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
	if (child.code == 0) != success {
		return error('${program} ${args.join(' ')} exited ${child.code}\n${output}${diagnostics}')
	}
	return output
}
