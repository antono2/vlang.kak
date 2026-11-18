// Check the installed VLS through its public language-server protocol.
import flag
import json2
import liveeditor
import lspwire
import net.urllib
import os
import rand
import time

const request_timeout = 20 * time.second
const exit_timeout = 5 * time.second
const poll_interval = 20 * time.millisecond
const diagnostic_limit = 1200
// LSP positions are zero-based. These points address the declaration and call in source.
const declaration_line = 3
const main_line = 7
const call_line = 8
const call_column = 14
const hover_column = 15
const completion_column = 17
const signature_column = 21
const declaration_name_column = 4
const organize_line = 2
const error_severity = 1
const source = 'module main

// Adds two values.
fn add(left int, right int) int {
    return left + right
}

fn main() {
    result := add(1, 2)
    println(result)
}
'
const imports = 'module main\n\nimport os\nimport math\n\nfn main() { println(os.args.len) }\n'
const broken = "module main\nfn broken() int { return 'wrong' }\n"
const capabilities = ['hoverProvider', 'signatureHelpProvider', 'definitionProvider',
	'referencesProvider', 'renameProvider', 'callHierarchyProvider', 'codeActionProvider',
	'documentHighlightProvider', 'selectionRangeProvider', 'documentSymbolProvider',
	'completionProvider', 'semanticTokensProvider']

struct Transport {
mut:
	process     &os.Process
	reader      lspwire.FrameReader
	last_id     int
	diagnostics string
}

fn require(ok bool, message string) ! {
	if !ok {
		return error(message)
	}
}

fn (mut wire Transport) send(body string) {
	wire.process.stdin_write('Content-Length: ${body.len}\r\n\r\n${body}')
}

fn (mut wire Transport) drain_errors() {
	wire.diagnostics += wire.process.stderr_read()
	if wire.diagnostics.len > diagnostic_limit {
		wire.diagnostics = wire.diagnostics[wire.diagnostics.len - diagnostic_limit..]
	}
}

fn (mut wire Transport) receive(deadline u64) !map[string]json2.Any {
	for time.sys_mono_now() < deadline {
		body := wire.reader.next()!
		if body != '' {
			return json2.decode[map[string]json2.Any](body)
		}
		chunk := wire.process.stdout_read()
		wire.reader.pending += chunk
		wire.drain_errors()
		if chunk != '' {
			continue
		}
		require(wire.process.is_alive(), 'VLS closed stdout unexpectedly')!
		time.sleep(poll_interval)
	}
	return error('Timed out waiting for a VLS response')
}

fn (mut wire Transport) acknowledge_request(message map[string]json2.Any) bool {
	if id := message['id'] {
		if 'method' in message {
			wire.send('{"jsonrpc":"2.0","id":${id.json_str()},"result":null}')
			return true
		}
	}
	return false
}

fn (mut wire Transport) request(method string, params string) !json2.Any {
	wire.last_id++
	id := wire.last_id.str()
	wire.send('{"jsonrpc":"2.0","id":${id},"method":${json2.encode(method)},"params":${params}}')
	deadline := time.sys_mono_now() + u64(request_timeout)
	for {
		message := wire.receive(deadline)!
		if wire.acknowledge_request(message) {
			continue
		}
		if optional(message, 'id').json_str() == id {
			if details := message['error'] {
				return error('VLS ${method} failed: ${details.json_str()}')
			}
			return message['result'] or { return error('VLS ${method} omitted its result') }
		}
	}
	return error('VLS did not respond to ${method}')
}

fn (mut wire Transport) notify(method string, params string) {
	wire.send('{"jsonrpc":"2.0","method":${json2.encode(method)},"params":${params}}')
}

fn (mut wire Transport) open(uri string, content string) {
	wire.notify('textDocument/didOpen', '{"textDocument":{"uri":${uri},"languageId":"v","version":1,"text":${json2.encode(content)}}}')
}

fn uri(path string) string {
	return json2.encode('file://' + path.split('/').map(urllib.path_escape(it)).join('/'))
}

