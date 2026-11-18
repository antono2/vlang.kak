// Validate the installed VLS candidate before activating it in a managed prefix.
import json2
import os
import strconv
import time

const timeout_seconds = 10
const poll_interval = 20 * time.millisecond
const max_header_bytes = 8192
const max_body_bytes = 10_000_000
const diagnostic_bytes = 4096
const initialize_id = 1

struct FrameReader {
mut:
	pending     string
	diagnostics string
}

fn (mut reader FrameReader) next() !string {
	header_end := reader.pending.index('\r\n\r\n') or {
		if reader.pending.len > max_header_bytes {
			return error('VLS response has an oversized header')
		}
		return ''
	}
	if header_end > max_header_bytes {
		return error('VLS response has an oversized header')
	}
	mut length := 0
	for line in reader.pending[..header_end].split('\r\n') {
		name, value := line.split_once(':') or { return error('Malformed VLS response header') }
		if name.to_lower() == 'content-length' {
			if length != 0 {
				return error('Repeated VLS Content-Length')
			}
			length = strconv.atoi(value.trim_space())!
			if length <= 0 || length > max_body_bytes {
				return error('Invalid VLS Content-Length ${length}')
			}
		}
	}
	if length == 0 {
		return error('Missing VLS Content-Length')
	}
	body_start := header_end + '\r\n\r\n'.len
	end := body_start + length
	if end > reader.pending.len {
		return ''
	}
	body := reader.pending[body_start..end]
	reader.pending = reader.pending[end..]
	return body
}

fn is_initialize_response(message string) !bool {
	response := json2.decode[map[string]json2.Any](message)!
	id := response['id'] or { return false }
	if id.json_str() != initialize_id.str() || 'method' in response {
		return false
	}
	version := response['jsonrpc'] or { return error('VLS response omitted its JSON-RPC version') }
	if version.json_str() != '"2.0"' {
		return error('VLS sent an invalid JSON-RPC version')
	}
	if details := response['error'] {
		if details !is json2.Null {
			return error('VLS initialization failed: ${details.json_str()}')
		}
	}
	result := response['result'] or { return error('VLS initialize response omitted its result') }
	capabilities := result.as_map()['capabilities'] or {
		return error('VLS initialize response omitted server capabilities')
	}
	if capabilities !is map[string]json2.Any {
		return error('VLS server capabilities must be an object')
	}
	return true
}

fn initialize(mut server os.Process, mut reader FrameReader) ! {
	body := '{"jsonrpc":"2.0","id":${initialize_id},"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
	server.stdin_write('Content-Length: ${body.len}\r\n\r\n${body}')
	end := time.sys_mono_now() + u64(timeout_seconds * time.second)
	for time.sys_mono_now() < end {
		alive := server.is_alive()
		chunk := server.stdout_read()
		reader.pending += chunk
		reader.diagnostics += server.stderr_read()
		if reader.diagnostics.len > diagnostic_bytes {
			reader.diagnostics = reader.diagnostics[reader.diagnostics.len - diagnostic_bytes..]
		}
		for {
			message := reader.next()!
			if message == '' {
				break
			}
			if is_initialize_response(message)! {
				return
			}
		}
		if !alive && chunk == '' {
			return error('VLS exited before completing initialization')
		}
		time.sleep(poll_interval)
	}
	return error('VLS did not complete LSP initialization within ${timeout_seconds} seconds.')
}

fn probe(path string) ! {
	server_path := os.find_abs_path_of_executable(path)!
	mut server := os.new_process(server_path)
	server.set_redirect_stdio()
	server.run()
	defer {
		if server.is_alive() {
			server.signal_kill()
			server.status = .running
			server.wait()
		}
		server.close()
	}
	mut reader := FrameReader{}
	initialize(mut server, mut reader) or {
		if reader.diagnostics != '' {
			eprintln(reader.diagnostics.trim_space())
		}
		return err
	}
	println('VLS initialization: passed')
}

args := os.args[1..]
usage := 'Usage: v run scripts/probe-vls.vsh VLS_EXECUTABLE'
if args in [['--help'], ['-h']] {
	println(usage)
	exit(0)
}
if args.len != 1 {
	eprintln(usage)
	exit(2)
}
probe(args[0]) or {
	eprintln(err)
	exit(1)
}
