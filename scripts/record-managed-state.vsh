// Record owned tool and editor files without adopting additions to existing releases.
import crypto.sha256
import managedfiles { ManifestEntry, digest, read_manifest, settings_block }
import os
import rand

const usage = 'Usage: v run scripts/record-managed-state.vsh PREFIX CONFIG_HOME [VLS_MODE]'
const tools = ['kakoune', 'kak-lsp', 'vls', 'v']
const markers = ['.vlang-version', '.vlang-commit', '.vlang-revision']

fn has_entry(path string) bool {
	return os.exists(path) || os.is_link(path)
}

fn record_path(path string, mut entries map[string]ManifestEntry) ! {
	if !has_entry(path) {
		return
	}
	metadata := os.lstat(path)!
	match metadata.get_filetype() {
		.symbolic_link {
			entries[path] = ManifestEntry{
				kind:     'link'
				identity: os.readlink(path)!
			}
		}
		.regular {
			entries[path] = ManifestEntry{
				kind:     'file'
				identity: digest(path)!
			}
		}
		.directory {
			entries[path] = ManifestEntry{
				kind:     'dir'
				identity: '-'
			}
		}
		else {}
	}
}

fn record_new_release(path string, mut entries map[string]ManifestEntry) ! {
	record_path(path, mut entries)!
	if os.is_dir(path) && !os.is_link(path) {
		for name in os.ls(path)! {
			record_new_release(os.join_path(path, name), mut entries)!
		}
	}
}

fn release_fingerprints(previous map[string]ManifestEntry, prefix string) map[string][]string {
	mut releases := map[string][]string{}
	for path, _ in previous {
		for tool in tools {
			parent := os.join_path(prefix, 'opt', 'vlang-' + tool, 'releases')
			if path.starts_with(parent + '/') {
				version := path[parent.len + 1..].all_before('/')
				if version != '' {
					releases[os.join_path(parent, version)] << path
				}
				break
			}
		}
	}
	return releases
}

fn record_tools(prefix string, previous map[string]ManifestEntry, unowned []string, mut entries map[string]ManifestEntry) ! {
	known := release_fingerprints(previous, prefix)
	for tool in tools {
		root := os.join_path(prefix, 'opt', 'vlang-' + tool)
		if !os.is_dir(root) || os.is_link(root) {
			continue
		}
		parent := os.join_path(root, 'releases')
		if os.is_dir(parent) && !os.is_link(parent) {
			for version in os.ls(parent)! {
				release := os.join_path(parent, version)
				if version.starts_with('.') || release in unowned || os.is_link(release)
					|| !markers.any(os.is_file(os.join_path(release, it))) {
					continue
				}
				if paths := known[release] {
					// Keep the old identity for paths that still exist, even after local edits.
					for path in paths {
						if os.real_path(os.dir(path)) == os.dir(path) && has_entry(path) {
							entries[path] = previous[path]
						}
					}
				} else {
					record_new_release(release, mut entries)!
				}
			}
		}
		for name in ['current', 'candidate', 'releases'] {
			record_path(os.join_path(root, name), mut entries)!
		}
		record_path(root, mut entries)!
	}
}

