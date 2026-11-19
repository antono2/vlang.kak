// Download and verify the pinned terminal releases used by the host tests.
import crypto.sha256
import os
import rand
import releasetest

const usage = 'Usage: v run tests/install-pane-hosts.vsh ARTIFACT_DIRECTORY (Linux x86_64)'
const hash_chunk_bytes = 64 * 1024
const digest_hex_length = 64
const download_retries = '3'

struct Tool {
	name       string
	archive    string
	url        string
	digest     string
	executable string
}

fn required(values map[string]string, name string) !string {
	value := values[name]
	if value == '' {
		return error('Missing ${name} in pane-hosts.env')
	}
	return value
}

fn tool_pins() ![]Tool {
	values := releasetest.read_assignments(os.join_path(@DIR, 'pane-hosts.env'))!
	zellij := required(values, 'ZELLIJ_VERSION')!
	wezterm := required(values, 'WEZTERM_VERSION')!
	kitty := required(values, 'KITTY_VERSION')!
	return [
		Tool{
			name:       'zellij'
			archive:    'zellij.tar.gz'
			url:        'https://github.com/zellij-org/zellij/releases/download/v${zellij}/zellij-x86_64-unknown-linux-musl.tar.gz'
			digest:     required(values, 'ZELLIJ_SHA256')!
			executable: 'zellij/zellij'
		},
		Tool{
			name:       'wezterm'
			archive:    'wezterm.tar.xz'
			url:        'https://github.com/wezterm/wezterm/releases/download/${wezterm}/wezterm-${wezterm}.Debian12.tar.xz'
			digest:     required(values, 'WEZTERM_SHA256')!
			executable: 'wezterm/wezterm/usr/bin/wezterm'
		},
		Tool{
			name:       'kitty'
			archive:    'kitty.txz'
			url:        'https://github.com/kovidgoyal/kitty/releases/download/v${kitty}/kitty-${kitty}-x86_64.txz'
			digest:     required(values, 'KITTY_SHA256')!
			executable: 'kitty/bin/kitty'
		},
	]
}

fn checksum(path string) !string {
	mut file := os.open(path)!
	defer { file.close() }
	mut digest := sha256.new()
	mut buffer := []u8{len: hash_chunk_bytes}
	for {
		count := file.read(mut buffer) or {
			if err is os.Eof {
				break
			}
			return err
		}
		if count == 0 {
			break
		}
		digest.write(buffer[..count])!
	}
	return digest.sum([]u8{}).hex()
}

fn verified_archive(root string, tool Tool) ! {
	if tool.digest.len != digest_hex_length || !tool.digest.bytes().all((it >= `0` && it <= `9`)
		|| (it >= `a` && it <= `f`)) {
		return error('Invalid SHA-256 for ${tool.archive}')
	}
	archive := os.join_path(root, tool.archive)
	if os.is_dir(archive) {
		return error('Expected an archive file at ${archive}')
	}
	if os.is_file(archive) && checksum(archive)! == tool.digest {
		println('${archive}: OK (cached)')
		return
	}
	// Keep the previous cache entry intact until a complete download passes verification.
	part := archive + '.part-' + rand.uuid_v4()
	defer { os.rm(part) or {} }
	releasetest.run_inherited('curl', ['--fail', '--location', '--retry', download_retries, '--output',
		part, tool.url])!
	actual := checksum(part)!
	if actual != tool.digest {
		return error('SHA-256 mismatch for ${tool.archive}: expected ${tool.digest}, got ${actual}')
	}
	os.rename(part, archive)!
	println('${archive}: OK')
}

fn install(requested string) ! {
	$if !( linux && amd64 ) {
		return error('Pinned pane-host test downloads require Linux x86_64')
	}
	os.mkdir_all(requested)!
	root := os.real_path(requested)
	tools := tool_pins()!
	for tool in tools {
		verified_archive(root, tool)!
	}
	mut path_dirs := []string{cap: tools.len}
	for tool in tools {
		target := os.join_path(root, tool.name)
		os.mkdir_all(target)!
		// tar recognizes gzip and xz from the verified archives.
		releasetest.run_inherited('tar', ['-xf', os.join_path(root, tool.archive), '-C', target])!
		binary := os.join_path(root, tool.executable)
		releasetest.run_inherited(binary, ['--version'])!
		path_dirs << os.dir(binary)
	}
	println('PATH directories: ' + path_dirs.join(':'))
}

fn run(args []string) ! {
	if args.len == 0 || args in [['--help'], ['-h'], ['']] {
		println(usage)
		return
	}
	if args.len != 1 {
		return error_with_code(usage, 2)
	}
	install(args[0])!
}

run(os.args[1..]) or {
	eprintln(err)
	exit(if err.code() == 2 { 2 } else { 1 })
}
