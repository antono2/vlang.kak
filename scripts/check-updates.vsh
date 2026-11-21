// Compare installed and published releases and record successful checks.
import os
import releaseinfo { Release, git_at, latest_release, release_commit, stable_version }
import setupconfig { make_directory }
import time

#include "@DIR/maintenance-signals.h"

fn C.kak_track_maintenance_signals() int
fn C.kak_maintenance_signal() int

const check_interval = 7 * 24 * time.hour
const delivery_timeout = 5 * time.second
const delivery_poll = 20 * time.millisecond
const usage = 'Usage: check-updates.sh [--background | --notify SESSION CLIENT]'

struct Notification {
	session string
	client  string
}

fn update_status(release Release) !string {
	repo := os.dir(@DIR)
	installed := git_at(repo, ['describe', '--tags', '--always']) or { 'unknown' }
	head := git_at(repo, ['rev-parse', 'HEAD']) or { '' }
	target := release_commit(release)!
	if head != '' && head == target {
		return 'Up to date: ${release.tag}'
	}
	// git describe can include commits after a tag. Compare the base version
	// so a checkout already at or beyond that release does not get a prompt.
	base_tag := installed.all_before('-').all_before('+')
	installed_version := stable_version(base_tag) or {
		return available_status(release.tag, installed)
	}
	if installed_version < release.version {
		return available_status(release.tag, installed)
	}
	return 'Installed: ${installed}. Latest release: ${release.tag}.'
}

fn available_status(tag string, installed string) string {
	return 'Release available: ${tag} (installed: ${installed}). Use :v-update-release to install it.'
}

fn quote(value string) string {
	return "'" + value.replace("'", "''") + "'"
}

fn (target Notification) deliver(state string, lock_path string) ! {
	status_path := os.join_path(state, 'update-status')
	if !os.is_file(status_path) {
		return
	}
	status := os.read_file(status_path)!
	if !status.starts_with('Release available: ') {
		return
	}
	marker := os.join_path(state, 'update-notified')
	if os.is_file(marker) && os.read_file(marker)! == status {
		return
	}
	command := 'echo ' + quote(status.trim_right('\n'))
	kak := os.find_abs_path_of_executable('kak')!
	mut child := os.new_process(kak)
	defer { child.close() }
	child.set_args(['-p', target.session])
	child.set_redirect_stdio()
	child.run()
	os.signal_ignore(.pipe)
	child.stdin_write('evaluate-commands -client ${quote(target.client)} ${quote(command)}\n')
	os.fd_close(child.stdio_fd[0])
	child.stdio_fd[0] = -1
	deadline := time.sys_mono_now() + u64(delivery_timeout)
	for child.is_alive() {
		if time.sys_mono_now() >= deadline || C.kak_maintenance_signal() != 0 {
			child.signal_kill()
			child.status = .running
			child.wait()
			return error('Kakoune did not receive the release notification.')
		}
		child.stdout_read()
		child.stderr_read()
		time.sleep(delivery_poll)
	}
	child.wait()
	if child.code != 0 {
		return error('Kakoune did not receive the release notification (${child.code}).')
	}
	// Stage the exact bytes sent to the client while holding the shared check lock.
	staged := os.join_path(lock_path, 'notified')
	defer { os.rm(staged) or {} }
	os.write_file(staged, status)!
	os.rename_dir(staged, marker)!
}

fn refresh(state string, stamp string) ! {
	release := latest_release()!
	if C.kak_maintenance_signal() != 0 {
		return
	}
	status := update_status(release)!
	if C.kak_maintenance_signal() != 0 {
		return
	}
	os.write_file(os.join_path(state, 'update-status'), status + '\n')!
	os.write_file(stamp, time.utc().format_rfc3339() + '\n')!
	println(status)
}

fn check(state string, background bool, target Notification) ! {
	make_directory(state)!
	lock_path := state + '/check-lock'
	// Both paths use the same directory so editor-only and V installs serialize.
	os.mkdir(lock_path) or { return }
	defer { os.rmdir(lock_path) or { eprintln(err) } }
	if C.kak_maintenance_signal() != 0 {
		return
	}
	stamp := os.join_path(state, 'update-checked')
	fresh := background && os.is_file(stamp)
		&& time.utc().unix() - os.file_last_mod_unix(stamp) < i64(check_interval / time.second)
	if !fresh {
		refresh(state, stamp)!
	}
	if target.session != '' && C.kak_maintenance_signal() == 0 {
		target.deliver(state, lock_path)!
	}
}

fn main() {
	mode := os.args[2] or { '' }
	notify := os.args.len == 5 && mode == '--notify' && os.args[3] != '' && os.args[4] != ''
	if !notify && os.args.len != 2 && !(os.args.len == 3 && mode == '--background') {
		eprintln(usage)
		exit(2)
	}
	target := if notify { Notification{os.args[3], os.args[4]} } else { Notification{} }
	if C.kak_track_maintenance_signals() != 0 {
		eprintln('Could not register release check signal handlers.')
		exit(1)
	}
	mut status := 0
	check(os.args[1], mode != '', target) or {
		if C.kak_maintenance_signal() == 0 {
			eprintln(err)
		}
		status = 1
	}
	signum := C.kak_maintenance_signal()
	exit(if signum == 0 { status } else { 128 + signum })
}
