// Resolve alternate files and the source locations remembered by Kakoune views.
import os

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

// Kakoune escapes both the map separator and literal backslashes.
fn map_escape(value string) string {
	return value.replace_each(['\\', '\\\\', '=', '\\='])
}

fn map_entry(client string, value string) string {
	return quote(map_escape(client) + '=' + map_escape(value))
}

fn remembered(entries []string, client string) string {
	mut value := ''
	key := map_escape(client) + '='
	for entry in entries {
		if entry.starts_with(key) {
			value = entry[key.len..].replace_each(['\\\\', '\\', '\\=', '='])
		}
	}
	return value
}

fn alternate(file string) {
	// Kakoune's alternate command pairs .v and _test.v files.
	path, missing := if file.ends_with('_test.v') {
		file.trim_string_right('_test.v') + '.v', 'implementation file not found'
	} else if file.ends_with('.v') {
		file.trim_string_right('.v') + '_test.v', 'test file not found'
	} else {
		println("fail 'alternative file not found'")
		return
	}
	if os.is_file(path) {
		println('edit -- ' + quote(path))
	} else {
		println('fail ' + quote(missing))
	}
}

fn navigate(args []string) {
	if args.len < 2 {
		return
	}
	if args[0] == 'alternate' && args.len == 2 {
		alternate(args[1])
		return
	}
	action, client := args[0], args[1]
	if action in ['remember-doc', 'remember-results'] && args.len == 4 {
		view := action.trim_string_left('remember-')
		println('set-option -add global v_${view}_origins ${map_entry(client, args[2])}')
		println('set-option -add global v_${view}_selections ${map_entry(client, args[3])}')
		return
	}
	if action !in ['doc', 'results'] {
		return
	}
	// The empty argument separates Kakoune's two lists of key=value entries.
	entries := args[2..]
	boundary := entries.index('')
	if boundary < 0 {
		return
	}
	origin := remembered(entries[..boundary], client)
	if origin != '' {
		selection := remembered(entries[boundary + 1..], client)
		println('v-${action}-install ${quote(origin)} ${quote(selection)}')
	}
}

fn main() {
	navigate(os.args[1..])
}
