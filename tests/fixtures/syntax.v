module main

@[deprecated: 'use replacement']
fn legacy() string {
	return 'legacy'
}

struct Widget {
	name  string = 'demo'
	count usize  = 0x2a
}

fn identity[T](value T) T {
	return value
}

fn (widget Widget) label() string {
	return '${widget.name}: ${widget.count}'
}

fn main() {
	widget := Widget{}
	answer, scientific := identity[int](42), 1.2E3
	// TODO: exercise a modern V corpus
	assert widget.label() == 'demo: 42'
	println('${answer} ${scientific} ${widget.label()}')
}
