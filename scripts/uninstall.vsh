// Remove files still owned by a recorded installation and preserve user edits.
import crypto.sha256
import managedfiles { ManifestEntry, SettingsBlock, acquire_lock, active_executables, digest, read_manifest, release_lock, settings_block }
import os
import rand

const usage = 'Usage: v run scripts/uninstall.vsh [--prefix DIRECTORY] [--apply] [--verbose]
Default: preview. Personal settings, modified files and external tools are kept.'

const tool_names = ['kakoune', 'kak-lsp', 'vls', 'v']

struct Options {
mut:
	prefix  string
	apply   bool
	verbose bool
}

fn options(args []string) !Options {
	setting := os.getenv('VLANG_KAK_PREFIX')
	mut result := Options{
		prefix: if setting == '' {
			os.join_path(os.home_dir(), '.local')
		} else {
			setting
		}
	}
	for i := 0; i < args.len; i++ {
		match args[i] {
			'--apply' {
				result.apply = true
			}
			'--verbose' {
				result.verbose = true
			}
			'--prefix' {
				i++
				if i == args.len || args[i] == '' {
					return error('--prefix requires a directory.')
				}
				result.prefix = args[i]
			}
			else {
				return error('Unknown option: ${args[i]}')
			}
		}
	}
	return result
}

fn check_idle(prefix string, kakoune string) ! {
	if active_executables(prefix)!.len != 0 {
		return error('Managed tool processes are still running. Close them before removal.')
	}
	if !os.is_dir(kakoune) {
		return
	}
	for name in os.ls(kakoune)!.sorted() {
		restart := os.join_path(kakoune, name)
		if !name.starts_with('restart.') || !os.is_dir(restart) {
			continue
		}
		owner := (os.read_file(os.join_path(restart, 'owner-pid')) or {
			return error('Close older managed sessions before removal; inspect stale restart directories manually.')
		}).trim_space()
		if owner.len == 0 || !owner.bytes().all(it.is_digit()) || owner.int() <= 0 {
			return error('Invalid session owner marker; refusing removal.')
		}
		if os.is_dir('/proc/${owner}') {
			return error('Close managed Kakoune sessions before removal.')
		}
		println('Ignoring stale session marker: ${restart}')
	}
}

fn recognized(path string, prefix string, config string, roots []string) bool {
	if path in [prefix + '/bin/kak', prefix + '/bin/kak-v', prefix + '/bin/vls', prefix + '/bin/v',
		config + '/kak/autoload/vlang.kak', config + '/kak/autoload/vlang-site-runtime',
		config +
			'/kak/kakrc'] {
		return true
	}
	return roots.any(path == it || path.starts_with(it + '/'))
}

fn shared_runtime(config string, kakoune string) !string {
	autoload := os.join_path(config, 'kak', 'autoload')
	runtime := os.join_path(autoload, 'vlang-site-runtime')
	if !os.is_link(runtime) {
		return ''
	}
	other_entries := os.ls(autoload)!
	if other_entries.any(it !in ['vlang.kak', 'vlang-site-runtime']) {
		return os.real_path(os.join_path(kakoune, 'current'))
	}
	return ''
}

fn matches(path string, entry ManifestEntry, block SettingsBlock) !bool {
	kind := os.lstat(path)!.get_filetype()
	return match entry.kind {
		'file' { kind == .regular && digest(path)! == entry.identity }
		'link' { kind == .symbolic_link && os.readlink(path)! == entry.identity }
		'dir' { kind == .directory }
		'block' { block.owned != '' && sha256.hexhash(block.owned) == entry.identity }
		else { false }
	}
}

fn write_settings_copy(path string, content string, mode int) ! {
	mut file := os.open_file(path, 'w', 0o600)!
	defer { file.close() }
	if file.write_string(content)! != content.len {
		return error('Incomplete write to ${path}')
	}
	file.flush()
	os.chmod(path, mode)!
}

fn remove_block(path string, block SettingsBlock) ! {
	target := os.real_path(path)
	metadata := os.stat(target)!
	if metadata.get_filetype() != .regular || os.read_file(target)! != block.original {
		return error('Managed configuration changed during removal: ${path}')
	}
	backup := target + '.vlang-backup.' + rand.uuid_v4()
	next := target + '.vlang-next.' + rand.uuid_v4()
	defer { os.rm(next) or {} }
	mode := int(metadata.mode & 0o777)
	write_settings_copy(backup, block.original, mode)!
	write_settings_copy(next, block.remaining, mode)!
	if os.read_file(backup)! != block.original || os.read_file(next)! != block.remaining {
		return error('Could not verify the settings backup and replacement for ${path}')
	}
	os.rename_dir(next, target)!
}

