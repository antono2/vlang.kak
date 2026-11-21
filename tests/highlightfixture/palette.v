// Give syntax faces stable foreground markers for the Kakoune JSON assertions.
module highlightfixture

import crypto.sha256

// Kakoune's RGB format uses two hexadecimal digits for each color channel.
const rgb_hex_digits = 6
const syntax_faces = ['attribute', 'comment', 'function', 'keyword', 'meta', 'operator', 'string',
	'type', 'value']

pub fn colors() map[string]string {
	mut palette := map[string]string{}
	for face in syntax_faces {
		// Derive a marker from the face name independently of the editor theme.
		digest := sha256.hexhash('vlang.kak highlighting fixture: ' + face)
		palette[face] = 'rgb:' + digest[..rgb_hex_digits]
	}
	return palette
}
