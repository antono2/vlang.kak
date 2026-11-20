// Preview or remove unchanged inactive releases under the installation lock.
import managedfiles { ManifestEntry, acquire_lock, active_executables, digest, read_manifest, release_lock }
import os
import time

const usage = 'Usage: v run scripts/cleanup.vsh [--prefix DIRECTORY] [--apply] [--cache]'
const tools = ['kakoune', 'kak-lsp', 'vls', 'v']
const cache_minimum_age = i64(31 * 24 * 60 * 60) // Match find -mtime +30.

struct Options {
mut:
	prefix string
	apply  bool
	cache  bool
}

struct SessionProtection {
	all_releases bool
	releases     []string
}

fn parse_args(args []string) !Options {
	setting := os.getenv('VLANG_KAK_PREFIX')
	mut options := Options{
		prefix: if setting == '' {
			os.join_path(os.home_dir(), '.local')
		} else {
			setting
		}
	}
	for i := 0; i < args.len; i++ {
		match args[i] {
			'--apply' {
				options.apply = true
			}
			'--cache' {
				options.cache = true
			}
			'--prefix' {
				i++
				if i >= args.len || args[i] == '' {
					return error('--prefix requires a directory.')
				}
				options.prefix = args[i]
			}
			else {
				return error('Unknown option: ${args[i]}')
			}
		}
	}
	return options
}

fn unchanged(path string, manifest map[string]ManifestEntry) !bool {
	record := manifest[path] or { return false }
	metadata := os.lstat(path)!
	return match metadata.get_filetype() {
		.symbolic_link {
			record.kind == 'link' && os.readlink(path)! == record.identity
		}
		.regular {
			record.kind == 'file' && digest(path)! == record.identity
		}
		.directory {
			if record.kind != 'dir' {
				return false
			}
			for name in os.ls(path)! {
				if !unchanged(os.join_path(path, name), manifest)! {
					return false
				}
			}
			true
		}
		else {
			false
		}
	}
}

fn protected_sessions(prefix string) !SessionProtection {
	root := os.join_path(prefix, 'opt', 'vlang-kakoune')
	mut releases := []string{}
	if os.is_dir(root) {
		for name in os.ls(root)! {
			path := os.join_path(root, name)
			if !name.starts_with('restart.') || !os.is_dir(path) {
				continue
			}
			owner := (os.read_file(os.join_path(path, 'owner-pid')) or { '' }).trim_space()
			if owner == '' || !owner.bytes().all(it.is_digit()) || owner.int() <= 0 {
				return SessionProtection{
					all_releases: true
				}
			}
			if os.is_dir('/proc/${owner}') {
				used := os.read_lines(os.join_path(path, 'tool-releases')) or {
					return SessionProtection{
						all_releases: true
					}
				}
				releases << used
			}
		}
	}
	return SessionProtection{
		releases: releases
	}
}

fn link_target(root string, link string) string {
	target := os.readlink(link) or { return '' }
	path := if os.is_abs_path(target) { target } else { os.join_path(root, target) }
	return os.real_path(path)
}

fn in_use(path string, sessions SessionProtection, active []string) bool {
	return sessions.all_releases || path in sessions.releases
		|| active.any(it.starts_with(path + '/'))
}

fn clean_releases(prefix string, state string, apply bool, manifest map[string]ManifestEntry) ! {
	unowned_file := os.join_path(state, 'unowned-releases')
	unowned := if os.exists(unowned_file) { os.read_lines(unowned_file)! } else { []string{} }
	active := active_executables(prefix)!
	sessions := protected_sessions(prefix)!
	for tool in tools {
		root := os.join_path(prefix, 'opt', 'vlang-' + tool)
		releases := os.join_path(root, 'releases')
		if !os.is_dir(releases) || os.real_path(releases) != releases {
			continue
		}
		previous := os.join_path(state, 'previous', 'opt', 'vlang-' + tool, 'current')
		protected := [link_target(root, os.join_path(root, 'current')),
			link_target(root, os.join_path(root, 'candidate')),
			link_target(root, previous)]
		for name in os.ls(releases)!.sorted() {
			path := os.join_path(releases, name)
			if name.starts_with('.') || !os.is_dir(path) || os.is_link(path) {
				continue
			}
			if path in unowned {
				println('Keep release without a trusted ownership baseline: ${path}')
			} else if path in protected {
				continue
			} else if in_use(path, sessions, active) {
				println('Keep release used by an active session: ${path}')
			} else if unchanged(path, manifest) or { false } {
				// A session may have started while the file hashes were checked.
				if apply && in_use(path, protected_sessions(prefix)!, active_executables(prefix)!) {
					println('Keep release used by an active session: ${path}')
					continue
				}
				println('Remove unused release: ${path}')
				if apply {
					os.rmdir_all(path)!
				}
			} else {
				println('Keep changed/unrecorded release: ${path}')
			}
		}
	}
}

fn is_compiled_helper(name string) bool {
	for prefix in ['explorer-', 'debug-', 'preferences-', 'windowing-', 'helper-dispatch-',
		'checkpoint-', 'history-', 'task-'] {
		if name.starts_with(prefix) && name.len > prefix.len {
			return name[prefix.len].is_digit()
		}
	}
	return false
}

fn clean_cache(state string, apply bool) ! {
	home := os.read_file(os.join_path(state, 'cache-home'))!.trim_right('\n')
	path := os.join_path(home, 'vlang.kak')
	if !os.is_abs_path(home) || !os.is_dir(path) || os.is_link(path) {
		return
	}
	cutoff := time.now().unix() - cache_minimum_age
	for name in os.ls(path)!.sorted() {
		helper := os.join_path(path, name)
		if is_compiled_helper(name) && !os.is_link(helper) && os.is_file(helper)
			&& os.is_executable(helper) && os.file_last_mod_unix(helper) <= cutoff {
			println('Remove old compiled helper (rebuilds on demand): ${helper}')
			if apply {
				os.rm(helper)!
			}
		}
	}
}

fn clean(options Options) ! {
	prefix := os.real_path(options.prefix)
	state := os.join_path(prefix, 'opt', 'vlang-state')
	if !os.is_dir(state) || os.real_path(state) != state {
		return error('Run setup to record ownership first.')
	}
	identity := acquire_lock(state, 'cleanup')!
	defer { release_lock(state, identity) }
	manifest := read_manifest(os.join_path(state, 'manifest.tsv'))!
	clean_releases(prefix, state, options.apply, manifest)!
	if options.cache {
		clean_cache(state, options.apply)!
	}
	if !options.apply {
		println('Preview only; repeat with --apply to clean up.')
	}
}

if os.args[1..].any(it in ['--help', '-h']) {
	println(usage)
	exit(0)
}
options := parse_args(os.args[1..]) or {
	eprintln(err)
	eprintln(usage)
	exit(2)
}
clean(options) or {
	eprintln(err)
	exit(1)
}
