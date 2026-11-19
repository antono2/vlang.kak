// Read Linux process identities and recover only a verifiably stale lock.
module managedfiles

import os
import strconv

#include <errno.h>
#include <signal.h>

fn C.kill(int, int) int

// The fields after comm begin at field 3. Linux exposes starttime at field 22.
const process_start_index = 22 - 3
// kill takes a signed Linux pid_t.
const max_pid = u64(0x7fffffff)

pub fn process_start(pid int) !string {
	record := os.read_file('/proc/${pid}/stat')!
	return record.all_after_last(') ').fields()[process_start_index] or {
		return error('Could not determine the installation lock owner start time.')
	}
}

pub enum LockStatus {
	absent  = 0
	active  = 1
	unknown = 2
	stale   = 3
}

pub struct LockReport {
pub:
	status  LockStatus
	message string
}

fn unknown_lock(path string) LockReport {
	return LockReport{
		status:  .unknown
		message: 'Installation lock: unknown owner (${path}); inspect running operations before removing an empty legacy lock.'
	}
}

pub fn inspect_lock(prefix string, path string) LockReport {
	state := os.dir(path)
	if os.real_path(state) != state || os.is_link(state) {
		return LockReport{
			status:  .unknown
			message: 'Installation lock: redirected state directory; inspect ${state} manually.'
		}
	}
	metadata := os.lstat(path) or {
		if err.code() == C.ENOENT {
			return LockReport{
				status:  .absent
				message: 'Installation lock: none'
			}
		}
		return unknown_lock(path)
	}
	if metadata.get_filetype() == .symbolic_link {
		return LockReport{
			status:  .unknown
			message: 'Installation lock: redirected path; inspect ${path} manually.'
		}
	}
	owner := os.join_path(path, 'owner')
	if metadata.get_filetype() != .directory || os.is_link(owner) || !os.is_file(owner) {
		return unknown_lock(path)
	}
	fields := (os.read_file(owner) or { return unknown_lock(path) }).fields()
	if fields.len != 3 || !fields[0].bytes().all(it >= `0` && it <= `9`)
		|| !fields[1].bytes().all(it >= `0` && it <= `9`) {
		return unknown_lock(path)
	}
	pid_value := strconv.parse_uint(fields[0], 10, 32) or { return unknown_lock(path) }
	if pid_value == 0 || pid_value > max_pid {
		return unknown_lock(path)
	}
	pid := int(pid_value)
	strconv.parse_uint(fields[1], 10, 64) or { return unknown_lock(path) }
	operation := fields[2]
	actual := process_start(pid) or { '' }
	if actual == fields[1] {
		return LockReport{
			status:  .active
			message: 'Installation lock: active ${operation} (PID ${pid}). Wait for it to finish.'
		}
	}
	if actual == '' && (C.kill(pid, 0) == 0 || C.errno != C.ESRCH) {
		return LockReport{
			status:  .unknown
			message: 'Installation lock: owner PID ${pid} is running but its identity cannot be checked.'
		}
	}
	return LockReport{
		status:  .stale
		message: "Installation lock: stale ${operation} (PID ${pid}). Run scripts/lock.sh --prefix '${prefix}' --clear-stale."
	}
}

pub fn clear_stale_lock(prefix string, path string) ! {
	initial := inspect_lock(prefix, path)
	if initial.status == .absent {
		println('No installation lock.')
		return
	}
	if initial.status != .stale {
		println(initial.message)
		return error('Refusing to clear an active or unknown lock.')
	}
	recovery := os.join_path(path, 'recovery')
	os.mkdir(recovery) or { return error('Another lock recovery is active.') }
	mut held := true
	defer {
		if held {
			os.rmdir(recovery) or {}
		}
	}
	report := inspect_lock(prefix, path)
	println(report.message)
	if report.status != .stale {
		return error('Refusing to clear an active or unknown lock.')
	}
	entries := os.ls(path)!
	if entries.len != 2 || 'owner' !in entries || 'recovery' !in entries {
		return error('Unexpected lock contents; inspect manually.')
	}
	os.rm(os.join_path(path, 'owner'))!
	os.rmdir(recovery)!
	held = false
	os.rmdir(path)!
	println('Stale lock cleared. Run health.sh before retrying the operation.')
}
