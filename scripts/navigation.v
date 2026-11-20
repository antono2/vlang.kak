// Resolve the source location remembered for a Kakoune result or hover view.
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

fn navigate(args []string) {
	if args.len < 2 {
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
