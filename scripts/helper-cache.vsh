// Cache the editor's V helpers and pass the caller's arguments through unchanged.
import crypto.sha256
import os
import rand

// A numeric cache version keeps these files eligible for the existing cleanup command.
const cache_version = '1'

fn cached_tool(path string) bool {
	return os.is_file(path) && !os.is_link(path) && os.is_executable(path)
}

fn fingerprint(path string) !string {
	return sha256.sum(os.read_bytes(path)!).hex()
}

fn supports_old_compiler(compiler string) bool {
	mut child := os.new_process(compiler)
	defer { child.close() }
	child.set_args(['help', 'build-c'])
	child.set_redirect_stdio()
	child.run()
	help := child.stdout_slurp()
	child.wait()
	return child.code == 0 && help.contains('-old-compiler')
}

fn compile_helper(cache string, source string, expected string, destination string, tool string) ! {
	compiler := os.find_abs_path_of_executable('v') or {
		return error('V is required to build the Kakoune ${tool} helper.')
	}
	stage := cache + '/.helper-' + rand.uuid_v4()
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	path := stage + '/helper'
	mut args := ['-skip-running', '-o', path, source]
	// GDB's bridge still uses the compatibility compiler when available.
	if tool == 'debug' && supports_old_compiler(compiler) {
		args.prepend('-old-compiler')
	}
	mut child := os.new_process(compiler)
	defer { child.close() }
	child.set_args(args)
	child.run()
	child.wait()
	if child.code != 0 || !cached_tool(path) {
		return error_with_code('Could not build the Kakoune ${tool} helper.', if child.code > 0 {
			child.code
		} else {
			1
		})
	}
	if fingerprint(source)! != expected {
		return error('The ${tool} helper source changed during compilation. Retry the command.')
	}
	os.rename_dir(path, destination)!
}

fn run(args []string) ! {
	if args.len < 2 || args[1] !in ['debug', 'explorer', 'preferences'] {
		return error('Expected a helper cache directory and tool name.')
	}
	cache, tool := args[0], args[1]
	source := os.join_path(@DIR, tool + '.v')
	content := fingerprint(source)!
	// Include the source path because a compiled helper can embed its checkout.
	identity := sha256.hexhash(source + '\n' + content)
	destination := cache + '/${tool}-${cache_version}${identity}'
	if !cached_tool(destination) {
		compile_helper(cache, source, content, destination, tool)!
	}
	if args.len > 2 && args[2] == '--prepare' {
		return
	}
	os.execvp(destination, args[2..])!
}

fn main() {
	run(os.args[1..]) or {
		eprintln(err.msg())
		exit(if err.code() > 0 { err.code() } else { 1 })
	}
}
