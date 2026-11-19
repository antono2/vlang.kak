// Translate ANSI terminal captures into ImageMagick drawing commands.
module demoframes

import strings

pub const columns = 102
pub const rows = 33
const image_width = 960
const image_height = 665
const left_margin = 18
const title_baseline = 29
const body_top = 48
const glyph_baseline = 14
const cell_width = 9
const cell_height = 18
const font_size = 15
const palette = ['#171b24', '#e56c73', '#91c788', '#f1c75b', '#78a9e3', '#c49bdf', '#75c4c7',
	'#dce1e8']
// Xterm indices 16–231 encode a 6×6×6 RGB cube.
const cube_levels = [0, 95, 135, 175, 215, 255]

struct Style {
mut:
	fg string = palette[7]
	bg string = palette[0]
}

fn rgb(red int, green int, blue int) string {
	return '#${red:02x}${green:02x}${blue:02x}'
}

fn indexed_color(index int) string {
	if index < 16 {
		return palette[index % 8]
	}
	if index >= 232 {
		gray := 8 + (index - 232) * 10
		return rgb(gray, gray, gray)
	}
	cube := index - 16
	return rgb(cube_levels[cube / 36], cube_levels[(cube / 6) % 6], cube_levels[cube % 6])
}

// Apply ANSI Select Graphic Rendition color codes from tmux.
fn (mut style Style) apply(sequence string) {
	codes := sequence.split(';').map(it.int())
	for i := 0; i < codes.len; i++ {
		code := codes[i]
		match true {
			code == 0 {
				style = Style{}
			}
			code == 39 {
				style.fg = palette[7]
			}
			code == 49 {
				style.bg = palette[0]
			}
			code in [38, 48] && i + 2 < codes.len {
				mut color := ''
				match codes[i + 1] {
					5 {
						color = indexed_color(codes[i + 2] % 256)
						i += 2
					}
					2 {
						if i + 4 < codes.len {
							color = rgb(codes[i + 2] % 256, codes[i + 3] % 256, codes[i + 4] % 256)
							i += 4
						}
					}
					else {}
				}

				if color != '' {
					if code == 38 {
						style.fg = color
					} else {
						style.bg = color
					}
				}
			}
			(code >= 30 && code <= 37) || (code >= 90 && code <= 97) {
				style.fg = palette[code % 10]
			}
			(code >= 40 && code <= 47) || (code >= 100 && code <= 107) {
				style.bg = palette[code % 10]
			}
			else {}
		}
	}
}

fn drawing_text(text string) string {
	return text.replace_each(['\\', '\\\\', '"', '\\"'])
}

fn draw_span(mut drawing strings.Builder, text string, row int, column int, style Style) int {
	glyphs := text.runes()
	count := if glyphs.len > columns - column { columns - column } else { glyphs.len }
	y := body_top + row * cell_height
	x := left_margin + column * cell_width
	if count > 0 && style.bg != palette[0] {
		drawing.writeln('fill "${style.bg}" rectangle ${x},${y} ${x + count * cell_width - 1},${y +
			cell_height - 1}')
	}
	drawing.writeln('fill "${style.fg}"')
	for offset, glyph in glyphs[..count] {
		if glyph > 32 && glyph != 127 {
			drawing.writeln('text ${x + offset * cell_width},${y + glyph_baseline} "${drawing_text(glyph.str())}"')
		}
	}
	return column + count
}

fn draw_row(mut drawing strings.Builder, line string, row int) {
	mut style := Style{}
	mut column := 0
	mut start := 0
	mut cursor := 0
	for cursor + 1 < line.len && column < columns {
		if line[cursor] != 27 || line[cursor + 1] != `[` {
			cursor++
			continue
		}
		mut end := cursor + 2
		for end < line.len && ((line[end] >= `0` && line[end] <= `9`) || line[end] == `;`) {
			end++
		}
		if end >= line.len || line[end] != `m` {
			cursor++
			continue
		}
		column = draw_span(mut drawing, line[start..cursor], row, column, style)
		style.apply(line[cursor + 2..end])
		cursor = end + 1
		start = cursor
	}
	if column < columns {
		draw_span(mut drawing, line[start..], row, column, style)
	}
}

pub fn drawing(screen string, title string) string {
	mut commands := strings.new_builder(screen.len * 8)
	commands.writeln('viewbox 0 0 ${image_width} ${image_height}')
	commands.writeln('fill "${palette[0]}" rectangle 0,0 ${image_width - 1},${image_height - 1}')
	commands.writeln('font "DejaVu-Sans-Mono" font-size ${font_size}')
	commands.writeln('fill "${palette[3]}" text ${left_margin},${title_baseline} "${drawing_text(title)}"')
	for row, line in screen.split_into_lines() {
		if row >= rows {
			break
		}
		draw_row(mut commands, line, row)
	}
	return commands.str()
}