fn document(uri string) string {
	return '{"textDocument":{"uri":${uri}}}'
}

fn location(uri string, line int, column int) string {
	return '{"textDocument":{"uri":${uri}},"position":{"line":${line},"character":${column}}}'
}

fn optional(object map[string]json2.Any, key string) json2.Any {
	return object[key] or { json2.Any(json2.Null{}) }
}

fn lookup(node json2.Any, key string) !json2.Any {
	if node is map[string]json2.Any {
		return node[key] or { return error('VLS result omitted ${key}') }
	}
	return error('Expected an object containing ${key}')
}

fn result_array(node json2.Any) ![]json2.Any {
	if node is []json2.Any {
		return node
	}
	return error('Expected an array from VLS')
}

fn first(node json2.Any) !json2.Any {
	items := result_array(node)!
	if items.len == 0 {
		return error('Expected a nonempty array from VLS')
	}
	return items[0]
}

fn range_line(node json2.Any) !int {
	return lookup(lookup(lookup(node, 'range')!, 'start')!, 'line')!.int()
}

fn (mut wire Transport) check_navigation(main_uri string) ! {
	call := location(main_uri, call_line, call_column)
	hover := wire.request('textDocument/hover', location(main_uri, call_line, hover_column))!.json_str()
	require(hover.contains('fn add(left int, right int) int') && hover.contains('Adds two values.'),
		'VLS hover omitted the declaration or its documentation')!
	signature := wire.request('textDocument/signatureHelp', location(main_uri, call_line, signature_column))!
	label := lookup(first(lookup(signature, 'signatures')!)!, 'label')!.str()
	require(label.contains('add(left int, right int) int') && lookup(signature, 'activeParameter')!.int() == 1,
		'VLS omitted the signature or selected the wrong parameter')!
	definition := wire.request('textDocument/definition', call)!
	require(range_line(definition)! == declaration_line, 'VLS definition has the wrong line')!
	symbols := result_array(wire.request('textDocument/documentSymbol', document(main_uri))!)!
	require(symbols.any(optional(it.as_map(), 'name').str() == 'add'), 'VLS omitted the add symbol')!
	references := result_array(wire.request('textDocument/references', call[..call.len - 1] +
		',"context":{"includeDeclaration":true}}')!)!
	require(references.len >= 2, 'VLS did not find the declaration and call reference')!
	renamed := wire.request('textDocument/rename', call[..call.len - 1] + ',"newName":"sum_values"}')!
	edits := result_array(lookup(lookup(renamed, 'changes')!, json2.decode[string](main_uri)!)!)!
	mut lines := map[int]bool{}
	for edit in edits {
		lines[range_line(edit)!] = true
		require(lookup(edit, 'newText')!.str() == 'sum_values', 'VLS rename returned the wrong replacement')!
	}
	require(lines.len == 2 && declaration_line in lines && call_line in lines,
		'VLS rename did not edit the declaration and call')!
}

fn (mut wire Transport) check_calls(main_uri string) ! {
	callee := first(wire.request('textDocument/prepareCallHierarchy',
		location(main_uri, declaration_line, declaration_name_column))!)!
	require(lookup(callee, 'name')!.str() == 'add', 'VLS omitted the add call item')!
	incoming := result_array(wire.request('callHierarchy/incomingCalls', '{"item":${callee.json_str()}}')!)!
	require(incoming.any(optional(optional(it.as_map(), 'from').as_map(), 'name').str() == 'main'), 'VLS omitted the main caller')!
	caller := first(wire.request('textDocument/prepareCallHierarchy',
		location(main_uri, main_line, declaration_name_column))!)!
	require(lookup(caller, 'name')!.str() == 'main', 'VLS omitted the main call item')!
	outgoing := result_array(wire.request('callHierarchy/outgoingCalls', '{"item":${caller.json_str()}}')!)!
	require(outgoing.any(optional(optional(it.as_map(), 'to').as_map(), 'name').str() == 'add'), 'VLS omitted the add callee')!
}