fn remove_record(path string, kind string, block SettingsBlock) ! {
	match kind {
		'dir' { os.rmdir(path) or {} } // Leave nonempty directories and personal files.
		'block' { remove_block(path, block)! }
		else { os.rm(path)! }
	}
}

fn process_manifest(entries map[string]ManifestEntry, prefix string, config string, opts Options) !int {
	roots := tool_names.map(os.join_path(prefix, 'opt', 'vlang-' + it))
	kakoune := roots[0]
	runtime := shared_runtime(config, kakoune)!
	mut eligible := 0
	mut paths := entries.keys()
	paths.sort()
	paths.reverse_in_place()
	for path in paths {
		if !recognized(path, prefix, config, roots) {
			println('Keep unrecognized path: ${path}')
			continue
		}
		// Reject traversal and substituted ancestors before opening recorded files.
		parent := os.dir(path)
		if os.real_path(parent) != parent || os.norm_path(path) != path {
			println('Keep redirected path: ${path}')
			continue
		}
		if !os.exists(path) && !os.is_link(path) {
			continue
		}
		if runtime != '' {
			if path == config + '/kak/autoload/vlang-site-runtime' {
				println('Keep shared runtime required by other autoload entries: ${path}')
				continue
			}
			if path == runtime || path.starts_with(runtime + '/')
				|| path in [kakoune, kakoune + '/current', kakoune + '/releases'] {
				println('Keep shared Kakoune runtime: ${path}')
				continue
			}
		}
		entry := entries[path]
		mut block := SettingsBlock{}
		if entry.kind == 'block' && path == config + '/kak/kakrc' && os.is_file(path) {
			block = settings_block(path) or { SettingsBlock{} }
		}
		if !(matches(path, entry, block) or { false }) {
			println('Keep changed: ${path}')
			continue
		}
		eligible++
		if opts.verbose {
			println('Remove ${entry.kind}: ${path}')
		} else if entry.kind == 'block'
			|| (entry.kind == 'file' && path.starts_with(prefix + '/bin/'))
			|| (entry.kind == 'dir' && path in roots) {
			println('Eligible ${entry.kind}: ${path}')
		}
		if opts.apply { remove_record(path, entry.kind, block)! }
	}
	return eligible
}

fn uninstall(opts Options) ! {
	prefix := os.real_path(opts.prefix)
	state := os.join_path(prefix, 'opt', 'vlang-state')
	manifest := os.join_path(state, 'manifest.tsv')
	if os.real_path(state) != state || !os.is_file(manifest) || os.is_link(manifest) {
		return error('No ownership manifest. Rerun setup to record this installation before removal.')
	}
	mut identity := ''
	defer {
		if identity != '' { release_lock(state, identity) }
	}
	if opts.apply {
		identity = acquire_lock(state, 'uninstall')!
		check_idle(prefix, os.join_path(prefix, 'opt', 'vlang-kakoune'))!
	} else {
		lock_path := os.join_path(state, 'lock')
		if os.exists(lock_path) || os.is_link(lock_path) {
			return error('Installation lock is unavailable at ${lock_path}. Inspect it with scripts/lock.sh.')
		}
	}
	config := os.read_file(os.join_path(state, 'config-home'))!.trim_right('\n')
	if !os.is_abs_path(config) || os.real_path(config) != config {
		return error('Invalid recorded configuration directory: ${config}')
	}
	count := process_manifest(read_manifest(manifest)!, prefix, config, opts)!
	println('Eligible recorded entries: ${count} (use --verbose for every path)')
	println('Personal settings kept: ${config}/kak/vlang-user.kak')
	if opts.apply {
		println('Ownership record retained for inspecting any files that were kept.')
	} else {
		println('Preview only. Close managed sessions, then repeat with --apply.')
	}
}

if os.args[1..].any(it in ['--help', '-h']) {
	println(usage)
	exit(0)
}
opts := options(os.args[1..]) or {
	eprintln(err)
	eprintln(usage)
	exit(2)
}
uninstall(opts) or {
	eprintln(err)
	exit(1)
}
