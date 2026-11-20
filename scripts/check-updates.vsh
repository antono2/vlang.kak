// Compare installed and published releases and record successful checks.
import os
import releaseinfo { Release, git_at, latest_release, release_commit, stable_version }
import setupconfig { make_directory }
import time

#include "@DIR/maintenance-signals.h"

fn C.kak_track_maintenance_signals() int
fn C.kak_maintenance_signal() int

const check_interval = 7 * 24 * time.hour

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

fn check(state string, background bool) ! {
	make_directory(state)!
	lock_path := state + '/check-lock'
	// Both paths use the same directory so editor-only and V installs serialize.
	os.mkdir(lock_path) or { return }
	defer { os.rmdir(lock_path) or { eprintln(err) } }
	if C.kak_maintenance_signal() != 0 {
		return
	}
	stamp := os.join_path(state, 'update-checked')
	if background && os.is_file(stamp)
		&& time.utc().unix() - os.file_last_mod_unix(stamp) < i64(check_interval / time.second) {
		return
	}
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

fn main() {
	if os.args.len !in [2, 3] || (os.args.len == 3 && os.args[2] != '--background') {
		eprintln('Usage: check-updates.sh [--background]')
		exit(2)
	}
	if C.kak_track_maintenance_signals() != 0 {
		eprintln('Could not register release check signal handlers.')
		exit(1)
	}
	mut status := 0
	check(os.args[1], os.args.len == 3) or {
		if C.kak_maintenance_signal() == 0 {
			eprintln(err)
		}
		status = 1
	}
	signum := C.kak_maintenance_signal()
	exit(if signum == 0 { status } else { 128 + signum })
}
