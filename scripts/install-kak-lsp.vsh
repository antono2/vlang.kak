// Install a tagged kak-lsp release alongside the managed editor tools.
import archive.tar
import os
import rand
import strconv

const upstream = 'https://github.com/kakoune-lsp/kakoune-lsp'
const binary_name = 'kak-lsp'
const usage = 'Usage: v run scripts/install-kak-lsp.vsh [--latest | --version vMAJOR.MINOR.PATCH]
                                          [--prefix DIRECTORY]
Install kak-lsp under PREFIX/opt/vlang-kak-lsp.
Default: latest stable tag, PREFIX=$HOME/.local.'

struct Options {
mut:
	version string = 'latest'
	prefix  string
}

fn parse_args(args []string) !Options {
	mut options := Options{
		prefix: os.join_path(os.home_dir(), '.local')
	}
	for i := 0; i < args.len; i++ {
		name := args[i]
		if name == '--latest' {
			options.version = 'latest'
			continue
		}
		if name !in ['--version', '--prefix'] {
			return error('Unknown option: ${name}')
		}
		i++
		if i >= args.len || args[i] == '' {
			return error('Missing value for ${name}')
		}
		if name == '--version' {
			options.version = args[i]
		} else {
			options.prefix = args[i]
		}
	}
	return options
}

fn version_parts(tag string) ![]int {
	parts := tag.trim_string_left('v').split('.')
	if !tag.starts_with('v') || parts.len != 3 || !parts.all(it.len > 0
		&& it.bytes().all(it.is_digit())) {
		return error('Expected a stable kak-lsp tag such as v21.0.2.')
	}
	mut numbers := []int{cap: 3}
	for part in parts {
		numbers << strconv.atoi(part)!
	}
	return numbers
}

fn version_is_newer(candidate []int, previous []int) bool {
	for i in 0 .. 3 {
		if candidate[i] != previous[i] {
			return candidate[i] > previous[i]
		}
	}
	return false
}

fn resolve_version(requested string) !string {
	if requested != 'latest' {
		version_parts(requested)!
		return requested
	}
	git := os.find_abs_path_of_executable('git') or {
		return error('Git is required to resolve the latest kak-lsp tag.')
	}
	mut child := os.new_process(git)
	defer { child.close() }
	child.set_args(['ls-remote', '--tags', '--refs', upstream + '.git', 'v[0-9]*'])
	child.set_redirect_stdio()
	child.run()
	output := child.stdout_slurp()
	diagnostics := child.stderr_slurp()
	child.wait()
	if child.code != 0 {
		return error('Could not read kak-lsp tags: ${diagnostics.trim_space()}')
	}
	mut latest := ''
	mut latest_parts := [0, 0, 0]
	for line in output.split_into_lines() {
		tag := line.all_after_last('refs/tags/')
		parts := version_parts(tag) or { continue }
		if latest == '' || version_is_newer(parts, latest_parts) {
			latest = tag
			latest_parts = parts.clone()
		}
	}
	if latest == '' {
		return error('Could not resolve a stable kak-lsp release tag.')
	}
	return latest
}

fn run(executable string, args []string) ! {
	mut child := os.new_process(executable)
	defer { child.close() }
	child.set_args(args)
	child.wait()
	if child.code != 0 {
		return error('${executable} exited with status ${child.code}')
	}
}

struct ArchiveBinary implements tar.Reader {
mut:
	output   os.File
	size     u64
	written  u64
	selected bool
	failure  string
}

fn (mut binary ArchiveBinary) dir_block(mut _ tar.Read, _ u64) {}

fn (mut binary ArchiveBinary) file_block(mut block tar.Read, size u64) {
	if block.get_path() != binary_name {
		return
	}
	if binary.selected || size == 0 {
		binary.failure = 'Expected exactly one nonempty kak-lsp file in the release archive.'
		block.stop_early = true
		return
	}
	binary.selected = true
	binary.size = size
}

