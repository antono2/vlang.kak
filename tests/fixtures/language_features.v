module main

interface Speaker {
	speak() string
}

enum Phase {
	ready
	running
}

type Identifier = string

type Number = f64 | int

struct Greeter implements Speaker {
	prefix string = 'hello'
}

fn (greeter Greeter) speak() string {
	return greeter.prefix
}

fn identity[T](value T) T {
	return value
}

fn optional_name(ok bool) ?string {
	if ok {
		return 'V'
	}
	return none
}

fn require_positive(value int) !int {
	if value < 0 {
		return error('negative value')
	}
	return value
}

fn describe(number Number) string {
	return match number {
		int { 'integer ${number}' }
		f64 { 'float ${number}' }
	}
}

fn main() {
	greeter := Greeter{}
	phase := Phase.ready
	identifier := Identifier('sample')
	value := identity[int](42)
	name := optional_name(true) or { 'fallback' }
	positive := require_positive(value) or { 0 }
	letter := `V`
	raw := r'raw string'
	$if linux {
		assert @FILE.len > 0
	}
	assert greeter.speak() == 'hello'
	assert describe(value) == 'integer 42'
	assert phase == .ready
	assert identifier == 'sample'
	assert name == 'V'
	assert positive == 42
	assert letter == `V`
	assert raw == 'raw string'
}
