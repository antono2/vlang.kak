// Drive a temporary Kakoune JSON client and its command socket.
module editorui

import os
import rand
import time
import x.json2

const timeout = 15 * time.second
const poll = 30 * time.millisecond

struct KeyEvent {
	jsonrpc string = '2.0'
	method  string = 'keys'
	params  []string
}

pub struct Client {
	root       string
	executable string
	session    string
	env        map[string]string
mut:
	process &os.Process
	client  string
	output  string
	errors  string
}

pub fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

pub fn open(kak string, root string, file string) !&Client {
	mut env := os.environ()
	env['XDG_CONFIG_HOME'] = os.join_path(root, 'config')
	return start(kak, kak, root, file, env)
}

pub fn open_managed(kak string, launcher string, root string, file string) !&Client {
	return start(kak, launcher, root, file, os.environ())
}

fn start(kak string, launcher string, root string, file string, env map[string]string) !&Client {
	for executable in [kak, launcher] {
		if !os.is_executable(executable) {
			return error('Kakoune executable not found: ${executable}')
		}
	}
	os.signal_ignore(.pipe)
	session := 'vlang-ui-' + rand.uuid_v4()
	ready := os.join_path(root, 'ready')
	mut process := os.new_process(launcher)
	process.set_args(['-ui', 'json', '-s', session, file, '-e',
		'echo -to-file ${quote(ready)} %val{client}'])
	process.set_environment(env)
	process.set_redirect_stdio()
	process.run()
	mut editor := &Client{
		root:       root
		executable: kak
		session:    session
		env:        env
		process:    process
	}
	editor.wait_file(ready, 'startup') or {
		editor.close()
		return err
	}
	editor.client = os.read_file(ready) or {
		editor.close()
		return err
	}.trim_space()
	return editor
}

fn (mut editor Client) read_output() {
	for {
		out := editor.process.stdout_read()
		err := editor.process.stderr_read()
		if out == '' && err == '' {
			break
		}
		editor.output += out
		editor.errors += err
	}
}

pub fn (mut editor Client) diagnostic(label string) IError {
	editor.read_output()
	tail := editor.output[if editor.output.len > 4000 { editor.output.len - 4000 } else { 0 }..]
	return error('${label}\n${editor.errors}\n${tail}')
}

fn (mut editor Client) wait_file(path string, label string) ! {
	deadline := time.sys_mono_now() + u64(timeout)
	for time.sys_mono_now() < deadline && editor.process.is_alive() {
		editor.read_output()
		if os.is_file(path) && os.file_size(path) > 0 {
			return
		}
		time.sleep(poll)
	}
	return editor.diagnostic('Timed out waiting for ${label}')
}

fn (mut editor Client) send(command string) ! {
	mut child := os.new_process(editor.executable)
	child.set_args(['-p', editor.session])
	child.set_environment(editor.env)
	child.set_redirect_stdio()
	child.run()
	defer { child.close() }
	child.stdin_write(command + '\n')
	// Kakoune reads its remote command until EOF. Keep the output pipes open.
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	deadline := time.sys_mono_now() + u64(timeout)
	mut errors := ''
	for child.is_alive() && time.sys_mono_now() < deadline {
		editor.read_output()
		errors += child.stderr_read()
		child.stdout_read()
		time.sleep(poll)
	}
	if child.is_alive() {
		child.signal_kill()
		child.status = .running
		child.wait()
		return error('Kakoune command socket did not respond')
	}
	errors += child.stderr_read()
	if child.code != 0 {
		return error('Kakoune command socket failed (${child.code}): ${errors}')
	}
}

pub fn (mut editor Client) close() {
	if editor.process.is_alive() {
		editor.send('kill!') or {}
		if editor.process.stdio_fd[0] != -1 {
			os.fd_close(editor.process.stdio_fd[0])
			editor.process.stdio_fd[0] = -1
		}
		deadline := time.sys_mono_now() + u64(time.second)
		for editor.process.is_alive() && time.sys_mono_now() < deadline {
			editor.read_output()
			time.sleep(poll)
		}
		if editor.process.is_alive() {
			editor.process.signal_kill()
			editor.process.status = .running
			editor.process.wait()
		}
	}
	editor.read_output()
	editor.process.close()
}

pub fn (mut editor Client) remote(command string) ! {
	return editor.execute(command, false)
}

pub fn (mut editor Client) remote_allow_error(command string) ! {
	return editor.execute(command, true)
}

fn (mut editor Client) execute(command string, allow_error bool) ! {
	// Socket delivery can finish before Kakoune executes the command.
	done := os.join_path(editor.root, 'command-' + rand.uuid_v4())
	failure := done + '.error'
	defer {
		os.rm(done) or {}
		os.rm(failure) or {}
	}
	editor.send('try %{
evaluate-commands -client ${editor.client} %{
${command}
}
} catch %{
echo -to-file ${quote(failure)} %val{error}
}
echo -to-file ${quote(done)} done')!
	editor.wait_file(done, command)!
	if !allow_error && os.is_file(failure) {
		return error('Kakoune command failed: ' + os.read_file(failure)!.trim_space())
	}
}

pub fn (editor Client) save_artifacts() ! {
	os.write_file(os.join_path(editor.root, 'ui.jsonl'), editor.output)!
	os.write_file(os.join_path(editor.root, 'kak-stderr'), editor.errors)!
	if editor.errors != '' {
		return error('Kakoune wrote to stderr: ${editor.errors}')
	}
}

pub fn (mut editor Client) keys(value string) {
	editor.process.stdin_write(json2.encode(KeyEvent{ params: [value] }) + '\n')
}

pub fn (mut editor Client) value(expression string) !string {
	path := os.join_path(editor.root, 'value')
	editor.remote('echo -to-file ${quote(path)} ${expression}')!
	return os.read_file(path)!.trim_space()
}

pub fn (mut editor Client) offset() int {
	editor.read_output()
	return editor.output.len
}

pub fn (mut editor Client) wait_value(expression string, value string, prefix bool, label string) ! {
	deadline := time.sys_mono_now() + u64(timeout)
	for time.sys_mono_now() < deadline {
		actual := editor.value(expression)!
		if actual == value || (prefix && actual.starts_with(value)) {
			return
		}
		time.sleep(poll)
	}
	return editor.diagnostic('Timed out waiting for ${label}')
}

pub fn (mut editor Client) wait_info(offset int, needle string) !string {
	return editor.wait_event(offset, 'info_show', [needle])
}

pub fn (mut editor Client) wait_event(offset int, method_name string, needles []string) !string {
	deadline := time.sys_mono_now() + u64(timeout)
	for time.sys_mono_now() < deadline && editor.process.is_alive() {
		editor.read_output()
		for line in editor.output[offset..].split_into_lines() {
			event := json2.decode[json2.Any](line) or { continue }
			message := event.as_map()
			method := message['method'] or { continue }
			params := message['params'] or { continue }
			contents := params.str()
			if method.str() == method_name && needles.all(contents.contains(it)) {
				return contents
			}
		}
		time.sleep(poll)
	}
	return editor.diagnostic('Timed out waiting for ${method_name} with ${needles.join(', ')}')
}