fn (mut binary ArchiveBinary) data_block(mut block tar.Read, data []u8, _ int) {
	if block.get_path() != binary_name {
		return
	}
	n := binary.output.write(data) or {
		binary.failure = err.msg()
		block.stop_early = true
		return
	}
	binary.written += u64(n)
}

fn (mut binary ArchiveBinary) other_block(mut _ tar.Read, _ string) {}

fn extract_binary(archive string, output string) ! {
	mut binary := &ArchiveBinary{
		output: os.create(output)!
	}
	defer { binary.output.close() }
	mut reader := tar.new_decompressor(tar.new_untar(binary))
	reader.read_all(os.read_bytes(archive)!)!
	if binary.failure != '' {
		return error(binary.failure)
	}
	if !binary.selected || binary.written != binary.size {
		return error('Release archive does not contain a complete regular kak-lsp file.')
	}
}

fn is_installed(path string) bool {
	return os.is_file(path) && os.is_executable(path)
}

fn install_release(releases string, version string) !string {
	release := os.join_path(releases, version)
	destination := os.join_path(release, 'bin', binary_name)
	if is_installed(destination) {
		return release
	}
	if os.exists(release) || os.is_link(release) {
		return error('Incomplete managed release at ${release}; move it aside and retry.')
	}
	curl := os.find_abs_path_of_executable('curl') or {
		return error('curl is required to download kak-lsp.')
	}
	stage := os.join_path(releases, '.stage-${version}.' + rand.uuid_v4())
	os.mkdir(stage, mode: 0o700)!
	defer { os.rmdir_all(stage) or {} }
	asset := 'kakoune-lsp-${version}-x86_64-unknown-linux-musl.tar.gz'
	archive := os.join_path(stage, asset)
	run(curl, ['--fail', '--location', '--retry', '3', '--output', archive,
		'${upstream}/releases/download/${version}/${asset}'])!
	bin := os.join_path(stage, 'bin')
	os.mkdir(bin)!
	staged_binary := os.join_path(bin, binary_name)
	extract_binary(archive, staged_binary)!
	os.rm(archive)!
	os.chmod(staged_binary, 0o755)!
	run(staged_binary, ['--version'])!
	os.write_file(os.join_path(stage, '.vlang-version'), version + '\n')!
	os.rename_dir(stage, release) or {
		// A concurrent installer may have published this version first.
		if !is_installed(destination) {
			return err
		}
	}
	return release
}

fn replace_link(target string, path string) ! {
	temporary := path + '.next-' + rand.uuid_v4()
	os.symlink(target, temporary)!
	defer { os.rm(temporary) or {} }
	// Rename the link itself, even if the target is a directory.
	os.rename_dir(temporary, path)!
}

fn install(options Options) ! {
	$if linux && amd64 {
		version := resolve_version(options.version)!
		os.mkdir_all(options.prefix)!
		root := os.join_path(os.real_path(options.prefix), 'opt', 'vlang-kak-lsp')
		releases := os.join_path(root, 'releases')
		os.mkdir_all(releases)!
		release := install_release(releases, version)!
		if os.getenv('VLANG_KAK_STAGE') == '1' {
			replace_link(release, os.join_path(root, 'candidate'))!
			println('Prepared ${release}')
			return
		}
		replace_link('releases/${version}', os.join_path(root, 'current'))!
		launcher := os.join_path(root, 'current', 'bin', binary_name)
		run(launcher, ['--version'])!
		println('kak-lsp ${version} is available at ${launcher}')
	} $else {
		return error('The binary installer supports Linux x86_64. Install kak-lsp with Cargo and configure its path manually.')
	}
}

args := os.args[1..]
if args in [['--help'], ['-h']] {
	println(usage)
	exit(0)
}
options := parse_args(args) or {
	eprintln(err)
	eprintln(usage)
	exit(2)
}
install(options) or {
	eprintln(err)
	exit(1)
}
