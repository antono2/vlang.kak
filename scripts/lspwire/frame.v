// Decode byte-counted Language Server Protocol messages.
module lspwire

import strconv

const max_header_bytes = 8192
const max_body_bytes = 10_000_000

pub struct FrameReader {
pub mut:
	pending string
}

pub fn (mut reader FrameReader) next() !string {
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
