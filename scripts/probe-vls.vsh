// Validate the installed VLS candidate before activating it in a managed prefix.
import json2
import os
import lspwire
import time

const timeout_seconds = 10
const poll_interval = 20 * time.millisecond
const diagnostic_bytes = 4096
const initialize_id = 1

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

struct ProbeOutput {
mut:
	reader      lspwire.FrameReader
	diagnostics string
}

fn initialize(mut server os.Process, mut output ProbeOutput) ! {
	body := '{"jsonrpc":"2.0","id":${initialize_id},"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'
	server.stdin_write('Content-Length: ${body.len}\r\n\r\n${body}')
	end := time.sys_mono_now() + u64(timeout_seconds * time.second)
	for time.sys_mono_now() < end {
		alive := server.is_alive()
		chunk := server.stdout_read()
		output.reader.pending += chunk
		output.diagnostics += server.stderr_read()
		if output.diagnostics.len > diagnostic_bytes {
			output.diagnostics = output.diagnostics[output.diagnostics.len - diagnostic_bytes..]
		}
		for {
			message := output.reader.next()!
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
	os.signal_ignore(.pipe)
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
	mut output := ProbeOutput{}
	initialize(mut server, mut output) or {
		if output.diagnostics != '' {
			eprintln(output.diagnostics.trim_space())
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
