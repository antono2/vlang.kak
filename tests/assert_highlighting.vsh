// Verify syntax faces in the last draw sent by the Kakoune JSON UI.
import os
import strconv
import x.json2

const faces = {
	'attribute': 'rgb:101001'
	'comment':   'rgb:202002'
	'function':  'rgb:303003'
	'keyword':   'rgb:404004'
	'meta':      'rgb:505005'
	'operator':  'rgb:606006'
	'string':    'rgb:707007'
	'type':      'rgb:808008'
	'value':     'rgb:909009'
}

fn last_draw(path string) ![]json2.Any {
	mut draw := []json2.Any{}
	mut found := false
	for line in os.read_lines(path)! {
		message := json2.decode[json2.Any](line)!.as_map()
		method := message['method'] or { continue }
		if method.str() == 'draw' {
			params :=
				(message['params'] or { return error('Kakoune draw has no params') }).as_array()
			if params.len == 0 {
				return error('Kakoune draw has no viewport')
			}
			draw = params[0].as_array()
			found = true
		}
	}
	if !found {
		return error('Kakoune emitted no draw message')
	}
	return draw
}

fn rendered_line(atoms []json2.Any) !(string, []string) {
	mut rendered := ''
	mut colors := []string{}
	for value in atoms {
		atom := value.as_map()
		part :=
			(atom['contents'] or { return error('Draw atom has no text') }).str().trim_string_right('\n')
		rendered += part
		face := (atom['face'] or { return error('Draw atom has no face') }).as_map()
		color := (face['fg'] or { return error('Draw atom has no foreground') }).str()
		// V string indexes and lengths are bytes, so match the byte spans of UTF-8 text.
		for _ in 0 .. part.len {
			colors << color
		}
	}
	return rendered, colors
}

fn check(args []string) ! {
	if args.len != 2 {
		return error_with_code('Usage: v run tests/assert_highlighting.vsh UI_OUTPUT EXPECTATIONS',
			2)
	}
	lines := last_draw(args[0])!
	mut failures := []string{}
	for line in os.read_lines(args[1])! {
		if line == '' || line.starts_with('#') {
			continue
		}
		fields := line.split('\t')
		if fields.len != 3 || fields[1] == '' {
			return error('Expected a line number, text and face in ${line}')
		}
		index := strconv.atoi(fields[0])!
		needle := fields[1]
		face := fields[2]
		expected := faces[face] or { return error('Unknown highlighting face ${face}') }
		if index < 1 || index > lines.len {
			failures << 'line ${index}: outside rendered viewport (${lines.len} lines)'
			continue
		}
		rendered, colors := rendered_line(lines[index - 1].as_array())!
		start := rendered.index(needle) or {
			failures << 'line ${index}: text not rendered: ${needle}'
			continue
		}
		mut actual := []string{}
		for color in colors[start..start + needle.len] {
			if color !in actual {
				actual << color
			}
		}
		actual.sort()
		if actual != [expected] {
			failures << 'line ${index}: ${needle} expected ${face} (${expected}), got ${actual}'
		}
	}
	if failures.len > 0 {
		return error('Highlighting assertions failed:\n  ' + failures.join('\n  '))
	}
	println('ok - rendered syntax highlighting (${os.file_name(args[1]).all_before_last('.')})')
}

check(os.args[1..]) or {
	eprintln(err)
	exit(if err.code() == 2 { 2 } else { 1 })
}