fn record_editor(prefix string, config string, vls_mode string, previous map[string]ManifestEntry, mut entries map[string]ManifestEntry) ! {
	isolated := os.join_path(prefix, 'opt', 'vlang-kakoune', 'ide-config')
	settings := os.join_path(isolated, 'kak', 'kakrc')
	mut integrated := false
	if os.is_file(settings) {
		integrated = '# vlang.kak integrate: true' in os.read_lines(settings)!
		for path in ['kak/kakrc', 'kak/autoload/vlang.kak', 'kak/autoload/vlang-site-runtime',
			'kak/autoload', 'kak'] {
			record_path(os.join_path(isolated, path), mut entries)!
		}
		record_path(isolated, mut entries)!
	}
	for name in ['kak', 'kak-v', 'v'] {
		path := os.join_path(prefix, 'bin', name)
		if os.is_file(path) {
			lines := os.read_lines(path)!
			if lines.any(it.starts_with('# vlang.kak managed ')) {
				record_path(path, mut entries)!
			}
		}
	}
	vls := os.join_path(prefix, 'bin', 'vls')
	managed := os.join_path(prefix, 'opt', 'vlang-vls', 'current', 'bin', 'vls')
	if os.is_link(vls)
		&& (vls_mode == 'external' || vls in previous || (os.exists(vls) && os.exists(managed)
		&& os.real_path(vls) == os.real_path(managed))) {
		record_path(vls, mut entries)!
	}
	if integrated {
		for name in ['vlang.kak', 'vlang-site-runtime'] {
			link := os.join_path(config, 'kak', 'autoload', name)
			if os.is_link(link) { record_path(link, mut entries)! }
		}
		personal := os.join_path(config, 'kak', 'kakrc')
		if os.is_file(personal) {
			block := settings_block(personal)!
			if block.owned != '' {
				entries[personal] = ManifestEntry{
					kind:     'block'
					identity: sha256.hexhash(block.owned)
				}
			}
		}
	}
}

fn write_state(state string, manifest string, config string, cache string) ! {
	staging := os.join_path(state, '.record-' + rand.uuid_v4())
	os.mkdir(staging, mode: 0o700)!
	defer { os.rmdir_all(staging) or {} }
	for name, value in {
		'config-home':  config + '\n'
		'cache-home':   cache + '\n'
		'manifest.tsv': manifest
	} {
		path := os.join_path(staging, name)
		os.write_file(path, value)!
		if os.read_file(path)! != value {
			return error('Incomplete ownership record: ${name}')
		}
	}
	for name in ['config-home', 'cache-home', 'manifest.tsv'] {
		os.rename_dir(os.join_path(staging, name), os.join_path(state, name))!
	}
}

fn record(prefix string, config string, vls_mode string) ! {
	if !os.is_abs_path(prefix) || !os.is_abs_path(config) || prefix.contains_any('\t\r\n')
		|| config.contains_any('\t\r\n') {
		return error('Use absolute installation and configuration paths without tabs or newlines.')
	}
	state := os.join_path(prefix, 'opt', 'vlang-state')
	os.mkdir_all(state)!
	if os.real_path(state) != os.norm_path(state) {
		return error('The ownership directory has been redirected: ${state}')
	}
	manifest_path := os.join_path(state, 'manifest.tsv')
	previous := if has_entry(manifest_path) {
		read_manifest(manifest_path)!
	} else {
		map[string]ManifestEntry{}
	}
	unowned_path := os.join_path(state, 'unowned-releases')
	unowned := if has_entry(unowned_path) { os.read_lines(unowned_path)! } else { []string{} }
	mut entries := map[string]ManifestEntry{}
	println('Recording managed file ownership...')
	record_tools(prefix, previous, unowned, mut entries)!
	record_editor(prefix, config, vls_mode, previous, mut entries)!

	mut rows := []string{cap: entries.len}
	for path, entry in entries {
		if path.contains_any('\t\r\n') || entry.identity.contains_any('\t\r\n') {
			return error('Tabs and newlines are unsupported in recorded paths and link targets.')
		}
		rows << '${entry.kind}\t${entry.identity}\t${path}\n'
	}
	rows.sort()
	cache := os.getenv('XDG_CACHE_HOME')
	write_state(state, rows.join(''), config, if cache == '' {
		os.join_path(os.home_dir(), '.cache')
	} else {
		cache
	})!
}

if os.args[1..].any(it in ['--help', '-h']) {
	println(usage)
	exit(0)
}
if os.args.len !in [3, 4] {
	eprintln(usage)
	exit(2)
}
record(os.args[1], os.args[2], os.args[3] or { '' }) or {
	eprintln(err)
	exit(1)
}
