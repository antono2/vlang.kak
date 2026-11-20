// Cache the editor's V helpers and pass the caller's arguments through unchanged.
import crypto.sha256
import os
import rand
import time

// A numeric cache version keeps these files eligible for the existing cleanup command.
const cache_version = '1'

fn cached_tool(path string) bool {
	return os.is_file(path) && !os.is_link(path) && os.is_executable(path)
}

fn fingerprint(path string) !string {
	return sha256.sum(os.read_bytes(path)!).hex()
}

fn helper_fingerprint(source string, tool string) !string {
	mut contents := fingerprint(source)!
	dependencies := match tool {
		'history' { ['managedfiles'] }
		'explorer', 'task' { ['projectroot'] }
		'windowing' { ['windowhost'] }
		'context' { ['projectroot', 'windowhost'] }
		else { []string{} }
	}

	for dependency in dependencies {
		module_dir := os.join_path(@DIR, dependency)
		for name in os.ls(module_dir)!.filter(it.ends_with('.v')).sorted() {
			contents += '\n' + dependency + '/' + name + '\n' +
				fingerprint(os.join_path(module_dir, name))!
		}
	}
	return contents
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

fn compile_helper(cache string, source string, expected string, destination string, tool string, quiet bool) ! {
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
	if quiet {
		child.set_redirect_stdio()
	}
	child.run()
	if quiet {
		for child.is_alive() {
			_ = child.stdout_read()
			_ = child.stderr_read()
			time.sleep(5 * time.millisecond)
		}
	}
	child.wait()
	if child.code != 0 || !cached_tool(path) {
		return error_with_code('Could not build the Kakoune ${tool} helper.', if child.code > 0 {
			child.code
		} else {
			1
		})
	}
	if helper_fingerprint(source, tool)! != expected {
		return error('The ${tool} helper source changed during compilation. Retry the command.')
	}
	os.rename_dir(path, destination)!
}

fn prepare_helper(cache string, tool string, quiet bool) !string {
	name := if tool == 'checkpoint' { 'session-checkpoint.vsh' } else { tool + '.v' }
	source := os.join_path(@DIR, name)
	content := helper_fingerprint(source, tool)!
	// Include the source path because a compiled helper can embed its checkout.
	identity := sha256.hexhash(source + '\n' + content)
	destination := cache + '/${tool}-${cache_version}${identity}'
	if !cached_tool(destination) {
		compile_helper(cache, source, content, destination, tool, quiet)!
	}
	return destination
}

fn materialize_checkpoint(writer string, directory string) ! {
	stage := os.join_path(directory, '.writer-' + rand.uuid_v4())
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	copy := os.join_path(stage, 'writer')
	os.cp(writer, copy)!
	os.chmod(copy, 0o700)!
	os.rename_dir(copy, os.join_path(directory, 'session-checkpoint'))!
}

fn run(args []string) ! {
	if args.len < 2
		|| args[1] !in ['debug', 'explorer', 'preferences', 'windowing', 'checkpoint', 'history', 'task', 'context'] {
		return error('Expected a helper cache directory and tool name.')
	}
	cache, tool := args[0], args[1]
	if tool == 'checkpoint' {
		if args.len > 3 && args[2] == '--read' {
			writer := prepare_helper(cache, tool, true) or {
				return os.execvp(os.join_path(@DIR, 'session-checkpoint-posix'), args[3..])
			}
			return os.execvp(writer, args[3..])
		}
		if args.len != 3 || !os.is_dir(args[2]) {
			return error('Expected an existing session checkpoint directory.')
		}
		writer := prepare_helper(cache, tool, true)!
		materialize_checkpoint(writer, args[2])!
		return
	}
	fallback := tool in ['windowing', 'history', 'task', 'context']
		|| (tool == 'explorer' && args.len > 2 && args[2] in ['prompt', 'candidates', 'search'])
	destination := prepare_helper(cache, tool, fallback) or {
		if fallback {
			return os.execvp(os.join_path(@DIR, tool + '-posix'), args[2..])
		}
		return err
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