fn (mut wire Transport) check_imports(root string) ! {
	path := os.join_path(root, 'imports.v')
	os.write_file(path, imports)!
	defer { os.rm(path) or {} }
	import_uri := uri(path)
	wire.open(import_uri, imports)
	actions := result_array(wire.request('textDocument/codeAction',
		'{"textDocument":{"uri":${import_uri}},"range":{"start":{"line":${organize_line},"character":0},"end":{"line":${organize_line},"character":0}},"context":{"diagnostics":[],"only":["source.organizeImports"]}}')!)!
	for action in actions {
		if optional(action.as_map(), 'kind').str() != 'source.organizeImports' {
			continue
		}
		changes := lookup(lookup(action, 'edit')!, 'changes')!
		edit := first(lookup(changes, json2.decode[string](import_uri)!)!)!
		if lookup(edit, 'newText')!.str() == 'import math\nimport os' {
			return
		}
	}
	return error('VLS did not offer an import organizing action')
}

fn (mut wire Transport) check_syntax(main_uri string) ! {
	highlights := result_array(wire.request('textDocument/documentHighlight', location(main_uri, call_line, call_column))!)!
	mut highlighted := false
	for item in highlights {
		highlighted = highlighted || range_line(item)! == call_line
	}
	require(highlighted, 'VLS did not highlight the call')!
	ranges := wire.request('textDocument/selectionRange',
		'{"textDocument":{"uri":${main_uri}},"positions":[{"line":${call_line},"character":${call_column}}]}')!
	parent := lookup(first(ranges)!, 'parent')!
	require(parent is map[string]json2.Any && parent.as_map().len > 0,
		'VLS did not return an expandable syntax range')!
	completion := wire.request('textDocument/completion', location(main_uri, call_line, completion_column))!
	items := result_array(lookup(completion, 'items')!)!
	require(items.any(optional(it.as_map(), 'label').str() == 'add'), 'VLS completion omitted add')!
	tokens := wire.request('textDocument/semanticTokens/full', document(main_uri))!
	require(result_array(lookup(tokens, 'data')!)!.len > 0, 'VLS returned no semantic tokens')!
}

fn (mut wire Transport) check_diagnostics(main_uri string) ! {
	wire.notify('textDocument/didChange',
		'{"textDocument":{"uri":${main_uri},"version":2},"contentChanges":[{"text":${json2.encode(broken)}}]}')
	deadline := time.sys_mono_now() + u64(request_timeout)
	for {
		message := wire.receive(deadline)!
		if wire.acknowledge_request(message) || optional(message, 'method').str() != 'textDocument/publishDiagnostics' {
			continue
		}
		params := optional(message, 'params').as_map()
		if optional(params, 'version').int() != 2 {
			continue
		}
		items := result_array(optional(params, 'diagnostics'))!
		if items.len > 0 {
			require(items.any(optional(it.as_map(), 'severity').int() == error_severity),
				'VLS published no error diagnostic')!
			return
		}
	}
}

fn check_protocol(executable string, compiler string, root string) ! {
	// A server can close its input before the first request reaches it.
	os.signal_ignore(.pipe)
	mut environment := os.environ()
	environment['VLS_V_COMMAND'] = compiler
	mut child := os.new_process(executable)
	child.set_environment(environment)
	child.set_redirect_stdio()
	child.run()
	mut wire := Transport{ process: child }
	defer {
		if wire.process.is_alive() {
			wire.process.signal_kill()
			wire.process.wait()
		}
		wire.drain_errors()
		if wire.diagnostics != '' {
			eprintln(wire.diagnostics.trim_space())
		}
		wire.process.close()
	}
	root_uri := uri(root)
	main_uri := uri(os.join_path(root, 'main.v'))
	result := wire.request('initialize',
		'{"processId":${os.getpid()},"rootUri":${root_uri},"workspaceFolders":[{"uri":${root_uri},"name":"vlang-check"}],"capabilities":{}}')!
	server_capabilities := lookup(result, 'capabilities')!
	for name in capabilities {
		value := lookup(server_capabilities, name)!
		require(value !is json2.Null && value.json_str() != 'false', 'VLS does not advertise ${name}')!
	}
	wire.notify('initialized', '{}')
	wire.open(main_uri, source)
	wire.check_navigation(main_uri)!
	wire.check_calls(main_uri)!
	wire.check_imports(root)!
	wire.check_syntax(main_uri)!
	wire.check_diagnostics(main_uri)!
	wire.request('shutdown', '{}')!
	wire.notify('exit', '{}')
	deadline := time.sys_mono_now() + u64(exit_timeout)
	for wire.process.is_alive() && time.sys_mono_now() < deadline {
		wire.drain_errors()
		time.sleep(poll_interval)
	}
	require(!wire.process.is_alive() && wire.process.code == 0, 'VLS did not exit successfully after shutdown')!
	println('ok - VLS hover, rename, calls, import actions, syntax, completion, diagnostics')
}

