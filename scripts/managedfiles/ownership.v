// Read the shared ownership manifest and coordinate file maintenance.
module managedfiles

import crypto.sha256
import os
import strings

pub struct ManifestEntry {
pub:
	kind     string
	identity string
}

pub fn acquire_lock(state string, operation string) !string {
	path := os.join_path(state, 'lock')
	pid := os.getpid()
	process_stat := os.read_file('/proc/${pid}/stat')!
	birth := process_stat.all_after_last(') ').fields()[19] or {
		return error('Could not determine the installation lock owner start time.')
	}
	identity := '${pid} ${birth} ${operation}\n'
	os.mkdir(path) or {
		return error('Installation lock is unavailable at ${path}. Inspect it with scripts/lock.sh.')
	}
	owner := os.join_path(path, 'owner')
	os.write_file(owner, identity) or {
		os.rm(owner) or {}
		os.rmdir(path) or {}
		return err
	}
	return identity
}

pub fn release_lock(state string, identity string) {
	path := os.join_path(state, 'lock')
	owner := os.join_path(path, 'owner')
	if !os.is_link(path) && !os.is_link(owner) && (os.read_file(owner) or { '' }) == identity {
		os.rm(owner) or {
			eprintln(err)
			return
		}
		os.rmdir(path) or { eprintln('Kept unexpected lock contents at ${path}') }
	}
}

pub fn read_manifest(path string) !map[string]ManifestEntry {
	if !os.is_file(path) || os.is_link(path) {
		return error('Run setup to record ownership first.')
	}
	mut manifest := map[string]ManifestEntry{}
	for line in os.read_lines(path)! {
		fields := line.split('\t')
		if fields.len != 3 || fields[2] in manifest {
			return error('Invalid or duplicate ownership record in ${path}.')
		}
		manifest[fields[2]] = ManifestEntry{
			kind:     fields[0]
			identity: fields[1]
		}
	}
	return manifest
}

pub fn digest(path string) !string {
	mut file := os.open(path)!
	defer { file.close() }
	mut hash := sha256.new()
	mut buffer := []u8{len: 64 * 1024}
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
		hash.write(buffer[..count])!
	}
	return hash.sum([]u8{}).hex()
}

// Linux exposes one numeric directory for each running process.
pub fn process_ids() ![]string {
	return os.ls('/proc')!.filter(it != '' && it.bytes().all(it.is_digit()))
}

pub fn active_executables(prefix string) ![]string {
	mut active := []string{}
	for pid in process_ids()! {
		binary := os.readlink('/proc/${pid}/exe') or { continue }
		if binary.starts_with(prefix + '/opt/vlang-') {
			active << binary
		}
	}
	return active
}

const block_start = '# >>> vlang.kak managed >>>'
const block_end = '# <<< vlang.kak managed <<<'

pub struct SettingsBlock {
pub:
	original  string
	owned     string
	remaining string
}

pub fn settings_block(path string) !SettingsBlock {
	original := os.read_file(path)!
	mut inside := false
	mut owned := []string{}
	mut remaining := strings.new_builder(original.len)
	lines := original.split('\n')
	for index, line in lines {
		if line == block_start {
			if inside || owned.len > 0 {
				return error('Ambiguous managed block in ${path}.')
			}
			inside = true
		}
		if inside {
			owned << line
			if line == block_end {
				inside = false
			}
		} else {
			remaining.write_string(line)
			if index < lines.len - 1 {
				remaining.write_u8(`\n`)
			}
		}
	}
	if inside {
		return error('Incomplete or missing managed block in ${path}.')
	}
	if owned.len == 0 {
		return SettingsBlock{
			original:  original
			remaining: original
		}
	}
	return SettingsBlock{
		original:  original
		owned:     owned.join('\n') + '\n'
		remaining: remaining.str()
	}
}
