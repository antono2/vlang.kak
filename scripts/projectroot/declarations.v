// Recognize the test declarations used by the task runner and editor menu.
module projectroot

pub fn test_name(line string) string {
	declaration, _ := line.split_once('(') or { return '' }
	words := declaration.fields()
	start := if words.len == 3 && words[0] == 'pub' { 1 } else { 0 }
	if words.len != start + 2 || words[start] != 'fn' || !words[start + 1].starts_with('test_') {
		return ''
	}
	name := words[start + 1]
	suffix := name['test_'.len..]
	return if suffix.len > 0 && suffix.bytes().all(it.is_alnum() || it == `_`) { name } else { '' }
}