fn run(args []string) ! {
	mut parser := flag.new_flag_parser(args)
	parser.application('check-vls')
	parser.description('Check the VLS protocol and optionally drive the managed Kakoune editor.')
	default_prefix := os.getenv_opt('VLANG_KAK_PREFIX') or { os.join_path(os.home_dir(), '.local') }
	prefix := os.expand_tilde_to_home(parser.string('prefix', 0, default_prefix, 'managed installation prefix'))
	server_path := parser.string('vls', 0, '', 'VLS executable (default: PREFIX/bin/vls)')
	project := parser.string('project', 0, '', 'use an existing empty directory for the test fixture')
	editor := parser.bool('editor', 0, false, 'also check the managed Kakoune launcher')
	if parser.bool('help', `h`, false, 'show this help') {
		println(parser.usage())
		return
	}
	require(parser.finalize()!.len == 0, parser.usage())!
	vls := os.abs_path(if server_path == '' {
		os.join_path(prefix, 'bin', 'vls')
	} else {
		os.expand_tilde_to_home(server_path)
	})
	require(os.is_file(vls) && os.is_executable(vls), 'VLS executable missing: ${vls}')!
	mut kak := ''
	launcher := os.join_path(os.abs_path(prefix), 'bin', 'kak-v')
	if editor {
		managed_vls := os.join_path(prefix, 'bin', 'vls')
		require(os.real_path(vls) == os.real_path(managed_vls),
			'The editor uses PREFIX/bin/vls. Use --vls alone to check a separate server.')!
		managed_kak := os.join_path(os.abs_path(prefix), 'bin', 'kak')
		kak = if os.is_executable(managed_kak) {
			managed_kak
		} else {
			os.find_abs_path_of_executable('kak')!
		}
		require(os.is_executable(launcher), 'V IDE launcher missing: ${launcher}')!
	}
	artifacts := os.getenv('VLANG_LSP_ARTIFACTS')
	if artifacts != '' && project == '' {
		os.mkdir_all(artifacts)!
	}
	parent := if artifacts == '' { os.temp_dir() } else { os.abs_path(artifacts) }
	root := if project == '' {
		os.join_path(parent, 'vlang-kak-lsp-' + rand.uuid_v4())
	} else {
		os.real_path(project)
	}
	if project == '' {
		os.mkdir(root, mode: 0o700)!
	} else {
		require(os.ls(root)!.len == 0, 'The live-check workspace must be empty: ${root}')!
	}
	defer {
		if artifacts == '' && project == '' {
			os.rmdir_all(root) or {}
		}
	}
	os.write_file(os.join_path(root, 'v.mod'), "Module { name: 'vlang_check' }\n")!
	os.write_file(os.join_path(root, 'main.v'), source)!
	check_protocol(vls, @VEXE, root)!
	if editor {
		liveeditor.run(kak, launcher, root, source, imports)!
	}
}

run(os.args[1..]) or {
	eprintln('not ok - live VLS protocol check: ${err.msg()}')
	exit(1)
}
